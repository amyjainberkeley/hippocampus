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
//!
//! # One pass, two callers
//!
//! [`generate_brief_once`] is the whole unit of work: select the source
//! events, author, run the tripwire, persist. The scheduled loop calls it
//! once per fire; `mci-agent brief` calls the same function once and exits.
//! Neither owns a copy of the body, so the cron path and the CLI path
//! cannot drift.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use mci_brain::{BrainStore, BriefRow, SqlCipherBrainStore};
use mci_brief::author::BriefAuthor;
use mci_brief::model::BriefState;
use mci_brief::tripwire::validate_citations;
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
    /// The author handed back a brief that was not a `Draft`, or one that
    /// already carried an approver. ADR-0018 §4.1 says a brief reaches
    /// `Approved` only through `lifecycle::advance` with an explicit human
    /// approver id, so a generator that produces anything else is refused
    /// and nothing is written.
    #[error("brief-worker: refused to persist a brief that is not a Draft: {0}")]
    NotDraft(String),
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

/// Whether brief generation can run at all, and if not, why.
///
/// The scheduled worker turns a blocked gate into disabled-idle. A CLI run
/// has nobody to idle for, so it prints [`gate_block_message`] and exits
/// non-zero — the alternative is a command that appears to succeed while
/// writing nothing, which is the failure mode `doctor` exists to end.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BriefGate {
    /// Nothing is in the way.
    Open,
    /// `MCI_BRIEFS_DISABLED=1` is set.
    DisabledByEnv,
    /// The Qwen3 `.mlmodelc` is not on disk.
    ModelMissing,
}

/// Read the gate. Callers pass [`briefs_disabled_via_env`] for
/// `disabled_by_env`; taking it as an argument keeps the decision pure and
/// keeps its test out of a race with every other test that touches the
/// process environment.
///
/// The env answer wins over the disk answer deliberately. Somebody who set
/// `MCI_BRIEFS_DISABLED=1` wants to hear about that variable, not be sent
/// to build a 1.7 B model they may already have.
#[must_use]
pub fn brief_gate(model_dir: &Path, disabled_by_env: bool) -> BriefGate {
    if disabled_by_env {
        return BriefGate::DisabledByEnv;
    }
    if qwen3_model_present(model_dir) {
        BriefGate::Open
    } else {
        BriefGate::ModelMissing
    }
}

