//! Bring the brain up to date with the transcripts on disk, within a budget.
//!
//! # Why this exists
//!
//! A handoff packet is only as fresh as the last import. The hook that
//! compiles one runs at the start of every agent session and has a few
//! seconds at most, so this is the bounded version of `import-sessions`
//! followed by `enrich`: import both roots incrementally, then run the
//! model-free understanding stages over the events that import just
//! wrote, and stop the moment the budget is spent. Cursors are stored per
//! file, so whatever did not fit is picked up next time.
//!
//! # What runs
//!
//! 1. Claude Code import, then Codex import, each resumable mid-file.
//! 2. Tier-1 entity extraction over the new events (regex, no model).
//! 3. Episode segmentation over the new, still unsegmented events.
//! 4. Embedding of the new events, only when an embedder was handed in.
//!
//! Alias resolution and consolidation are not run: they reconcile the
//! whole derived set and are not incremental. `mci-agent enrich` still
//! does the full pass. Nothing here loads Qwen.
//!
//! # Failure policy
//!
//! Nothing here fails the caller. A missing root, an unreadable file or a
//! store error is recorded in [`RefreshStats::notes`] and the next stage
//! still runs. The only way to get no result is to not have a store.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use mci_brain::episode_segmenter::{EpisodeSegmenter, EpisodeWriter, HeuristicEpisodeSegmenter};
use mci_brain::extraction::tier1::persist_tier1_matches;
use mci_brain::{Embedder, SqlCipherBrainStore, Tier1Extractor};
use mci_core::crypto::DbKey;
use tokio::sync::watch;

use crate::crash_recovery::{acquire_lock, lock_path_for_brain, LockAcquireOutcome, LockError};
use crate::import_codex;
use crate::import_sessions;
use crate::transcript::ImportStats;

/// Default time budget for one refresh, the CLI's `--budget-ms` default.
pub const DEFAULT_REFRESH_BUDGET: Duration = Duration::from_secs(3);

/// Events per store read in the enrich stages. Small so the deadline is
/// checked often.
const BATCH: usize = 32;

/// Where the transcripts live. `None` means the agent's default location.
#[derive(Debug, Clone, Default)]
pub struct RefreshRoots {
    /// Claude Code projects directory. Default `~/.claude/projects`.
    pub claude: Option<PathBuf>,
    /// Codex sessions directory. Default `~/.codex/sessions`.
    pub codex: Option<PathBuf>,
}

impl RefreshRoots {
    /// The Claude Code root that will be read.
    #[must_use]
    pub fn claude_root(&self) -> PathBuf {
        self.claude
            .clone()
            .unwrap_or_else(import_sessions::default_transcript_root)
    }

    /// The Codex root that will be read.
    #[must_use]
    pub fn codex_root(&self) -> PathBuf {
        self.codex
            .clone()
            .unwrap_or_else(import_codex::default_codex_root)
    }
}

/// The stages, in the order they run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefreshStage {
    /// Incremental Claude Code import.
    ImportClaude,
    /// Incremental Codex import.
    ImportCodex,
    /// Tier-1 entity extraction over new events.
    Extract,
    /// Episode segmentation over new events.
    Segment,
    /// Embedding of new events.
    Embed,
}

impl RefreshStage {
    /// Short label for the summary line.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            RefreshStage::ImportClaude => "import claude-code",
            RefreshStage::ImportCodex => "import codex",
            RefreshStage::Extract => "extract",
            RefreshStage::Segment => "segment",
            RefreshStage::Embed => "embed",
        }
    }
}

/// What one refresh did.
#[derive(Debug, Clone, Default)]
pub struct RefreshStats {
    /// Claude Code import counters.
    pub claude: ImportStats,
    /// Codex import counters.
    pub codex: ImportStats,
    /// Largest event id before the import; every id above it is new.
    pub last_event_id_before: u64,
    /// Events the two imports wrote.
    pub new_events: u64,
    /// New events run through Tier-1 extraction.
    pub extracted: u64,
    /// Entity mentions written by extraction (store delta).
    pub mentions_written: u64,
    /// New events assigned an episode.
    pub segmented: u64,
    /// Episodes created for them.
    pub episodes_created: u64,
    /// New events embedded. Zero when no embedder was supplied.
    pub embedded: u64,
    /// Embed calls or vector writes that failed and were skipped.
    pub embed_errors: u64,
    /// Whether an embedder was supplied at all.
    pub embedder_available: bool,
    /// The budget ran out before every stage finished. Later stages were
    /// skipped; the one named in `stopped_at` was cut short.
    pub deadline_hit: bool,
    /// The stage that was running, or about to run, when time ran out.
    pub stopped_at: Option<RefreshStage>,
    /// Wall-clock time spent.
    pub elapsed: Duration,
    /// Non-fatal problems, one line each, content-free.
    pub notes: Vec<String>,
}

