//! Daily-brief generator cron — ADR-0028 + ADR-0018.
//!
//! Same shutdown-channel / tokio task shape as
//! [`retention_worker`](crate::retention_worker). Each cycle:
//!
//! 1. Sleep until the next local-time fire (default 06:00).
//! 2. Query the last 24 h of OCR events from the brain.
//! 3. Pass them to a freshly-constructed [`BriefAuthor`] (loaded from
//!    the model factory; lazily so the ~500 MB working set is only
//!    resident during generation per ADR-0028 §6).
//! 4. Insert the resulting brief into the `briefs` table.
//!
//! # First-launch path
//!
//! If the briefs table is empty AND the brain has captured events for
//! ≥4 h of wall-clock, the worker fires a "partial day" brief on the
//! spot so the user sees their first brief end-of-day-one instead of
//! day-two morning.
//!
//! # Disable path
//!
//! When `MCI_BRIEFS_DISABLED=1` is set OR the Qwen3 `.mlmodelc` is not
//! present in `~/Library/Application Support/MCI/Models/`, the worker
//! logs a single line and idles on the shutdown channel — no busy-loop,
//! no repeated failure logs.
//!
//! # Privacy invariants
//!
//! - WRITES only `briefs` rows; never modifies `events` (ADR-0018 §4.2).
//! - Reads only `.allow`-stored events via `events_since` (suppressed
//!   events have no row in `events` by construction; ADR-0016 §4.3).
//! - The author runs entirely on-device — no network. ADR-0018 §4.6.
//! - Brief is written in `Draft` state structurally; auto-approve is
//!   structurally banned (ADR-0018 §4.1). The lifecycle state lives in
//!   the brief row's content; the briefs table itself does not store
//!   `BriefState` — Tier-2 syncs are gated separately by ADR-0019.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use mci_brain::{BriefRow, SqlCipherBrainStore};
use mci_brief::author::BriefAuthor;
use tokio::sync::watch;

use crate::wall_clock::format_unix_ms;

/// Default target hour for the daily brief, local time. 06:00.
pub const DEFAULT_BRIEF_HOUR: u32 = 6;

/// Cap on events fed to the author in one cycle. ~2 K events is well
/// past the Qwen3-1.7B fixed-2048-token context — the author truncates
/// internally. The cap is a defence against the brain runaway case.
pub const MAX_EVENTS_PER_BRIEF: usize = 2048;

/// Minimum wall-clock elapsed since the oldest event before the
/// first-launch path fires a partial-day brief.
pub const FIRST_BRIEF_MIN_AGE: Duration = Duration::from_secs(4 * 3600);

/// Minimum sleep between fires. Guards against clock-skew + DST shifts
/// that could otherwise compute a near-zero (or negative) wait.
pub const MIN_SLEEP: Duration = Duration::from_secs(60);

/// Errors the brief worker can surface.
#[derive(Debug, thiserror::Error)]
pub enum BriefWorkerError {
    /// A cycle failed fatally (join error).
    #[error("brief-worker: {0}")]
    Fatal(String),
    /// The author backend failed.
    #[error("brief-worker: author: {0}")]
    Author(String),
    /// The brain store call failed.
    #[error("brief-worker: store: {0}")]
    Store(String),
}

/// Stats reported when the worker exits.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct BriefWorkerStats {
    /// Number of briefs generated and stored.
    pub briefs_generated: u64,
    /// Number of cycles that ran but produced no brief because the
    /// 24 h window held no events.
    pub cycles_skipped_empty: u64,
    /// Cycles that errored (logged, not fatal).
    pub cycle_errors: u64,
    /// True if the worker entered disabled-idle mode and never fired.
    pub disabled: bool,
}

/// Factory that constructs a fresh [`BriefAuthor`] for one cycle.
///
/// Constructed inside [`tokio::task::spawn_blocking`] so model load
/// (~1-2 s on M-series; longer on first ANE compile) does not block
/// the tokio runtime. Dropped at the end of each cycle so the ~500 MB
/// working set is only resident during generation per ADR-0028 §6.
pub type AuthorFactory =
    Arc<dyn Fn() -> Result<Box<dyn BriefAuthor>, BriefWorkerError> + Send + Sync>;

