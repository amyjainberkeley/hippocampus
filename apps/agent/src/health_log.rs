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
//!
//! ## Amendment 2026-06-01 (Phase 6 PR 6 — MetricKit + per-app failsafe)
//!
//! Four new fields surfaced from wire 0x09 (PR #226 §5.1 + CTO §4
//! Phase 6 PR 6, S13 acceptance gate):
//!
//! - `failsafe_by_app`: per-bundle `.failsafeUnknown` tombstone
//!   counter, fixed-cardinality (cap 8 entries, least-recent-bump
//!   eviction). Bundle ids enumerated here are ALREADY cascade-
//!   attributed — the cascade had to evaluate the app to emit a
//!   `.failsafeUnknown` tombstone, so the bundle id has already
//!   reached the `PrivacyTombstone` wire surface. Surfacing the
//!   aggregated per-app count adds no fresh content boundary; it
//!   does add information-theoretic enumeration of which apps the
//!   cascade has failsafed in the last process. The cap-8 bound +
//!   least-recent-bump eviction is the load-bearing PII-leak
//!   defence: only the 8 most-recently-failsafed apps are surfaced,
//!   not the full historical set. Per-bundle counters do NOT
//!   distinguish individual users beyond what `app_bundle` on
//!   tombstones already does. Resets on helper restart.
//! - `cpu_pct_micro`: helper CPU sample, microfraction. Numeric.
//! - `rss_bytes`: helper RSS sample. Numeric.
//! - `tracker_alive_at_us`: V2-P1 PR 13 reserved slot, zero until
//!   PR 13 populates. Numeric timestamp.
//!
//! All four are content-free under the same NG3 discipline as the
//! existing wire-0x03..0x08 counters. The cap-8 cardinality bound
//! is the structural argument that satisfies §9.3.
//!
//! — CSO sign-off (driver-CSO, dispatch §"NO DRIVER-CSO REQUIRED"
//! 3-row mini-audit in PR body), 2026-06-01

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
    /// Cumulative count of frames dropped by the ADR-0031 §5.3 race-
    /// consistency gate (`FocusedWindowStore.generation` mismatched the
    /// `installedFocusGeneration` at SCStream callback time). Promoted
    /// to the wire by the `0x07 → 0x08` bump (V2-P1 / ADR-0031 —
    /// `docs/research/capture-scope-window-vs-display-2026-05-29.md`).
    /// Content-free observability counter; the Telemetry-Gap analyst
    /// uses it to detect rapid focus changes (alt-tab cadence faster
    /// than the rebind task) or Electron AX intermittency drifting the
    /// FocusTracker. Cascade-twice OCR emitter is NOT consulted on
    /// frames counted here — the gate fails closed before reaching it.
    pub frames_focus_race_dropped: u64,
    /// Per-app `.failsafeUnknown` tombstone counter map (cap 8 entries,
    /// least-recent-bump eviction). Promoted to the wire by the
    /// `0x08 → 0x09` bump (PR #226 §5.1 + CTO Phase 6 PR 6). The
    /// load-bearing addition for the S13 acceptance gate: surfaces
    /// `failsafe-by-app: com.example.app=124, …` shape per
    /// `mci-agent --health-summary`, attributing cascade silence to
    /// specific bundles. Cap-8 LRU cardinality is the structural PII
    /// defence — see mod docstring Amendment 2026-06-01.
    pub failsafe_by_app: Vec<(String, u64)>,
    /// Instantaneous helper CPU sample, microfraction (1_000_000 =
    /// 100% of one core). Promoted by the `0x08 → 0x09` bump. Pairs
    /// with the MetricKit pipeline (Phase 6 PR 6 same dispatch) for
    /// finer-than-daily CPU observability against the G2-ratified
    /// ≤10–15% SLO (S4 acceptance gate). `0` = sampler did not
    /// take a sample this tick.
    pub cpu_pct_micro: u32,
    /// Instantaneous helper resident set size in bytes, sampled via
    /// Mach `task_info(MACH_TASK_BASIC_INFO)`. Promoted by the
    /// `0x08 → 0x09` bump. Pairs with MetricKit for finer-than-daily
    /// memory observability against ≤2 GB SLO. `0` = sampler failed.
    pub rss_bytes: u64,
    /// Reserved slot for V2-P1 PR 13 focused-window race-gate timeout
    /// (§6.2 = A; see `docs/research/v2-p1-redesign-architecture-2026-06-01.md`
    /// §6.2 + §8 coordination). Phase 6 PR 6 ships this at 0
    /// (sentinel); PR 13 populates with the AX-focus-tracker
    /// heartbeat timestamp. Reusing this PR's wire bump saves PR 13
    /// from carrying a 0x09 → 0x0A bump.
    pub tracker_alive_at_us: u64,
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
        // quotes; future change might) and for bundle ids in
        // `failsafe_by_app` (bundle ids are reverse-DNS — should not
        // contain quotes, but escape defensively).
        let failsafe_by_app_json = render_failsafe_by_app(&self.failsafe_by_app);
        format!(
            r#"{{"wall_ts":"{}","device_id":"{}","uptime_ms":{},"frames_delivered":{},"frames_suppressed":{},"frames_redacted_by_failsafe":{},"cascade_forced_count":{},"frames_dropped_backpressure":{},"frames_dropped_late_ack":{},"frames_encode_failed":{},"frames_focus_race_dropped":{},"failsafe_by_app":{},"cpu_pct_micro":{},"rss_bytes":{},"tracker_alive_at_us":{}}}"#,
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
            self.frames_focus_race_dropped,
            failsafe_by_app_json,
            self.cpu_pct_micro,
            self.rss_bytes,
            self.tracker_alive_at_us,
        )
    }
}

