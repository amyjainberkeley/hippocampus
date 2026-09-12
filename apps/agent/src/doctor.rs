//! Explain why the brain is empty.
//!
//! # Why this exists
//!
//! An install of Hippocampus captured 52,457 frames over 27 hours and wrote
//! zero events. Nothing in the product said why. Finding the answer took
//! reading 5.8 MB of helper logs and cross-referencing capture startup state.
//!
//! Three independent things were wrong at once, and each failed silently:
//! capture was off, Screen Recording TCC had been declined, and the helper had
//! no DB key. A user who hits any of them sees the same thing: an
//! app that looks like it is running and a memory that stays empty.
//!
//! `doctor` reads the same evidence and says it in one screen. It is
//! deliberately read-only and dependency-free: it opens the brain read-only,
//! and greps logs it already owns.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use crate::capture_status::CaptureStatus;
use crate::wall_clock::parse_unix_ms;
use mci_brain::{BrainStats, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

const RECEIPT_FRESHNESS_MS: u64 = 120_000;

/// How a single check came out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    /// Working.
    Pass,
    /// Working, but worth knowing about.
    Warn,
    /// Broken, and the reason the pipeline is not producing.
    Fail,
}

impl Status {
    /// Fixed-width marker so the report lines up.
    #[must_use]
    pub fn marker(self) -> &'static str {
        match self {
            Status::Pass => "ok  ",
            Status::Warn => "warn",
            Status::Fail => "FAIL",
        }
    }
}

/// One diagnostic line.
#[derive(Debug, Clone)]
pub struct Check {
    /// Short name of what was checked.
    pub name: String,
    /// Outcome.
    pub status: Status,
    /// What was actually observed.
    pub detail: String,
    /// What to do about it. Empty when nothing is needed.
    pub fix: String,
}

impl Check {
    fn new(name: &str, status: Status, detail: impl Into<String>, fix: impl Into<String>) -> Self {
        Self {
            name: name.to_string(),
            status,
            detail: detail.into(),
            fix: fix.into(),
        }
    }
}

/// Where the helper writes its logs. Read-only; never created here.
fn helper_log_path() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join("Library/Logs/MCI/helper.stderr.log")
}

/// Read the tail of a log without pulling a large file into memory.
fn tail_of(path: &Path, max_bytes: usize) -> Option<String> {
    let data = std::fs::read(path).ok()?;
    let start = data.len().saturating_sub(max_bytes);
    Some(String::from_utf8_lossy(&data[start..]).into_owned())
}

/// Historical logs cannot establish current Screen Recording permission.
fn check_screen_recording(log: Option<&str>) -> Check {
    let Some(text) = log else {
        return Check::new(
            "screen recording",
            Status::Warn,
            "no fresh capture receipt; current Screen Recording status is unknown",
            "Launch the app once, then re-run doctor.",
        );
    };
    if text.contains("user declined TCC") || text.contains("declined TCC") {
        return Check::new(
            "screen recording",
            Status::Warn,
            "historical helper log contains a ScreenCaptureKit refusal; current permission is unknown",
            "Launch Hippocampus and re-run doctor for a fresh capture receipt.",
        );
    }
    if text.contains("first sample received") {
        return Check::new(
            "screen recording",
            Status::Warn,
            "historical helper log records frames; current capture status is unknown",
            "Launch Hippocampus and re-run doctor for a fresh capture receipt.",
        );
    }
    Check::new(
        "screen recording",
        Status::Warn,
        "no fresh capture receipt; current Screen Recording status is unknown",
        "Launch the app and use it for a minute, then re-run doctor.",
    )
}

/// Can the helper write keyframe blobs?
fn check_helper_key(log: Option<&str>) -> Check {
    match log {
        Some(t) if t.contains("database key unavailable from Keychain") => Check::new(
            "helper db key",
            Status::Warn,
            "historical helper log contains a Keychain error; current key access is unknown",
            "Launch Hippocampus and re-run doctor for current capture status.",
        ),
        _ => Check::new(
            "helper db key",
            Status::Warn,
            "current helper key access is unknown without a fresh capture receipt",
            "",
        ),
    }
}

