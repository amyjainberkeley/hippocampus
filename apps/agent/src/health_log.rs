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
//! Rotation: size-based at 10 MiB, atomic rename chain retaining 5
//! archived copies (`.1` through `.5`). Oldest archive (`.5`) is
//! discarded on each rotation. `fsync` on the active file before
//! rename ensures the last batch of records is durable.
//!
//! # CSO sign-off (binding, `AGENT_PROTOCOL` §5)
//!
//! - The JSON shape is fixed at struct level (`HealthLogRecord`).
//!   Adding a field that could carry user content (e.g.
//!   `last_window_title`) requires a fresh CSO ADR amendment.
//! - The `device_id` field carries the opaque per-device id; never
//!   the user's name, hostname, or any other identifier.
//! - Rotated archives inherit 0600 from the active file. Fresh
//!   active file is re-created at 0600.
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
    /// Cumulative count of cascade evaluations that ran because the
    /// cascade-floor heartbeat elapsed (filter returned `.drop*` but
    /// the floor interval forced the cascade anyway). Promoted to
    /// the wire by the 0x02 → 0x03 bump (STEP-2-FINDING-004) and
    /// mirrored here for the Telemetry-Gap analyst's static-secure-
    /// surface signal — content-free counter, no user text or
    /// identifiers; safe to persist under the §9.3 / NG3 invariant.
    pub cascade_forced_count: u64,
    /// Cumulative counters since helper start.
    pub frames_dropped_backpressure: u64,
    /// Cumulative counters since helper start.
    pub frames_dropped_late_ack: u64,
    /// Cumulative count of VideoToolbox HEVC encode throws on the
    /// `.allow` branch. Promoted to the wire by the `0x06 → 0x07` bump
    /// (ocr-emit-silence fix —
    /// `docs/research/ocr-emit-silence-2026-05-28.md`). Mirrors the
    /// existing `frames_redacted_by_failsafe` content-free discipline:
    /// a non-zero value historically silently muted the cascade-twice
    /// OCR emitter, so the Telemetry-Gap analyst now has a trip-wire.
    pub frames_encode_failed: u64,
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
            r#"{{"wall_ts":"{}","device_id":"{}","uptime_ms":{},"frames_delivered":{},"frames_suppressed":{},"frames_redacted_by_failsafe":{},"cascade_forced_count":{},"frames_dropped_backpressure":{},"frames_dropped_late_ack":{},"frames_encode_failed":{}}}"#,
            escape_json_string(&self.wall_ts),
            escape_json_string(&self.device_id),
            self.uptime_ms,
            self.frames_delivered,
            self.frames_suppressed,
            self.frames_redacted_by_failsafe,
            self.cascade_forced_count,
            self.frames_dropped_backpressure,
            self.frames_dropped_late_ack,
            self.frames_encode_failed,
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

/// Maximum number of rotated archives to retain (`.1` … `.5`).
const MAX_ROTATIONS: u32 = 5;

/// Configuration for the health-log sink.
#[derive(Debug, Clone)]
pub struct HealthLogConfig {
    /// Path the JSONL log writes to. Default
    /// `~/Library/Logs/MCI/helper-health.jsonl`.
    pub path: PathBuf,
    /// Rotation ceiling in bytes. When the file exceeds this size,
    /// the active file is fsync'd and renamed into the archive chain.
    /// Default 10 MiB.
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
    /// 0600 on first call. Rotates via atomic rename chain if the
    /// file exceeds `cfg.max_bytes` after the write.
    pub async fn record(&self, rec: &HealthLogRecord) -> Result<(), HealthLogError> {
        if let Some(parent) = self.cfg.path.parent() {
            fs::create_dir_all(parent).await?;
        }

        let mut file = open_append_0600(&self.cfg.path).await?;
        let line = rec.to_json_line();
        file.write_all(line.as_bytes()).await?;
        file.write_all(b"\n").await?;
        file.flush().await?;
        file.sync_all().await?;
        drop(file);

        let metadata = fs::metadata(&self.cfg.path).await?;
        if metadata.len() > self.cfg.max_bytes {
            self.rotate().await?;
        }
        Ok(())
    }

    /// Atomic rename chain: `.5` dropped, `.4`→`.5`, … `.1`→`.2`,
    /// active→`.1`. Fresh empty active file re-created at 0600.
    async fn rotate(&self) -> Result<(), HealthLogError> {
        let base = &self.cfg.path;

        // Drop the oldest archive if it exists.
        let oldest = rotation_path(base, MAX_ROTATIONS);
        let _ = fs::remove_file(&oldest).await;

        // Shift archives down: .4→.5, .3→.4, .2→.3, .1→.2
        for i in (1..MAX_ROTATIONS).rev() {
            let src = rotation_path(base, i);
            let dst = rotation_path(base, i + 1);
            let _ = fs::rename(&src, &dst).await;
        }

        // Active → .1
        let archive_1 = rotation_path(base, 1);
        fs::rename(base, &archive_1).await?;

        // Fresh active file at 0600.
        let _ = open_append_0600(base).await?;
        Ok(())
    }
}

