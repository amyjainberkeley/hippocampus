//! Import Claude Code session transcripts into the brain.
//!
//! # Why this exists
//!
//! Claude Code writes every session to `~/.claude/projects/<project>/<uuid>.jsonl`.
//! On this machine that is 77 files and 76 MB of real working history, and
//! there is no way to search across it. `/resume` lists sessions per project;
//! `grep` returns raw wire records.
//!
//! Grep is bad here for a specific, measurable reason. In a sample of those
//! files the content blocks were 161 `tool_use`, 160 `tool_result`, 123
//! `thinking` and only 124 `text`. More than three quarters of what you match
//! on is machinery, not conversation. Importing **only** the `text` blocks is
//! the whole trick: it is why searching this beats grepping it.
//!
//! Deliberately dropped:
//!
//! - `thinking` — reasoning the user never saw and did not choose to keep.
//! - `tool_use` / `tool_result` — file dumps and command output. Enormous,
//!   low signal, and the reason raw grep is useless here.
//! - `image` — no text to index.
//!
//! Everything lands as an ordinary `Event`, so recall, entity extraction,
//! episode segmentation and the MCP server all work on it unchanged.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore};

/// What an import pass did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ImportStats {
    /// Session files opened.
    pub files_scanned: u64,
    /// JSONL records parsed.
    pub records_read: u64,
    /// Events written to the brain.
    pub events_written: u64,
    /// Records with no usable text (pure tool traffic, thinking, images).
    pub skipped_no_text: u64,
    /// Lines that were not valid JSON. A truncated tail is normal for a
    /// session still being written, so this is counted, not fatal.
    pub malformed_lines: u64,
}

/// Errors an import can surface.
#[derive(Debug, thiserror::Error)]
pub enum ImportError {
    /// The transcript root does not exist or cannot be listed.
    #[error("import: cannot read {0}")]
    Root(String),
    /// A store write failed fatally.
    #[error("import: store: {0}")]
    Store(String),
}

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
/// take it rather than guessing where the slashes were.
fn project_label(dir_name: &str) -> String {
    dir_name
        .rsplit('-')
        .find(|s| !s.is_empty())
        .unwrap_or(dir_name)
        .to_string()
}

