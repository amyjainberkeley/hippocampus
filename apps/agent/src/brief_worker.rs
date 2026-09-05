//! Calendar-day briefs: ambient Today and a scheduled completed-day brief.
//!
//! Same shutdown-channel / tokio task shape as
//! [`retention_worker`](crate::retention_worker). Each cycle:
//!
//! 1. Sleep until the next local-time fire (default 06:00).
//! 2. Query the previous local calendar day using OS timezone rules.
//! 3. Pass them to a freshly-constructed [`BriefAuthor`]. The default
//!    extractive author has no model dependency; an installed Qwen author
//!    is loaded lazily so its working set is resident only during generation.
//! 4. Insert the resulting brief into the `briefs` table.
//!
//! # Ambient Today
//!
//! A separate model-free worker checks current-day evidence every minute.
//! The first check with useful evidence produces a cited draft; later
//! changes rebuild at most every five minutes. Unchanged evidence does not
//! rewrite the draft. Morning generation owns yesterday's row, never Today.
//!
//! # Disable path
//!
//! When `MCI_BRIEFS_DISABLED=1` is set, the worker logs a single line and
//! idles on the shutdown channel — no busy-loop or repeated failure logs.
//! A missing Qwen model selects the evidence-cited extractive author instead.
//!
//! # Privacy invariants
//!
//! - WRITES only `briefs` rows; never modifies `events` (ADR-0018 §4.2).
//! - Reads retained events from a bounded calendar window. Suppressed
//!   captures have no event row by construction (ADR-0016 §4.3).
//! - The author runs entirely on-device — no network. ADR-0018 §4.6.
//! - Brief is written in `Draft` state structurally; auto-approve is
//!   structurally banned (ADR-0018 §4.1). The lifecycle state lives in
//!   the brief row's content; the briefs table itself does not store
//!   `BriefState` — Tier-2 syncs are gated separately by ADR-0019.
//!
//! # Shared authoring
//!
//! [`generate_brief_once`] selects sources, authors, validates and persists
//! for scheduled and explicit CLI runs. Today shares the authoring/persistence
//! path after comparing its bounded evidence snapshot. It refuses citation
//! violations instead of publishing an invalid ambient draft.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use mci_brain::{BrainStore, BriefRow, EventRecord, SqlCipherBrainStore};
use mci_brief::author::{AuthorError, BriefAuthor};
use mci_brief::extractive_author::ExtractiveBriefAuthor;
use mci_brief::model::BriefState;
use mci_brief::tripwire::validate_citations;
use tokio::sync::watch;

use crate::child_command_environment::sanitized_command;
use crate::wall_clock::format_unix_ms;

/// Default target hour for the daily brief, local time. 06:00.
pub const DEFAULT_BRIEF_HOUR: u32 = 6;

/// Ambient evidence checks run once per minute, never per frame.
pub const TODAY_BRIEF_CHECK_INTERVAL: Duration = Duration::from_secs(60);

/// Minimum interval between successful rebuilds within the same local day.
pub const TODAY_BRIEF_REBUILD_INTERVAL: Duration = Duration::from_secs(5 * 60);

/// Cap on events fed to the author in one cycle. ~2 K events is well
/// past the Qwen3-1.7B fixed-2048-token context — the author truncates
/// internally. The cap is a defence against the brain runaway case.
pub const MAX_EVENTS_PER_BRIEF: usize = 2048;

/// Legacy first-launch policy, retained for callers of [`should_fire_first_brief`].
/// Production Today generation no longer uses an age gate.
pub const FIRST_BRIEF_MIN_AGE: Duration = Duration::from_secs(4 * 3600);

/// Minimum sleep between fires. Guards against clock-skew + DST shifts
/// that could otherwise compute a near-zero (or negative) wait.
pub const MIN_SLEEP: Duration = Duration::from_secs(60);

