//! Health-log summary aggregator.
//!
//! Reads JSONL written by [`crate::health_log::HealthLog`] and
//! aggregates the records over a wall-clock window into one human-
//! readable line. The intended consumer is the live-workday debrief:
//! the human runs `mci-agent --health-summary` after a G2 measurement
//! window and gets a one-line picture of helper behavior.
//!
//! Per the CRS production-telemetry & gap memo (iter 10, 2026-05-19),
//! this is the analyst-flagged recommendation #3. The sibling
//! recommendation #1 — the `frames_redacted_by_failsafe` wire-bump
//! (CSO-gated, wire `0x01 → 0x02`) — is now **landed**: the summary
//! surfaces it as the `failsafe=Δ<delta>/<latest>` segment, the
//! privacy-regression sentinel a fail-safe spike trips. The cycle-3
//! `tracing` event taps remain separately owed.
//!
//! # CSO sign-off (binding, `AGENT_PROTOCOL` §5)
//!
//! The summary path is **read-only** against the existing `HealthLog`
//! JSONL file. It does **not** introduce new fields, does **not**
//! change the on-disk shape, does **not** emit any user-content text.
//! Inputs: the fixed-shape `HealthLogRecord` JSONL written by the same
//! crate. Outputs: integers + the already-on-disk RFC-3339 timestamps
//! + the opaque `device_id`. No new privacy surface.
//!
//! The hand-rolled parser mirrors `HealthLogRecord::to_json_line` —
//! `serde` / `serde_json` are deliberately NOT pulled in, matching the
//! existing stance in [`crate::health_log`] and [`crate::wall_clock`].
//! The parser intentionally accepts only the fixed-shape lines this
//! crate writes; arbitrary JSON is **not** supported.
//!
//! — CSO, 2026-05-19

use std::path::Path;

use thiserror::Error;

use crate::health_log::HealthLogRecord;

/// Errors the file-level summary path may surface.
#[derive(Debug, Error)]
pub enum SummaryError {
    /// I/O failure reading the log file.
    #[error("health-summary io: {0}")]
    Io(#[from] std::io::Error),
}

/// Errors the per-line parser may surface. Aggregators count these
/// (`malformed_lines_skipped`) and continue rather than fail — a torn
/// tail-write or a rotation race shouldn't abort the summary.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum ParseError {
    /// Line did not match the fixed-shape JSONL envelope.
    #[error("health-summary parse shape: {0}")]
    Shape(String),
    /// A required field was missing or malformed.
    #[error("health-summary parse field: {0}")]
    Field(String),
}

/// Aggregated picture of helper behavior over a wall-clock window.
///
/// Deltas are sums of per-step positive differences across consecutive
/// in-window samples; `restarts_detected` records how often we saw
/// `uptime_ms` decrease between samples (the helper-child restarted).
/// When a restart is detected the new sample's cumulative counters are
/// treated as fresh contributions to the delta sum.
///
/// `latest` values are the absolute cumulative counters from the most
/// recent in-window sample, useful as a "where are we now" reading.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HealthSummary {
    /// Inclusive RFC-3339 cutoff for the window (records with
    /// `wall_ts >= window_start_ts` are included).
    pub window_start_ts: String,
    /// Number of in-window samples that parsed successfully.
    pub samples: u64,
    /// Earliest in-window record's `wall_ts`, if any.
    pub earliest_ts: Option<String>,
    /// Latest in-window record's `wall_ts`, if any.
    pub latest_ts: Option<String>,
    /// Opaque `device_id` from the latest in-window record. Useful
    /// when multiple machines write to a shared inspection target.
    pub device_id: Option<String>,
    /// Sum of per-step positive deltas for `frames_delivered`.
    pub frames_delivered_delta: u64,
    /// Absolute `frames_delivered` from the latest in-window sample.
    pub frames_delivered_latest: u64,
    /// Sum of per-step positive deltas for `frames_suppressed`.
    pub frames_suppressed_delta: u64,
    /// Absolute `frames_suppressed` from the latest in-window sample.
    pub frames_suppressed_latest: u64,
    /// Sum of per-step positive deltas for `frames_redacted_by_failsafe`
    /// — the ADR-0013 §7 fail-safe subset. A non-trivial delta here
    /// (especially relative to `frames_suppressed_delta`) is the CRS
    /// Telemetry-Gap privacy-regression sentinel.
    pub frames_redacted_by_failsafe_delta: u64,
    /// Absolute `frames_redacted_by_failsafe` from the latest sample.
    pub frames_redacted_by_failsafe_latest: u64,
    /// Sum of per-step positive deltas for `frames_dropped_backpressure`.
    pub frames_dropped_backpressure_delta: u64,
    /// Absolute `frames_dropped_backpressure` from the latest sample.
    pub frames_dropped_backpressure_latest: u64,
    /// Sum of per-step positive deltas for `frames_dropped_late_ack`.
    pub frames_dropped_late_ack_delta: u64,
    /// Absolute `frames_dropped_late_ack` from the latest sample.
    pub frames_dropped_late_ack_latest: u64,
    /// JSONL lines that failed to parse (torn writes, future schema
    /// from a newer agent, etc). Counted, never logged.
    pub malformed_lines_skipped: u64,
    /// Number of in-window helper restarts detected via `uptime_ms`
    /// going backward across consecutive samples.
    pub restarts_detected: u64,
}

