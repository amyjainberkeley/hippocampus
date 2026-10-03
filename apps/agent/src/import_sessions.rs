//! Import Claude Code session transcripts into the brain.
//!
//! # Why this exists
//!
//! Claude Code writes every session to `~/.claude/projects/<project>/<uuid>.jsonl`.
//! On this machine that is hundreds of files and hundreds of megabytes of
//! real working history, and there is no way to search across it. `/resume`
//! lists sessions per project; `grep` returns raw wire records.
//!
//! Grep is bad here for a specific, measurable reason. In a sample of those
//! files the content blocks were 302 `tool_use`, 302 `tool_result`, 147
//! `thinking` and only 85 `text`. More than three quarters of what you match
//! on is machinery, not conversation. Importing the `text` blocks, plus one
//! short line per call that changed something, is the whole trick.
//!
//! What lands, per `docs/handoff/CONTRACT.md` section 1:
//!
//! - `user` and `assistant` events: the human-visible `text` blocks.
//! - `tool` events: one per assistant record holding a mutating call
//!   (`Edit`, `Write`, `MultiEdit`, `NotebookEdit`, or a `Bash` command that
//!   commits, pushes, checks out, merges, rebases, tags, stashes, opens a
//!   PR, or publishes). One line per call, `{tool} {primary_arg}`, cut at
//!   200 characters. Enough to say which files a session touched and which
//!   commits it made, without storing the diff.
//!
//! Deliberately dropped:
//!
//! - `thinking`: reasoning the user never saw and did not choose to keep.
//! - `tool_result`, non-mutating `tool_use`: file dumps and command output.
//! - `image`: no text to index.
//! - Harness-injected "user" records (`<system-reminder>`, `<task-notification>`,
//!   `# Files mentioned by the user`, `[Request interrupted`), `isSidechain`
//!   and `isMeta` records: not something the person typed.
//! - Nested `subagents/` transcripts: agent-to-agent traffic.
//!
//! Every file is resumable through `import_cursors`, so the second run over
//! an unchanged root reads nothing and writes nothing.

use std::path::{Path, PathBuf};
use std::time::Instant;

use mci_brain::SqlCipherBrainStore;

use crate::transcript::{
    self, import_file, import_files, is_injected_user_text, is_mutating_shell, parse_ts_us,
    tool_line, write_event, Agent, EventContext, FileOutcome, Role,
};
pub use crate::transcript::{ImportError, ImportStats};

/// Default transcript root.
#[must_use]
pub fn default_transcript_root() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join(".claude/projects")
}

/// Turn `-Users-amy-hippo-work` into something a human recognizes.
///
/// Claude Code encodes the project directory by replacing `/` with `-`, which
/// is lossy: the original path cannot be recovered, because a directory may
/// legitimately contain a hyphen. The last segment is the useful label, so
/// take it rather than guessing where the slashes were. Only a fallback:
/// every record carries `cwd`, whose last component is the real label.
fn project_label(dir_name: &str) -> String {
    dir_name
        .rsplit('-')
        .find(|s| !s.is_empty())
        .unwrap_or(dir_name)
        .to_string()
}

/// Pull the human-readable text out of one message, dropping machinery.
fn text_of(message: &serde_json::Value) -> String {
    let content = &message["content"];
    if let Some(s) = content.as_str() {
        return s.trim().to_string();
    }
    let Some(blocks) = content.as_array() else {
        return String::new();
    };
    let mut parts: Vec<&str> = Vec::new();
    for b in blocks {
        // Only `text`. See the module docs for why the rest is dropped.
        if b["type"] == "text" {
            if let Some(t) = b["text"].as_str() {
                let t = t.trim();
                if !t.is_empty() {
                    parts.push(t);
                }
            }
        }
    }
    parts.join("\n")
}

/// One body line per mutating `tool_use` block in a message, in order.
fn mutating_tool_lines(message: &serde_json::Value) -> Vec<String> {
    let Some(blocks) = message["content"].as_array() else {
        return Vec::new();
    };
    let mut lines = Vec::new();
    for b in blocks {
        if b["type"] != "tool_use" {
            continue;
        }
        let name = b["name"].as_str().unwrap_or("");
        let input = &b["input"];
        let primary = match name {
            "Edit" | "Write" | "MultiEdit" => input["file_path"].as_str(),
            "NotebookEdit" => input["notebook_path"].as_str(),
            "Bash" => input["command"]
                .as_str()
                .filter(|cmd| is_mutating_shell(cmd)),
            _ => None,
        };
        if let Some(arg) = primary {
            lines.push(tool_line(name, arg));
        }
    }
    lines
}