/// Build the path for the Nth rotated archive (e.g. `foo.jsonl.3`).
fn rotation_path(base: &std::path::Path, n: u32) -> PathBuf {
    let mut s = base.as_os_str().to_os_string();
    s.push(format!(".{n}"));
    PathBuf::from(s)
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
            cascade_forced_count: 3,
            frames_dropped_backpressure: 0,
            frames_dropped_late_ack: 0,
            frames_encode_failed: 7,
        }
    }

    #[test]
    fn to_json_line_matches_fixed_shape() {
        let r = sample_record();
        let line = r.to_json_line();
        assert_eq!(
            line,
            r#"{"wall_ts":"2026-05-19T04:30:00Z","device_id":"0123456789abcdef0123456789abcdef","uptime_ms":1234,"frames_delivered":10,"frames_suppressed":2,"frames_redacted_by_failsafe":1,"cascade_forced_count":3,"frames_dropped_backpressure":0,"frames_dropped_late_ack":0,"frames_encode_failed":7}"#
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
    async fn record_rotates_into_archive_chain() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("mci/helper-health.jsonl");
        let log = HealthLog::new(HealthLogConfig {
            path: path.clone(),
            max_bytes: 1,
        });
        // Each record exceeds 1 byte → rotation after every write.
        // After 2 records: active=empty, .1=1line, .2=1line.
        log.record(&sample_record()).await.unwrap();
        log.record(&sample_record()).await.unwrap();

        // .1 and .2 archives should exist.
        let archive_1 = rotation_path(&path, 1);
        assert!(archive_1.exists(), ".1 archive must exist after rotation");
        let arch_body = tokio::fs::read_to_string(&archive_1).await.unwrap();
        assert_eq!(
            arch_body.lines().count(),
            1,
            ".1 archive should have 1 line"
        );

        let archive_2 = rotation_path(&path, 2);
        assert!(
            archive_2.exists(),
            ".2 archive must exist after 2 rotations"
        );

        // Active file is empty (last rotation moved content to .1).
        let body = tokio::fs::read_to_string(&path).await.unwrap();
        assert_eq!(body.lines().count(), 0, "active file empty after rotation");

        // Mode is still 0600 on active file.
        let meta = tokio::fs::metadata(&path).await.unwrap();
        let mode = meta.permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[tokio::test]
    async fn rotation_chain_retains_up_to_5_archives() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("mci/helper-health.jsonl");
        let log = HealthLog::new(HealthLogConfig {
            path: path.clone(),
            max_bytes: 1,
        });

        // 8 records → triggers rotation after each → at most 5 archives.
        for _ in 0..8 {
            log.record(&sample_record()).await.unwrap();
        }

        for i in 1..=5 {
            let archive = rotation_path(&path, i);
            assert!(archive.exists(), ".{i} archive must exist");
        }
        let archive_6 = rotation_path(&path, 6);
        assert!(!archive_6.exists(), ".6 must NOT exist (max 5 retained)");
    }

    #[tokio::test]
    async fn concurrent_writers_no_panic() {
        use std::sync::Arc;
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("mci/concurrent.jsonl");
        let log = Arc::new(HealthLog::new(HealthLogConfig {
            path: path.clone(),
            max_bytes: 10 * 1024 * 1024,
        }));

        let mut handles = Vec::new();
        for t in 0..10u64 {
            let log = Arc::clone(&log);
            handles.push(tokio::spawn(async move {
                for i in 0..20u64 {
                    let rec = HealthLogRecord {
                        wall_ts: format!("2026-05-21T00:00:{:02}Z", (t * 20 + i) % 60),
                        device_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"[..32].to_string(),
                        uptime_ms: t * 1000 + i,
                        frames_delivered: i,
                        frames_suppressed: 0,
                        frames_redacted_by_failsafe: 0,
                        cascade_forced_count: 0,
                        frames_dropped_backpressure: 0,
                        frames_dropped_late_ack: 0,
                        frames_encode_failed: 0,
                    };
                    log.record(&rec).await.unwrap();
                }
            }));
        }
        for h in handles {
            h.await.unwrap();
        }

        // All 200 records should be present (no rotation at 10 MiB ceiling).
        let body = tokio::fs::read_to_string(&path).await.unwrap();
        let count = body.lines().count();
        assert_eq!(
            count, 200,
            "expected 200 lines from 10 concurrent writers, got {count}"
        );
    }

    #[test]
    fn default_for_user_uses_library_logs_path() {
        let cfg = HealthLogConfig::default_for_user();
        let s = cfg.path.display().to_string();
        assert!(
            s.ends_with("Library/Logs/MCI/helper-health.jsonl"),
            "got {s}"
        );
    }

    #[test]
    fn rotation_path_format() {
        let base = PathBuf::from("/tmp/test.jsonl");
        assert_eq!(
            rotation_path(&base, 1).display().to_string(),
            "/tmp/test.jsonl.1"
        );
        assert_eq!(
            rotation_path(&base, 5).display().to_string(),
            "/tmp/test.jsonl.5"
        );
    }
}
