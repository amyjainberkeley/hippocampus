//! Import Codex session rollouts into the brain.
//!
//! # The format
//!
//! Codex writes `~/.codex/sessions/YYYY/MM/DD/rollout-<stamp>-<id>.jsonl`.
//! Every line is `{"timestamp", "ordinal", "type", "payload"}`. Line 1 is a
//! `session_meta` whose payload carries `id` and `cwd`. A `turn_context`
//! may carry a fresh `cwd` mid-session. The conversation itself is in
//! `response_item` records: `payload.type == "message"` with a `role` and
//! `content[].text`; `function_call` (`shell`, `exec_command`, `js`, ...);
//! `custom_tool_call` (`apply_patch`, `exec`); plus `reasoning`, the tool
//! outputs and `agent_message`, none of which are stored.
//!
//! Measured on this machine (182 files): 26,552 of the 29,700 tool calls
//! were the `exec` JavaScript runtime, and every Codex `git commit` seen
//! was inside it as `tools.exec_command({cmd: "git commit ..."})`. So the
//! mutating-call rule in `docs/handoff/CONTRACT.md` section 1 (`shell` and
//! `apply_patch`) is applied to `exec_command` and to commands embedded in
//! `exec` / `js` code as well; otherwise no Codex commit would ever be
//! recorded.
//!
//! # Subagent threads
//!
//! 158 of those 182 files are subagent threads: `session_meta` carries a
//! `parent_thread_id`, and 52 of them are forks that replay the parent's
//! history from line 2 onward. Importing them would repeat parent
//! conversations dozens of times and bury the person's 214 real messages
//! under 617 agent-to-agent instructions. They are skipped, the same way
//! Claude Code's nested `subagents/` transcripts are, and counted in
//! `files_skipped_subagent`. The contract does not say this; it is an
//! addition recorded here and in the commit that introduced it.

use std::path::{Path, PathBuf};
use std::time::Instant;

use mci_brain::SqlCipherBrainStore;

use crate::transcript::{
    self, import_file, import_files, is_injected_user_text, is_mutating_shell, parse_ts_us,
    read_first_line, tool_line, write_event, Agent, EventContext, FileOutcome, ImportError,
    ImportStats, Role,
};

/// Default rollout root.
#[must_use]
pub fn default_codex_root() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join(".codex/sessions")
}

/// Per-file state carried between lines.
#[derive(Debug, Default, Clone)]
struct SessionState {
    session: String,
    cwd: String,
    branch: String,
}

impl SessionState {
    /// Read what a `session_meta` payload says. Returns `true` if the
    /// payload marks a subagent thread.
    fn apply_meta(&mut self, payload: &serde_json::Value) -> bool {
        if let Some(id) = payload["id"].as_str() {
            self.session = id.to_string();
        }
        if let Some(cwd) = payload["cwd"].as_str() {
            self.cwd = cwd.to_string();
        }
        if let Some(branch) = payload["git"]["branch"].as_str() {
            self.branch = branch.to_string();
        }
        payload
            .get("parent_thread_id")
            .is_some_and(|v| !v.is_null())
    }
}