/// Render the per-app failsafe counter map as a JSON object literal
/// (`{"com.example.app":124,"com.microsoft.VSCode":87}`). The cap-8
/// LRU shape is preserved by the caller (the wire decoder enforces
/// the cap structurally); this function emits whatever entries the
/// record carries, with bundle-id keys escape-safe-rendered.
fn render_failsafe_by_app(entries: &[(String, u64)]) -> String {
    let mut s = String::from("{");
    for (i, (bundle_id, counter)) in entries.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push('"');
        s.push_str(&escape_json_string(bundle_id));
        s.push_str("\":");
        s.push_str(&counter.to_string());
    }
    s.push('}');
    s
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
            frames_focus_race_dropped: 4,
            failsafe_by_app: vec![],
            cpu_pct_micro: 0,
            rss_bytes: 0,
            tracker_alive_at_us: 0,
        }
    }

    fn sample_record_with_failsafe_by_app() -> HealthLogRecord {
        HealthLogRecord {
            wall_ts: "2026-06-01T12:00:00Z".to_string(),
            device_id: "0123456789abcdef0123456789abcdef".to_string(),
            uptime_ms: 60_000,
            frames_delivered: 100,
            frames_suppressed: 50,
            frames_redacted_by_failsafe: 50,
            cascade_forced_count: 12,
            frames_dropped_backpressure: 0,
            frames_dropped_late_ack: 0,
            frames_encode_failed: 0,
            frames_focus_race_dropped: 0,
            failsafe_by_app: vec![
                ("com.anthropic.claudefordesktop".to_string(), 124),
                ("com.microsoft.VSCode".to_string(), 87),
            ],
            cpu_pct_micro: 15_000, // 1.5%
            rss_bytes: 187 * 1024 * 1024,
            tracker_alive_at_us: 1_700_000_000_000_000,
        }
    }

    #[test]
    fn to_json_line_matches_fixed_shape_empty_failsafe_by_app() {
        let r = sample_record();
        let line = r.to_json_line();
        assert_eq!(
            line,
            r#"{"wall_ts":"2026-05-19T04:30:00Z","device_id":"0123456789abcdef0123456789abcdef","uptime_ms":1234,"frames_delivered":10,"frames_suppressed":2,"frames_redacted_by_failsafe":1,"cascade_forced_count":3,"frames_dropped_backpressure":0,"frames_dropped_late_ack":0,"frames_encode_failed":7,"frames_focus_race_dropped":4,"failsafe_by_app":{},"cpu_pct_micro":0,"rss_bytes":0,"tracker_alive_at_us":0}"#
        );
    }

    #[test]
    fn to_json_line_matches_fixed_shape_with_failsafe_by_app() {
        let r = sample_record_with_failsafe_by_app();
        let line = r.to_json_line();
        // Per PR #226 §5.1 the on-disk shape surfaces
        // `failsafe-by-app: com.example.app=124, …` via
        // `mci-agent --health-summary`; the JSONL layer emits the
        // same map as a JSON object literal so a Phase 7 PR 27
        // dashboard frontend can read it.
        assert_eq!(
            line,
            r#"{"wall_ts":"2026-06-01T12:00:00Z","device_id":"0123456789abcdef0123456789abcdef","uptime_ms":60000,"frames_delivered":100,"frames_suppressed":50,"frames_redacted_by_failsafe":50,"cascade_forced_count":12,"frames_dropped_backpressure":0,"frames_dropped_late_ack":0,"frames_encode_failed":0,"frames_focus_race_dropped":0,"failsafe_by_app":{"com.anthropic.claudefordesktop":124,"com.microsoft.VSCode":87},"cpu_pct_micro":15000,"rss_bytes":196083712,"tracker_alive_at_us":1700000000000000}"#
        );
    }

    #[test]
    fn json_line_has_no_user_visible_text_fields() {
        // Trip-wire: scan the rendered output for fields that look
        // like they might carry user content. There must be NO
        // app_bundle / window_title / url / text field in the shape.
        // The wire-0x09 `failsafe_by_app` map enumerates bundle ids
        // ALREADY cascade-attributed (see CSO Amendment 2026-06-01)
        // and is bounded at 8 entries by least-recent-bump eviction —
        // this is not a user-visible-text field in the §9.3 sense.
        for r in [sample_record(), sample_record_with_failsafe_by_app()] {
            let line = r.to_json_line();
            for forbidden in [
                "\"app_bundle\":",
                "\"window_title\":",
                "\"url\":",
                "\"text\":",
                "\"summary\":",
                "\"entities\":",
                // Wire-0x09 additions MUST NOT introduce text-shaped
                // counter values either; explicitly forbid common OCR-
                // content field names the failsafe-by-app surface
                // might be drifted into in a future careless edit.
                "\"text_snippet\":",
                "\"text_len\":",
                "\"ocr_text\":",
                "\"recognized_text\":",
            ] {
                assert!(
                    !line.contains(forbidden),
                    "health-log line must not contain {forbidden} — CSO sign-off in mod docstring"
                );
            }
        }
    }

    #[test]
    fn failsafe_by_app_struct_has_no_text_carrying_field() {
        // Grep-style invariant in test form (PR body mini-audit row 2):
        // the `failsafe_by_app` Vec entry type is `(String, u64)`,
        // where String is a *bundle id* (already cascade-attributed)
        // and u64 is a *counter* — NOT an OCR text snippet, NOT a
        // text length, NOT recognized-text content. The test
        // structurally asserts the entry shape by constructing the
        // entries via positional tuple — adding a third field to the
        // tuple (or renaming the type to carry text) would require
        // editing this test, which is the human-readable trip-wire.
        let entries: Vec<(String, u64)> = vec![("com.example".to_string(), 42)];
        let rec = HealthLogRecord {
            wall_ts: "2026-06-01T00:00:00Z".to_string(),
            device_id: "0".repeat(32),
            uptime_ms: 0,
            frames_delivered: 0,
            frames_suppressed: 0,
            frames_redacted_by_failsafe: 0,
            cascade_forced_count: 0,
            frames_dropped_backpressure: 0,
            frames_dropped_late_ack: 0,
            frames_encode_failed: 0,
            frames_focus_race_dropped: 0,
            failsafe_by_app: entries,
            cpu_pct_micro: 0,
            rss_bytes: 0,
            tracker_alive_at_us: 0,
        };
        let line = rec.to_json_line();
        assert!(line.contains(r#""failsafe_by_app":{"com.example":42}"#));
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
                        frames_focus_race_dropped: 0,
                        failsafe_by_app: vec![],
                        cpu_pct_micro: 0,
                        rss_bytes: 0,
                        tracker_alive_at_us: 0,
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