impl HealthSummary {
    /// Render a single human-readable line. Intended for stdout of
    /// `mci-agent --health-summary`; the live-workday human-CEO
    /// debrief tool.
    ///
    /// Shape is deliberately compact and grep-friendly. Each delta is
    /// printed as `Δ<delta>/<latest>` so the reader sees both the
    /// activity inside the window and the cumulative position.
    #[must_use]
    pub fn to_human_line(&self) -> String {
        let earliest = self.earliest_ts.as_deref().unwrap_or("-");
        let latest = self.latest_ts.as_deref().unwrap_or("-");
        let device = self.device_id.as_deref().unwrap_or("-");
        format!(
            "mci-agent health-summary \
             window_start={window_start} \
             samples={samples} \
             device_id={device} \
             deliv=Δ{deliv_d}/{deliv_l} \
             suppr=Δ{suppr_d}/{suppr_l} \
             failsafe=Δ{failsafe_d}/{failsafe_l} \
             backp=Δ{backp_d}/{backp_l} \
             late_ack=Δ{lateack_d}/{lateack_l} \
             earliest={earliest} \
             latest={latest} \
             restarts={restarts} \
             malformed={malformed}",
            window_start = self.window_start_ts,
            samples = self.samples,
            deliv_d = self.frames_delivered_delta,
            deliv_l = self.frames_delivered_latest,
            suppr_d = self.frames_suppressed_delta,
            suppr_l = self.frames_suppressed_latest,
            failsafe_d = self.frames_redacted_by_failsafe_delta,
            failsafe_l = self.frames_redacted_by_failsafe_latest,
            backp_d = self.frames_dropped_backpressure_delta,
            backp_l = self.frames_dropped_backpressure_latest,
            lateack_d = self.frames_dropped_late_ack_delta,
            lateack_l = self.frames_dropped_late_ack_latest,
            restarts = self.restarts_detected,
            malformed = self.malformed_lines_skipped,
        )
    }
}