/// Join the visible text of a `message` payload.
fn message_text(payload: &serde_json::Value) -> String {
    let Some(blocks) = payload["content"].as_array() else {
        return payload["content"]
            .as_str()
            .map_or("", str::trim)
            .to_string();
    };
    let mut parts: Vec<&str> = Vec::new();
    for b in blocks {
        if matches!(
            b["type"].as_str(),
            Some("input_text" | "output_text" | "text")
        ) {
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

/// `cmd` string literals passed to `exec_command(...)` inside JavaScript
/// run by the `exec` / `js` tools. A small hand parser: after each
/// `exec_command` find the `cmd` key, expect a quoted literal, unescape
/// `\"`, `\\`, `\n`, `\t`. Anything it cannot follow is skipped.
fn embedded_exec_commands(code: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = code;
    while let Some(pos) = rest.find("exec_command") {
        rest = &rest[pos + "exec_command".len()..];
        let Some(cpos) = rest.find("cmd") else {
            break;
        };
        let after = rest[cpos + 3..]
            .trim_start_matches(['"', '\''])
            .trim_start();
        let Some(after) = after.strip_prefix(':') else {
            continue;
        };
        let after = after.trim_start();
        let mut chars = after.char_indices();
        let Some((_, quote)) = chars.next() else {
            break;
        };
        if !matches!(quote, '"' | '\'' | '`') {
            continue;
        }
        let mut literal = String::new();
        let mut escaped = false;
        let mut end = after.len();
        for (idx, c) in chars {
            if escaped {
                literal.push(match c {
                    'n' => '\n',
                    't' => '\t',
                    other => other,
                });
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == quote {
                end = idx + c.len_utf8();
                break;
            } else {
                literal.push(c);
            }
        }
        if !literal.trim().is_empty() {
            out.push(literal);
        }
        rest = &after[end..];
    }
    out
}

/// Parse `arguments`, which Codex serializes as a JSON string.
fn function_arguments(payload: &serde_json::Value) -> serde_json::Value {
    match &payload["arguments"] {
        serde_json::Value::String(s) => serde_json::from_str(s).unwrap_or(serde_json::Value::Null),
        other => other.clone(),
    }
}

/// A `command` that is either a string or an argv array.
fn command_string(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(s) => Some(s.clone()),
        serde_json::Value::Array(items) => Some(
            items
                .iter()
                .filter_map(serde_json::Value::as_str)
                .collect::<Vec<_>>()
                .join(" "),
        ),
        _ => None,
    }
}

/// Paths an `apply_patch` input touches, in order.
fn apply_patch_paths(input: &str) -> Vec<&str> {
    input
        .lines()
        .filter_map(|line| {
            let line = line.trim_end();
            line.strip_prefix("*** Update File: ")
                .or_else(|| line.strip_prefix("*** Add File: "))
                .or_else(|| line.strip_prefix("*** Delete File: "))
                .map(str::trim)
        })
        .filter(|p| !p.is_empty())
        .collect()
}

/// One body line per mutating call in a `function_call` or
/// `custom_tool_call` payload.
fn mutating_tool_lines(kind: &str, payload: &serde_json::Value) -> Vec<String> {
    let name = payload["name"].as_str().unwrap_or("");
    let mut lines = Vec::new();
    let mut push_shell = |tool: &str, cmd: &str| {
        if is_mutating_shell(cmd) {
            lines.push(tool_line(tool, cmd));
        }
    };
    match (kind, name) {
        ("function_call", "shell" | "shell_command") => {
            let args = function_arguments(payload);
            if let Some(cmd) = command_string(&args["command"]) {
                push_shell(name, &cmd);
            }
        }
        ("function_call", "exec_command") => {
            let args = function_arguments(payload);
            if let Some(cmd) = args["cmd"].as_str() {
                push_shell(name, cmd);
            }
        }
        ("function_call", "js") => {
            let args = function_arguments(payload);
            for cmd in embedded_exec_commands(args["code"].as_str().unwrap_or("")) {
                push_shell("exec_command", &cmd);
            }
        }
        ("custom_tool_call", "exec") => {
            for cmd in embedded_exec_commands(payload["input"].as_str().unwrap_or("")) {
                push_shell("exec_command", &cmd);
            }
        }
        ("custom_tool_call", "apply_patch") => {
            for path in apply_patch_paths(payload["input"].as_str().unwrap_or("")) {
                lines.push(tool_line("apply_patch", path));
            }
        }
        _ => {}
    }
    lines
}

/// Every `.jsonl` under `root`, recursively, sorted by path.
fn rollout_files(root: &Path) -> Result<Vec<PathBuf>, ImportError> {
    fn walk(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                if depth < 6 {
                    walk(&path, depth + 1, out);
                }
            } else if path.is_file() && path.extension().is_some_and(|e| e == "jsonl") {
                out.push(path);
            }
        }
    }
    if !root.is_dir() {
        return Err(ImportError::Root(format!(
            "{}: not a directory",
            root.display()
        )));
    }
    let mut files = Vec::new();
    walk(root, 0, &mut files);
    files.sort();
    Ok(files)
}

/// Import one rollout file, resuming from its cursor.
///
/// # Errors
/// [`ImportError::Store`] if a write fails.
pub fn import_rollout_file(
    store: &SqlCipherBrainStore,
    path: &Path,
    deadline: Option<Instant>,
    stats: &mut ImportStats,
) -> Result<FileOutcome, ImportError> {
    // Line 1 is the session_meta. Read it on its own so a resumed pass,
    // which starts past it, still knows the session id and cwd, and so a
    // subagent thread is recognized before anything is parsed.
    let mut session = SessionState::default();
    if let Ok(first) = read_first_line(path) {
        if let Ok(rec) = serde_json::from_str::<serde_json::Value>(&first) {
            if rec["type"] == "session_meta" && session.apply_meta(&rec["payload"]) {
                stats.files_skipped_subagent += 1;
                return Ok(FileOutcome::Done);
            }
        }
    }

    let src_path = path.to_string_lossy().into_owned();
    import_file(store, path, deadline, stats, |line_no, line, stats| {
        let Ok(rec) = serde_json::from_str::<serde_json::Value>(line) else {
            stats.malformed_lines += 1;
            return Ok(true);
        };
        stats.records_read += 1;
        let payload = &rec["payload"];
        match rec["type"].as_str().unwrap_or("") {
            "session_meta" => {
                // Only the first one describes this file. A later one is a
                // forked parent's history being replayed; that file was
                // already skipped above, so this is defensive.
                if session.session.is_empty() {
                    session.apply_meta(payload);
                }
                return Ok(true);
            }
            "turn_context" => {
                if let Some(cwd) = payload["cwd"].as_str() {
                    if !cwd.is_empty() {
                        session.cwd = cwd.to_string();
                    }
                }
                return Ok(true);
            }
            "response_item" => {}
            _ => return Ok(true),
        }

        let kind = payload["type"].as_str().unwrap_or("");
        let (role, body) = match kind {
            "message" => {
                let role = match payload["role"].as_str() {
                    Some("user") => Role::User,
                    Some("assistant") => Role::Assistant,
                    _ => {
                        // `developer` and anything else: not conversation.
                        stats.skipped_no_text += 1;
                        return Ok(true);
                    }
                };
                let text = message_text(payload);
                if text.is_empty() {
                    stats.skipped_no_text += 1;
                    return Ok(true);
                }
                if role == Role::User && is_injected_user_text(&text) {
                    stats.skipped_injected += 1;
                    return Ok(true);
                }
                (role, text)
            }
            "function_call" | "custom_tool_call" => {
                let lines = mutating_tool_lines(kind, payload);
                if lines.is_empty() {
                    return Ok(true);
                }
                (Role::Tool, lines.join("\n"))
            }
            _ => return Ok(true),
        };
        let Some(ts_us) = rec["timestamp"].as_str().and_then(parse_ts_us) else {
            stats.skipped_no_text += 1;
            return Ok(true);
        };
        let ctx = EventContext {
            agent: Agent::Codex,
            label: transcript::basename(&session.cwd),
            cwd: &session.cwd,
            branch: &session.branch,
            session: &session.session,
            src_path: &src_path,
            line_no,
        };
        write_event(store, &ctx.event(role, ts_us, &body), role, stats)?;
        Ok(true)
    })
}

/// Import every rollout under `root` (recursively, `YYYY/MM/DD/*.jsonl`),
/// resuming each file from its stored cursor, stopping at `deadline`.
///
/// # Errors
/// [`ImportError::Root`] if the root cannot be listed;
/// [`ImportError::Store`] if a write fails.
pub fn import_codex_incremental(
    store: &SqlCipherBrainStore,
    root: &Path,
    deadline: Option<Instant>,
    mut on_progress: impl FnMut(&ImportStats),
) -> Result<ImportStats, ImportError> {
    let mut stats = ImportStats::default();
    let files = rollout_files(root)?;
    import_files(&files, deadline, &mut stats, |path, stats| {
        let outcome = import_rollout_file(store, path, deadline, stats)?;
        on_progress(stats);
        Ok(outcome)
    })?;
    Ok(stats)
}

/// Import every rollout under `root`, incrementally.
///
/// # Errors
/// See [`import_codex_incremental`].
pub fn import_codex(
    store: &SqlCipherBrainStore,
    root: &Path,
    on_progress: impl FnMut(&ImportStats),
) -> Result<ImportStats, ImportError> {
    import_codex_incremental(store, root, None, on_progress)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_text_joins_visible_blocks_only() {
        let p = serde_json::json!({
            "role": "assistant",
            "content": [
                {"type": "output_text", "text": " first "},
                {"type": "input_image", "image_url": "data:..."},
                {"type": "text", "text": "second"},
            ]
        });
        assert_eq!(message_text(&p), "first\nsecond");
    }

    #[test]
    fn exec_commands_are_pulled_out_of_javascript() {
        let code = r#"const r = await tools.exec_command({cmd:"git commit -m \"chore: x\"","workdir":"/w"});
text(r);
const s = await tools.exec_command({ "cmd": 'ls -la', yield_time_ms: 10 });
const t = await tools.exec_command({cmd: `git push origin main`});"#;
        assert_eq!(
            embedded_exec_commands(code),
            vec![
                "git commit -m \"chore: x\"",
                "ls -la",
                "git push origin main",
            ]
        );
        assert!(embedded_exec_commands("nothing here").is_empty());
        assert!(embedded_exec_commands("exec_command(").is_empty());
    }

    #[test]
    fn apply_patch_lists_each_changed_path() {
        let input = "*** Begin Patch\n*** Update File: /a/b.rs\n@@\n-x\n+y\n*** Add File: /c.md\n+hi\n*** Delete File: /d\n*** End Patch\n";
        assert_eq!(apply_patch_paths(input), vec!["/a/b.rs", "/c.md", "/d"]);
    }

    #[test]
    fn tool_lines_cover_each_codex_call_shape() {
        let shell = serde_json::json!({
            "name": "shell",
            "arguments": "{\"command\":[\"bash\",\"-lc\",\"git push origin feat\"]}"
        });
        assert_eq!(
            mutating_tool_lines("function_call", &shell),
            vec!["shell bash -lc git push origin feat"]
        );
        let exec_command = serde_json::json!({
            "name": "exec_command",
            "arguments": "{\"cmd\":\"git status\",\"yield_time_ms\":1}"
        });
        assert!(mutating_tool_lines("function_call", &exec_command).is_empty());
        let exec = serde_json::json!({
            "name": "exec",
            "input": "const r = await tools.exec_command({cmd:\"git commit -m 'x'\"});"
        });
        assert_eq!(
            mutating_tool_lines("custom_tool_call", &exec),
            vec!["exec_command git commit -m 'x'"]
        );
        let patch = serde_json::json!({
            "name": "apply_patch",
            "input": "*** Begin Patch\n*** Update File: /p/q.rs\n*** End Patch"
        });
        assert_eq!(
            mutating_tool_lines("custom_tool_call", &patch),
            vec!["apply_patch /p/q.rs"]
        );
        let js = serde_json::json!({
            "name": "js",
            "arguments": "{\"code\":\"await tools.exec_command({cmd:\\\"git tag v1\\\"})\"}"
        });
        assert_eq!(
            mutating_tool_lines("function_call", &js),
            vec!["exec_command git tag v1"]
        );
    }

    #[test]
    fn session_meta_marks_subagents() {
        let mut s = SessionState::default();
        let top = serde_json::json!({"id": "t1", "cwd": "/w", "git": {}});
        assert!(!s.apply_meta(&top));
        assert_eq!(s.session, "t1");
        assert_eq!(s.cwd, "/w");
        let sub = serde_json::json!({"id": "s1", "cwd": "/w", "parent_thread_id": "t1"});
        assert!(s.apply_meta(&sub));
    }
}