impl RefreshStats {
    /// Fold a separately run embed stage into these stats.
    pub fn absorb_embed(&mut self, outcome: EmbedOutcome) {
        self.embedder_available = true;
        self.embedded += outcome.embedded;
        self.embed_errors += outcome.errors;
        if outcome.errors > 0 {
            self.notes
                .push(format!("embed: {} event(s) skipped", outcome.errors));
        }
        if outcome.deadline_hit {
            self.deadline_hit = true;
            self.stopped_at = Some(RefreshStage::Embed);
        }
    }

    /// One line for stdout.
    #[must_use]
    pub fn summary_line(&self) -> String {
        let embed = if self.embedder_available {
            format!("embedded {}", self.embedded)
        } else {
            "embed skipped (no embedder)".to_string()
        };
        let outcome = match self.stopped_at {
            Some(stage) => format!("budget spent during {}", stage.label()),
            None => "complete".to_string(),
        };
        let notes = if self.notes.is_empty() {
            String::new()
        } else {
            format!("; {} note(s) on stderr", self.notes.len())
        };
        format!(
            "refresh: claude-code {} events from {} file(s), codex {} events from {} file(s), \
             {} new; extracted {} ({} mentions), segmented {} ({} episodes), {}; {:.2}s; {outcome}{notes}",
            self.claude.events_written,
            self.claude.files_scanned,
            self.codex.events_written,
            self.codex.files_scanned,
            self.new_events,
            self.extracted,
            self.mentions_written,
            self.segmented,
            self.episodes_created,
            embed,
            self.elapsed.as_secs_f64(),
        )
    }
}

struct Clock {
    deadline: Instant,
}

impl Clock {
    fn spent(&self) -> bool {
        Instant::now() >= self.deadline
    }
}

/// Import both roots incrementally, then enrich only the events that
/// import wrote, stopping when `budget` is spent.
///
/// `embedder` is optional; without one the embed stage is skipped. Never
/// loads a model itself. Never fails: see the module docs.
#[must_use]
pub fn refresh(
    store: &SqlCipherBrainStore,
    embedder: Option<&dyn Embedder>,
    budget: Duration,
    roots: &RefreshRoots,
) -> RefreshStats {
    let start = Instant::now();
    let clock = Clock {
        deadline: start + budget,
    };
    let mut stats = RefreshStats {
        embedder_available: embedder.is_some(),
        ..RefreshStats::default()
    };

    stats.last_event_id_before = match store.max_event_id() {
        Ok(id) => id,
        Err(e) => {
            stats.notes.push(format!("cannot read max event id: {e}"));
            stats.elapsed = start.elapsed();
            return stats;
        }
    };

    run_imports(store, roots, &clock, &mut stats);
    stats.new_events = store
        .max_event_id()
        .unwrap_or(stats.last_event_id_before)
        .saturating_sub(stats.last_event_id_before);

    if stats.stopped_at.is_none() && stats.new_events > 0 {
        if let Err(e) = extract_new(store, &clock, &mut stats) {
            stats.notes.push(format!("extract: {e}"));
        }
    }
    if stats.stopped_at.is_none() && stats.new_events > 0 {
        if let Err(e) = segment_new(store, &clock, &mut stats) {
            stats.notes.push(format!("segment: {e}"));
        }
    }
    if stats.stopped_at.is_none() && stats.new_events > 0 {
        if let Some(emb) = embedder {
            match embed_events_after(store, emb, stats.last_event_id_before, clock.deadline) {
                Ok(outcome) => stats.absorb_embed(outcome),
                Err(e) => stats.notes.push(format!("embed: {e}")),
            }
        }
    }

    stats.deadline_hit = stats.stopped_at.is_some();
    stats.elapsed = start.elapsed();
    stats
}

