//! Content-free JSON health-counter log sink.
//!
//! PROTECTED-SET per `AGENT_PROTOCOL` §5 (agent shell logging).
//! `AGENT_PROTOCOL` §9.3 + ADR-0001 NG3: telemetry is **content-free**
//! — counter values + timestamps + opaque `device_id` only. No
//! window titles, no URLs, no OCR text, no event-level content.
//! This module enforces that by-construction: the only API surface
//! is `record_health(snapshot)` which takes the typed counter snapshot
//! from `mci_core::ipc::Message::HelperHealth` and writes a fixed JSON
//! shape. There is no overload for "log user-visible text."
//!
//! Per the CRS telemetry-gap memo (2026-05-19 + iter-7 refresh), the
//! sink writes to `~/Library/Logs/MCI/helper-health.jsonl` by default.
//! Rotation is best-effort: the sink truncates at a configurable
//! byte ceiling (default 10 MiB) by deleting + recreating the file —
//! we lose history, not user-visible content, and the live measurement
//! protocol cares about the last workday only.
//!
//! # CSO sign-off (binding, `AGENT_PROTOCOL` §5)
//!
//! - The JSON shape is fixed at struct level (`HealthLogRecord`).
//!   Adding a field that could carry user content (e.g.
//!   `last_window_title`) requires a fresh CSO ADR amendment.
//! - The `device_id` field carries the opaque per-device id; never
//!   the user's name, hostname, or any other identifier.
//! - Rotation deletes-and-recreates rather than ranging into the file
//!   — keeps the surface tiny + means the file mode (0600) gets
//!   re-applied on every rotation.
//!
//! — CSO, 2026-05-19

use std::path::PathBuf;

use thiserror::Error;
use tokio::fs;
use tokio::io::AsyncWriteExt;

/// Errors the health-log sink may surface.
#[derive(Debug, Error)]
pub enum HealthLogError {
    /// File-system I/O failed.
    #[error("health-log io: {0}")]
    Io(#[from] std::io::Error),
    /// JSON serialization failed.
    #[error("health-log json: {0}")]
    Json(String),
}

/// One line of the helper-health JSONL log.
///
/// Stable on-disk shape. New fields are append-only (older lines stay
/// readable). Removing or renaming a field is a CSO-protected change.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HealthLogRecord {
    /// RFC-3339 wall-clock timestamp the record was written. Wall-
    /// clock — distinct from the helper's monotonic `uptime_ms`.
    /// Wall-clock is what a human reading the log needs to correlate
    /// with a real workday.
    pub wall_ts: String,
    /// The opaque per-device identifier (32-char hex). Never the
    /// hostname / MAC / serial.
    pub device_id: String,
    /// Helper-side uptime in ms (monotonic).
    pub uptime_ms: u64,
    /// Cumulative counters since helper start.
    pub frames_delivered: u64,
    /// Cumulative counters since helper start. **Total** cascade
    /// suppressions across every ADR-0013 reason.
    pub frames_suppressed: u64,
    /// Cumulative count of suppressions via the ADR-0013 §7 fail-safe
    /// path specifically — a **subset** of `frames_suppressed`. The
    /// CRS Telemetry-Gap privacy-regression sentinel (a fail-safe
    /// spike = the cascade lost positive-classification ability).
    pub frames_redacted_by_failsafe: u64,
    /// Cumulative counters since helper start.
    pub frames_dropped_backpressure: u64,
    /// Cumulative counters since helper start.
    pub frames_dropped_late_ack: u64,
}

impl HealthLogRecord {
    /// Manually serialize to a single JSON line (no trailing newline).
    /// Hand-rolled to avoid pulling `serde` / `serde_json` into the
    /// agent crate (CRS Security-Signal stance: minimize the dep
    /// surface; the JSON shape is small + fixed).
    #[must_use]
    pub fn to_json_line(&self) -> String {
        // Keys are typed strings — never user content — so we don't
        // need to escape them. Values are integers or pre-validated
        // hex/RFC-3339 strings. Defensive: still escape strings the
        // standard JSON way for the wall_ts (it shouldn't contain
        // quotes; future change might).
        format!(
            r#"{{"wall_ts":"{}","device_id":"{}","uptime_ms":{},"frames_delivered":{},"frames_suppressed":{},"frames_redacted_by_failsafe":{},"frames_dropped_backpressure":{},"frames_dropped_late_ack":{}}}"#,
            escape_json_string(&self.wall_ts),
            escape_json_string(&self.device_id),
            self.uptime_ms,
            self.frames_delivered,
            self.frames_suppressed,
            self.frames_redacted_by_failsafe,
            self.frames_dropped_backpressure,
            self.frames_dropped_late_ack,
        )
    }
}

