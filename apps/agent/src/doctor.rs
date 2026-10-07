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
use crate::client_hooks::{self, CodexHooksFeature, HookPaths, HookPresence};
use crate::handoff_status::{self, RootFreshness, TranscriptRoots};
use crate::refresh_agent;
use crate::wall_clock::parse_unix_ms;
use mci_brain::{BrainStats, SqlCipherBrainStore};
use mci_core::crypto::DbKey;
use mci_core::store::Db;

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

/// Where the handoff layer's files live. `diagnose` builds one from `HOME`;
/// tests build one over a temporary home.
#[derive(Debug, Clone)]
pub struct HandoffProbe {
    /// Transcript roots for both agents.
    pub roots: TranscriptRoots,
    /// The two client hook files and the Codex feature switch.
    pub hooks: HookPaths,
    /// The background refresh `LaunchAgent` plist.
    pub refresh_plist: PathBuf,
    /// Seconds east of UTC, for the timestamps in the report.
    pub tz_offset_secs: i32,
}

impl HandoffProbe {
    /// Standard locations under `home`, with an optional Codex home override.
    #[must_use]
    pub fn for_home(home: &Path, codex_home: Option<&Path>, tz_offset_secs: i32) -> Self {
        Self {
            roots: TranscriptRoots::for_home(home, codex_home),
            hooks: HookPaths::for_home(home, codex_home),
            refresh_plist: refresh_agent::plist_path(home),
            tz_offset_secs,
        }
    }