/// What to print when the gate is shut. Names the thing that is missing,
/// where it was looked for, and the one action that changes the answer.
///
/// Returns an empty string for [`BriefGate::Open`] — there is nothing to
/// explain when nothing is blocked.
#[must_use]
pub fn gate_block_message(gate: BriefGate, model_dir: &Path) -> String {
    match gate {
        BriefGate::Open => String::new(),
        BriefGate::DisabledByEnv => "briefs are switched off: MCI_BRIEFS_DISABLED=1 is set in \
             this environment.\n\
             Unset it (`unset MCI_BRIEFS_DISABLED`) and run this again."
            .to_owned(),
        BriefGate::ModelMissing => format!(
            "no Qwen3 model, so there is nothing to write the brief with.\n\
             \n\
             Looked for:\n      \
               {}\n\
             \n\
             That model is ~1.7 B parameters and is not checked into the\n\
             repository. Convert and compile it yourself:\n\
             \n      \
               python3.11 -m venv .venv-ml && source .venv-ml/bin/activate\n      \
               pip install -r scripts/requirements-ml.txt\n      \
               python scripts/convert_brief_model.py --help\n\
             \n\
             The full recipe, including the `xcrun coremlcompiler compile` step\n\
             that produces the .mlmodelc the loader needs, is in\n\
             docs/coreml-conversion-howto.md. Put the compiled directory at the\n\
             path above, or pass --model-dir to point somewhere else.\n\
             \n\
             Everything else keeps working — recall, enrich, doctor. There is\n\
             just no author to run yet, so no brief was written.",
            model_dir
                .join(QWEN3_MODEL_ID)
                .join(QWEN3_MODEL_BASENAME)
                .display(),
        ),
    }
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
                Ok(BriefOutcome::Stored {
                    date_local,
                    word_count,
                    event_count,
                    id,
                    citation_violations,
                }) => {
                    stats.briefs_generated += 1;
                    eprintln!(
                    "mci-agent: brief generated for {date_local} (first-launch, id={id}, {event_count} events, {word_count} words, {citation_violations} citation violations)"
                );
                }
                Ok(BriefOutcome::SkippedEmpty) => {
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
            Ok(BriefOutcome::Stored {
                date_local,
                word_count,
                event_count,
                id,
                citation_violations,
            }) => {
                stats.briefs_generated += 1;
                eprintln!(
                    "mci-agent: brief generated for {date_local} (id={id}, {event_count} events, {word_count} words, {citation_violations} citation violations)"
                );
            }
            Ok(BriefOutcome::SkippedEmpty) => {
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

/// The slice of time one brief covers, plus the local date its row is
/// keyed on.
///
/// `briefs.date_local` is UNIQUE, so the date is not decoration: it is the
/// identity of the row. Keeping it next to the bounds it was derived from
/// stops the two from disagreeing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BriefWindow {
    /// Inclusive lower bound, unix microseconds.
    pub since_us: u64,
    /// Exclusive upper bound, unix microseconds.
    pub until_us: u64,
    /// `YYYY-MM-DD` in the user's local zone. Keys the `briefs` row.
    pub date_local: String,
}

impl BriefWindow {
    /// The scheduled worker's window: the 24 h ending now, filed under
    /// today's local date.
    ///
    /// The upper bound is open on purpose. Generation takes seconds, and an
    /// event captured while the author is running still happened today —
    /// clipping at the instant the cycle started would drop it from a brief
    /// that no later cycle will ever cover.
    #[must_use]
    pub fn trailing_24h(now_us: u64, tz_offset_secs: i32) -> Self {
        let now_secs = i64::try_from(now_us / 1_000_000).unwrap_or(i64::MAX);
        Self {
            since_us: now_us.saturating_sub(24 * 3600 * 1_000_000),
            until_us: u64::MAX,
            date_local: local_date_string(now_secs, tz_offset_secs),
        }
    }

    /// One whole local day, for `mci-agent brief --date YYYY-MM-DD`.
    ///
    /// Returns `None` if the date is not a real `YYYY-MM-DD` calendar date.
    /// Both bounds are closed on the local midnights, so re-running for a
    /// past day reads exactly what that day held and nothing either side.
    #[must_use]
    pub fn for_local_date(date_local: &str, tz_offset_secs: i32) -> Option<Self> {
        let start_secs = local_date_start_secs(date_local, tz_offset_secs)?;
        let start_us = u64::try_from(start_secs).ok()?.saturating_mul(1_000_000);
        Some(Self {
            since_us: start_us,
            until_us: start_us.saturating_add(24 * 3600 * 1_000_000),
            date_local: date_local.to_owned(),
        })
    }

    /// Lower bound in the form `events_since` wants it.
    ///
    /// That query is `ts_us > cursor`, strictly greater, so an event landing
    /// exactly on local midnight would fall out of its own day. Step back one
    /// microsecond to make the bound inclusive.
    fn query_cursor_us(&self) -> u64 {
        self.since_us.saturating_sub(1)
    }
}

/// Outcome of one brief pass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BriefOutcome {
    /// A brief was authored and written to the `briefs` table.
    Stored {
        /// Local date the row is keyed on.
        date_local: String,
        /// Words in the body.
        word_count: u32,
        /// Events fed to the author.
        event_count: u32,
        /// Row id assigned by the store.
        id: u64,
        /// Citation violations the tripwire found. Non-zero does NOT stop
        /// the draft being written — a draft is exactly the thing a human
        /// reviews. It blocks approval later, in `lifecycle::advance`.
        citation_violations: usize,
    },
    /// The window held no events, so there was nothing to summarize.
    SkippedEmpty,
}

/// Author and persist one brief. The entire unit of work, done once.
///
/// Both callers run this and nothing else: [`run_brief_worker`] on its
/// schedule, `mci-agent brief` on demand. Synchronous and free of tokio so
/// a CLI does not have to stand up a runtime to reach it; the async worker
/// hands it to `spawn_blocking`.
///
/// Order is: select events in `window`, author them, check the state,
/// run the tripwire, write the row.
///
/// # ADR-0018 §4.1
///
/// The brief is written as authored — `Draft`. This function never calls
/// `lifecycle::advance` and takes no approver, so no caller can reach
/// `Approved` through it. A brief that arrives in any other state is
/// refused with [`BriefWorkerError::NotDraft`] and nothing is written.
///
/// # Errors
/// [`BriefWorkerError::Store`] if the brain read or write fails,
/// [`BriefWorkerError::Author`] if generation fails, and
/// [`BriefWorkerError::NotDraft`] if the author breaks the ADR-0018
/// invariant above.
pub fn generate_brief_once(
    store: &SqlCipherBrainStore,
    factory: &AuthorFactory,
    topic: &str,
    window: &BriefWindow,
    generated_ts_us: u64,
) -> Result<BriefOutcome, BriefWorkerError> {
    let mut records = store
        .events_since(window.query_cursor_us(), MAX_EVENTS_PER_BRIEF)
        .map_err(|e| BriefWorkerError::Store(format!("events_since: {e}")))?;
    records.retain(|r| r.ts_us < window.until_us);

    if records.is_empty() {
        return Ok(BriefOutcome::SkippedEmpty);
    }
    let event_count = u32::try_from(records.len()).unwrap_or(u32::MAX);

    // The author is constructed here, not by the caller, and dropped at the
    // end of this function — the ~500 MB working set is resident only while
    // generating (ADR-0028 §6), and only when there was something to write.
    let author = (factory)()?;
    let brief = author
        .author(&records, topic)
        .map_err(|e| BriefWorkerError::Author(e.to_string()))?;
    drop(author);

    if brief.state != BriefState::Draft || brief.human_approver_id.is_some() {
        return Err(BriefWorkerError::NotDraft(format!(
            "state={} approver={:?}",
            brief.state, brief.human_approver_id
        )));
    }

    // Runs on every generated brief so the count is visible at generation
    // time rather than only when somebody opens the review UI. Advisory
    // here; structural at the approval chokepoint.
    let citation_violations = validate_citations(&brief, store as &dyn BrainStore).len();

    let word_count = u32::try_from(brief.body.split_whitespace().count()).unwrap_or(u32::MAX);
    let row = BriefRow {
        id: 0,
        date_local: window.date_local.clone(),
        generated_ts_us,
        model_id: QWEN3_MODEL_ID.to_owned(),
        model_version: "1.0".to_owned(),
        title: brief.title,
        body: brief.body,
        word_count,
        source_event_count: event_count,
    };

    // INSERT OR REPLACE on UNIQUE(date_local): regenerating a date replaces
    // that date's brief rather than accumulating duplicates.
    let id = store
        .put_brief(&row)
        .map_err(|e| BriefWorkerError::Store(format!("put_brief: {e}")))?;

    Ok(BriefOutcome::Stored {
        date_local: window.date_local.clone(),
        word_count,
        event_count,
        id,
        citation_violations,
    })
}

/// Async shell around [`generate_brief_once`]: resolve the clock, then run
/// the pass on the blocking pool so model load and `SQLCipher` I/O stay off
/// the runtime thread.
async fn run_one_cycle(
    store: &Arc<SqlCipherBrainStore>,
    factory: &AuthorFactory,
    topic: &str,
    tz_offset_resolver: &Arc<dyn Fn() -> i32 + Send + Sync>,
) -> Result<BriefOutcome, BriefWorkerError> {
    let now_us = unix_now_us();
    let window = BriefWindow::trailing_24h(now_us, (tz_offset_resolver)());

    let store_c = Arc::clone(store);
    let factory_c = Arc::clone(factory);
    let topic_owned = topic.to_owned();
    tokio::task::spawn_blocking(move || {
        generate_brief_once(&store_c, &factory_c, &topic_owned, &window, now_us)
    })
    .await
    .map_err(|e| BriefWorkerError::Fatal(format!("brief cycle join: {e}")))?
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

/// Pure: the UTC second at which `date_local` (`YYYY-MM-DD`) begins in a
/// zone `tz_offset_secs` east of UTC. The exact inverse of
/// [`local_date_string`].
///
/// `None` for anything that is not a real calendar date. The check is a
/// round-trip through [`local_date_string`] rather than a hand-written
/// month-length table: "2026-02-30" parses as digits, converts to a day
/// number, and renders back as "2026-03-02", which is not what was asked
/// for, so it is rejected.
#[must_use]
pub fn local_date_start_secs(date_local: &str, tz_offset_secs: i32) -> Option<i64> {
    let bytes = date_local.as_bytes();
    if bytes.len() != 10 || bytes[4] != b'-' || bytes[7] != b'-' {
        return None;
    }
    let year: i64 = date_local.get(0..4)?.parse().ok()?;
    let month: u32 = date_local.get(5..7)?.parse().ok()?;
    let day: u32 = date_local.get(8..10)?.parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }

    let local_midnight = days_from_civil(year, month, day).checked_mul(86_400)?;
    if local_date_string(local_midnight, 0) != date_local {
        return None;
    }
    local_midnight.checked_sub(i64::from(tz_offset_secs))
}

/// Days since 1970-01-01 for a civil date. Howard Hinnant's
/// `days_from_civil`; the inverse of the `civil_from_days` that
/// [`crate::wall_clock::format_unix_ms`] already uses.
fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400; // [0, 399]
    let mp = i64::from(if month > 2 { month - 3 } else { month + 9 }); // [0, 11]
    let doy = (153 * mp + 2) / 5 + i64::from(day) - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146_097 + doe - 719_468
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

    // ---------------- local_date_start_secs ----------------

    #[test]
    fn local_date_start_is_the_inverse_of_local_date_string() {
        // Every date it accepts must render back to itself, in any zone.
        for date in [
            "1970-01-01",
            "2024-02-29",
            "2026-05-19",
            "2026-12-31",
            "2027-01-01",
        ] {
            for off in [0, -8 * 3600, 5 * 3600 + 30 * 60, 14 * 3600] {
                let start = local_date_start_secs(date, off).expect(date);
                assert_eq!(
                    local_date_string(start, off),
                    date,
                    "{date} at offset {off}"
                );
                // One second earlier is the previous day — the bound is
                // exactly midnight, not "some time that morning". Skipped
                // at the epoch itself, where there is no previous day to
                // land in and `local_date_string` clamps at zero.
                if start.saturating_add(i64::from(off)) > 0 {
                    assert_ne!(
                        local_date_string(start - 1, off),
                        date,
                        "{date} at offset {off}"
                    );
                }
            }
        }
    }

    #[test]
    fn local_date_start_rejects_dates_that_do_not_exist() {
        assert_eq!(local_date_start_secs("2026-02-30", 0), None);
        assert_eq!(
            local_date_start_secs("2025-02-29", 0),
            None,
            "not a leap year"
        );
        assert_eq!(local_date_start_secs("2026-13-01", 0), None);
        assert_eq!(local_date_start_secs("2026-00-10", 0), None);
        assert_eq!(local_date_start_secs("2026-01-00", 0), None);
    }

    #[test]
    fn local_date_start_rejects_malformed_input() {
        assert_eq!(local_date_start_secs("", 0), None);
        assert_eq!(local_date_start_secs("2026-5-19", 0), None);
        assert_eq!(local_date_start_secs("2026/05/19", 0), None);
        assert_eq!(local_date_start_secs("19-05-2026", 0), None);
        assert_eq!(local_date_start_secs("yesterday", 0), None);
        assert_eq!(local_date_start_secs("2026-05-19T00:00:00Z", 0), None);
    }

    // ---------------- BriefWindow ----------------

    #[test]
    fn trailing_window_covers_the_last_24h_and_stays_open_at_the_top() {
        let now_us = 1_779_163_200_000_000_u64; // 2026-05-19T04:00:00Z
        let w = BriefWindow::trailing_24h(now_us, 0);
        assert_eq!(w.since_us, now_us - 24 * 3600 * 1_000_000);
        assert_eq!(
            w.until_us,
            u64::MAX,
            "an event captured during generation still belongs to today"
        );
        assert_eq!(w.date_local, "2026-05-19");
    }

    #[test]
    fn dated_window_is_exactly_one_local_day() {
        let w = BriefWindow::for_local_date("2026-05-19", -8 * 3600).expect("valid date");
        assert_eq!(w.until_us - w.since_us, 24 * 3600 * 1_000_000);
        assert_eq!(w.date_local, "2026-05-19");
        // Local midnight in PST is 08:00 UTC.
        let start_secs = i64::try_from(w.since_us / 1_000_000).unwrap();
        assert_eq!(local_date_string(start_secs, -8 * 3600), "2026-05-19");
    }

    #[test]
    fn dated_window_query_cursor_includes_midnight_itself() {
        // `events_since` is `ts_us > cursor`. An event landing exactly on
        // local midnight has to stay inside its own day.
        let w = BriefWindow::for_local_date("2026-05-19", 0).expect("valid date");
        assert_eq!(w.query_cursor_us(), w.since_us - 1);
    }

    #[test]
    fn dated_window_rejects_a_date_that_does_not_exist() {
        assert_eq!(BriefWindow::for_local_date("2026-02-30", 0), None);
    }

    // ---------------- brief_gate ----------------

    #[test]
    fn gate_is_open_only_with_a_model_and_no_disable_flag() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(brief_gate(dir.path(), false), BriefGate::ModelMissing);
        assert_eq!(brief_gate(dir.path(), true), BriefGate::DisabledByEnv);

        std::fs::create_dir_all(dir.path().join(QWEN3_MODEL_ID).join(QWEN3_MODEL_BASENAME))
            .unwrap();
        assert_eq!(brief_gate(dir.path(), false), BriefGate::Open);
        assert_eq!(
            brief_gate(dir.path(), true),
            BriefGate::DisabledByEnv,
            "the switch wins over the model being there"
        );
    }

    #[test]
    fn every_shut_gate_says_what_to_do_about_it() {
        let dir = tempfile::tempdir().unwrap();

        let missing = gate_block_message(BriefGate::ModelMissing, dir.path());
        assert!(
            missing.contains(QWEN3_MODEL_BASENAME),
            "must name the file it looked for: {missing}"
        );
        assert!(
            missing.contains("convert_brief_model.py"),
            "must say how to get one: {missing}"
        );

        let disabled = gate_block_message(BriefGate::DisabledByEnv, dir.path());
        assert!(
            disabled.contains("MCI_BRIEFS_DISABLED"),
            "must name the variable that is switching it off: {disabled}"
        );

        assert!(gate_block_message(BriefGate::Open, dir.path()).is_empty());
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