fn run_imports(
    store: &SqlCipherBrainStore,
    roots: &RefreshRoots,
    clock: &Clock,
    stats: &mut RefreshStats,
) {
    let claude_root = roots.claude_root();
    if claude_root.is_dir() {
        match import_sessions::import_sessions_incremental(
            store,
            &claude_root,
            Some(clock.deadline),
            |_| {},
        ) {
            Ok(s) => stats.claude = s,
            Err(e) => stats.notes.push(format!("claude-code import: {e}")),
        }
        if stats.claude.deadline_hit {
            stats.stopped_at = Some(RefreshStage::ImportClaude);
            return;
        }
    } else {
        stats.notes.push(format!(
            "claude-code: no transcripts at {}",
            claude_root.display()
        ));
    }

    if clock.spent() {
        stats.stopped_at = Some(RefreshStage::ImportCodex);
        return;
    }
    let codex_root = roots.codex_root();
    if codex_root.is_dir() {
        match import_codex::import_codex_incremental(
            store,
            &codex_root,
            Some(clock.deadline),
            |_| {},
        ) {
            Ok(s) => stats.codex = s,
            Err(e) => stats.notes.push(format!("codex import: {e}")),
        }
        if stats.codex.deadline_hit {
            stats.stopped_at = Some(RefreshStage::ImportCodex);
        }
    } else {
        stats
            .notes
            .push(format!("codex: no rollouts at {}", codex_root.display()));
    }
}

fn extract_new(
    store: &SqlCipherBrainStore,
    clock: &Clock,
    stats: &mut RefreshStats,
) -> Result<(), String> {
    let extractor = Tier1Extractor::new();
    // Measure the store, not the extractor: its writers are INSERT OR
    // IGNORE, so "offered" over-reports on any re-run.
    let before = store
        .stats()
        .map_err(|e| e.to_string())?
        .entity_mention_count;
    let mut cursor = stats.last_event_id_before;
    loop {
        if clock.spent() {
            stats.stopped_at = Some(RefreshStage::Extract);
            break;
        }
        let batch = store
            .events_after_id(cursor, BATCH)
            .map_err(|e| e.to_string())?;
        if batch.is_empty() {
            break;
        }
        for event in &batch {
            let matches = extractor.extract(&event.text);
            if !matches.is_empty() {
                // A per-event failure must not strand the rest of the batch.
                let _ = persist_tier1_matches(store, event.id, event.ts_us, &matches);
            }
            stats.extracted += 1;
            cursor = event.id.0;
        }
    }
    let after = store
        .stats()
        .map_err(|e| e.to_string())?
        .entity_mention_count;
    stats.mentions_written = after.saturating_sub(before);
    Ok(())
}

fn segment_new(
    store: &SqlCipherBrainStore,
    clock: &Clock,
    stats: &mut RefreshStats,
) -> Result<(), String> {
    let segmenter = HeuristicEpisodeSegmenter::default();
    loop {
        if clock.spent() {
            stats.stopped_at = Some(RefreshStage::Segment);
            break;
        }
        let batch = store
            .unsegmented_events_after(stats.last_event_id_before, BATCH)
            .map_err(|e| e.to_string())?;
        if batch.is_empty() {
            break;
        }
        // Episodes are contiguous in time, so each batch needs the tail of
        // the previous one to decide whether it continues that episode.
        let last = store.last_segmented_event().map_err(|e| e.to_string())?;
        let result = segmenter
            .segment(&batch, last.as_ref(), store as &dyn EpisodeWriter)
            .map_err(|e| e.to_string())?;
        if result.events_assigned == 0 {
            // Nothing assigned means the same rows come back next read.
            break;
        }
        stats.segmented += result.events_assigned;
        stats.episodes_created += result.episodes_created;
    }
    Ok(())
}

/// What [`embed_events_after`] did.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct EmbedOutcome {
    /// Events given a vector.
    pub embedded: u64,
    /// Embed calls or vector writes that failed and were skipped.
    pub errors: u64,
    /// The deadline passed with events still unembedded.
    pub deadline_hit: bool,
}