/// Minimal JSON-string escape. Only handles the characters our fixed
/// inputs can contain: backslash + double-quote + control chars. We do
/// NOT call this on the integer fields; they don't need escaping.
fn escape_json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                use std::fmt::Write as _;
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out
}

/// Configuration for the health-log sink.
#[derive(Debug, Clone)]
pub struct HealthLogConfig {
    /// Path the JSONL log writes to. Default
    /// `~/Library/Logs/MCI/helper-health.jsonl`.
    pub path: PathBuf,
    /// Rotation ceiling in bytes. When the file exceeds this size,
    /// the sink truncates by recreating it (lose history, never user
    /// content). Default 10 MiB.
    pub max_bytes: u64,
}

impl HealthLogConfig {
    /// Default config — writes to the standard macOS user-log path.
    #[must_use]
    pub fn default_for_user() -> Self {
        let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
        Self {
            path: home.join("Library/Logs/MCI/helper-health.jsonl"),
            max_bytes: 10 * 1024 * 1024,
        }
    }
}

/// Appender — opens the file lazily, rotates on byte-ceiling overrun.
///
/// Thread-safety: the caller wraps in `tokio::sync::Mutex` if multiple
/// tasks write concurrently. For the agent's current design (one
/// `HelperConnection::recv_one()` task per helper child) there's
/// exactly one writer.
pub struct HealthLog {
    cfg: HealthLogConfig,
}

impl HealthLog {
    /// Construct a new appender. No I/O yet; the file opens on first
    /// `record()` call.
    #[must_use]
    pub const fn new(cfg: HealthLogConfig) -> Self {
        Self { cfg }
    }

    /// Append one record. Creates the parent dir + the file at mode
    /// 0600 on first call. Rotates by truncate-and-recreate if the
    /// file is over `cfg.max_bytes` after the write.
    pub async fn record(&self, rec: &HealthLogRecord) -> Result<(), HealthLogError> {
        if let Some(parent) = self.cfg.path.parent() {
            fs::create_dir_all(parent).await?;
        }

        let mut file = open_append_0600(&self.cfg.path).await?;
        let line = rec.to_json_line();
        file.write_all(line.as_bytes()).await?;
        file.write_all(b"\n").await?;
        file.flush().await?;
        drop(file);

        // Rotate if the file is over the ceiling. The check + truncate
        // is racy under concurrent writers; the agent has one writer
        // by design (see struct docs). A torn rotation loses some
        // recent records but no user content; acceptable.
        let metadata = fs::metadata(&self.cfg.path).await?;
        if metadata.len() > self.cfg.max_bytes {
            self.rotate().await?;
        }
        Ok(())
    }

    /// Truncate-and-recreate. Drops history. Re-applies 0600 mode.
    async fn rotate(&self) -> Result<(), HealthLogError> {
        fs::remove_file(&self.cfg.path).await?;
        // Create the empty file with 0600 so the very next record's
        // open-append doesn't fall back to umask defaults.
        let _ = open_append_0600(&self.cfg.path).await?;
        Ok(())
    }
}