/// True if briefs are disabled via the `MCI_BRIEFS_DISABLED=1` env var.
#[must_use]
pub fn briefs_disabled_via_env() -> bool {
    std::env::var("MCI_BRIEFS_DISABLED").as_deref() == Ok("1")
}

/// Default install path for the Qwen3 Core ML model on macOS.
#[must_use]
pub fn default_model_dir() -> PathBuf {
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    home.join("Library/Application Support/MCI/Models")
}

/// Filename of the Qwen3 Core ML model on disk. Must match
/// `apps/hippocampus/Resources/models.json`'s `downloadURL` filename
/// stem (without the `.tar.gz`).
pub const QWEN3_MODEL_BASENAME: &str = "Qwen3-1.7B-FP16.mlmodelc";

/// `modelID` from `apps/hippocampus/Resources/models.json`. The Swift-side
/// `ModelDownloadManager` unpacks the tarball into a per-`modelID`
/// subdirectory under [`default_model_dir`], so the on-disk path is
/// `<model_dir>/<QWEN3_MODEL_ID>/<QWEN3_MODEL_BASENAME>/...`. Keep this
/// constant in sync with the manifest.
pub const QWEN3_MODEL_ID: &str = "qwen3-1.7b-fp16";

/// True if the Qwen3 `.mlmodelc` is present under `model_dir`.
///
/// Checks `<model_dir>/<QWEN3_MODEL_ID>/<QWEN3_MODEL_BASENAME>` — the
/// canonical layout written by `ModelDownloadManager`'s unpack step.
#[must_use]
pub fn qwen3_model_present(model_dir: &std::path::Path) -> bool {
    model_dir
        .join(QWEN3_MODEL_ID)
        .join(QWEN3_MODEL_BASENAME)
        .exists()
}

/// Run the daily brief loop until the shutdown signal fires.
///
/// `tz_offset_resolver` returns the local timezone offset (in seconds
/// east of UTC) — production passes [`current_tz_offset_secs`], tests
/// pass a fixed offset.
pub async fn run_brief_worker(
    store: Arc<SqlCipherBrainStore>,
    author_factory: AuthorFactory,
    brief_hour: u32,
    tz_offset_resolver: Arc<dyn Fn() -> i32 + Send + Sync>,
    mut shutdown: watch::Receiver<bool>,
) -> Result<BriefWorkerStats, BriefWorkerError> {
    let mut stats = BriefWorkerStats::default();

    // First-launch check: fire a partial-day brief if appropriate.
    match first_launch_decision(&store).await {
        Ok(true) => {
            match run_one_cycle(&store, &author_factory, "First brief", &tz_offset_resolver).await {
                Ok(CycleOutcome::Stored {
                    date_local,
                    word_count,
                    event_count,
                    id,
                }) => {
                    stats.briefs_generated += 1;
                    eprintln!(
                    "mci-agent: brief generated for {date_local} (first-launch, id={id}, {event_count} events, {word_count} words)"
                );
                }
                Ok(CycleOutcome::SkippedEmpty) => {
                    stats.cycles_skipped_empty += 1;
                }
                Err(e) => {
                    stats.cycle_errors += 1;
                    eprintln!("mci-agent: first-launch brief error: {e}");
                }
            }
        }
        Ok(false) => {}
        Err(e) => {
            stats.cycle_errors += 1;
            eprintln!("mci-agent: first-launch decision error: {e}");
        }
    }

    loop {
        if *shutdown.borrow() {
            break;
        }

        let tz_off = (tz_offset_resolver)();
        let now_secs = unix_now_secs();
        let target_secs = next_fire_secs(now_secs, tz_off, brief_hour);
        let min_sleep_i64 = i64::try_from(MIN_SLEEP.as_secs()).unwrap_or(60);
        let sleep_secs = (target_secs - now_secs).max(min_sleep_i64);
        let sleep_dur = Duration::from_secs(u64::try_from(sleep_secs).unwrap_or(60));

        tokio::select! {
            () = tokio::time::sleep(sleep_dur) => {}
            _ = shutdown.changed() => break,
        }

        if *shutdown.borrow() {
            break;
        }

        match run_one_cycle(&store, &author_factory, "Daily brief", &tz_offset_resolver).await {
            Ok(CycleOutcome::Stored {
                date_local,
                word_count,
                event_count,
                id,
            }) => {
                stats.briefs_generated += 1;
                eprintln!(
                    "mci-agent: brief generated for {date_local} (id={id}, {event_count} events, {word_count} words)"
                );
            }
            Ok(CycleOutcome::SkippedEmpty) => {
                stats.cycles_skipped_empty += 1;
                eprintln!("mci-agent: brief skipped (no events in 24 h window)");
            }
            Err(e) => {
                stats.cycle_errors += 1;
                eprintln!("mci-agent: brief cycle error: {e}");
            }
        }
    }

    Ok(stats)
}