/// Embed every event with `id > after_id` that has no vector yet, until
/// `deadline`.
///
/// Public on its own because loading the embedder costs seconds: the CLI
/// runs the model-free stages first, then loads the model only when the
/// import proved there is something new and the budget still has room.
///
/// # Errors
/// The store read that failed, as text. Per-event failures are counted.
pub fn embed_events_after(
    store: &SqlCipherBrainStore,
    embedder: &dyn Embedder,
    after_id: u64,
    deadline: Instant,
) -> Result<EmbedOutcome, String> {
    let clock = Clock { deadline };
    let mut outcome = EmbedOutcome::default();
    loop {
        if clock.spent() {
            outcome.deadline_hit = true;
            break;
        }
        let batch = store
            .unembedded_events_after(after_id, BATCH)
            .map_err(|e| e.to_string())?;
        if batch.is_empty() {
            break;
        }
        let mut progressed = false;
        for event in &batch {
            if clock.spent() {
                outcome.deadline_hit = true;
                break;
            }
            match embedder.embed_one(&event.text) {
                Ok(vector) => match store.set_event_embedding(event.id, &vector) {
                    Ok(()) => {
                        outcome.embedded += 1;
                        progressed = true;
                    }
                    Err(_) => outcome.errors += 1,
                },
                Err(_) => outcome.errors += 1,
            }
        }
        if !progressed {
            // Every event in the batch failed: the same rows would come
            // back forever. Stop and let the caller report it.
            break;
        }
    }
    Ok(outcome)
}

// ---------------------------------------------------------------------------
// Leased entry point: refresh, or say why not.
// ---------------------------------------------------------------------------

/// What [`refresh_or_skip`] did.
#[derive(Debug)]
pub enum RefreshOutcome {
    /// The lease was free; the brain was opened, checked and refreshed.
    /// Boxed: the stats carry two import counters and a note list, and
    /// the other arms are a pid or a string.
    Ran(Box<RefreshStats>),
    /// Another writer holds the brain: the running app's daemon, which
    /// refreshes transcripts itself, or a one-shot command. Nothing was
    /// done and nothing needs to be.
    Skipped {
        /// The lease owner's pid from the crash marker, when readable.
        owner_pid: Option<i32>,
    },
    /// The lease was taken but the brain could not be opened or failed its
    /// integrity check. Content-free description.
    Failed(String),
}

/// Take the brain's writer lease, open the store, run [`refresh`], release.
///
/// The one call a packet compiler needs before reading: it never fails the
/// packet because of the lease. The running app holds the lease for its
/// whole lifetime and refreshes transcripts on its own schedule, so a held
/// lease means the brain is already being kept current and the answer is
/// [`RefreshOutcome::Skipped`].
///
/// `key` is the caller's, because development keys (`MCI_DB_KEY_HEX`) are
/// resolved by the binary, not this library. `embedder` is never loaded
/// here; pass [`refresh_or_skip_then`] a closure to do that lazily.
#[must_use]
pub fn refresh_or_skip(
    db_path: &Path,
    key: &DbKey,
    budget: Duration,
    roots: &RefreshRoots,
) -> RefreshOutcome {
    refresh_or_skip_then(db_path, key, budget, roots, |_, _, _| {})
}

/// [`refresh_or_skip`] with a hook that runs while the lease and store are
/// still held, after the model-free stages. The CLI uses it to load the
/// embedder only once the import proved there is something to embed.
/// The hook receives the store, the run's deadline and the stats to fold
/// its result into.
#[must_use]
pub fn refresh_or_skip_then(
    db_path: &Path,
    key: &DbKey,
    budget: Duration,
    roots: &RefreshRoots,
    then: impl FnOnce(&SqlCipherBrainStore, Instant, &mut RefreshStats),
) -> RefreshOutcome {
    let started = Instant::now();
    let lock_path = lock_path_for_brain(db_path);
    let (outcome, lock) = match acquire_lock(&lock_path) {
        Ok(pair) => pair,
        Err(LockError::WriterLeaseHeld { owner_pid }) => {
            return RefreshOutcome::Skipped { owner_pid };
        }
        Err(e) => return RefreshOutcome::Failed(format!("writer lease: {e}")),
    };
    let passes = if matches!(outcome, LockAcquireOutcome::UncleanShutdown { .. }) {
        2
    } else {
        1
    };

    let result = open_checked(db_path, key, passes).map(|store| {
        let mut stats = refresh(&store, None, budget, roots);
        then(&store, started + budget, &mut stats);
        stats.elapsed = started.elapsed();
        stats
    });
    if let Err(e) = lock.release() {
        eprintln!("mci-agent refresh: writer lease clean-release failed: {e}");
    }
    match result {
        Ok(stats) => RefreshOutcome::Ran(Box::new(stats)),
        Err(e) => RefreshOutcome::Failed(e),
    }
}