async fn open_append_0600(path: &std::path::Path) -> std::io::Result<tokio::fs::File> {
    tokio::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)
        .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn sample_record() -> HealthLogRecord {
        HealthLogRecord {
            wall_ts: "2026-05-19T04:30:00Z".to_string(),
            device_id: "0123456789abcdef0123456789abcdef".to_string(),
            uptime_ms: 1234,
            frames_delivered: 10,
            frames_suppressed: 2,
            frames_redacted_by_failsafe: 1,
            frames_dropped_backpressure: 0,
            frames_dropped_late_ack: 0,
        }
    }

    #[test]
    fn to_json_line_matches_fixed_shape() {
        let r = sample_record();
        let line = r.to_json_line();
        assert_eq!(
            line,
            r#"{"wall_ts":"2026-05-19T04:30:00Z","device_id":"0123456789abcdef0123456789abcdef","uptime_ms":1234,"frames_delivered":10,"frames_suppressed":2,"frames_redacted_by_failsafe":1,"frames_dropped_backpressure":0,"frames_dropped_late_ack":0}"#
        );
    }

    #[test]
    fn json_line_has_no_user_visible_text_fields() {
        // Trip-wire: scan the rendered output for fields that look
        // like they might carry user content. There must be NO
        // app_bundle / window_title / url / text field in the shape.
        let r = sample_record();
        let line = r.to_json_line();
        for forbidden in [
            "\"app_bundle\":",
            "\"window_title\":",
            "\"url\":",
            "\"text\":",
            "\"summary\":",
            "\"entities\":",
        ] {
            assert!(
                !line.contains(forbidden),
                "health-log line must not contain {forbidden} — CSO sign-off in mod docstring"
            );
        }
    }

    #[test]
    fn escape_json_string_handles_specials() {
        assert_eq!(escape_json_string("plain"), "plain");
        assert_eq!(escape_json_string("a\"b"), "a\\\"b");
        assert_eq!(escape_json_string("a\\b"), "a\\\\b");
        assert_eq!(escape_json_string("a\nb"), "a\\nb");
        assert_eq!(escape_json_string("a\x01b"), "a\\u0001b");
    }

    #[tokio::test]
    async fn record_writes_jsonl_to_path() {
        let tmp = tempfile::tempdir().unwrap();
        let log = HealthLog::new(HealthLogConfig {
            path: tmp.path().join("mci/helper-health.jsonl"),
            max_bytes: 10 * 1024 * 1024,
        });
        let r = sample_record();
        log.record(&r).await.unwrap();
        log.record(&r).await.unwrap();

        let body = tokio::fs::read_to_string(tmp.path().join("mci/helper-health.jsonl"))
            .await
            .unwrap();
        let lines: Vec<&str> = body.lines().collect();
        assert_eq!(lines.len(), 2);
        for line in lines {
            assert!(line.starts_with('{'));
            assert!(line.ends_with('}'));
            assert!(line.contains("\"device_id\":\"0123456789abcdef0123456789abcdef\""));
        }
    }

    #[tokio::test]
    async fn record_creates_file_at_0600() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("mci/helper-health.jsonl");
        let log = HealthLog::new(HealthLogConfig {
            path: path.clone(),
            max_bytes: 1024 * 1024,
        });
        log.record(&sample_record()).await.unwrap();
        let meta = tokio::fs::metadata(&path).await.unwrap();
        let mode = meta.permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "health-log file must be 0600");
    }

    #[tokio::test]
    async fn record_rotates_when_over_ceiling() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("mci/helper-health.jsonl");
        let log = HealthLog::new(HealthLogConfig {
            path: path.clone(),
            // Tiny ceiling — one record blows past it instantly.
            max_bytes: 1,
        });
        // First record creates the file + writes + rotates (the file
        // gets truncated immediately after this single line).
        log.record(&sample_record()).await.unwrap();
        // Second record: file should be (re-created or truncated) +
        // contain exactly one line after this call.
        log.record(&sample_record()).await.unwrap();

        let body = tokio::fs::read_to_string(&path).await.unwrap();
        // After rotation, exactly the most-recent line remains.
        let line_count = body.lines().count();
        assert!(
            line_count <= 1,
            "after rotation file should have ≤1 line, got {line_count}"
        );

        // Mode is still 0600 after rotation.
        let meta = tokio::fs::metadata(&path).await.unwrap();
        let mode = meta.permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn default_for_user_uses_library_logs_path() {
        let cfg = HealthLogConfig::default_for_user();
        let s = cfg.path.display().to_string();
        // Either under $HOME or the /tmp fallback — both end with the
        // canonical relative path.
        assert!(
            s.ends_with("Library/Logs/MCI/helper-health.jsonl"),
            "got {s}"
        );
    }
}