/// Session files sitting directly in each project directory, sorted.
///
/// Claude Code also writes nested `subagents/` and `subagents/workflows/`
/// transcripts, and those are deliberately skipped: they are
/// machine-to-machine traffic, not conversations the user had. Importing
/// them would bury real answers under agent chatter.
fn session_files(root: &Path) -> Result<Vec<(String, PathBuf)>, ImportError> {
    let projects = std::fs::read_dir(root)
        .map_err(|e| ImportError::Root(format!("{}: {e}", root.display())))?;
    let mut files: Vec<(String, PathBuf)> = Vec::new();
    for p in projects.flatten() {
        if !p.path().is_dir() {
            continue;
        }
        let label = project_label(&p.file_name().to_string_lossy());
        let Ok(entries) = std::fs::read_dir(p.path()) else {
            continue;
        };
        for f in entries.flatten() {
            let path = f.path();
            if path.is_file() && path.extension().is_some_and(|e| e == "jsonl") {
                files.push((label.clone(), path));
            }
        }
    }
    // Sorted so a run is reproducible and progress reads sensibly.
    files.sort_by(|a, b| a.1.cmp(&b.1));
    Ok(files)
}

/// Import one Claude Code session file, resuming from its cursor.
///
/// # Errors
/// [`ImportError::Store`] if a write fails.
pub fn import_session_file(
    store: &SqlCipherBrainStore,
    path: &Path,
    fallback_label: &str,
    deadline: Option<Instant>,
    stats: &mut ImportStats,
) -> Result<FileOutcome, ImportError> {
    let src_path = path.to_string_lossy().into_owned();
    import_file(store, path, deadline, stats, |line_no, line, stats| {
        let Ok(rec) = serde_json::from_str::<serde_json::Value>(line) else {
            stats.malformed_lines += 1;
            return Ok(true);
        };
        stats.records_read += 1;

        let kind = rec["type"].as_str().unwrap_or("");
        let role = match kind {
            "user" => Role::User,
            "assistant" => Role::Assistant,
            _ => return Ok(true),
        };
        if rec["isSidechain"].as_bool() == Some(true) {
            stats.skipped_sidechain += 1;
            return Ok(true);
        }
        if rec["isMeta"].as_bool() == Some(true) {
            stats.skipped_meta += 1;
            return Ok(true);
        }

        let text = text_of(&rec["message"]);
        let tool_lines = if role == Role::Assistant {
            mutating_tool_lines(&rec["message"])
        } else {
            Vec::new()
        };
        if text.is_empty() && tool_lines.is_empty() {
            stats.skipped_no_text += 1;
            return Ok(true);
        }
        let Some(ts_us) = rec["timestamp"].as_str().and_then(parse_ts_us) else {
            stats.skipped_no_text += 1;
            return Ok(true);
        };

        let cwd = rec["cwd"].as_str().unwrap_or("");
        let label = if cwd.is_empty() {
            fallback_label
        } else {
            transcript::basename(cwd)
        };
        let ctx = EventContext {
            agent: Agent::ClaudeCode,
            label,
            cwd,
            branch: rec["gitBranch"].as_str().unwrap_or(""),
            session: rec["sessionId"].as_str().unwrap_or(""),
            src_path: &src_path,
            line_no,
        };

        if !text.is_empty() {
            if role == Role::User && is_injected_user_text(&text) {
                stats.skipped_injected += 1;
            } else {
                write_event(store, &ctx.event(role, ts_us, &text), role, stats)?;
            }
        }
        if !tool_lines.is_empty() {
            let body = tool_lines.join("\n");
            write_event(
                store,
                &ctx.event(Role::Tool, ts_us, &body),
                Role::Tool,
                stats,
            )?;
        }
        Ok(true)
    })
}

/// Import every session transcript under `root`, resuming each file from
/// its stored cursor, stopping at `deadline` if one is given.
///
/// # Errors
/// [`ImportError::Root`] if the transcript directory cannot be read;
/// [`ImportError::Store`] if a write fails.
pub fn import_sessions_incremental(
    store: &SqlCipherBrainStore,
    root: &Path,
    deadline: Option<Instant>,
    mut on_progress: impl FnMut(&ImportStats),
) -> Result<ImportStats, ImportError> {
    let mut stats = ImportStats::default();
    let files = session_files(root)?;
    let paths: Vec<PathBuf> = files.iter().map(|(_, p)| p.clone()).collect();
    let labels: std::collections::HashMap<&Path, &str> = files
        .iter()
        .map(|(label, p)| (p.as_path(), label.as_str()))
        .collect();
    import_files(&paths, deadline, &mut stats, |path, stats| {
        let label = labels.get(path).copied().unwrap_or("");
        let outcome = import_session_file(store, path, label, deadline, stats)?;
        on_progress(stats);
        Ok(outcome)
    })?;
    Ok(stats)
}