fn fresh_capture_checks(receipt: &CaptureStatus, now_ms: u64) -> Option<Vec<Check>> {
    let updated = parse_unix_ms(&receipt.updated_at)?;
    if receipt.schema_version != 1 || updated > now_ms || now_ms - updated > RECEIPT_FRESHNESS_MS {
        return None;
    }
    let recent_frame = receipt
        .last_stored_frame_at
        .as_deref()
        .and_then(parse_unix_ms)
        .is_some_and(|ts| ts <= updated && now_ms.saturating_sub(ts) <= RECEIPT_FRESHNESS_MS);
    let runtime = if let Some(reason) = &receipt.blocked_reason {
        Check::new(
            "capture runtime",
            if reason == "capture_disabled" {
                Status::Warn
            } else {
                Status::Fail
            },
            format!("fresh agent receipt reports {reason}"),
            "Review capture status in Hippocampus.",
        )
    } else if let Some(reason) = &receipt.suppression_reason {
        Check::new(
            "capture runtime",
            Status::Warn,
            format!("fresh helper receipt reports suppression: {reason}"),
            "",
        )
    } else if recent_frame && receipt.stored_frame_count > 0 {
        Check::new(
            "capture runtime",
            Status::Pass,
            "a screen frame was committed within the last two minutes",
            "",
        )
    } else {
        Check::new(
            "capture runtime",
            Status::Warn,
            "agent receipt is fresh, but no recent saved screen frame is confirmed",
            "Use an allowed app and check capture status in Hippocampus.",
        )
    };
    Some(vec![
        runtime,
        Check::new(
            "capture storage",
            if receipt.stored_frame_count > 0 {
                Status::Pass
            } else {
                Status::Warn
            },
            format!(
                "{} retained screen events; {} retained screenshot references",
                receipt.stored_frame_count, receipt.stored_screenshot_count
            ),
            "",
        ),
    ])
}

/// Is there an embedder model, and therefore semantic recall?
fn check_embedder() -> Check {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    let candidates = [
        std::env::var_os("MCI_ARCTIC_MODEL_PATH").map(PathBuf::from),
        Some(PathBuf::from(
            "/Applications/Hippocampus.app/Contents/Resources/Models/ArcticEmbedS_FP16.mlmodelc",
        )),
        Some(home.join("Library/Application Support/MCI/Models/ArcticEmbedS_FP16.mlmodelc")),
    ];
    for c in candidates.into_iter().flatten() {
        if c.exists() {
            return Check::new(
                "embedder model",
                Status::Pass,
                format!("found at {}", c.display()),
                "",
            );
        }
    }
    Check::new(
        "embedder model",
        Status::Warn,
        "no ArcticEmbedS model found",
        "Recall works, but keyword-only. Build it with scripts/convert_embedder.py, \
         then run `mci-agent embed-backfill`.",
    )
}

/// The headline: is anything actually stored?
fn check_events(stats: &BrainStats) -> Check {
    if stats.event_count == 0 {
        return Check::new(
            "events",
            Status::Fail,
            "0 events",
            "No events are retained. Review the current capture checks.",
        );
    }
    Check::new(
        "events",
        Status::Pass,
        format!("{} events stored", stats.event_count),
        "",
    )
}

/// Has the understanding pass run over what is stored?
fn check_enriched(stats: &BrainStats) -> Check {
    if stats.event_count == 0 {
        return Check::new("understanding", Status::Warn, "nothing to enrich yet", "");
    }
    if stats.entity_count == 0 {
        return Check::new(
            "understanding",
            Status::Warn,
            format!("{} events but 0 entities", stats.event_count),
            "Run `mci-agent enrich` to extract entities, group episodes and \
             resolve identities.",
        );
    }
    Check::new(
        "understanding",
        Status::Pass,
        format!(
            "{} entities, {} identities, {} episode links",
            stats.entity_count, stats.entity_identity_count, stats.episode_edge_count
        ),
        "",
    )
}