    fn from_environment() -> Self {
        let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
        let codex_home = std::env::var_os("CODEX_HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from);
        Self::for_home(
            &home,
            codex_home.as_deref(),
            crate::brief_worker::current_tz_offset_secs(),
        )
    }
}

/// The handoff layer's two questions: are transcripts imported, and is the
/// packet reaching the agents? `db` is `None` when the brain could not be
/// opened for raw reads; the tables are then reported as unavailable.
#[must_use]
pub fn handoff_checks(db: Option<&Db>, probe: &HandoffProbe) -> Vec<Check> {
    vec![
        check_transcripts(db, probe),
        check_delivery(db, probe),
        check_refresh_agent(probe),
    ]
}

fn describe_root(freshness: &RootFreshness, have_cursors: bool, tz_offset_secs: i32) -> String {
    if !have_cursors {
        return format!("{} files", freshness.files);
    }
    match freshness.last_import_us {
        Some(last) => format!(
            "{} files, {} newer than last import ({})",
            freshness.files,
            freshness.newer,
            handoff_status::format_local_minute(last, tz_offset_secs)
        ),
        None => format!("{} files, none imported yet", freshness.files),
    }
}

/// Transcript files on disk against the `import_cursors` table.
fn check_transcripts(db: Option<&Db>, probe: &HandoffProbe) -> Check {
    let cursors = match db.map(handoff_status::read_import_cursors) {
        Some(Ok(cursors)) => cursors,
        Some(Err(error)) => {
            return Check::new(
                "transcripts",
                Status::Warn,
                format!("cannot read import_cursors: {error}"),
                "",
            );
        }
        None => None,
    };
    let claude_files = handoff_status::claude_transcript_files(&probe.roots.claude);
    let codex_files = handoff_status::codex_transcript_files(&probe.roots.codex);
    let claude =
        handoff_status::root_freshness(&probe.roots.claude, &claude_files, cursors.as_ref());
    let codex = handoff_status::root_freshness(&probe.roots.codex, &codex_files, cursors.as_ref());
    let have_cursors = cursors.is_some();
    let mut detail = format!(
        "claude-code: {}; codex: {}",
        describe_root(&claude, have_cursors, probe.tz_offset_secs),
        describe_root(&codex, have_cursors, probe.tz_offset_secs)
    );
    if !have_cursors {
        detail.push_str("; import cursors not available yet");
        return Check::new(
            "transcripts",
            Status::Warn,
            detail,
            "Run `mci-agent import-sessions` once. The refresh agent keeps it current after that.",
        );
    }
    if claude.files == 0 && codex.files == 0 {
        return Check::new(
            "transcripts",
            Status::Warn,
            format!(
                "no transcripts under {} or {}",
                probe.roots.claude.display(),
                probe.roots.codex.display()
            ),
            "",
        );
    }
    Check::new("transcripts", Status::Pass, detail, "")
}

/// Hook presence in both client files plus the newest `handoff_deliveries` row.
fn check_delivery(db: Option<&Db>, probe: &HandoffProbe) -> Check {
    let deliveries = match db.map(handoff_status::read_last_deliveries) {
        Some(Ok(rows)) => rows,
        Some(Err(error)) => {
            return Check::new(
                "delivery",
                Status::Warn,
                format!("cannot read handoff_deliveries: {error}"),
                "",
            );
        }
        None => None,
    };
    let mut parts: Vec<String> = Vec::new();
    let mut fixes: Vec<&str> = Vec::new();
    let mut missing = false;
    for (label, path) in [
        ("claude-code", &probe.hooks.claude_settings),
        ("codex", &probe.hooks.codex_hooks),
    ] {
        let presence = client_hooks::detect_handoff_hook(path);
        let mut part = match presence {
            HookPresence::Installed => format!("{label} hook installed"),
            HookPresence::NotInstalled | HookPresence::FileMissing => {
                missing = true;
                format!("{label} hook NOT installed")
            }
            HookPresence::Unreadable => {
                missing = true;
                format!("{label} hook file unreadable")
            }
        };
        if presence == HookPresence::Installed {
            match deliveries.as_ref().map(|rows| rows.get(label)) {
                Some(Some(row)) => {
                    let _ = write!(
                        part,
                        ", last packet {} for {} ({} tokens)",
                        handoff_status::format_local_minute(row.ts_us, probe.tz_offset_secs),
                        row.project_root,
                        row.token_estimate
                    );
                }
                Some(None) => part.push_str(", no packet delivered yet"),
                None => part.push_str(", deliveries not available yet"),
            }
        }
        parts.push(part);
    }
    if missing {
        fixes.push("Run `mci-agent connect --all` to install the SessionStart hooks.");
    }
    if client_hooks::claude_hooks_disabled(&probe.hooks.claude_settings) == Ok(true) {
        parts.push("claude-code hooks disabled by settings.json".into());
        fixes.push("Remove disableAllHooks from ~/.claude/settings.json so the hook can run.");
    }
    if client_hooks::codex_hooks_feature(&probe.hooks.codex_config)
        == Ok(CodexHooksFeature::Disabled)
    {
        parts.push("codex hooks disabled in config.toml".into());
        fixes.push(
            "Set hooks = true under [features] in ~/.codex/config.toml. Hippocampus never flips it.",
        );
    }
    let status = if fixes.is_empty() {
        Status::Pass
    } else {
        Status::Warn
    };
    Check::new("delivery", status, parts.join("; "), fixes.join(" "))
}

/// Is the background refresh `LaunchAgent` in place?
fn check_refresh_agent(probe: &HandoffProbe) -> Check {
    if !cfg!(target_os = "macos") {
        return Check::new(
            "refresh agent",
            Status::Pass,
            "launchd is only available on macOS; nothing to check",
            "",
        );
    }
    if probe.refresh_plist.is_file() {
        return Check::new(
            "refresh agent",
            Status::Pass,
            format!(
                "{} installed, runs `mci-agent refresh` every {} s",
                refresh_agent::LABEL,
                refresh_agent::START_INTERVAL_SECONDS
            ),
            "",
        );
    }
    Check::new(
        "refresh agent",
        Status::Warn,
        "not installed; packets only refresh when a session starts",
        "Run `mci-agent connect --all` to install it, or pass --no-refresh-agent to keep skipping it.",
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
    diagnose_with_probe(db_path, key, &HandoffProbe::from_environment())
}

/// [`diagnose`] with explicit handoff-layer paths, for tests.
///
/// # Errors
/// A message describing why the brain could not be opened.
pub fn diagnose_with_probe(
    db_path: &Path,
    key: &DbKey,
    probe: &HandoffProbe,
) -> Result<Vec<Check>, String> {
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
    drop(store);
    let raw = mci_core::store::open_readonly(db_path, key).ok();
    checks.extend(handoff_checks(raw.as_ref(), probe));
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

    const CONTRACT_TABLES_SQL: &str = "
        CREATE TABLE IF NOT EXISTS import_cursors (
          path          TEXT PRIMARY KEY,
          byte_offset   INTEGER NOT NULL,
          file_size     INTEGER NOT NULL,
          mtime_us      INTEGER NOT NULL,
          updated_at_us INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS handoff_deliveries (
          id             INTEGER PRIMARY KEY AUTOINCREMENT,
          ts_us          INTEGER NOT NULL,
          client         TEXT NOT NULL,
          project_root   TEXT NOT NULL,
          packet_sha256  TEXT NOT NULL,
          token_estimate INTEGER NOT NULL,
          event_ids      TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS handoff_deliveries_ts ON handoff_deliveries(ts_us);
    ";

    fn key() -> DbKey {
        DbKey::from_bytes([0xD0; 32])
    }

    /// A brain with the production schema, closed again so readers can open it.
    fn fresh_brain(dir: &Path) -> PathBuf {
        let path = dir.join("brain.sqlite");
        drop(SqlCipherBrainStore::new(&path, &key()).expect("create brain"));
        path
    }

    fn execute(path: &Path, sql: &str) {
        let db = mci_core::store::open(path, &key()).expect("open brain read-write");
        db.conn().execute_batch(sql).expect("execute");
    }

    fn write_transcript(path: &Path) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, "{}\n").unwrap();
    }

    fn probe(home: &Path) -> HandoffProbe {
        HandoffProbe::for_home(home, None, -7 * 3600)
    }

    fn line(checks: &[Check], name: &str) -> String {
        let check = checks.iter().find(|c| c.name == name).expect(name);
        format!("[{}] {}", check.status.marker(), check.detail)
    }

    #[test]
    fn handoff_checks_report_tables_as_unavailable_before_the_migrations() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let brain = fresh_brain(temp.path());
        // Migrations 0011 and 0012 create these on every fresh brain; an older
        // brain opened by a newer reader is the case this test keeps alive.
        execute(&brain, "DROP INDEX IF EXISTS handoff_deliveries_ts; DROP TABLE IF EXISTS handoff_deliveries; DROP TABLE IF EXISTS import_cursors;");
        write_transcript(&home.join(".claude/projects/-Users-amy-x/one.jsonl"));
        write_transcript(&home.join(".codex/sessions/2026/09/26/rollout.jsonl"));
        let db = mci_core::store::open_readonly(&brain, &key()).unwrap();

        let checks = handoff_checks(Some(&db), &probe(&home));

        assert_eq!(
            line(&checks, "transcripts"),
            "[warn] claude-code: 1 files; codex: 1 files; import cursors not available yet"
        );
        assert_eq!(
            line(&checks, "delivery"),
            "[warn] claude-code hook NOT installed; codex hook NOT installed"
        );
        assert!(checks
            .iter()
            .find(|c| c.name == "delivery")
            .unwrap()
            .fix
            .contains("connect --all"));
        assert_eq!(
            line(&checks, "refresh agent"),
            "[warn] not installed; packets only refresh when a session starts"
        );
    }

    #[test]
    fn handoff_checks_compare_mtimes_with_cursors_and_show_the_last_packet() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let brain = fresh_brain(temp.path());
        execute(&brain, CONTRACT_TABLES_SQL);
        let stale = home.join(".claude/projects/-Users-amy-x/stale.jsonl");
        let fresh = home.join(".claude/projects/-Users-amy-x/fresh.jsonl");
        let unseen = home.join(".claude/projects/-Users-amy-x/unseen.jsonl");
        let codex = home.join(".codex/sessions/2026/09/26/rollout.jsonl");
        for path in [&stale, &fresh, &unseen, &codex] {
            write_transcript(path);
        }
        // 2026-09-25T09:10:00Z is 02:10 at UTC-7. Cursors written "in the
        // future" cover the stale file; "in the past" leaves fresh newer.
        let far_future: u64 = 4_102_444_800_000_000;
        let imported_at: u64 = 1_790_327_400_000_000;
        execute(
            &brain,
            &format!(
                "INSERT INTO import_cursors (path, byte_offset, file_size, mtime_us, updated_at_us) VALUES ('{}', 10, 10, 1, {far_future});
                 INSERT INTO import_cursors (path, byte_offset, file_size, mtime_us, updated_at_us) VALUES ('{}', 10, 10, 1, {imported_at});
                 INSERT INTO import_cursors (path, byte_offset, file_size, mtime_us, updated_at_us) VALUES ('{}', 10, 10, 1, {far_future});
                 INSERT INTO handoff_deliveries (ts_us, client, project_root, packet_sha256, token_estimate, event_ids)
                 VALUES (1790415667000000, 'claude-code', '/Users/amy/hippo-work/hippocampus', 'abc', 583, '[1,2]'),
                        (1790415000000000, 'claude-code', '/Users/amy/older', 'def', 100, '[]'),
                        (1790415600000000, 'cli', '/Users/amy/cli', 'ghi', 50, '[]');",
                stale.display(),
                fresh.display(),
                codex.display()
            ),
        );
        let command = client_hooks::HookCommand::new(
            PathBuf::from("/Applications/Hippocampus.app/Contents/MacOS/mci-agent"),
            brain.clone(),
        );
        let paths = HookPaths::for_home(&home, None);
        client_hooks::install_claude_hook(&paths.claude_settings, &command).unwrap();
        std::fs::create_dir_all(paths.codex_config.parent().unwrap()).unwrap();
        std::fs::write(&paths.codex_config, "[features]\nhooks = false\n").unwrap();
        let db = mci_core::store::open_readonly(&brain, &key()).unwrap();

        let checks = handoff_checks(Some(&db), &probe(&home));

        assert_eq!(
            line(&checks, "transcripts"),
            "[ok  ] claude-code: 3 files, 2 newer than last import (2099-12-31 17:00); \
             codex: 1 files, 0 newer than last import (2099-12-31 17:00)"
        );
        assert_eq!(
            line(&checks, "delivery"),
            "[warn] claude-code hook installed, last packet 2026-09-26 02:41 for \
             /Users/amy/hippo-work/hippocampus (583 tokens); codex hook NOT installed; \
             codex hooks disabled in config.toml"
        );
        let delivery = checks.iter().find(|c| c.name == "delivery").unwrap();
        assert!(delivery.fix.contains("connect --all"));
        assert!(delivery.fix.contains("hooks = true"));
        assert_eq!(
            std::fs::read_to_string(&paths.codex_config).unwrap(),
            "[features]\nhooks = false\n",
            "the feature switch is reported, never flipped"
        );

        client_hooks::install_codex_hook(&paths.codex_hooks, &command).unwrap();
        std::fs::write(&paths.codex_config, "[features]\nhooks = true\n").unwrap();
        std::fs::create_dir_all(probe(&home).refresh_plist.parent().unwrap()).unwrap();
        std::fs::write(&probe(&home).refresh_plist, "<plist/>").unwrap();
        let checks = handoff_checks(Some(&db), &probe(&home));
        assert_eq!(
            line(&checks, "delivery"),
            "[ok  ] claude-code hook installed, last packet 2026-09-26 02:41 for \
             /Users/amy/hippo-work/hippocampus (583 tokens); codex hook installed, \
             no packet delivered yet"
        );
        assert_eq!(
            line(&checks, "refresh agent"),
            "[ok  ] ai.hippocampus.refresh installed, runs `mci-agent refresh` every 300 s"
        );
    }

    #[test]
    fn diagnose_with_probe_appends_the_handoff_sections_to_the_report() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        let brain = fresh_brain(temp.path());
        execute(&brain, "DROP INDEX IF EXISTS handoff_deliveries_ts; DROP TABLE IF EXISTS handoff_deliveries; DROP TABLE IF EXISTS import_cursors;");

        let checks = diagnose_with_probe(&brain, &key(), &probe(&home)).unwrap();
        let names: Vec<&str> = checks.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names[0], "events");
        assert_eq!(
            &names[names.len() - 3..],
            ["transcripts", "delivery", "refresh agent"]
        );
        let report = render(&checks);
        assert!(report.contains(
            "[warn] transcripts        claude-code: 0 files; codex: 0 files; import cursors not available yet"
        ));
        assert!(report.contains(
            "[warn] delivery           claude-code hook NOT installed; codex hook NOT installed"
        ));
        assert!(
            !report.contains('\u{2014}'),
            "no em dashes in doctor output"
        );
    }

    #[test]
    fn render_does_not_claim_clean_when_no_checks_ran() {
        let out = render(&[]);
        assert!(!out.contains("Nothing to fix."));
        assert!(out.contains("No checks were run."));
        assert!(!out.contains("Review warnings above."));
    }
}