/// Import every session transcript under `root`.
///
/// Incremental: a file already imported to its end is not read again
/// unless it changed. Call [`crate::transcript::ImportStats`]'s
/// `files_unchanged` to see how many were skipped. To force a full
/// re-import, clear the cursors first with
/// `SqlCipherBrainStore::clear_import_cursors`.
///
/// # Errors
/// [`ImportError::Root`] if the transcript directory cannot be read;
/// [`ImportError::Store`] if a write fails.
pub fn import_sessions(
    store: &SqlCipherBrainStore,
    root: &Path,
    on_progress: impl FnMut(&ImportStats),
) -> Result<ImportStats, ImportError> {
    import_sessions_incremental(store, root, None, on_progress)
}

#[cfg(test)]
mod tests {
    use super::*;
    use mci_core::crypto::DbKey;

    #[test]
    fn only_text_blocks_survive() {
        let m = serde_json::json!({
            "content": [
                {"type": "thinking", "thinking": "internal reasoning"},
                {"type": "text", "text": "the actual answer"},
                {"type": "tool_use", "name": "Bash", "input": {"command": "ls"}},
                {"type": "tool_result", "content": "a huge file dump"},
            ]
        });
        assert_eq!(text_of(&m), "the actual answer");
    }

    #[test]
    fn plain_string_content_is_supported() {
        let m = serde_json::json!({ "content": "just a string" });
        assert_eq!(text_of(&m), "just a string");
    }

    #[test]
    fn a_message_of_pure_machinery_yields_nothing() {
        // This is the load-bearing case. If tool traffic leaked in, the
        // index would be the same noise that makes grep useless.
        let m = serde_json::json!({
            "content": [
                {"type": "tool_use", "name": "Read", "input": {"file_path": "/x"}},
                {"type": "thinking", "thinking": "x"},
            ]
        });
        assert!(text_of(&m).is_empty(), "tool traffic must not be indexed");
        assert!(
            mutating_tool_lines(&m).is_empty(),
            "a Read is not a mutation"
        );
    }

    #[test]
    fn mutating_calls_become_one_line_each() {
        let m = serde_json::json!({
            "content": [
                {"type": "tool_use", "name": "Read", "input": {"file_path": "/r"}},
                {"type": "tool_use", "name": "Edit", "input": {"file_path": "/a/b.rs", "old_string": "x", "new_string": "y"}},
                {"type": "tool_use", "name": "Bash", "input": {"command": "git status"}},
                {"type": "tool_use", "name": "Bash", "input": {"command": "git add -A && git commit -m \"feat: z\""}},
                {"type": "tool_use", "name": "NotebookEdit", "input": {"notebook_path": "/n.ipynb"}},
                {"type": "tool_use", "name": "Write", "input": {"file_path": "/w.md", "content": "..."}},
            ]
        });
        assert_eq!(
            mutating_tool_lines(&m),
            vec![
                "Edit /a/b.rs",
                "Bash git add -A && git commit -m \"feat: z\"",
                "NotebookEdit /n.ipynb",
                "Write /w.md",
            ]
        );
    }

    #[test]
    fn nested_subagent_transcripts_are_not_imported() {
        // Claude Code writes agent-to-agent transcripts under
        // subagents/ and subagents/workflows/. They are not conversations
        // the user had, and importing them buries real answers under
        // machine chatter.
        let dir = tempfile::TempDir::new().expect("tempdir");
        let proj = dir.path().join("-Users-someone");
        std::fs::create_dir_all(proj.join("subagents/workflows/wf_x")).expect("mkdir");

        let rec = |t: &str| {
            format!(
                "{{\"type\":\"user\",\"timestamp\":\"2024-01-01T00:00:00Z\",\"cwd\":\"/x\",\
                 \"gitBranch\":\"main\",\"sessionId\":\"s\",\
                 \"message\":{{\"content\":[{{\"type\":\"text\",\"text\":\"{t}\"}}]}}}}\n"
            )
        };
        std::fs::write(proj.join("session.jsonl"), rec("real conversation")).expect("w1");
        std::fs::write(
            proj.join("subagents/workflows/wf_x/agent.jsonl"),
            rec("agent chatter"),
        )
        .expect("w2");

        let key = DbKey::generate().expect("csprng");
        let store = SqlCipherBrainStore::new(&dir.path().join("b.sqlite"), &key).expect("store");
        let stats = import_sessions(&store, dir.path(), |_| {}).expect("import");

        assert_eq!(stats.files_scanned, 1, "only the top-level session counts");
        assert_eq!(stats.events_written, 1);

        // Second pass over the same root: nothing to read, nothing to write.
        let again = import_sessions(&store, dir.path(), |_| {}).expect("import");
        assert_eq!(again.files_scanned, 0);
        assert_eq!(again.files_unchanged, 1);
        assert_eq!(again.events_written, 0);
    }

    #[test]
    fn project_label_takes_the_last_segment() {
        assert_eq!(project_label("-Users-amy-hippo-work"), "work");
        assert_eq!(project_label("-Users-amy"), "amy");
        assert_eq!(project_label("plain"), "plain");
    }
}
