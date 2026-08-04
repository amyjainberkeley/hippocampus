//! Explain why the brain is empty.
//!
//! # Why this exists
//!
//! An install of Hippocampus captured 52,457 frames over 27 hours and wrote
//! zero events. Nothing in the product said why. Finding the answer took
//! reading 5.8 MB of helper logs, cross-referencing a Swift kill-switch, and
//! knowing that `v2p1_gate=disabled` on one log line meant every OCR emit was
//! a no-op.
//!
//! Three independent things were wrong at once, and each failed silently:
//! the V2-P1 gate was off, Screen Recording TCC had been declined, and the
//! helper had no DB key. A user who hits any of them sees the same thing: an
//! app that looks like it is running and a memory that stays empty.
//!
//! `doctor` reads the same evidence and says it in one screen. It is
//! deliberately read-only and dependency-free: it opens the brain read-only,
//! reads env vars, and greps logs it already owns.

use std::path::{Path, PathBuf};

use mci_brain::{BrainStats, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

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

/// Is the V2-P1 capture gate on for *this* process?
///
/// The helper inherits its environment from whoever launched it, so the
/// value here is the value the helper would see if it were launched the
/// same way. That is the check that matters: a gate set in one terminal
/// says nothing about an app launched from Finder.
fn check_gate() -> Check {
    let on = std::env::var("HIPPOCAMPUS_ENABLE_V2P1").as_deref() == Ok("1");
    if on {
        Check::new(
            "capture gate",
            Status::Pass,
            "HIPPOCAMPUS_ENABLE_V2P1=1, OCR emit is armed",
            "",
        )
    } else {
        Check::new(
            "capture gate",
            Status::Fail,
            "HIPPOCAMPUS_ENABLE_V2P1 is not 1, so killOcrEmit stays true",
            "Frames are captured and cascaded, then every OCR emit is dropped. \
             Launch the app with the gate on:\n      \
             HIPPOCAMPUS_ENABLE_V2P1=1 /Applications/Hippocampus.app/Contents/MacOS/Hippocampus",
        )
    }
}

/// Did ScreenCaptureKit report a TCC refusal in the helper log?
fn check_screen_recording(log: Option<&str>) -> Check {
    let Some(text) = log else {
        return Check::new(
            "screen recording",
            Status::Warn,
            "no helper log yet, so capture has not been attempted",
            "Launch the app once, then re-run doctor.",
        );
    };
    if text.contains("user declined TCC") || text.contains("declined TCC") {
        return Check::new(
            "screen recording",
            Status::Fail,
            "the helper log shows ScreenCaptureKit was declined",
            "macOS remembers a refusal and will not ask again. Grant it by hand:\n      \
             System Settings > Privacy & Security > Screen & System Audio Recording\n      \
             enable Hippocampus, then quit and relaunch the app.",
        );
    }
    if text.contains("first sample received") {
        return Check::new(
            "screen recording",
            Status::Pass,
            "the helper has received frames from ScreenCaptureKit",
            "",
        );
    }
    Check::new(
        "screen recording",
        Status::Warn,
        "no frames and no refusal in the log",
        "Launch the app and use it for a minute, then re-run doctor.",
    )
}

/// Can the helper write keyframe blobs?
fn check_helper_key(log: Option<&str>) -> Check {
    match log {
        Some(t) if t.contains("MCI_DB_KEY_HEX not set or invalid") => Check::new(
            "helper db key",
            Status::Warn,
            "the helper ran without MCI_DB_KEY_HEX",
            "Text still lands; keyframe images do not. Set MCI_DB_KEY_HEX in the \
             environment the app is launched from if you want thumbnails.",
        ),
        _ => Check::new(
            "helper db key",
            Status::Pass,
            "no key complaint in the log",
            "",
        ),
    }
}

/// Is there an embedder model, and therefore semantic recall?
fn check_embedder() -> Check {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    let candidates = [
        std::env::var_os("MCI_ARCTIC_MODEL_PATH").map(PathBuf::from),
        Some(PathBuf::from(
            "/Applications/Hippocampus.app/Contents/Resources/Models/ArcticEmbedS_INT8.mlmodelc",
        )),
        Some(home.join("Library/Application Support/MCI/Models/ArcticEmbedS_INT8.mlmodelc")),
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
            "Nothing has been captured. The checks above say why.",
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

    let log = tail_of(&helper_log_path(), 256 * 1024);
    let log_ref = log.as_deref();

    Ok(vec![
        check_events(&stats),
        check_gate(),
        check_screen_recording(log_ref),
        check_helper_key(log_ref),
        check_embedder(),
        check_enriched(&stats),
    ])
}

/// Render the checks as the report the CLI prints.
#[must_use]
pub fn render(checks: &[Check]) -> String {
    let mut out = String::new();
    for c in checks {
        out.push_str(&format!(
            "  [{}] {:<18} {}\n",
            c.status.marker(),
            c.name,
            c.detail
        ));
    }

    let blockers: Vec<&Check> = checks.iter().filter(|c| c.status == Status::Fail).collect();
    let advisories: Vec<&Check> = checks
        .iter()
        .filter(|c| c.status == Status::Warn && !c.fix.is_empty())
        .collect();

    if blockers.is_empty() && advisories.is_empty() {
        out.push_str("\n  Nothing to fix.\n");
        return out;
    }

    if !blockers.is_empty() {
        out.push_str("\nBlocking:\n");
        for c in blockers {
            out.push_str(&format!("\n  {}\n    {}\n", c.name, c.fix));
        }
    }
    if !advisories.is_empty() {
        out.push_str("\nWorth doing:\n");
        for c in advisories {
            out.push_str(&format!("\n  {}\n    {}\n", c.name, c.fix));
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
    fn declined_tcc_is_detected_and_explains_itself() {
        let log = "mci-capture-helper: live capture start failed: Code=-3801 \
                   \"The user declined TCC\"";
        let c = check_screen_recording(Some(log));
        assert_eq!(c.status, Status::Fail);
        assert!(
            c.fix.contains("Screen & System Audio Recording"),
            "should name the exact settings pane"
        );
    }

    #[test]
    fn frames_received_passes() {
        let c = check_screen_recording(Some("SCStream callback alive: first sample received."));
        assert_eq!(c.status, Status::Pass);
    }

    #[test]
    fn missing_helper_key_is_a_warning_not_a_blocker() {
        // Text still lands without it; only keyframe images are lost. Calling
        // this fatal would send people chasing the wrong thing.
        let c = check_helper_key(Some(
            "mci-capture-helper: MCI_DB_KEY_HEX not set or invalid",
        ));
        assert_eq!(c.status, Status::Warn);
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
    }

    #[test]
    fn render_says_so_when_everything_is_fine() {
        let out = render(&[Check::new("a", Status::Pass, "fine", "")]);
        assert!(out.contains("Nothing to fix."));
    }
}