/// Disabled-idle mode: log once, then sleep on the shutdown channel.
///
/// Used when the model is not present OR `MCI_BRIEFS_DISABLED=1`. The
/// task exits cleanly on shutdown; no work happens between launch and
/// exit beyond the single log line.
pub async fn run_disabled_idle(
    reason: &str,
    mut shutdown: watch::Receiver<bool>,
) -> BriefWorkerStats {
    eprintln!("mci-agent: brief worker disabled ({reason}); will sleep until shutdown");
    let _ = shutdown.changed().await;
    BriefWorkerStats {
        disabled: true,
        ..BriefWorkerStats::default()
    }
}

/// Outcome of one brief cycle. Used internally for stats accounting.
enum CycleOutcome {
    Stored {
        date_local: String,
        word_count: u32,
        event_count: u32,
        id: u64,
    },
    SkippedEmpty,
}

async fn run_one_cycle(
    store: &Arc<SqlCipherBrainStore>,
    factory: &AuthorFactory,
    topic: &str,
    tz_offset_resolver: &Arc<dyn Fn() -> i32 + Send + Sync>,
) -> Result<CycleOutcome, BriefWorkerError> {
    let now_us = unix_now_us();
    let since_us = now_us.saturating_sub(24 * 3600 * 1_000_000);

    let store_for_query = Arc::clone(store);
    let records = tokio::task::spawn_blocking(move || {
        store_for_query.events_since(since_us, MAX_EVENTS_PER_BRIEF)
    })
    .await
    .map_err(|e| BriefWorkerError::Fatal(format!("events_since join: {e}")))?
    .map_err(|e| BriefWorkerError::Store(format!("events_since: {e}")))?;

    if records.is_empty() {
        return Ok(CycleOutcome::SkippedEmpty);
    }

    let event_count = u32::try_from(records.len()).unwrap_or(u32::MAX);
    let factory_c = Arc::clone(factory);
    let topic_owned = topic.to_owned();
    let records_for_author = records;
    let brief = tokio::task::spawn_blocking(
        move || -> Result<mci_brief::model::Brief, BriefWorkerError> {
            let author = (factory_c)()?;
            author
                .author(&records_for_author, &topic_owned)
                .map_err(|e| BriefWorkerError::Author(e.to_string()))
        },
    )
    .await
    .map_err(|e| BriefWorkerError::Fatal(format!("author join: {e}")))??;

    let body = brief.body;
    let title = brief.title;
    let word_count = u32::try_from(body.split_whitespace().count()).unwrap_or(u32::MAX);
    let tz_off = (tz_offset_resolver)();
    let now_secs = i64::try_from(now_us / 1_000_000).unwrap_or(i64::MAX);
    let date_local = local_date_string(now_secs, tz_off);

    let row = BriefRow {
        id: 0,
        date_local: date_local.clone(),
        generated_ts_us: now_us,
        model_id: "qwen3-1.7b-fp16".to_owned(),
        model_version: "1.0".to_owned(),
        title,
        body,
        word_count,
        source_event_count: event_count,
    };

    let store_for_write = Arc::clone(store);
    let row_for_write = row;
    let id = tokio::task::spawn_blocking(move || store_for_write.put_brief(&row_for_write))
        .await
        .map_err(|e| BriefWorkerError::Fatal(format!("put_brief join: {e}")))?
        .map_err(|e| BriefWorkerError::Store(format!("put_brief: {e}")))?;

    Ok(CycleOutcome::Stored {
        date_local,
        word_count,
        event_count,
        id,
    })
}