/// Open the brain for writing the way the one-shot commands do: a
/// read-only integrity preflight on an existing file, then the writer
/// open, then the integrity check again on the writer handle (twice after
/// an unclean shutdown).
fn open_checked(db_path: &Path, key: &DbKey, passes: u32) -> Result<SqlCipherBrainStore, String> {
    if db_path.exists() {
        let probe = SqlCipherBrainStore::open_readonly(db_path, key)
            .map_err(|e| format!("open {} read-only: {e}", db_path.display()))?;
        for pass in 1..=passes {
            probe
                .verify_integrity_on_boot()
                .map_err(|e| format!("integrity preflight (pass {pass}/{passes}): {e}"))?;
        }
    }
    let store = SqlCipherBrainStore::new(db_path, key)
        .map_err(|e| format!("open {}: {e}", db_path.display()))?;
    for pass in 1..=passes {
        store
            .verify_integrity_on_boot()
            .map_err(|e| format!("integrity check (pass {pass}/{passes}): {e}"))?;
    }
    Ok(store)
}

// ---------------------------------------------------------------------------
// The daemon's periodic refresh.
// ---------------------------------------------------------------------------

/// Set to `1` (or `true`) to keep the running app from importing
/// transcripts in the background.
pub const TRANSCRIPT_REFRESH_DISABLED_ENV: &str = "MCI_TRANSCRIPT_REFRESH_DISABLED";

/// Whether the daemon's periodic transcript refresh should run, given the
/// kill switch's value. Unset or anything but `1` / `true` means yes.
#[must_use]
pub fn transcript_refresh_enabled(kill_switch: Option<&str>) -> bool {
    !kill_switch.is_some_and(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "true"))
}

/// [`transcript_refresh_enabled`] read from the process environment.
#[must_use]
pub fn transcript_refresh_enabled_from_env() -> bool {
    transcript_refresh_enabled(
        std::env::var(TRANSCRIPT_REFRESH_DISABLED_ENV)
            .ok()
            .as_deref(),
    )
}

/// When the daemon refreshes transcripts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RefreshSchedule {
    /// Wait after start before the first run, so boot-time work settles.
    pub initial_delay: Duration,
    /// Pause between the end of one run and the start of the next.
    pub interval: Duration,
    /// Time budget for each run.
    pub budget: Duration,
}

impl Default for RefreshSchedule {
    fn default() -> Self {
        Self {
            initial_delay: Duration::from_secs(5),
            interval: Duration::from_secs(60),
            budget: Duration::from_secs(10),
        }
    }
}

impl RefreshSchedule {
    /// When the next run is due: `started + initial_delay` until the first
    /// run has happened, then `last_run_finished + interval`. Measured from
    /// the end of a run, so a run that used its whole budget still leaves
    /// the full interval for frame ingest.
    #[must_use]
    pub fn next_run(&self, started: Instant, last_run_finished: Option<Instant>) -> Instant {
        match last_run_finished {
            None => started + self.initial_delay,
            Some(finished) => finished + self.interval,
        }
    }
}

/// Totals when the worker exits.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct TranscriptRefreshWorkerStats {
    /// Refresh runs completed.
    pub runs: u64,
    /// Runs that wrote at least one event.
    pub runs_with_writes: u64,
    /// Events written across all runs.
    pub events_written: u64,
    /// Runs that stopped on their budget.
    pub runs_over_budget: u64,
}