/// Run every check against the brain at `db_path`.
///
/// Read-only throughout: the store is opened with `open_readonly`, and the
/// logs are read, never written.
///
/// # Errors
/// A message describing why the brain could not be opened.
pub fn diagnose(db_path: &Path, key: &DbKey) -> Result<Vec<Check>, String> {
    let store = SqlCipherBrainStore::open_readonly(db_path, key)
        .map_err(|e| format!("open brain at {}: {e}", db_path.display()))?;
    let stats = store.stats().map_err(|e| format!("read stats: {e}"))?;

    let now_ms = u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis(),
    )
    .unwrap_or(u64::MAX);
    let receipt = std::fs::read(db_path.with_file_name("capture-status.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<CaptureStatus>(&bytes).ok());
    let mut checks = vec![check_events(&stats)];
    checks.extend(
        receipt
            .as_ref()
            .and_then(|value| fresh_capture_checks(value, now_ms))
            .unwrap_or_else(|| {
                let log = tail_of(&helper_log_path(), 256 * 1024);
                vec![
                    check_screen_recording(log.as_deref()),
                    check_helper_key(log.as_deref()),
                ]
            }),
    );
    checks.extend([check_embedder(), check_enriched(&stats)]);
    Ok(checks)
}

/// Render the checks as the report the CLI prints.
#[must_use]
pub fn render(checks: &[Check]) -> String {
    let mut out = String::new();
    for c in checks {
        let _ = writeln!(out, "  [{}] {:<18} {}", c.status.marker(), c.name, c.detail);
    }

    let blockers: Vec<&Check> = checks.iter().filter(|c| c.status == Status::Fail).collect();
    let advisories: Vec<&Check> = checks
        .iter()
        .filter(|c| c.status == Status::Warn && !c.fix.is_empty())
        .collect();

    if checks.is_empty() {
        out.push_str("\n  No checks were run.\n");
        return out;
    }

    if checks.iter().all(|c| c.status == Status::Pass) {
        out.push_str("\n  Nothing to fix.\n");
        return out;
    }

    if blockers.is_empty() {
        out.push_str("\n  Review warnings above.\n");
    }

    if !blockers.is_empty() {
        out.push_str("\nBlocking:\n");
        for c in blockers {
            let _ = write!(out, "\n  {}\n    {}\n", c.name, c.fix);
        }
    }
    if !advisories.is_empty() {
        out.push_str("\nWorth doing:\n");
        for c in advisories {
            let _ = write!(out, "\n  {}\n    {}\n", c.name, c.fix);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stats(events: u64, entities: u64) -> BrainStats {
        BrainStats {
            event_count: events,
            oldest_ts_us: None,
            newest_ts_us: None,
            entity_count: entities,
            entity_mention_count: 0,
            entity_identity_count: 0,
            episode_edge_count: 0,
        }
    }

    #[test]
    fn zero_events_is_a_blocker() {
        let c = check_events(&stats(0, 0));
        assert_eq!(c.status, Status::Fail);
    }

    #[test]
    fn events_without_entities_suggests_enrich() {
        let c = check_enriched(&stats(100, 0));
        assert_eq!(c.status, Status::Warn);
        assert!(
            c.fix.contains("enrich"),
            "should point at enrich: {}",
            c.fix
        );
    }

    #[test]
    fn historical_tcc_refusal_is_not_a_current_blocker() {
        let log = "mci-capture-helper: live capture start failed: Code=-3801 \
                   \"The user declined TCC\"";
        let c = check_screen_recording(Some(log));
        assert_eq!(c.status, Status::Warn);
        assert!(c.detail.contains("current permission is unknown"));
    }

    #[test]
    fn historical_frames_do_not_prove_current_capture() {
        let c = check_screen_recording(Some("SCStream callback alive: first sample received."));
        assert_eq!(c.status, Status::Warn);
    }

    #[test]
    fn historical_missing_key_is_not_a_current_blocker() {
        let c = check_helper_key(Some(
            "mci-capture-helper: database key unavailable from Keychain",
        ));
        assert_eq!(c.status, Status::Warn);
    }

    #[test]
    fn receipt_freshness_and_frame_time_are_independent() {
        let now = parse_unix_ms("2026-09-05T12:00:30.000Z").unwrap();
        let mut receipt = CaptureStatus {
            schema_version: 1,
            updated_at: "2026-09-05T12:00:00.000Z".into(),
            last_stored_frame_at: Some("2026-09-05T11:59:59.000Z".into()),
            stored_frame_count: 4,
            stored_screenshot_count: 2,
            suppression_reason: None,
            blocked_reason: None,
        };
        assert_eq!(
            fresh_capture_checks(&receipt, now).unwrap()[0].status,
            Status::Pass
        );
        receipt.last_stored_frame_at = Some("2026-09-01T11:59:59.000Z".into());
        assert_eq!(
            fresh_capture_checks(&receipt, now).unwrap()[0].status,
            Status::Warn
        );
        assert!(fresh_capture_checks(&receipt, now + RECEIPT_FRESHNESS_MS).is_none());
        assert!(fresh_capture_checks(&receipt, now - 60_000).is_none());
        receipt.schema_version = 2;
        assert!(fresh_capture_checks(&receipt, now).is_none());
    }

    #[test]
    fn receipt_timestamp_parser_rejects_invalid_dates() {
        assert!(parse_unix_ms("2026-02-30T12:00:00.000Z").is_none());
        assert!(parse_unix_ms("2026-09-05T25:00:00.000Z").is_none());
        assert!(parse_unix_ms("2026-09-05T12:00:00.000X").is_none());
        assert_eq!(parse_unix_ms("1970-01-01T00:00:00.000Z"), Some(0));
        assert!(parse_unix_ms("2024-02-29T12:00:00.123Z").is_some());
    }

    #[test]
    fn render_separates_blockers_from_advisories() {
        let checks = vec![
            Check::new("a", Status::Fail, "broken", "do this"),
            Check::new("b", Status::Warn, "meh", "maybe this"),
            Check::new("c", Status::Pass, "fine", ""),
        ];
        let out = render(&checks);
        assert!(out.contains("Blocking:"));
        assert!(out.contains("Worth doing:"));
        assert!(out.contains("do this"));
        assert!(out.contains("maybe this"));
        assert!(!out.contains("Nothing to fix."));
        assert!(!out.contains("Review warnings above."));
    }

    #[test]
    fn render_says_so_when_everything_is_fine() {
        let out = render(&[Check::new("a", Status::Pass, "fine", "")]);
        assert!(out.contains("Nothing to fix."));
    }

    #[test]
    fn render_reviews_warnings_without_remediation() {
        let warning = Check::new(
            "capture runtime",
            Status::Warn,
            "suppressed: denylist-source",
            "",
        );
        for checks in [
            vec![warning.clone()],
            vec![Check::new("a", Status::Pass, "fine", ""), warning],
        ] {
            let out = render(&checks);
            assert!(!out.contains("Nothing to fix."));
            assert!(out.contains("Review warnings above."));
            assert!(out.contains("[warn]"));
            assert!(out.contains("denylist-source"));
            assert!(!out.contains("Blocking:"));
            assert!(!out.contains("Worth doing:"));
        }
    }

    #[test]
    fn render_reviews_warnings_with_remediation() {
        let out = render(&[Check::new("a", Status::Warn, "meh", "maybe this")]);
        assert!(out.contains("Review warnings above."));
        assert!(out.contains("Worth doing:"));
        assert!(out.contains("maybe this"));
        assert!(!out.contains("Nothing to fix."));
        assert!(!out.contains("Blocking:"));
    }

    #[test]
    fn render_does_not_claim_clean_when_no_checks_ran() {
        let out = render(&[]);
        assert!(!out.contains("Nothing to fix."));
        assert!(out.contains("No checks were run."));
        assert!(!out.contains("Review warnings above."));
    }
}