/// Decide whether the first-launch path should fire on startup.
///
/// Fires iff the briefs table is empty AND the brain has at least one
/// event AND the oldest event is at least [`FIRST_BRIEF_MIN_AGE`] old.
async fn first_launch_decision(store: &Arc<SqlCipherBrainStore>) -> Result<bool, BriefWorkerError> {
    let store_c = Arc::clone(store);
    let (brief_count, oldest_ts_us) = tokio::task::spawn_blocking(move || {
        let bc = store_c.brief_count()?;
        let stats = store_c.stats()?;
        Ok::<_, mci_brain::StoreError>((bc, stats.oldest_ts_us))
    })
    .await
    .map_err(|e| BriefWorkerError::Fatal(format!("first_launch join: {e}")))?
    .map_err(|e| BriefWorkerError::Store(format!("first_launch read: {e}")))?;

    Ok(should_fire_first_brief(
        brief_count,
        oldest_ts_us,
        unix_now_us(),
    ))
}

/// Pure: should the first-launch brief fire?
#[must_use]
pub fn should_fire_first_brief(
    brief_count: u64,
    oldest_event_us: Option<u64>,
    now_us: u64,
) -> bool {
    if brief_count > 0 {
        return false;
    }
    match oldest_event_us {
        Some(oldest) if now_us > oldest => {
            let age_us = now_us - oldest;
            let min_age_us = u64::try_from(FIRST_BRIEF_MIN_AGE.as_micros()).unwrap_or(u64::MAX);
            age_us >= min_age_us
        }
        _ => false,
    }
}

/// Pure: compute the next UTC second when the local clock will read
/// `target_hour:00:00`.
///
/// `tz_offset_secs` is the local zone's offset in seconds east of UTC
/// (e.g. PST = -28800, IST = +19800). DST mid-day transitions are
/// not handled precisely — if a DST shift happens between `now` and
/// the fire time, the fire will land ~1 h off the user-perceived hour.
/// Acceptable for daily-brief use; tested-against-edge-cases for
/// timezone math.
#[must_use]
pub fn next_fire_secs(now_utc_secs: i64, tz_offset_secs: i32, target_hour: u32) -> i64 {
    let local_now = now_utc_secs.saturating_add(i64::from(tz_offset_secs));
    let secs_of_day = local_now.rem_euclid(86_400);
    let target_secs_of_day = i64::from(target_hour) * 3600;
    let delta = if secs_of_day < target_secs_of_day {
        target_secs_of_day - secs_of_day
    } else {
        86_400 - secs_of_day + target_secs_of_day
    };
    now_utc_secs.saturating_add(delta)
}

/// Pure: render the local-clock date in `YYYY-MM-DD` form for the given
/// UTC second + local-zone offset.
#[must_use]
pub fn local_date_string(unix_secs: i64, tz_offset_secs: i32) -> String {
    let local_secs = unix_secs.saturating_add(i64::from(tz_offset_secs)).max(0);
    let ms = u128::from(u64::try_from(local_secs).unwrap_or(0)).saturating_mul(1000);
    let rfc = format_unix_ms(ms);
    // `format_unix_ms` always returns `YYYY-MM-DDTHH:MM:SS.sssZ`.
    rfc[..10].to_owned()
}