/// Refresh transcripts periodically on the store the daemon already owns.
///
/// The daemon holds the brain's writer lease for its whole lifetime, so
/// no other process can import while the app runs; this is where new
/// transcripts get in. Each run is [`refresh`] under `schedule.budget`,
/// on the blocking pool so the ingest loop keeps turning; the store's
/// mutex is held per statement, never across a batch. `embedder` is
/// optional and normally `None`: the idle-batch worker embeds every new
/// event within seconds anyway, and the Core ML embedder is meant to be
/// single-flight. Logs one line per run, only when it wrote something.
/// Exits when `shutdown` flips to `true`.
pub async fn run_transcript_refresh_worker(
    store: Arc<SqlCipherBrainStore>,
    embedder: Option<Arc<dyn Embedder>>,
    schedule: RefreshSchedule,
    mut shutdown: watch::Receiver<bool>,
) -> TranscriptRefreshWorkerStats {
    let mut totals = TranscriptRefreshWorkerStats::default();
    let started = Instant::now();
    let mut last_finished: Option<Instant> = None;
    loop {
        if *shutdown.borrow() {
            break;
        }
        let due = schedule.next_run(started, last_finished);
        tokio::select! {
            () = tokio::time::sleep_until(tokio::time::Instant::from_std(due)) => {}
            _ = shutdown.changed() => break,
        }
        if *shutdown.borrow() {
            break;
        }

        let run_store = Arc::clone(&store);
        let run_embedder = embedder.clone();
        let budget = schedule.budget;
        let run_started = Instant::now();
        let stats = tokio::task::spawn_blocking(move || {
            refresh(
                &run_store,
                run_embedder.as_deref(),
                budget,
                &RefreshRoots::default(),
            )
        })
        .await;
        last_finished = Some(Instant::now());
        totals.runs += 1;
        match stats {
            Ok(stats) => {
                totals.events_written += stats.new_events;
                if stats.deadline_hit {
                    totals.runs_over_budget += 1;
                }
                if stats.new_events > 0 {
                    totals.runs_with_writes += 1;
                    eprintln!(
                        "mci-agent: transcript refresh: +{} events (claude-code {}, codex {}) in {} ms{}",
                        stats.new_events,
                        stats.claude.events_written,
                        stats.codex.events_written,
                        run_started.elapsed().as_millis(),
                        if stats.deadline_hit {
                            ", budget spent, continuing next run"
                        } else {
                            ""
                        },
                    );
                }
            }
            Err(e) => eprintln!("mci-agent: transcript refresh: worker task failed: {e}"),
        }
    }
    totals
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_line_names_the_stage_that_ran_out_of_time() {
        let mut s = RefreshStats::default();
        assert!(s.summary_line().ends_with("complete"));
        assert!(s.summary_line().contains("embed skipped (no embedder)"));
        s.stopped_at = Some(RefreshStage::Segment);
        s.embedder_available = true;
        s.notes.push("x".into());
        let line = s.summary_line();
        assert!(line.contains("budget spent during segment"));
        assert!(line.contains("embedded 0"));
        assert!(line.ends_with("1 note(s) on stderr"));
        assert!(!line.contains('\n'));
    }

    #[test]
    fn roots_default_to_the_agent_locations() {
        let roots = RefreshRoots::default();
        assert!(roots.claude_root().ends_with(".claude/projects"));
        assert!(roots.codex_root().ends_with(".codex/sessions"));
    }

    #[test]
    fn the_schedule_waits_for_the_initial_delay_then_measures_from_the_last_run() {
        let schedule = RefreshSchedule::default();
        assert_eq!(schedule.initial_delay, Duration::from_secs(5));
        assert_eq!(schedule.interval, Duration::from_secs(60));
        assert_eq!(schedule.budget, Duration::from_secs(10));

        let started = Instant::now();
        assert_eq!(
            schedule.next_run(started, None),
            started + Duration::from_secs(5)
        );
        // A run that ended 40 s after start (it used its whole budget) is
        // followed by a full interval of quiet, not `started + 65 s`.
        let finished = started + Duration::from_secs(40);
        assert_eq!(
            schedule.next_run(started, Some(finished)),
            finished + Duration::from_secs(60)
        );
        let custom = RefreshSchedule {
            initial_delay: Duration::from_millis(1),
            interval: Duration::from_millis(2),
            budget: Duration::from_millis(3),
        };
        assert_eq!(
            custom.next_run(started, Some(started)),
            started + Duration::from_millis(2)
        );
    }

    #[test]
    fn the_kill_switch_only_trips_on_one_or_true() {
        assert!(transcript_refresh_enabled(None));
        assert!(transcript_refresh_enabled(Some("")));
        assert!(transcript_refresh_enabled(Some("0")));
        assert!(transcript_refresh_enabled(Some("no")));
        assert!(!transcript_refresh_enabled(Some("1")));
        assert!(!transcript_refresh_enabled(Some("true")));
        assert!(!transcript_refresh_enabled(Some(" TRUE ")));
    }

    fn empty_roots(dir: &Path) -> RefreshRoots {
        RefreshRoots {
            claude: Some(dir.join("no-claude")),
            codex: Some(dir.join("no-codex")),
        }
    }

    #[test]
    fn refresh_or_skip_runs_on_a_free_brain_and_reports_missing_roots() {
        let dir = tempfile::TempDir::new().expect("tempdir");
        let brain = dir.path().join("brain.sqlite");
        let key = DbKey::generate().expect("csprng");
        match refresh_or_skip(
            &brain,
            &key,
            Duration::from_secs(5),
            &empty_roots(dir.path()),
        ) {
            RefreshOutcome::Ran(stats) => {
                assert_eq!(stats.new_events, 0);
                assert_eq!(stats.notes.len(), 2, "{:?}", stats.notes);
                assert!(!stats.deadline_hit);
            }
            other => panic!("expected Ran, got {other:?}"),
        }
        // The lease was released: a second run is not skipped.
        assert!(matches!(
            refresh_or_skip(
                &brain,
                &key,
                Duration::from_secs(5),
                &empty_roots(dir.path())
            ),
            RefreshOutcome::Ran(_)
        ));
        // A wrong key is a failure, not a skip and not a panic.
        let wrong = DbKey::generate().expect("csprng");
        assert!(matches!(
            refresh_or_skip(
                &brain,
                &wrong,
                Duration::from_secs(5),
                &empty_roots(dir.path())
            ),
            RefreshOutcome::Failed(_)
        ));
    }

    #[test]
    fn refresh_or_skip_yields_to_another_process_holding_the_lease() {
        let dir = tempfile::TempDir::new().expect("tempdir");
        let brain = dir.path().join("brain.sqlite");
        let ready = dir.path().join("holder-ready");
        let mut child = std::process::Command::new(std::env::current_exe().expect("test exe"))
            .args([
                "--exact",
                "refresh::tests::child_holds_brain_writer_lease",
                "--nocapture",
            ])
            .env("MCI_TEST_REFRESH_LEASE_BRAIN", &brain)
            .env("MCI_TEST_REFRESH_LEASE_READY", &ready)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn lease holder");
        for _ in 0..250 {
            if ready.exists() {
                break;
            }
            assert!(
                child.try_wait().expect("poll child").is_none(),
                "lease holder exited before publishing readiness"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(ready.exists(), "lease holder never became ready");

        let key = DbKey::generate().expect("csprng");
        let outcome = refresh_or_skip(
            &brain,
            &key,
            Duration::from_secs(5),
            &empty_roots(dir.path()),
        );
        let child_pid = i32::try_from(child.id()).expect("pid fits");
        match outcome {
            RefreshOutcome::Skipped { owner_pid } => assert_eq!(owner_pid, Some(child_pid)),
            other => panic!("expected Skipped, got {other:?}"),
        }
        assert!(
            !brain.exists(),
            "a skipped refresh must not create the brain"
        );

        child.kill().expect("kill lease holder");
        child.wait().expect("reap lease holder");
        assert!(matches!(
            refresh_or_skip(
                &brain,
                &key,
                Duration::from_secs(5),
                &empty_roots(dir.path())
            ),
            RefreshOutcome::Ran(_)
        ));
    }

    /// Helper process for the test above; a no-op unless spawned by it.
    #[test]
    fn child_holds_brain_writer_lease() {
        let Some(brain) = std::env::var_os("MCI_TEST_REFRESH_LEASE_BRAIN") else {
            return;
        };
        let ready = std::env::var_os("MCI_TEST_REFRESH_LEASE_READY").expect("ready path");
        let (_outcome, _lock) =
            acquire_lock(&lock_path_for_brain(Path::new(&brain))).expect("child takes the lease");
        std::fs::write(ready, b"ready").expect("publish readiness");
        std::thread::sleep(Duration::from_secs(60));
    }
}