/// Errors the brief worker can surface.
#[derive(Debug, thiserror::Error)]
pub enum BriefWorkerError {
    /// Calendar bounds could not be resolved; never guess a day or UTC fallback.
    #[error("brief-worker: calendar: {0}")]
    Calendar(String),
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
    /// selected window held no useful events.
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
pub fn brief_gate(_model_dir: &Path, disabled_by_env: bool) -> BriefGate {
    if disabled_by_env {
        return BriefGate::DisabledByEnv;
    }
    BriefGate::Open
}

/// What to print when the gate is shut. Names the thing that is missing,
/// where it was looked for, and the one action that changes the answer.
///
/// Returns an empty string for [`BriefGate::Open`] — there is nothing to
/// explain when nothing is blocked.
#[must_use]
pub fn gate_block_message(gate: BriefGate, _model_dir: &Path) -> String {
    match gate {
        BriefGate::Open => String::new(),
        BriefGate::DisabledByEnv => "briefs are switched off: MCI_BRIEFS_DISABLED=1 is set in \
             this environment.\n\
             Unset it (`unset MCI_BRIEFS_DISABLED`) and run this again."
            .to_owned(),
    }
}

/// Factory for the deterministic, evidence-cited author available on every host.
#[must_use]
pub fn extractive_author_factory() -> AuthorFactory {
    Arc::new(|| Ok(Box::new(ExtractiveBriefAuthor) as Box<dyn BriefAuthor>))
}

type TodayClock = Arc<dyn Fn() -> Result<(u64, BriefWindow), BriefWorkerError> + Send + Sync>;

#[derive(Default)]
struct TodayBriefState {
    day: Option<BriefWindow>,
    last_evidence: Option<Vec<EventRecord>>,
    last_generated_us: Option<u64>,
}

impl TodayBriefState {
    fn refresh(
        &mut self,
        store: &SqlCipherBrainStore,
        now_us: u64,
        day: &BriefWindow,
        shutdown: &watch::Receiver<bool>,
    ) -> Result<Option<BriefOutcome>, BriefWorkerError> {
        if *shutdown.borrow() || shutdown.has_changed().is_err() {
            return Ok(None);
        }
        if now_us < day.since_us || now_us >= day.until_us {
            return Err(BriefWorkerError::Calendar(
                "clock is outside its local day".into(),
            ));
        }
        let topic = format!("Day so far - {}", day.date_local);
        if self.day.as_ref() != Some(day) {
            let last_generated_us = store
                .brief_for_date(&day.date_local)
                .map_err(|e| BriefWorkerError::Store(format!("read Today brief: {e}")))?
                .filter(|row| row.model_id == "hippocampus-extractive" && row.title == topic)
                .map(|row| row.generated_ts_us);
            self.day = Some(day.clone());
            self.last_evidence = None;
            self.last_generated_us = last_generated_us;
        }
        let minimum_us =
            u64::try_from(TODAY_BRIEF_REBUILD_INTERVAL.as_micros()).unwrap_or(u64::MAX);
        if self
            .last_generated_us
            .is_some_and(|last| now_us.saturating_sub(last) < minimum_us)
        {
            return Ok(None);
        }
        let window = BriefWindow {
            until_us: day.until_us.min(now_us.saturating_add(1)),
            ..day.clone()
        };
        // Reuse the range-limited, evenly sampled daily read. No full-corpus
        // stats, per-frame query, or author/model construction on unchanged data.
        let records = store
            .sampled_events_between(window.since_us, window.until_us, MAX_EVENTS_PER_BRIEF)
            .map_err(|e| BriefWorkerError::Store(format!("sample Today evidence: {e}")))?;
        if self.last_evidence.as_deref() == Some(records.as_slice())
            || *shutdown.borrow()
            || shutdown.has_changed().is_err()
        {
            return Ok(None);
        }
        // A restart loses the in-memory snapshot. Preserve an identical persisted
        // draft rather than falsely advancing its generation timestamp.
        if self.last_evidence.is_none() {
            if let Some(existing) = store
                .brief_for_date(&day.date_local)
                .map_err(|e| BriefWorkerError::Store(format!("read Today draft: {e}")))?
                .filter(|row| {
                    row.model_id == ExtractiveBriefAuthor.model_id()
                        && row.model_version == ExtractiveBriefAuthor.model_version()
                        && row.title == topic
                })
            {
                if let Ok(draft) = ExtractiveBriefAuthor.author(&records, &topic) {
                    if draft.body == existing.body
                        && usize::try_from(existing.source_event_count).ok() == Some(records.len())
                    {
                        self.last_evidence = Some(records);
                        return Ok(None);
                    }
                }
            }
        }
        let outcome = author_and_store_brief(
            store,
            &extractive_author_factory(),
            &topic,
            &window,
            now_us,
            &records,
            true,
        )?;
        if matches!(outcome, BriefOutcome::Stored { .. }) {
            self.last_generated_us = Some(now_us);
        }
        self.last_evidence = Some(records);
        Ok(Some(outcome))
    }
}

/// Keep the current local day's draft useful without loading a model.
pub async fn run_today_brief_worker(
    store: Arc<SqlCipherBrainStore>,
    shutdown: watch::Receiver<bool>,
) -> Result<BriefWorkerStats, BriefWorkerError> {
    let clock: TodayClock = Arc::new(|| {
        let now = unix_now_us();
        Ok((now, calendar_day_window(now, 0)?))
    });
    run_today_brief_worker_with_clock(store, clock, shutdown).await
}

async fn run_today_brief_worker_with_clock(
    store: Arc<SqlCipherBrainStore>,
    clock: TodayClock,
    mut shutdown: watch::Receiver<bool>,
) -> Result<BriefWorkerStats, BriefWorkerError> {
    let mut stats = BriefWorkerStats::default();
    let mut state = TodayBriefState::default();
    loop {
        if *shutdown.borrow() {
            break;
        }
        let store = Arc::clone(&store);
        let clock = Arc::clone(&clock);
        let stopped = shutdown.clone();
        let mut task = tokio::task::spawn_blocking(move || {
            let result = clock().and_then(|(now, day)| state.refresh(&store, now, &day, &stopped));
            (state, result)
        });
        let result = tokio::select! {
            biased;
            _ = shutdown.changed() => { task.abort(); break; }
            result = &mut task => result,
        }
        .map_err(|e| BriefWorkerError::Fatal(format!("Today cycle join: {e}")))?;
        state = result.0;
        match result.1 {
            Ok(Some(BriefOutcome::Stored { .. })) => stats.briefs_generated += 1,
            Ok(Some(BriefOutcome::SkippedEmpty)) => stats.cycles_skipped_empty += 1,
            Ok(None) => {}
            Err(e) => {
                stats.cycle_errors += 1;
                eprintln!("mci-agent: Today brief cycle skipped: {e}");
            }
        }
        tokio::select! {
            _ = shutdown.changed() => break,
            () = tokio::time::sleep(TODAY_BRIEF_CHECK_INTERVAL) => {}
        }
    }
    Ok(stats)
}

/// Run the previous-calendar-day brief loop until the shutdown signal fires.
///
/// `tz_offset_resolver` returns the local timezone offset (in seconds
/// east of UTC) — production passes [`current_tz_offset_secs`], tests
/// pass a fixed offset. This schedules the wake only; source window bounds
/// independently use the OS timezone rules at each calendar midnight.
pub async fn run_brief_worker(
    store: Arc<SqlCipherBrainStore>,
    author_factory: AuthorFactory,
    brief_hour: u32,
    tz_offset_resolver: Arc<dyn Fn() -> i32 + Send + Sync>,
    mut shutdown: watch::Receiver<bool>,
) -> Result<BriefWorkerStats, BriefWorkerError> {
    let mut stats = BriefWorkerStats::default();

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

        let result = tokio::select! {
            biased;
            _ = shutdown.changed() => break,
            result = run_one_cycle(&store, &author_factory) => result,
        };
        match result {
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
                eprintln!("mci-agent: brief skipped (no useful events in previous local day)");
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
/// Used when `MCI_BRIEFS_DISABLED=1`. A missing model uses extractive briefs. The
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
    /// Explicit on-demand window: the 24 h ending now, filed under
    /// today's local date. Scheduled generation uses the previous calendar day.
    ///
    /// Future-dated events are excluded, including those after this snapshot.
    #[must_use]
    pub fn trailing_24h(now_us: u64, tz_offset_secs: i32) -> Self {
        let now_secs = i64::try_from(now_us / 1_000_000).unwrap_or(i64::MAX);
        Self {
            since_us: now_us.saturating_sub(24 * 3600 * 1_000_000),
            until_us: now_us.saturating_add(1),
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
        /// Citation violations the tripwire found. Scheduled/explicit drafts
        /// retain these for review, with approval blocked in `lifecycle::advance`.
        /// Ambient Today refuses drafts with any violations.
        citation_violations: usize,
    },
    /// The window held no useful evidence, so there was nothing to summarize.
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
    let records = store
        .sampled_events_between(window.since_us, window.until_us, MAX_EVENTS_PER_BRIEF)
        .map_err(|e| BriefWorkerError::Store(format!("sampled_events_between: {e}")))?;

    author_and_store_brief(
        store,
        factory,
        topic,
        window,
        generated_ts_us,
        &records,
        false,
    )
}

fn author_and_store_brief(
    store: &SqlCipherBrainStore,
    factory: &AuthorFactory,
    topic: &str,
    window: &BriefWindow,
    generated_ts_us: u64,
    records: &[EventRecord],
    require_valid_citations: bool,
) -> Result<BriefOutcome, BriefWorkerError> {
    if records.is_empty() {
        return Ok(BriefOutcome::SkippedEmpty);
    }
    let event_count = u32::try_from(records.len()).unwrap_or(u32::MAX);

    // The author is constructed here, not by the caller, and dropped at the
    // end of this function — the ~500 MB working set is resident only while
    // generating (ADR-0028 §6), and only when there was something to write.
    let author = (factory)()?;
    let model_id = author.model_id().to_owned();
    let model_version = author.model_version().to_owned();
    let brief = match author.author(records, topic) {
        Ok(brief) => brief,
        Err(AuthorError::NoEvents) => return Ok(BriefOutcome::SkippedEmpty),
        Err(e) => return Err(BriefWorkerError::Author(e.to_string())),
    };
    drop(author);

    if brief.state != BriefState::Draft || brief.human_approver_id.is_some() {
        return Err(BriefWorkerError::NotDraft(format!(
            "state={} approver={:?}",
            brief.state, brief.human_approver_id
        )));
    }

    // Runs on every generated brief so the count is visible at generation
    // time rather than only when somebody opens the review UI. Ambient drafts
    // require valid citations before publication; approval always requires them.
    let citation_violations = validate_citations(&brief, store as &dyn BrainStore).len();
    if require_valid_citations && citation_violations != 0 {
        return Err(BriefWorkerError::Author(format!(
            "refused ambient draft with {citation_violations} citation violations"
        )));
    }

    let word_count = u32::try_from(brief.body.split_whitespace().count()).unwrap_or(u32::MAX);
    let row = BriefRow {
        id: 0,
        date_local: window.date_local.clone(),
        generated_ts_us,
        model_id,
        model_version,
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
) -> Result<BriefOutcome, BriefWorkerError> {
    let now_us = unix_now_us();

    let store_c = Arc::clone(store);
    let factory_c = Arc::clone(factory);
    tokio::task::spawn_blocking(move || {
        let window = calendar_day_window(now_us, 1)?;
        let topic = format!("Daily brief - {}", window.date_local);
        generate_brief_once(&store_c, &factory_c, &topic, &window, now_us)
    })
    .await
    .map_err(|e| BriefWorkerError::Fatal(format!("brief cycle join: {e}")))?
}

/// Legacy age-gate helper. Production first evidence is handled by the Today worker.
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

fn calendar_day_window(now_us: u64, days_before: u32) -> Result<BriefWindow, BriefWorkerError> {
    if let Ok(value) = std::env::var("MCI_BRIEF_TZ_OFFSET_SECONDS") {
        let offset = value
            .parse::<i32>()
            .ok()
            .filter(|value| (-86_399..=86_399).contains(value))
            .ok_or_else(|| BriefWorkerError::Calendar("invalid fixed timezone override".into()))?;
        let now_secs = i64::try_from(now_us / 1_000_000)
            .map_err(|e| BriefWorkerError::Calendar(e.to_string()))?;
        let today = local_date_string(now_secs, offset);
        let date = shifted_calendar_date(&today, -i64::from(days_before))?;
        return BriefWindow::for_local_date(&date, offset)
            .ok_or_else(|| BriefWorkerError::Calendar("invalid fixed-offset day".into()));
    }
    local_day_window_in_zone(now_us, days_before, None)
}

fn shifted_calendar_date(date: &str, days: i64) -> Result<String, BriefWorkerError> {
    let midnight = local_date_start_secs(date, 0)
        .and_then(|value| value.checked_add(days.checked_mul(86_400)?))
        .filter(|value| *value >= 0)
        .ok_or_else(|| BriefWorkerError::Calendar("invalid calendar date".into()))?;
    Ok(local_date_string(midnight, 0))
}

fn calendar_date_output(args: &[&str], timezone: Option<&str>) -> Result<String, BriefWorkerError> {
    let mut command = sanitized_command("/bin/date");
    command.args(args);
    if let Some(timezone) = timezone {
        command.env("TZ", timezone);
    }
    let output = command
        .output()
        .map_err(|e| BriefWorkerError::Calendar(e.to_string()))?;
    if !output.status.success() {
        return Err(BriefWorkerError::Calendar(
            "OS date conversion failed".into(),
        ));
    }
    String::from_utf8(output.stdout)
        .map(|value| value.trim().to_owned())
        .map_err(|e| BriefWorkerError::Calendar(e.to_string()))
}

fn local_day_window_in_zone(
    now_us: u64,
    days_before: u32,
    timezone: Option<&str>,
) -> Result<BriefWindow, BriefWorkerError> {
    let seconds = (now_us / 1_000_000).to_string();
    #[cfg(target_os = "macos")]
    let today = calendar_date_output(&["-r", &seconds, "+%Y-%m-%d"], timezone)?;
    #[cfg(not(target_os = "macos"))]
    let today = calendar_date_output(&["-d", &format!("@{seconds}"), "+%Y-%m-%d"], timezone)?;
    let date = shifted_calendar_date(&today, -i64::from(days_before))?;
    let next = shifted_calendar_date(&date, 1)?;
    let midnight = |date: &str| -> Result<u64, BriefWorkerError> {
        let civil = format!("{date} 00:00:00");
        // Resolve each midnight separately: a calendar day may have 23 or 25 hours.
        #[cfg(target_os = "macos")]
        let seconds =
            calendar_date_output(&["-j", "-f", "%Y-%m-%d %H:%M:%S", &civil, "+%s"], timezone)?;
        #[cfg(not(target_os = "macos"))]
        let seconds = calendar_date_output(&["-d", &civil, "+%s"], timezone)?;
        seconds
            .parse::<u64>()
            .ok()
            .and_then(|value| value.checked_mul(1_000_000))
            .ok_or_else(|| BriefWorkerError::Calendar("invalid OS midnight".into()))
    };
    let since_us = midnight(&date)?;
    let until_us = midnight(&next)?;
    if since_us >= until_us {
        return Err(BriefWorkerError::Calendar(
            "invalid OS day boundaries".into(),
        ));
    }
    Ok(BriefWindow {
        since_us,
        until_us,
        date_local: date,
    })
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
    let output = match sanitized_command("date").arg("+%z").output() {
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
mod today_tests {
    use super::*;
    use mci_brain::{Event, EventId, EventSource};
    use mci_core::crypto::DbKey;

    fn store(dir: &tempfile::TempDir) -> Arc<SqlCipherBrainStore> {
        Arc::new(
            SqlCipherBrainStore::new(
                &dir.path().join("brain.sqlite"),
                &DbKey::from_bytes([61; 32]),
            )
            .unwrap(),
        )
    }

    fn record(store: &SqlCipherBrainStore, ts_us: u64, text: &str) -> EventId {
        store
            .put_event_with_source(
                &Event {
                    id: EventId(0),
                    ts_us,
                    app_bundle_id: Some("test.screen".into()),
                    window_title: None,
                    url: None,
                    text: text.into(),
                    summary: None,
                    entities: None,
                    episode_id: None,
                    cascade_reason: 0,
                    keyframe_blob: None,
                    tab_id: None,
                    embedding: None,
                },
                EventSource::ScreenOcr,
            )
            .unwrap()
    }

    #[test]
    fn first_three_screen_records_produce_a_cited_day_draft_without_age_gate() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(&dir);
        let day = BriefWindow::for_local_date("2026-09-05", 0).unwrap();
        record(
            &store,
            day.since_us - 1,
            "Yesterday secret fixture must stay outside Today",
        );
        let ids = [
            "Completed the release checklist",
            "Follow up on the signing certificate",
            "Reading the capture implementation",
        ]
        .map(|text| record(&store, day.since_us + 1_000_000, text));
        record(
            &store,
            day.until_us,
            "Tomorrow fixture must not leak into Today",
        );
        let (_tx, rx) = watch::channel(false);
        let mut state = TodayBriefState::default();
        let result = state
            .refresh(&store, day.since_us + 2_000_000, &day, &rx)
            .unwrap();
        assert!(matches!(
            result,
            Some(BriefOutcome::Stored {
                event_count: 3,
                citation_violations: 0,
                ..
            })
        ));
        let row = store.brief_for_date(&day.date_local).unwrap().unwrap();
        assert_eq!(row.model_id, "hippocampus-extractive");
        assert_eq!(row.title, "Day so far - 2026-09-05");
        for id in ids {
            assert!(row.body.contains(&format!("[event:{}]", id.0)));
        }
        assert!(!row.body.contains("Yesterday"));
        assert!(!row.body.contains("Tomorrow"));
    }

    #[test]
    fn empty_or_metadata_only_evidence_never_creates_a_brief() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(&dir);
        let day = BriefWindow::for_local_date("2026-09-05", 0).unwrap();
        let (_tx, rx) = watch::channel(false);
        let mut state = TodayBriefState::default();
        assert_eq!(
            state.refresh(&store, day.since_us, &day, &rx).unwrap(),
            Some(BriefOutcome::SkippedEmpty)
        );
        record(&store, day.since_us, "[app=test.screen]\n   ");
        assert_eq!(
            state.refresh(&store, day.since_us + 1, &day, &rx).unwrap(),
            Some(BriefOutcome::SkippedEmpty)
        );
        assert_eq!(store.brief_count().unwrap(), 0);
        record(
            &store,
            day.since_us + 2,
            "Completed the first useful captured note",
        );
        assert!(matches!(
            state.refresh(&store, day.since_us + 3, &day, &rx).unwrap(),
            Some(BriefOutcome::Stored { .. })
        ));
    }

    #[test]
    fn unchanged_evidence_does_not_rewrite_and_new_evidence_waits_five_minutes() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(&dir);
        let day = BriefWindow::for_local_date("2026-09-05", 0).unwrap();
        let now = day.since_us + 10_000_000;
        record(&store, now, "Completed the first useful captured note");
        let (_tx, rx) = watch::channel(false);
        let mut state = TodayBriefState::default();
        state.refresh(&store, now, &day, &rx).unwrap();
        let first = store.brief_for_date(&day.date_local).unwrap().unwrap();
        let later = record(&store, now + 1, "Waiting for the next release approval");
        assert_eq!(
            state.refresh(&store, now + 60_000_000, &day, &rx).unwrap(),
            None
        );
        assert_eq!(
            store.brief_for_date(&day.date_local).unwrap().unwrap().id,
            first.id
        );
        assert!(matches!(
            state.refresh(&store, now + 300_000_000, &day, &rx).unwrap(),
            Some(BriefOutcome::Stored { .. })
        ));
        let refreshed = store.brief_for_date(&day.date_local).unwrap().unwrap();
        assert!(refreshed.body.contains(&format!("[event:{}]", later.0)));
        assert_eq!(
            state
                .refresh(&store, now + 3_600_000_000, &day, &rx)
                .unwrap(),
            None
        );
        let unchanged = store.brief_for_date(&day.date_local).unwrap().unwrap();
        assert_eq!(unchanged.id, refreshed.id);
        assert_eq!(unchanged.generated_ts_us, refreshed.generated_ts_us);
        let mut restarted = TodayBriefState::default();
        assert_eq!(
            restarted
                .refresh(&store, now + 3_700_000_000, &day, &rx)
                .unwrap(),
            None
        );
        assert_eq!(
            store.brief_for_date(&day.date_local).unwrap().unwrap(),
            unchanged
        );
    }

    #[test]
    fn midnight_resets_evidence_and_allows_a_prompt_new_day_draft() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(&dir);
        let day = BriefWindow::for_local_date("2026-09-05", 0).unwrap();
        let next = BriefWindow::for_local_date("2026-09-06", 0).unwrap();
        let old = record(&store, day.until_us - 1, "Completed yesterday's release");
        let new = record(&store, next.since_us, "Review today's new rollout");
        let (_tx, rx) = watch::channel(false);
        let mut state = TodayBriefState::default();
        state.refresh(&store, day.until_us - 1, &day, &rx).unwrap();
        state
            .refresh(&store, next.since_us + 1, &next, &rx)
            .unwrap();
        let row = store.brief_for_date(&next.date_local).unwrap().unwrap();
        assert!(row.body.contains(&format!("[event:{}]", new.0)));
        assert!(!row.body.contains(&format!("[event:{}]", old.0)));
        assert_eq!(store.brief_count().unwrap(), 2);
    }

    #[test]
    fn os_day_boundaries_follow_dst_instead_of_the_current_offset() {
        for (instant, date, hours) in [
            ("2026-03-08T19:00:00.000Z", "2026-03-08", 23),
            ("2026-11-01T20:00:00.000Z", "2026-11-01", 25),
        ] {
            let now = crate::wall_clock::parse_unix_ms(instant).unwrap() * 1000;
            let day = local_day_window_in_zone(now, 0, Some("America/Los_Angeles")).unwrap();
            assert_eq!(day.date_local, date);
            assert_eq!(day.until_us - day.since_us, hours * 3_600_000_000);
            assert!(day.since_us <= now && now < day.until_us);
        }
    }

    #[test]
    fn scheduled_previous_day_uses_dst_boundaries_without_overwriting_today() {
        for (instant, previous_date, hours) in [
            ("2026-03-09T16:00:00.000Z", "2026-03-08", 23),
            ("2026-11-02T16:00:00.000Z", "2026-11-01", 25),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let store = store(&dir);
            let now = crate::wall_clock::parse_unix_ms(instant).unwrap() * 1000;
            let previous = local_day_window_in_zone(now, 1, Some("America/Los_Angeles")).unwrap();
            let today = local_day_window_in_zone(now, 0, Some("America/Los_Angeles")).unwrap();
            assert_eq!(previous.date_local, previous_date);
            assert_eq!(previous.until_us - previous.since_us, hours * 3_600_000_000);
            assert_eq!(previous.until_us, today.since_us);
            record(
                &store,
                previous.since_us - 1,
                "Outside the completed calendar day",
            );
            let start = record(
                &store,
                previous.since_us,
                "Completed the morning release checklist",
            );
            let end = record(
                &store,
                previous.until_us - 1,
                "Completed the final evening review",
            );
            let current = record(
                &store,
                today.since_us,
                "Waiting for today's release approval",
            );
            let (_tx, rx) = watch::channel(false);
            TodayBriefState::default()
                .refresh(&store, now, &today, &rx)
                .unwrap();
            let current_row = store.brief_for_date(&today.date_local).unwrap().unwrap();
            let outcome = generate_brief_once(
                &store,
                &extractive_author_factory(),
                &format!("Daily brief - {previous_date}"),
                &previous,
                now,
            )
            .unwrap();
            assert!(matches!(
                outcome,
                BriefOutcome::Stored {
                    event_count: 2,
                    citation_violations: 0,
                    ..
                }
            ));
            let row = store.brief_for_date(previous_date).unwrap().unwrap();
            assert!(row.body.contains(&format!("[event:{}]", start.0)));
            assert!(row.body.contains(&format!("[event:{}]", end.0)));
            assert!(!row.body.contains(&format!("[event:{}]", current.0)));
            assert_eq!(
                store.brief_for_date(&today.date_local).unwrap().unwrap().id,
                current_row.id
            );
        }
    }

    #[tokio::test]
    async fn shutdown_does_not_wait_for_an_active_clock_or_cycle() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(&dir);
        let release = Arc::new(std::sync::Barrier::new(2));
        let gate = Arc::clone(&release);
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let started = std::sync::Mutex::new(Some(started_tx));
        let clock: TodayClock = Arc::new(move || {
            if let Some(tx) = started.lock().unwrap().take() {
                let _ = tx.send(());
            }
            gate.wait();
            let day = BriefWindow::for_local_date("2026-09-05", 0).unwrap();
            Ok((day.since_us, day))
        });
        let (tx, rx) = watch::channel(false);
        let task = tokio::spawn(run_today_brief_worker_with_clock(
            Arc::clone(&store),
            clock,
            rx,
        ));
        started_rx.await.unwrap();
        tx.send(true).unwrap();
        let result = tokio::time::timeout(Duration::from_secs(1), task).await;
        release.wait();
        assert_eq!(
            result
                .expect("worker must stop promptly")
                .unwrap()
                .unwrap()
                .briefs_generated,
            0
        );
        assert_eq!(store.brief_count().unwrap(), 0);
    }
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
    fn trailing_window_covers_the_last_24h_without_future_events() {
        let now_us = 1_779_163_200_000_000_u64; // 2026-05-19T04:00:00Z
        let w = BriefWindow::trailing_24h(now_us, 0);
        assert_eq!(w.since_us, now_us - 24 * 3600 * 1_000_000);
        assert_eq!(w.until_us, now_us + 1);
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
    fn dated_window_rejects_a_date_that_does_not_exist() {
        assert_eq!(BriefWindow::for_local_date("2026-02-30", 0), None);
    }

    // ---------------- brief_gate ----------------

    #[test]
    fn gate_is_open_without_a_model_and_disable_flag_still_wins() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(brief_gate(dir.path(), false), BriefGate::Open);
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