/// Resolve the system's current local-zone offset in seconds east of
/// UTC by shelling out to `date +%z`. Returns 0 on any failure.
///
/// The codebase forbids `unsafe_code` in `apps/agent` so we cannot call
/// `localtime_r` directly. Shelling out to `date` is the cheapest portable
/// way to get the current offset; called once per worker cycle (i.e.
/// once a day) so the cost is irrelevant.
#[must_use]
pub fn current_tz_offset_secs() -> i32 {
    if let Ok(override_str) = std::env::var("MCI_BRIEF_TZ_OFFSET_SECONDS") {
        if let Ok(v) = override_str.parse::<i32>() {
            return v;
        }
    }
    let output = match std::process::Command::new("date").arg("+%z").output() {
        Ok(o) if o.status.success() => o,
        _ => return 0,
    };
    let s = match std::str::from_utf8(&output.stdout) {
        Ok(s) => s.trim(),
        Err(_) => return 0,
    };
    parse_tz_offset(s).unwrap_or(0)
}

/// Parse `+HHMM` / `-HHMM` form into seconds east of UTC.
#[must_use]
pub fn parse_tz_offset(s: &str) -> Option<i32> {
    if s.len() != 5 {
        return None;
    }
    let bytes = s.as_bytes();
    let sign: i32 = match bytes[0] {
        b'+' => 1,
        b'-' => -1,
        _ => return None,
    };
    let hh: i32 = std::str::from_utf8(&bytes[1..3]).ok()?.parse().ok()?;
    let mm: i32 = std::str::from_utf8(&bytes[3..5]).ok()?.parse().ok()?;
    if !(0..=23).contains(&hh) || !(0..=59).contains(&mm) {
        return None;
    }
    Some(sign * (hh * 3600 + mm * 60))
}

fn unix_now_secs() -> i64 {
    i64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
    )
    .unwrap_or(0)
}