/// Parse one JSONL line written by [`HealthLogRecord::to_json_line`].
///
/// The parser is **input-restricted** — it accepts only the fixed-
/// shape line this crate writes. It is NOT a general JSON parser. If
/// the field order, presence, or type ever changes in the writer,
/// this parser must change in lockstep.
///
/// # Errors
/// Returns [`ParseError::Shape`] for non-brace-wrapped input, and
/// [`ParseError::Field`] for missing or malformed fields.
pub fn parse_jsonl_line(line: &str) -> Result<HealthLogRecord, ParseError> {
    let s = line.trim();
    if !s.starts_with('{') || !s.ends_with('}') {
        return Err(ParseError::Shape(format!("missing braces: {s:.20}…")));
    }
    let wall_ts = extract_string_field(s, "\"wall_ts\":\"")?;
    let device_id = extract_string_field(s, "\"device_id\":\"")?;
    let uptime_ms = extract_u64_field(s, "\"uptime_ms\":")?;
    let frames_delivered = extract_u64_field(s, "\"frames_delivered\":")?;
    let frames_suppressed = extract_u64_field(s, "\"frames_suppressed\":")?;
    // Back-compat: pre-wire-`0x02` JSONL lines (dev-only artifacts;
    // capture was default-OFF) have no `frames_redacted_by_failsafe`
    // key. Treat absent as 0 so `--health-summary` over a log that
    // straddles the bump stays readable rather than counting the old
    // lines as malformed. Lines that DO carry the key are parsed
    // strictly.
    let frames_redacted_by_failsafe =
        extract_u64_field_or_zero(s, "\"frames_redacted_by_failsafe\":")?;
    let frames_dropped_backpressure = extract_u64_field(s, "\"frames_dropped_backpressure\":")?;
    let frames_dropped_late_ack = extract_u64_field(s, "\"frames_dropped_late_ack\":")?;
    Ok(HealthLogRecord {
        wall_ts,
        device_id,
        uptime_ms,
        frames_delivered,
        frames_suppressed,
        frames_redacted_by_failsafe,
        frames_dropped_backpressure,
        frames_dropped_late_ack,
    })
}

fn extract_string_field(s: &str, key_with_open_quote: &str) -> Result<String, ParseError> {
    let start = s
        .find(key_with_open_quote)
        .ok_or_else(|| ParseError::Field(format!("missing key {key_with_open_quote}")))?;
    let value_start = start + key_with_open_quote.len();
    let rest = &s[value_start..];
    // The writer's `escape_json_string` would emit `\"` for an embedded
    // quote, but the inputs it actually escapes (wall_ts, device_id)
    // never contain a literal `"` in our shape — so the first `"` we
    // see ends the value. This parser intentionally refuses to roll
    // back over `\"`; if the writer ever emits an escaped quote in
    // wall_ts/device_id, that's a schema break and the parser should
    // fail loudly.
    let end = rest
        .find('"')
        .ok_or_else(|| ParseError::Field(format!("unterminated string {key_with_open_quote}")))?;
    Ok(rest[..end].to_string())
}

/// Like [`extract_u64_field`] but a *missing* key resolves to `0`
/// instead of [`ParseError::Field`]. Used only for fields added by a
/// later wire/log-schema bump so a log file that straddles the bump
/// stays readable. A key that is *present but malformed* still errors
/// (we do not silently zero a torn value).
fn extract_u64_field_or_zero(s: &str, key_with_colon: &str) -> Result<u64, ParseError> {
    if s.find(key_with_colon).is_none() {
        return Ok(0);
    }
    extract_u64_field(s, key_with_colon)
}

fn extract_u64_field(s: &str, key_with_colon: &str) -> Result<u64, ParseError> {
    let start = s
        .find(key_with_colon)
        .ok_or_else(|| ParseError::Field(format!("missing key {key_with_colon}")))?;
    let value_start = start + key_with_colon.len();
    let rest = &s[value_start..];
    let end = rest
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(rest.len());
    if end == 0 {
        return Err(ParseError::Field(format!(
            "non-digit value {key_with_colon}"
        )));
    }
    rest[..end]
        .parse::<u64>()
        .map_err(|e| ParseError::Field(format!("{key_with_colon}: {e}")))
}

