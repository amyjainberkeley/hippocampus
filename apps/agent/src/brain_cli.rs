//! Output formatting and query sanitization for the `mci-brain` CLI.
//!
//! Kept as a library module so tests can exercise formatting without
//! standing up a SQLCipher file. The bin entry-point (`mci_brain.rs`)
//! delegates all display logic here.

use mci_brain::{BrainStats, Event, EventRecord};

use crate::wall_clock::format_unix_ms;

/// Convert µs-since-epoch to a human-readable UTC string.
pub fn format_ts_us(ts_us: u64) -> String {
    format_unix_ms(u128::from(ts_us) / 1000)
}

/// Human-readable `BrainStats` block.
pub fn format_stats_human(s: &BrainStats) -> String {
    let mut out = format!("Events: {}\n", s.event_count);
    match s.oldest_ts_us {
        Some(ts) => out.push_str(&format!("Oldest: {} ({})\n", format_ts_us(ts), ts)),
        None => out.push_str("Oldest: (none)\n"),
    }
    match s.newest_ts_us {
        Some(ts) => out.push_str(&format!("Newest: {} ({})\n", format_ts_us(ts), ts)),
        None => out.push_str("Newest: (none)\n"),
    }
    out
}

/// Machine-readable JSON `BrainStats`.
pub fn format_stats_json(s: &BrainStats) -> String {
    serde_json::json!({
        "event_count": s.event_count,
        "oldest_ts_us": s.oldest_ts_us,
        "newest_ts_us": s.newest_ts_us,
    })
    .to_string()
}

/// One-line human-readable event record (pipe-separated).
///
/// Layout: `event:<ID> | <TIMESTAMP> | <APP> | <TITLE> | <URL> | <SNIPPET>`
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
pub fn format_event_human(e: &Event) -> String {
    let mut out = format!("Event: event:{}\n", e.id.0);
    out.push_str(&format!(
        "Timestamp: {} ({})\n",
        format_ts_us(e.ts_us),
        e.ts_us
    ));
    out.push_str(&format!(
        "App: {}\n",
        e.app_bundle_id.as_deref().unwrap_or("(none)")
    ));
    out.push_str(&format!(
        "Window: {}\n",
        e.window_title.as_deref().unwrap_or("(none)")
    ));
    out.push_str(&format!("URL: {}\n", e.url.as_deref().unwrap_or("(none)")));
    out.push_str(&format!(
        "Summary: {}\n",
        e.summary.as_deref().unwrap_or("(none)")
    ));
    out.push_str(&format!(
        "Entities: {}\n",
        e.entities.as_deref().unwrap_or("(none)")
    ));
    out.push_str("Text:\n");
    out.push_str(&e.text);
    if !e.text.ends_with('\n') {
        out.push('\n');
    }
    out
}

/// JSONL-formatted full event (for `show --json` and `export --format jsonl`).
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
pub fn format_event_csv_header() -> &'static str {
    "event_id,ts_us,app_bundle_id,window_title,url,text,summary,entities"
}

/// CSV row for one event. Fields are escaped per RFC 4180.
pub fn format_event_csv_row(e: &Event) -> String {
    fn esc(s: &str) -> String {
        if s.contains(',') || s.contains('\n') || s.contains('"') {
            format!("\"{}\"", s.replace('"', "\"\""))
        } else {
            s.to_owned()
        }
    }
    fn opt(o: &Option<String>) -> String {
        o.as_deref().map_or_else(String::new, esc)
    }
    format!(
        "{},{},{},{},{},{},{},{}",
        e.id.0,
        e.ts_us,
        opt(&e.app_bundle_id),
        opt(&e.window_title),
        opt(&e.url),
        esc(&e.text),
        opt(&e.summary),
        opt(&e.entities),
    )
}

/// Sanitize a raw user query for FTS5.
///
/// Wraps each whitespace-delimited token in double-quotes so hyphens
/// are treated literally (avoids the FTS5 hyphen-as-NOT-operator trap).
/// Strips pre-existing double-quotes to prevent FTS5 syntax injection.
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