/// RFC3339 to microseconds since epoch.
///
/// Hand-rolled to avoid taking a date dependency for one field. Returns
/// `None` on anything unexpected, so a malformed record is skipped rather
/// than silently stamped with the wrong time and sorted into the wrong day.
fn parse_ts_us(ts: &str) -> Option<u64> {
    // Expect YYYY-MM-DDTHH:MM:SS[.fff]Z
    let b = ts.as_bytes();
    if b.len() < 20 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' {
        return None;
    }
    let num = |a: usize, z: usize| ts.get(a..z)?.parse::<i64>().ok();
    let (y, mo, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (h, mi, s) = (num(11, 13)?, num(14, 16)?, num(17, 19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) {
        return None;
    }
    if !(0..=23).contains(&h) || !(0..=59).contains(&mi) || !(0..=60).contains(&s) {
        return None;
    }
    // Days from civil epoch (Howard Hinnant's algorithm).
    let y2 = if mo <= 2 { y - 1 } else { y };
    let era = if y2 >= 0 { y2 } else { y2 - 399 } / 400;
    let yoe = y2 - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let secs = days * 86_400 + h * 3600 + mi * 60 + s;
    u64::try_from(secs).ok()?.checked_mul(1_000_000)
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

/// Import every session transcript under `root`.
///
/// Only transcripts sitting directly in a project directory are imported.
/// Claude Code also writes nested `subagents/` and `subagents/workflows/`
/// transcripts, and those are deliberately skipped: they are machine-to-machine
/// traffic, not conversations the user had. On this machine that is the
/// difference between 50 session files and 77 total, and importing the other
/// 27 would bury real answers under agent chatter.
///
/// # Errors
/// [`ImportError::Root`] if the transcript directory cannot be read;
/// [`ImportError::Store`] if a write fails.
pub fn import_sessions(
    store: &SqlCipherBrainStore,
    root: &Path,
    mut on_progress: impl FnMut(&ImportStats),
) -> Result<ImportStats, ImportError> {
    let mut stats = ImportStats::default();

    let projects = std::fs::read_dir(root)
        .map_err(|e| ImportError::Root(format!("{}: {e}", root.display())))?;

    // Sorted so a run is reproducible and progress reads sensibly.
    let mut files: BTreeMap<String, Vec<PathBuf>> = BTreeMap::new();
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
            if path.extension().is_some_and(|e| e == "jsonl") {
                files.entry(label.clone()).or_default().push(path);
            }
        }
    }

    for (label, paths) in &files {
        for path in paths {
            let Ok(content) = std::fs::read_to_string(path) else {
                continue;
            };
            stats.files_scanned += 1;

            for line in content.lines() {
                if line.trim().is_empty() {
                    continue;
                }
                let Ok(rec) = serde_json::from_str::<serde_json::Value>(line) else {
                    stats.malformed_lines += 1;
                    continue;
                };
                stats.records_read += 1;

                let kind = rec["type"].as_str().unwrap_or("");
                if kind != "user" && kind != "assistant" {
                    continue;
                }
                let text = text_of(&rec["message"]);
                if text.is_empty() {
                    stats.skipped_no_text += 1;
                    continue;
                }
                let Some(ts_us) = rec["timestamp"].as_str().and_then(parse_ts_us) else {
                    stats.skipped_no_text += 1;
                    continue;
                };

                let branch = rec["gitBranch"].as_str().unwrap_or("");
                let cwd = rec["cwd"].as_str().unwrap_or("");
                let title = format!("{label} · {kind}");

                // The same context header the capture path prepends
                // (ADR-0010 §1.3), so Tier-1 extraction and FTS5 see the
                // project and branch, not only the prose.
                let header = format!("[app=claude-code | title={title} | url={cwd}#{branch}]\n");

                let event = Event {
                    id: EventId(0),
                    ts_us,
                    app_bundle_id: Some("com.anthropic.claude-code".to_string()),
                    window_title: Some(title),
                    url: if cwd.is_empty() {
                        None
                    } else {
                        Some(cwd.to_string())
                    },
                    text: format!("{header}{text}"),
                    embedding: None,
                    summary: None,
                    entities: None,
                    episode_id: None,
                    cascade_reason: 0,
                    keyframe_blob: None,
                    tab_id: None,
                };
                store
                    .put_event(&event)
                    .map_err(|e| ImportError::Store(e.to_string()))?;
                stats.events_written += 1;
            }
            on_progress(&stats);
        }
    }

    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;
    use mci_core::crypto::DbKey;

    #[test]
    fn timestamps_parse_to_microseconds() {
        // 2024-01-01T00:00:00Z = 1_704_067_200 s
        assert_eq!(
            parse_ts_us("2024-01-01T00:00:00.000Z"),
            Some(1_704_067_200_000_000)
        );
        assert_eq!(parse_ts_us("1970-01-01T00:00:00Z"), Some(0));
    }

    #[test]
    fn malformed_timestamps_are_rejected_not_guessed() {
        // A wrong timestamp is worse than a dropped record: it sorts the
        // event into the wrong day and quietly corrupts any review of it.
        assert_eq!(parse_ts_us(""), None);
        assert_eq!(parse_ts_us("not-a-date"), None);
        assert_eq!(parse_ts_us("2024-13-01T00:00:00Z"), None, "month 13");
        assert_eq!(parse_ts_us("2024-01-32T00:00:00Z"), None, "day 32");
        assert_eq!(parse_ts_us("2024-01-01T25:00:00Z"), None, "hour 25");
    }

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
                {"type": "tool_use", "name": "Read"},
                {"type": "thinking", "thinking": "x"},
            ]
        });
        assert!(text_of(&m).is_empty(), "tool traffic must not be indexed");
    }

    #[test]
    fn nested_subagent_transcripts_are_not_imported() {
        // Claude Code writes agent-to-agent transcripts under
        // subagents/ and subagents/workflows/. They are not conversations
        // the user had, and importing them buries real answers under
        // machine chatter.
        let dir = std::env::temp_dir().join("mci-import-nesting-test");
        let _ = std::fs::remove_dir_all(&dir);
        let proj = dir.join("-Users-someone");
        std::fs::create_dir_all(proj.join("subagents/workflows/wf_x")).expect("mkdir");

        let rec = |t: &str| {
            format!(
                r#"{{"type":"user","timestamp":"2024-01-01T00:00:00Z","cwd":"/x","gitBranch":"main","message":{{"content":[{{"type":"text","text":"{t}"}}]}}}}"#
            )
        };
        std::fs::write(proj.join("session.jsonl"), rec("real conversation")).expect("w1");
        std::fs::write(
            proj.join("subagents/workflows/wf_x/agent.jsonl"),
            rec("agent chatter"),
        )
        .expect("w2");

        let key = DbKey::generate().expect("csprng");
        let store = SqlCipherBrainStore::new(&dir.join("b.sqlite"), &key).expect("store");
        let stats = import_sessions(&store, &dir, |_| {}).expect("import");

        assert_eq!(stats.files_scanned, 1, "only the top-level session counts");
        assert_eq!(stats.events_written, 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn project_label_takes_the_last_segment() {
        assert_eq!(project_label("-Users-amy-hippo-work"), "work");
        assert_eq!(project_label("-Users-amy"), "amy");
        assert_eq!(project_label("plain"), "plain");
    }
}