/// Aggregate JSONL `lines` into a [`HealthSummary`] over the window
/// `[window_start_ts, +∞)`. Lines outside the window are skipped.
/// Malformed lines are counted, never logged.
///
/// The caller is responsible for computing `window_start_ts` (typically
/// `format_unix_ms(now_ms - window_seconds*1000)`).
#[must_use]
pub fn summarize_lines<'a, I>(window_start_ts: String, lines: I) -> HealthSummary
where
    I: IntoIterator<Item = &'a str>,
{
    let mut summary = HealthSummary {
        window_start_ts,
        ..HealthSummary::default()
    };

    // We track the previous in-window record to compute per-step
    // positive deltas. `uptime_ms` going backward = restart.
    let mut prev: Option<HealthLogRecord> = None;

    for raw in lines {
        if raw.trim().is_empty() {
            continue;
        }
        let Ok(rec) = parse_jsonl_line(raw) else {
            summary.malformed_lines_skipped = summary.malformed_lines_skipped.saturating_add(1);
            continue;
        };
        if rec.wall_ts < summary.window_start_ts {
            continue;
        }

        summary.samples = summary.samples.saturating_add(1);
        if summary.earliest_ts.is_none() {
            summary.earliest_ts = Some(rec.wall_ts.clone());
        }
        summary.latest_ts = Some(rec.wall_ts.clone());
        summary.device_id = Some(rec.device_id.clone());

        if let Some(p) = &prev {
            if rec.uptime_ms >= p.uptime_ms {
                summary.frames_delivered_delta = summary
                    .frames_delivered_delta
                    .saturating_add(rec.frames_delivered.saturating_sub(p.frames_delivered));
                summary.frames_suppressed_delta = summary
                    .frames_suppressed_delta
                    .saturating_add(rec.frames_suppressed.saturating_sub(p.frames_suppressed));
                summary.frames_redacted_by_failsafe_delta =
                    summary.frames_redacted_by_failsafe_delta.saturating_add(
                        rec.frames_redacted_by_failsafe
                            .saturating_sub(p.frames_redacted_by_failsafe),
                    );
                summary.frames_dropped_backpressure_delta =
                    summary.frames_dropped_backpressure_delta.saturating_add(
                        rec.frames_dropped_backpressure
                            .saturating_sub(p.frames_dropped_backpressure),
                    );
                summary.frames_dropped_late_ack_delta =
                    summary.frames_dropped_late_ack_delta.saturating_add(
                        rec.frames_dropped_late_ack
                            .saturating_sub(p.frames_dropped_late_ack),
                    );
            } else {
                // Restart: the new record's cumulative counters
                // started from 0. Treat the full new values as
                // fresh deltas for this step.
                summary.restarts_detected = summary.restarts_detected.saturating_add(1);
                summary.frames_delivered_delta = summary
                    .frames_delivered_delta
                    .saturating_add(rec.frames_delivered);
                summary.frames_suppressed_delta = summary
                    .frames_suppressed_delta
                    .saturating_add(rec.frames_suppressed);
                summary.frames_redacted_by_failsafe_delta = summary
                    .frames_redacted_by_failsafe_delta
                    .saturating_add(rec.frames_redacted_by_failsafe);
                summary.frames_dropped_backpressure_delta = summary
                    .frames_dropped_backpressure_delta
                    .saturating_add(rec.frames_dropped_backpressure);
                summary.frames_dropped_late_ack_delta = summary
                    .frames_dropped_late_ack_delta
                    .saturating_add(rec.frames_dropped_late_ack);
            }
        } else {
            // First in-window sample: no baseline, contributes zero
            // to the delta sum. (Equivalently: with N=1 sample we
            // can't measure a delta; deltas report 0.)
        }

        summary.frames_delivered_latest = rec.frames_delivered;
        summary.frames_suppressed_latest = rec.frames_suppressed;
        summary.frames_redacted_by_failsafe_latest = rec.frames_redacted_by_failsafe;
        summary.frames_dropped_backpressure_latest = rec.frames_dropped_backpressure;
        summary.frames_dropped_late_ack_latest = rec.frames_dropped_late_ack;
        prev = Some(rec);
    }

    summary
}