fn unix_now_us() -> u64 {
    u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_micros(),
    )
    .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use mci_brief::author::StubBriefAuthor;

    // ---------------- parse_tz_offset ----------------

    #[test]
    fn parse_tz_offset_pst() {
        assert_eq!(parse_tz_offset("-0800"), Some(-8 * 3600));
    }

    #[test]
    fn parse_tz_offset_pdt() {
        assert_eq!(parse_tz_offset("-0700"), Some(-7 * 3600));
    }

    #[test]
    fn parse_tz_offset_ist_half_hour() {
        assert_eq!(parse_tz_offset("+0530"), Some(5 * 3600 + 30 * 60));
    }

    #[test]
    fn parse_tz_offset_utc() {
        assert_eq!(parse_tz_offset("+0000"), Some(0));
    }

    #[test]
    fn parse_tz_offset_rejects_missing_sign() {
        assert_eq!(parse_tz_offset("0500"), None);
        assert_eq!(parse_tz_offset("00500"), None);
    }

    #[test]
    fn parse_tz_offset_rejects_bad_length() {
        assert_eq!(parse_tz_offset(""), None);
        assert_eq!(parse_tz_offset("+05"), None);
        assert_eq!(parse_tz_offset("+05300"), None);
    }

    #[test]
    fn parse_tz_offset_rejects_out_of_range() {
        // 24:00 is invalid even if HHMM parses.
        assert_eq!(parse_tz_offset("+2400"), None);
        assert_eq!(parse_tz_offset("+0060"), None);
    }

    // ---------------- next_fire_secs ----------------

    // 2026-05-19T00:00:00Z = unix 1_779_148_800. The wall_clock test
    // already pins 2026-05-19T04:00:00Z as 1_779_163_200; midnight
    // is that minus 4 h = 1_779_148_800.
    const MIDNIGHT_2026_05_19_UTC: i64 = 1_779_148_800;

    #[test]
    fn next_fire_secs_at_utc_midnight_fires_at_six() {
        // UTC midnight, UTC tz (offset 0), target hour 6 → fire in 6 h.
        let now = MIDNIGHT_2026_05_19_UTC;
        let next = next_fire_secs(now, 0, 6);
        assert_eq!(next - now, 6 * 3600);
    }

    #[test]
    fn next_fire_secs_just_after_target_fires_next_day() {
        // Local 06:00:01 → next fire is 23 h 59 m 59 s later.
        let now = MIDNIGHT_2026_05_19_UTC + 6 * 3600 + 1;
        let next = next_fire_secs(now, 0, 6);
        assert_eq!(next - now, 86_400 - 1);
    }

    #[test]
    fn next_fire_secs_exactly_at_target_fires_next_day() {
        // At exactly 06:00:00 we choose the NEXT day (not zero-delta).
        let now = MIDNIGHT_2026_05_19_UTC + 6 * 3600;
        let next = next_fire_secs(now, 0, 6);
        assert_eq!(next - now, 86_400);
    }

    #[test]
    fn next_fire_secs_pst_winter() {
        // 2026-05-19T00:00:00 UTC = 2026-05-18T16:00:00 PST (offset -8h).
        // Next local 06:00 = 2026-05-19T06:00 PST = 2026-05-19T14:00 UTC.
        // Delta = 14 h.
        let now = MIDNIGHT_2026_05_19_UTC;
        let next = next_fire_secs(now, -8 * 3600, 6);
        assert_eq!(next - now, 14 * 3600);
    }

    #[test]
    fn next_fire_secs_ist_half_hour_offset() {
        // 2026-05-19T00:00:00 UTC = 2026-05-19T05:30:00 IST (+05:30).
        // Next local 06:00 IST is 30 min later → 2026-05-19T00:30:00 UTC.
        let now = MIDNIGHT_2026_05_19_UTC;
        let offset = 5 * 3600 + 30 * 60;
        let next = next_fire_secs(now, offset, 6);
        assert_eq!(next - now, 30 * 60);
    }

    #[test]
    fn next_fire_secs_negative_tz_extreme() {
        // Samoa-style +14h: at UTC midnight, local is 14:00. Next local
        // 06:00 lands tomorrow at 16:00 UTC → 16 h delta.
        let now = MIDNIGHT_2026_05_19_UTC;
        let next = next_fire_secs(now, 14 * 3600, 6);
        assert_eq!(next - now, 16 * 3600);
    }

    #[test]
    fn next_fire_secs_dst_shift_within_window() {
        // We don't try to handle DST mid-flight: the test pins that the
        // offset passed in is what's used. A real DST shift will be
        // picked up on the next loop iteration. Verify we use the
        // offset as given.
        let now = MIDNIGHT_2026_05_19_UTC;
        // PDT (offset = -7h). Local time = 17:00. Next local 06:00 lands
        // 13 h later UTC.
        let next = next_fire_secs(now, -7 * 3600, 6);
        assert_eq!(next - now, 13 * 3600);
    }

    // ---------------- local_date_string ----------------

    #[test]
    fn local_date_string_utc() {
        // 2026-05-19T04:00:00Z, offset 0 → "2026-05-19"
        assert_eq!(local_date_string(1_779_163_200, 0), "2026-05-19");
    }

    #[test]
    fn local_date_string_pst_crosses_to_previous_day() {
        // 2026-05-19T04:00:00 UTC = 2026-05-18T20:00 PST.
        assert_eq!(local_date_string(1_779_163_200, -8 * 3600), "2026-05-18");
    }

    #[test]
    fn local_date_string_ist_advances_to_next_day() {
        // 2026-05-19T20:00:00 UTC = 2026-05-20T01:30 IST.
        let utc = 1_779_163_200 + 16 * 3600;
        let off = 5 * 3600 + 30 * 60;
        assert_eq!(local_date_string(utc, off), "2026-05-20");
    }

    // ---------------- should_fire_first_brief ----------------

    #[test]
    fn first_brief_fires_when_4h_old_and_empty() {
        let now = 5_000_000_000_000_u64;
        let oldest = now - (4 * 3600 + 60) * 1_000_000;
        assert!(should_fire_first_brief(0, Some(oldest), now));
    }

    #[test]
    fn first_brief_does_not_fire_below_4h() {
        let now = 5_000_000_000_000_u64;
        let oldest = now - (2 * 3600) * 1_000_000;
        assert!(!should_fire_first_brief(0, Some(oldest), now));
    }

    #[test]
    fn first_brief_does_not_fire_when_brief_exists() {
        let now = 5_000_000_000_000_u64;
        let oldest = now - (24 * 3600) * 1_000_000;
        assert!(!should_fire_first_brief(1, Some(oldest), now));
    }

    #[test]
    fn first_brief_does_not_fire_with_no_events() {
        let now = 5_000_000_000_000_u64;
        assert!(!should_fire_first_brief(0, None, now));
    }

    #[test]
    fn first_brief_clock_skew_returns_false() {
        // Oldest event in the future (clock skew). Don't fire.
        let now = 5_000_000_000_000_u64;
        let oldest = now + 10_000_000;
        assert!(!should_fire_first_brief(0, Some(oldest), now));
    }

    // ---------------- briefs_disabled_via_env ----------------

    #[test]
    fn briefs_disabled_via_env_reads_var() {
        // SAFETY: tests run sequentially under cargo test with the
        // current-thread runtime; this var is reset before exit. The
        // sole reader (briefs_disabled_via_env) just compares the env
        // var literally so no other test that runs in the same process
        // is sensitive to the value.
        std::env::set_var("MCI_BRIEFS_DISABLED", "1");
        assert!(briefs_disabled_via_env());
        std::env::set_var("MCI_BRIEFS_DISABLED", "0");
        assert!(!briefs_disabled_via_env());
        std::env::remove_var("MCI_BRIEFS_DISABLED");
        assert!(!briefs_disabled_via_env());
    }

    // ---------------- model_present ----------------

    #[test]
    fn qwen3_model_present_false_when_absent() {
        let dir = tempfile::tempdir().unwrap();
        assert!(!qwen3_model_present(dir.path()));
    }

    #[test]
    fn qwen3_model_present_true_when_subdir_exists() {
        // Mirrors the on-disk layout written by `ModelDownloadManager`:
        // `<model_dir>/qwen3-1.7b-fp16/Qwen3-1.7B-FP16.mlmodelc/`.
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(QWEN3_MODEL_ID).join(QWEN3_MODEL_BASENAME))
            .unwrap();
        assert!(qwen3_model_present(dir.path()));
    }

    #[test]
    fn qwen3_model_present_false_when_basename_at_root() {
        // Regression: pre-`QWEN3_MODEL_ID` layout (no per-model subdir)
        // must NOT count as present. The unpack always writes a
        // modelID-prefixed path, so a basename at the root is stale.
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(QWEN3_MODEL_BASENAME)).unwrap();
        assert!(!qwen3_model_present(dir.path()));
    }

    #[test]
    fn qwen3_model_present_false_when_only_subdir_exists() {
        // The modelID subdir exists but the `.mlmodelc` inside doesn't —
        // an interrupted unpack, for instance. Must NOT count as present.
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(QWEN3_MODEL_ID)).unwrap();
        assert!(!qwen3_model_present(dir.path()));
    }

    // ---------------- stats default ----------------

    #[test]
    fn worker_stats_default_values() {
        let s = BriefWorkerStats::default();
        assert_eq!(s.briefs_generated, 0);
        assert_eq!(s.cycles_skipped_empty, 0);
        assert_eq!(s.cycle_errors, 0);
        assert!(!s.disabled);
    }

    // ---------------- disabled idle ----------------

    #[tokio::test]
    async fn disabled_idle_returns_disabled_flag_on_shutdown() {
        let (tx, rx) = watch::channel(false);
        let handle = tokio::spawn(async move { run_disabled_idle("test", rx).await });
        // give the task a tick to install the .changed() future
        tokio::task::yield_now().await;
        let _ = tx.send(true);
        let stats = handle.await.unwrap();
        assert!(stats.disabled);
        assert_eq!(stats.briefs_generated, 0);
    }

    // ---------------- factory smoke ----------------

    #[test]
    fn author_factory_returns_stub_box() {
        let f: AuthorFactory = Arc::new(|| -> Result<Box<dyn BriefAuthor>, BriefWorkerError> {
            Ok(Box::new(StubBriefAuthor))
        });
        let _author = (f)().expect("stub factory");
    }
}
