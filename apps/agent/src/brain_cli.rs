//! Output formatting and query sanitization for the `mci-brain` CLI.
//!
//! Kept as a library module so tests can exercise formatting without
//! standing up a `SQLCipher` file. The bin entry-point (`mci_brain.rs`)
//! delegates all display logic here.

use mci_brain::{BrainStats, Event, EventRecord};
use std::fmt::Write as _;

use crate::wall_clock::format_unix_ms;

/// Convert µs-since-epoch to a human-readable UTC string.
#[must_use]
pub fn format_ts_us(ts_us: u64) -> String {
    format_unix_ms(u128::from(ts_us) / 1000)
}

/// Human-readable `BrainStats` block.
#[must_use]
pub fn format_stats_human(s: &BrainStats) -> String {
    let mut out = format!("Events: {}\n", s.event_count);
    match s.oldest_ts_us {
        Some(ts) => {
            let _ = writeln!(out, "Oldest: {} ({})", format_ts_us(ts), ts);
        }
        None => out.push_str("Oldest: (none)\n"),
    }
    match s.newest_ts_us {
        Some(ts) => {
            let _ = writeln!(out, "Newest: {} ({})", format_ts_us(ts), ts);
        }
        None => out.push_str("Newest: (none)\n"),
    }
    // V2-P6 graph surface (Phase-6 close).
    let _ = writeln!(out, "Entities: {}", s.entity_count);
    let _ = writeln!(out, "Entity mentions: {}", s.entity_mention_count);
    let _ = writeln!(out, "Identities: {}", s.entity_identity_count);
    let _ = writeln!(out, "Episode links: {}", s.episode_edge_count);
    out
}

/// Machine-readable JSON `BrainStats`.
#[must_use]
pub fn format_stats_json(s: &BrainStats) -> String {
    serde_json::json!({
        "event_count": s.event_count,
        "oldest_ts_us": s.oldest_ts_us,
        "newest_ts_us": s.newest_ts_us,
        "entity_count": s.entity_count,
        "entity_mention_count": s.entity_mention_count,
        "entity_identity_count": s.entity_identity_count,
        "episode_edge_count": s.episode_edge_count,
    })
    .to_string()
}

/// One-line human-readable event record (pipe-separated).
///
/// Layout: `event:<ID> | <TIMESTAMP> | <APP> | <TITLE> | <URL> | <SNIPPET>`
#[must_use]
pub fn format_event_record_human(r: &EventRecord) -> String {
    let app = r.app_bundle_id.as_deref().unwrap_or("-");
    let title = r.window_title.as_deref().unwrap_or("-");
    let url = r.url.as_deref().unwrap_or("-");
    let snippet = r.text_snippet.replace('\n', " ");
    format!(
        "{} | {} | {} | {} | {} | {}",
        r.event_id,
        format_ts_us(r.ts_us),
        app,
        title,
        url,
        snippet
    )
}

/// JSONL-formatted event record. Shape matches [`EventRecord`] fields.
#[must_use]
pub fn format_event_record_jsonl(r: &EventRecord) -> String {
    serde_json::json!({
        "event_id": r.event_id.0,
        "ts_us": r.ts_us,
        "app_bundle_id": r.app_bundle_id,
        "window_title": r.window_title,
        "url": r.url,
        "text_snippet": r.text_snippet,
    })
    .to_string()
}

/// Full human-readable event (for `show`).
#[must_use]
pub fn format_event_human(e: &Event) -> String {
    let mut out = format!("Event: event:{}\n", e.id.0);
    let _ = writeln!(out, "Timestamp: {} ({})", format_ts_us(e.ts_us), e.ts_us);
    let _ = writeln!(
        out,
        "App: {}",
        e.app_bundle_id.as_deref().unwrap_or("(none)")
    );
    let _ = writeln!(
        out,
        "Window: {}",
        e.window_title.as_deref().unwrap_or("(none)")
    );
    let _ = writeln!(out, "URL: {}", e.url.as_deref().unwrap_or("(none)"));
    let _ = writeln!(out, "Summary: {}", e.summary.as_deref().unwrap_or("(none)"));
    let _ = writeln!(
        out,
        "Entities: {}",
        e.entities.as_deref().unwrap_or("(none)")
    );
    out.push_str("Text:\n");
    out.push_str(&e.text);
    if !e.text.ends_with('\n') {
        out.push('\n');
    }
    out
}

/// JSONL-formatted full event (for `show --json` and `export --format jsonl`).
#[must_use]
pub fn format_event_jsonl(e: &Event) -> String {
    serde_json::json!({
        "event_id": e.id.0,
        "ts_us": e.ts_us,
        "app_bundle_id": e.app_bundle_id,
        "window_title": e.window_title,
        "url": e.url,
        "text": e.text,
        "summary": e.summary,
        "entities": e.entities,
        "cascade_reason": e.cascade_reason,
        "keyframe_blob": e.keyframe_blob,
    })
    .to_string()
}

/// CSV header for event export.
#[must_use]
pub fn format_event_csv_header() -> &'static str {
    "event_id,ts_us,app_bundle_id,window_title,url,text,summary,entities"
}

/// CSV row for one event. Fields are escaped per RFC 4180.
#[must_use]
pub fn format_event_csv_row(e: &Event) -> String {
    fn esc(s: &str) -> String {
        if s.contains(',') || s.contains('\n') || s.contains('"') {
            format!("\"{}\"", s.replace('"', "\"\""))
        } else {
            s.to_owned()
        }
    }
    fn opt(value: Option<&String>) -> String {
        value.map_or_else(String::new, |text| esc(text))
    }
    format!(
        "{},{},{},{},{},{},{},{}",
        e.id.0,
        e.ts_us,
        opt(e.app_bundle_id.as_ref()),
        opt(e.window_title.as_ref()),
        opt(e.url.as_ref()),
        esc(&e.text),
        opt(e.summary.as_ref()),
        opt(e.entities.as_ref()),
    )
}

/// Sanitize a raw user query for FTS5.
///
/// Wraps each whitespace-delimited token in double-quotes so hyphens
/// are treated literally (avoids the FTS5 hyphen-as-NOT-operator trap).
/// Strips pre-existing double-quotes to prevent FTS5 syntax injection.
#[must_use]
pub fn sanitize_fts5_query(raw: &str) -> String {
    let stripped = raw.replace('"', "");
    let tokens: Vec<&str> = stripped.split_whitespace().collect();
    if tokens.is_empty() {
        return String::new();
    }
    tokens
        .iter()
        .map(|t| format!("\"{t}\""))
        .collect::<Vec<_>>()
        .join(" ")
}