/// Read `path` and summarize its lines over the given window. A
/// missing file is treated as an empty log (zero samples) rather than
/// an error — running `--health-summary` before the helper has ever
/// emitted a heartbeat should not be a hard failure.
///
/// # Errors
/// Returns [`SummaryError::Io`] only for file-system errors other than
/// `NotFound`.
pub async fn summarize_file(
    path: &Path,
    window_start_ts: String,
) -> Result<HealthSummary, SummaryError> {
    let content = match tokio::fs::read_to_string(path).await {
        Ok(s) => s,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(SummaryError::Io(e)),
    };
    Ok(summarize_lines(window_start_ts, content.lines()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::health_log::HealthLogRecord;

    fn rec(
        wall_ts: &str,
        uptime_ms: u64,
        delivered: u64,
        suppressed: u64,
        backpressure: u64,
        late_ack: u64,
    ) -> HealthLogRecord {
        HealthLogRecord {
            wall_ts: wall_ts.to_string(),
            device_id: "0123456789abcdef0123456789abcdef".to_string(),
            uptime_ms,
            frames_delivered: delivered,
            frames_suppressed: suppressed,
            // The 6-arg helper keeps the fail-safe subcount at 0; the
            // dedicated `rec_fs` builder below exercises non-zero
            // values so existing delta/restart assertions stay
            // unchanged.
            frames_redacted_by_failsafe: 0,
            frames_dropped_backpressure: backpressure,
            frames_dropped_late_ack: late_ack,
        }
    }

    /// `rec` with an explicit `frames_redacted_by_failsafe`. Only the
    /// fail-safe-sentinel tests need this; the rest stay on `rec`.
    fn rec_fs(
        wall_ts: &str,
        uptime_ms: u64,
        delivered: u64,
        suppressed: u64,
        redacted_by_failsafe: u64,
    ) -> HealthLogRecord {
        HealthLogRecord {
            frames_redacted_by_failsafe: redacted_by_failsafe,
            ..rec(wall_ts, uptime_ms, delivered, suppressed, 0, 0)
        }
    }

    #[test]
    fn parse_round_trips_writer_output() {
        let r = rec("2026-05-19T04:00:00.000Z", 1234, 10, 2, 0, 0);
        let line = r.to_json_line();
        let parsed = parse_jsonl_line(&line).expect("parse own output");
        assert_eq!(parsed, r);
    }

    #[test]
    fn parse_round_trips_zero_record() {
        let r = rec("2026-05-19T04:00:00.000Z", 0, 0, 0, 0, 0);
        let line = r.to_json_line();
        assert_eq!(parse_jsonl_line(&line).expect("parse"), r);
    }

    #[test]
    fn parse_rejects_missing_braces() {
        let err = parse_jsonl_line("not json").unwrap_err();
        assert!(matches!(err, ParseError::Shape(_)));
    }

    #[test]
    fn parse_rejects_missing_field() {
        let err = parse_jsonl_line(r#"{"wall_ts":"x","device_id":"y","uptime_ms":1}"#).unwrap_err();
        assert!(matches!(err, ParseError::Field(_)));
    }

    #[test]
    fn parse_rejects_non_digit_for_u64_field() {
        let bad = r#"{"wall_ts":"2026-05-19T04:00:00.000Z","device_id":"0123456789abcdef0123456789abcdef","uptime_ms":abc,"frames_delivered":0,"frames_suppressed":0,"frames_dropped_backpressure":0,"frames_dropped_late_ack":0}"#;
        let err = parse_jsonl_line(bad).unwrap_err();
        assert!(matches!(err, ParseError::Field(_)));
    }

    #[test]
    fn empty_input_yields_empty_summary() {
        let s = summarize_lines("2026-05-19T00:00:00.000Z".to_string(), std::iter::empty());
        assert_eq!(s.samples, 0);
        assert_eq!(s.earliest_ts, None);
        assert_eq!(s.latest_ts, None);
        assert_eq!(s.frames_delivered_delta, 0);
        assert_eq!(s.malformed_lines_skipped, 0);
        assert_eq!(s.restarts_detected, 0);
    }

    #[test]
    fn single_sample_reports_zero_delta_but_records_latest() {
        let r = rec("2026-05-19T04:00:00.000Z", 1000, 5, 1, 0, 0);
        let line = r.to_json_line();
        let s = summarize_lines("2026-05-19T03:00:00.000Z".to_string(), [line.as_str()]);
        assert_eq!(s.samples, 1);
        assert_eq!(s.frames_delivered_delta, 0);
        assert_eq!(s.frames_delivered_latest, 5);
        assert_eq!(s.frames_suppressed_latest, 1);
        assert_eq!(s.earliest_ts.as_deref(), Some("2026-05-19T04:00:00.000Z"));
        assert_eq!(s.latest_ts.as_deref(), Some("2026-05-19T04:00:00.000Z"));
    }

    #[test]
    fn delta_sums_positive_per_step_deltas_no_restart() {
        let lines = [
            rec("2026-05-19T04:00:00.000Z", 1000, 0, 0, 0, 0).to_json_line(),
            rec("2026-05-19T04:00:30.000Z", 31000, 10, 2, 0, 0).to_json_line(),
            rec("2026-05-19T04:01:00.000Z", 61000, 25, 5, 1, 0).to_json_line(),
        ];
        let refs: Vec<&str> = lines.iter().map(String::as_str).collect();
        let s = summarize_lines("2026-05-19T03:00:00.000Z".to_string(), refs);
        assert_eq!(s.samples, 3);
        assert_eq!(s.frames_delivered_delta, 25);
        assert_eq!(s.frames_delivered_latest, 25);
        assert_eq!(s.frames_suppressed_delta, 5);
        assert_eq!(s.frames_dropped_backpressure_delta, 1);
        assert_eq!(s.restarts_detected, 0);
    }

    #[test]
    fn restart_detected_via_uptime_decrease() {
        // Helper ran, restarted mid-window.
        let lines = [
            rec("2026-05-19T04:00:00.000Z", 60_000, 100, 5, 0, 0).to_json_line(),
            // Restart: uptime_ms went from 60_000 to 1_000.
            rec("2026-05-19T04:00:30.000Z", 1_000, 7, 1, 0, 0).to_json_line(),
            rec("2026-05-19T04:01:00.000Z", 31_000, 15, 2, 0, 0).to_json_line(),
        ];
        let refs: Vec<&str> = lines.iter().map(String::as_str).collect();
        let s = summarize_lines("2026-05-19T03:00:00.000Z".to_string(), refs);
        assert_eq!(s.samples, 3);
        // The restart sample contributes its full 7; the next step
        // contributes 15-7=8. Total 15.
        assert_eq!(s.frames_delivered_delta, 15);
        assert_eq!(s.frames_delivered_latest, 15);
        assert_eq!(s.restarts_detected, 1);
    }

    #[test]
    fn lines_outside_window_skipped() {
        let lines = [
            rec("2026-05-19T03:00:00.000Z", 1000, 100, 5, 0, 0).to_json_line(),
            rec("2026-05-19T04:00:00.000Z", 4_000_000, 200, 10, 0, 0).to_json_line(),
        ];
        let refs: Vec<&str> = lines.iter().map(String::as_str).collect();
        // Cutoff between the two samples.
        let s = summarize_lines("2026-05-19T03:30:00.000Z".to_string(), refs);
        assert_eq!(s.samples, 1);
        assert_eq!(s.frames_delivered_latest, 200);
        // Only one in-window sample → delta is 0 (no baseline to subtract).
        assert_eq!(s.frames_delivered_delta, 0);
    }

    #[test]
    fn malformed_lines_counted_and_skipped() {
        let good = rec("2026-05-19T04:00:00.000Z", 1000, 5, 1, 0, 0).to_json_line();
        let s = summarize_lines(
            "2026-05-19T00:00:00.000Z".to_string(),
            ["not json", good.as_str(), "", "{\"partial\":1}"],
        );
        // 1 good, 2 malformed (empty line is skipped silently — JSONL
        // tolerates blanks; an empty line is not a torn write).
        assert_eq!(s.samples, 1);
        assert_eq!(s.malformed_lines_skipped, 2);
        assert_eq!(s.frames_delivered_latest, 5);
    }

    #[test]
    fn empty_lines_are_skipped_silently() {
        let s = summarize_lines("2026-05-19T00:00:00.000Z".to_string(), ["", "  ", "\t"]);
        assert_eq!(s.samples, 0);
        assert_eq!(s.malformed_lines_skipped, 0);
    }

    #[test]
    fn to_human_line_has_no_user_visible_text_fields() {
        // Trip-wire mirroring the writer's: the summary line must
        // never carry app_bundle / window_title / url / text / etc.
        let s = HealthSummary {
            window_start_ts: "2026-05-19T03:00:00.000Z".to_string(),
            samples: 3,
            earliest_ts: Some("2026-05-19T03:30:00.000Z".to_string()),
            latest_ts: Some("2026-05-19T04:00:00.000Z".to_string()),
            device_id: Some("0123456789abcdef0123456789abcdef".to_string()),
            frames_delivered_delta: 25,
            frames_delivered_latest: 25,
            frames_suppressed_delta: 5,
            frames_suppressed_latest: 5,
            frames_redacted_by_failsafe_delta: 2,
            frames_redacted_by_failsafe_latest: 2,
            frames_dropped_backpressure_delta: 0,
            frames_dropped_backpressure_latest: 0,
            frames_dropped_late_ack_delta: 0,
            frames_dropped_late_ack_latest: 0,
            malformed_lines_skipped: 0,
            restarts_detected: 0,
        };
        let line = s.to_human_line();
        for forbidden in [
            "app_bundle",
            "window_title",
            "url=",
            "text=",
            "summary_text",
            "entities",
        ] {
            assert!(
                !line.contains(forbidden),
                "health-summary line must not contain {forbidden}"
            );
        }
        // And it does contain the expected delta + cumulative shape.
        assert!(line.contains("deliv=Δ25/25"));
        assert!(line.contains("suppr=Δ5/5"));
        assert!(line.contains("failsafe=Δ2/2"));
        assert!(line.contains("samples=3"));
        assert!(line.contains("device_id=0123456789abcdef0123456789abcdef"));
        assert!(line.contains("window_start=2026-05-19T03:00:00.000Z"));
    }

    #[tokio::test]
    async fn summarize_file_missing_path_is_zero_samples_not_error() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("does-not-exist.jsonl");
        let s = summarize_file(&path, "2026-05-19T00:00:00.000Z".to_string())
            .await
            .expect("missing file is OK");
        assert_eq!(s.samples, 0);
        assert_eq!(s.latest_ts, None);
    }

    #[tokio::test]
    async fn summarize_file_reads_jsonl_back() {
        use crate::health_log::{HealthLog, HealthLogConfig};
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("mci/helper-health.jsonl");
        let log = HealthLog::new(HealthLogConfig {
            path: path.clone(),
            max_bytes: 10 * 1024 * 1024,
        });
        log.record(&rec("2026-05-19T04:00:00.000Z", 1000, 5, 1, 0, 0))
            .await
            .unwrap();
        log.record(&rec("2026-05-19T04:00:30.000Z", 31_000, 12, 3, 0, 0))
            .await
            .unwrap();

        let s = summarize_file(&path, "2026-05-19T00:00:00.000Z".to_string())
            .await
            .unwrap();
        assert_eq!(s.samples, 2);
        assert_eq!(s.frames_delivered_delta, 7);
        assert_eq!(s.frames_delivered_latest, 12);
        assert_eq!(
            s.device_id.as_deref(),
            Some("0123456789abcdef0123456789abcdef")
        );
    }

    #[test]
    fn failsafe_sentinel_delta_and_latest_are_summed() {
        // Fail-safe subcount rises 0 → 4 → 9. Delta = 9, latest = 9.
        // `frames_suppressed` rises faster (it is the superset).
        let lines = [
            rec_fs("2026-05-19T04:00:00.000Z", 1_000, 0, 0, 0).to_json_line(),
            rec_fs("2026-05-19T04:00:30.000Z", 31_000, 50, 10, 4).to_json_line(),
            rec_fs("2026-05-19T04:01:00.000Z", 61_000, 90, 20, 9).to_json_line(),
        ];
        let refs: Vec<&str> = lines.iter().map(String::as_str).collect();
        let s = summarize_lines("2026-05-19T03:00:00.000Z".to_string(), refs);
        assert_eq!(s.samples, 3);
        assert_eq!(s.frames_redacted_by_failsafe_delta, 9);
        assert_eq!(s.frames_redacted_by_failsafe_latest, 9);
        // Sentinel is a strict subset signal — never exceeds suppressed.
        assert!(s.frames_redacted_by_failsafe_delta <= s.frames_suppressed_delta);
        assert!(s.to_human_line().contains("failsafe=Δ9/9"));
    }

    #[test]
    fn restart_resets_failsafe_sentinel_like_other_counters() {
        let lines = [
            rec_fs("2026-05-19T04:00:00.000Z", 60_000, 100, 30, 12).to_json_line(),
            // Restart (uptime backward): full new values are fresh delta.
            rec_fs("2026-05-19T04:00:30.000Z", 1_000, 7, 3, 2).to_json_line(),
            rec_fs("2026-05-19T04:01:00.000Z", 31_000, 15, 6, 5).to_json_line(),
        ];
        let refs: Vec<&str> = lines.iter().map(String::as_str).collect();
        let s = summarize_lines("2026-05-19T03:00:00.000Z".to_string(), refs);
        assert_eq!(s.restarts_detected, 1);
        // sample1 = baseline ⇒ 0; sample2 = restart ⇒ full +2;
        // sample3 = normal step ⇒ 5-2 = 3. Total 0+2+3 = 5.
        assert_eq!(s.frames_redacted_by_failsafe_delta, 5);
        assert_eq!(s.frames_redacted_by_failsafe_latest, 5);
    }

    #[test]
    fn pre_bump_line_without_failsafe_key_parses_as_zero() {
        // A pre-wire-0x02 JSONL line: every field EXCEPT
        // `frames_redacted_by_failsafe`. Must parse (back-compat),
        // resolving the absent sentinel to 0 — not be flagged
        // malformed.
        let old = r#"{"wall_ts":"2026-05-19T04:00:00.000Z","device_id":"0123456789abcdef0123456789abcdef","uptime_ms":1000,"frames_delivered":5,"frames_suppressed":1,"frames_dropped_backpressure":0,"frames_dropped_late_ack":0}"#;
        let parsed = parse_jsonl_line(old).expect("pre-bump line stays readable");
        assert_eq!(parsed.frames_redacted_by_failsafe, 0);
        assert_eq!(parsed.frames_suppressed, 1);

        // And it flows through the aggregator as a normal sample
        // (counted, not malformed).
        let s = summarize_lines("2026-05-19T00:00:00.000Z".to_string(), [old]);
        assert_eq!(s.samples, 1);
        assert_eq!(s.malformed_lines_skipped, 0);
        assert_eq!(s.frames_redacted_by_failsafe_latest, 0);
    }

    #[test]
    fn present_but_malformed_failsafe_value_still_errors() {
        // Back-compat zeroes only an ABSENT key. A present-but-torn
        // value is still a parse error (we do not silently zero it).
        let torn = r#"{"wall_ts":"2026-05-19T04:00:00.000Z","device_id":"0123456789abcdef0123456789abcdef","uptime_ms":1000,"frames_delivered":5,"frames_suppressed":1,"frames_redacted_by_failsafe":xx,"frames_dropped_backpressure":0,"frames_dropped_late_ack":0}"#;
        let err = parse_jsonl_line(torn).unwrap_err();
        assert!(matches!(err, ParseError::Field(_)));
    }
}
