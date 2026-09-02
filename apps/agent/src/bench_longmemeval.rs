//! `LongMemEval` retrieval benchmark, run against the real brain.
//!
//! # Why this exists
//!
//! Hippocampus has never had a number attached to it. Competing products
//! publish benchmark charts; practitioners in the local-memory community
//! complain, correctly, that no shared benchmark exists and so nobody can
//! tell which of these systems actually work. Without a measurement there
//! is no honest way to claim recall is good, and no way to tell whether a
//! change to fusion weights helped or hurt.
//!
//! # What is measured, and what is not
//!
//! This measures **retrieval**, not question answering. `LongMemEval`'s full
//! task is: read a long chat history, then answer a question about it.
//! That end-to-end score is dominated by whichever LLM writes the answer,
//! which is not the part Hippocampus supplies. Hippocampus supplies the
//! step before it: given the question, find the sessions that contain the
//! answer.
//!
//! So the metric is session-level retrieval over the labelled
//! `answer_session_ids`. A number produced this way is **not comparable**
//! to a published QA-accuracy number, and any writeup that puts the two on
//! one axis is wrong. It is comparable across runs of this harness, which
//! is what makes it useful for deciding whether a change was an
//! improvement.
//!
//! # Why it runs the production path
//!
//! Every instance gets a real `SqlCipherBrainStore`, the real
//! `HybridRetriever`, and the real `ArcticEmbedS` Core ML embedder loaded
//! through the same resolver `mcp-serve` uses. A benchmark that
//! reimplements retrieval measures the reimplementation. The cost is that
//! a run is slow, roughly 250,000 events embedded across 500 instances.
//! That is the right trade.
//!
//! # Arms
//!
//! Both arms run over the identical corpus so the comparison is internal
//! and fair:
//!
//! - `lexical` — FTS5 only, the embedder withheld. This is what
//!   `mci-brain search` gives you today.
//! - `hybrid` — FTS5 + semantic under ADR-0010 min-max fusion, which is
//!   what `mci_recall` gives Claude Code.
//!
//! If hybrid does not beat lexical here, the embedder is not earning the
//! 64 MB it costs, and that is a finding worth having either way.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use mci_brain::{
    lexical_retrieval_outcome, BrainStore, Embedder, Event, EventChunker, EventId, HybridRetriever,
    NothingMatchedReason, RetrievalDegradation, RetrievalOutcome, RetrievalQuery,
    SqlCipherBrainStore,
};
use mci_core::crypto::DbKey;

/// One `LongMemEval` instance: a question plus the haystack it hides in.
#[derive(serde::Deserialize, Clone)]
pub struct Instance {
    /// Dataset-assigned identifier, unique across the 500 instances.
    pub question_id: String,
    /// One of the six `LongMemEval` categories, e.g. `multi-session`.
    pub question_type: String,
    /// The question asked of the history.
    pub question: String,
    /// When the question is asked. Used as "now" so the recency term in
    /// fusion sees the same clock the scenario implies.
    pub question_date: String,
    /// Sessions that actually contain the answer. The ground truth.
    #[serde(default)]
    pub answer_session_ids: Vec<String>,
    /// One timestamp per haystack session, same order.
    pub haystack_dates: Vec<String>,
    /// One id per haystack session, same order.
    pub haystack_session_ids: Vec<String>,
    /// The haystack: every session, each a list of turns.
    pub haystack_sessions: Vec<Vec<Turn>>,
    /// Optional stable app id per haystack session for source reporting.
    #[serde(default)]
    pub haystack_app_ids: Vec<String>,
    /// Optional window title per haystack session for provenance.
    #[serde(default)]
    pub haystack_window_titles: Vec<String>,
    /// Optional URL or source locator per haystack session.
    #[serde(default)]
    pub haystack_urls: Vec<String>,
    /// Optional tags for slices such as `temporal` or `contradiction`.
    #[serde(default)]
    pub tags: Vec<String>,
    /// True when the correct behavior is to abstain.
    #[serde(default)]
    pub unanswerable: bool,
}

/// One message in a session.
#[derive(serde::Deserialize, Clone)]
pub struct Turn {
    /// `user` or `assistant`.
    pub role: String,
    /// The message text.
    pub content: String,
}

/// Synthetic work-memory corpus envelope. `LongMemEval` remains supported
/// through the legacy top-level array format.
#[allow(missing_docs)]
#[derive(serde::Deserialize)]
pub struct DatasetEnvelope {
    pub dataset_id: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub instances: Vec<Instance>,
}

#[derive(serde::Deserialize)]
#[serde(untagged)]
enum DatasetFile {
    Legacy(Vec<Instance>),
    Envelope(DatasetEnvelope),
}

/// Parsed dataset plus the metadata the report needs.
#[allow(missing_docs)]
pub struct LoadedDataset {
    pub dataset_id: String,
    pub description: Option<String>,
    pub instances: Vec<Instance>,
}

/// Parse either the legacy `LongMemEval` top-level array or the synthetic
/// work-memory envelope.
///
/// # Errors
/// Returns the underlying JSON parse error text.
pub fn load_dataset(raw: &str, fallback_dataset_id: &str) -> Result<LoadedDataset, String> {
    match serde_json::from_str::<DatasetFile>(raw) {
        Ok(DatasetFile::Legacy(instances)) => Ok(LoadedDataset {
            dataset_id: fallback_dataset_id.to_string(),
            description: None,
            instances,
        }),
        Ok(DatasetFile::Envelope(env)) => Ok(LoadedDataset {
            dataset_id: env.dataset_id,
            description: env.description,
            instances: env.instances,
        }),
        Err(e) => Err(e.to_string()),
    }
}

/// Which retrieval arm to run.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Arm {
    /// FTS5 only. What `mci-brain search` gives you.
    Lexical,
    /// FTS5 + semantic under ADR-0010 fusion. What `mci_recall` gives.
    Hybrid,
}

impl Arm {
    /// Short name used in output and in the JSON report.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Lexical => "lexical",
            Self::Hybrid => "hybrid",
        }
    }
}

/// Per-instance outcome. Kept per-instance rather than only aggregated so
/// a bad category can be traced back to the questions that caused it.
#[derive(serde::Serialize, Clone)]
pub struct InstanceResult {
    /// Which arm produced this result.
    pub arm: String,
    /// Which instance this scores.
    pub question_id: String,
    /// Its `LongMemEval` category.
    pub question_type: String,
    /// Optional slice tags carried through from the dataset.
    pub tags: Vec<String>,
    /// True when the correct behavior is to decline to answer.
    pub unanswerable: bool,
    /// Evaluation outcome at the max scored depth.
    pub outcome: Outcome,
    /// Exact production retrieval disposition before benchmark labels are
    /// applied. This keeps ranked unqualified fallback distinguishable from
    /// evidence-floor abstention in the report.
    pub retrieval_disposition: RetrievalDisposition,
    /// Rank (1-based) of the first answer session in the ranked session
    /// list, or `None` if no answer session was retrieved at all.
    pub first_hit_rank: Option<usize>,
    /// Fraction of this instance's answer sessions found within each k.
    pub recall_at: BTreeMap<usize, Option<f64>>,
    /// Whether at least one correct result in the top k carries source
    /// anchors a person can inspect.
    pub provenance_coverage_at: BTreeMap<usize, Option<bool>>,
    /// How many sessions held the answer, for this question.
    pub answer_sessions: usize,
    /// Haystack size, so a score can be read against its difficulty.
    pub sessions_in_haystack: usize,
    /// Turns actually written to the brain, after empty ones are skipped.
    pub events_indexed: usize,
    /// Representative retrieved hits after event -> session collapse.
    pub top_hits: Vec<RankedHit>,
    /// Per-instance end-to-end latency.
    pub latency_ms: f64,
    /// Size of the temporary `SQLite` file for this instance.
    pub index_size_bytes: u64,
}

/// Aggregate over a set of instances.
#[derive(serde::Serialize, Clone)]
pub struct Summary {
    /// Which arm produced these numbers.
    pub arm: String,
    /// How many instances are behind the averages.
    pub instances: usize,
    /// Proportion of questions where at least one answer session appeared
    /// in the top k. This is the number a user feels: did it find it.
    pub hit_rate_at: BTreeMap<usize, Option<f64>>,
    /// Mean proportion of answer sessions recovered within top k. Stricter
    /// than hit rate, because most questions have more than one.
    pub recall_at: BTreeMap<usize, Option<f64>>,
    /// Fraction of answerable questions where a correct top-k hit exposed
    /// enough source anchors to inspect.
    pub provenance_coverage_at: BTreeMap<usize, Option<f64>>,
    /// Fraction of unanswerable questions that still returned some top-k
    /// result. Lower is better.
    pub false_positive_rate_at: BTreeMap<usize, Option<f64>>,
    /// Answerable hit-rate minus unanswerable false-positive rate
    /// (Youden-style TPR - FPR). Undefined unless both denominators exist.
    pub abstention_separation_at: BTreeMap<usize, Option<f64>>,
    /// Mean reciprocal rank of the first answer session.
    pub mrr: Option<f64>,
    /// Answerable questions where no answer session was retrieved at any depth.
    pub complete_misses: usize,
    /// Counts by typed benchmark outcome.
    pub outcomes: OutcomeCounts,
    /// Answerable questions behind the retrieval metrics.
    pub answerable_instances: usize,
    /// Unanswerable questions behind the abstention metrics.
    pub unanswerable_instances: usize,
    /// Per-instance latency distribution.
    pub latency_ms: DistributionStats,
    /// Per-instance index-size distribution.
    pub index_size_bytes: DistributionStats,
}

/// Everything one run produced, written with `--out`.
#[derive(serde::Serialize)]
pub struct Report {
    /// True only when every requested arm completed without dropped instances
    /// and any baseline check passed.
    pub complete: bool,
    /// True only for a full, clean, canonical two-arm benchmark report.
    pub publishable: bool,
    /// True only when a publishable report also passes absolute quality.
    pub launch_qualified: bool,
    /// Repository-relative dataset path when the corpus belongs to this repo.
    pub dataset: String,
    /// Stable dataset identifier, used by the synthetic work-memory corpus.
    pub dataset_id: String,
    /// SHA-256 of the exact dataset bytes consumed by this run.
    pub dataset_checksum_sha256: String,
    /// Optional dataset description from the envelope format.
    pub dataset_description: Option<String>,
    /// One summary per arm, over every instance.
    pub overall: Vec<Summary>,
    /// `question_type` -> one summary per arm.
    pub by_type: BTreeMap<String, Vec<Summary>>,
    /// tag -> one summary per arm.
    pub by_tag: BTreeMap<String, Vec<Summary>>,
    /// Every per-instance result, so a category can be traced to cases.
    pub results: Vec<InstanceResult>,
    /// Any instance or run-level failure that made the report incomplete.
    pub failures: Vec<RunFailure>,
    /// Material-regression thresholds derived from this run's measured baseline.
    pub regression_thresholds: BTreeMap<String, RegressionThresholds>,
    /// Product quality bars that do not move with a weak measured baseline.
    pub absolute_quality_targets: BTreeMap<String, QualityTargets>,
    /// Comparison against the absolute quality bars.
    pub quality_gate: RegressionReport,
    /// Optional comparison of this run against a committed baseline file.
    pub regression: Option<RegressionReport>,
    /// Exact runtime environment captured for reproducibility.
    pub run: Option<RunMetadata>,
}

#[allow(missing_docs)]
#[derive(Debug, serde::Serialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Outcome {
    Matched,
    Missed,
    Abstained,
    FalsePositive,
}

#[allow(missing_docs)]
#[derive(Debug, serde::Serialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum RetrievalDisposition {
    Matched,
    Contradicted,
    NothingMatchedNoCandidates,
    NothingMatchedEvidenceFloor,
    NothingMatchedZeroLimit,
    DegradedEvidenceSufficiencyUnqualified,
    DegradedEvidenceVerifierUnavailable,
}

#[allow(missing_docs)]
#[derive(serde::Serialize, Clone)]
pub struct RankedHit {
    pub rank: usize,
    pub event_id: u64,
    pub session_id: String,
    pub app_bundle_id: Option<String>,
    pub window_title: Option<String>,
    pub url: Option<String>,
    pub relevant: bool,
    pub score: f64,
    pub excerpt: String,
}

#[allow(missing_docs)]
#[derive(serde::Serialize, Clone, Default)]
pub struct OutcomeCounts {
    pub matched: usize,
    pub missed: usize,
    pub abstained: usize,
    pub false_positive: usize,
}

#[allow(missing_docs)]
#[derive(serde::Serialize, Clone, Copy, Default)]
pub struct DistributionStats {
    pub min: f64,
    pub p50: f64,
    pub p95: f64,
    pub max: f64,
    pub mean: f64,
}

#[allow(missing_docs)]
#[derive(serde::Serialize, Clone)]
pub struct RunFailure {
    pub arm: String,
    pub question_id: Option<String>,
    pub error: String,
}

#[allow(missing_docs)]
#[derive(serde::Serialize, serde::Deserialize, Clone, Default)]
pub struct RegressionThresholds {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hit_rate_at_1_min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hit_rate_at_3_min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hit_rate_at_5_min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hit_rate_at_10_min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recall_at_1_min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recall_at_3_min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recall_at_5_min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recall_at_10_min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provenance_coverage_at_1_min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provenance_coverage_at_3_min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provenance_coverage_at_5_min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provenance_coverage_at_10_min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub false_positive_rate_at_1_max: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub false_positive_rate_at_3_max: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub false_positive_rate_at_5_max: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub false_positive_rate_at_10_max: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub abstention_separation_at_1_min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub abstention_separation_at_3_min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub abstention_separation_at_5_min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub abstention_separation_at_10_min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mrr_min: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub latency_p95_ms_max: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub index_size_p95_bytes_max: Option<f64>,
}

#[allow(missing_docs)]
#[derive(serde::Serialize, serde::Deserialize, Clone)]
pub struct BaselineFile {
    pub complete: bool,
    pub publishable: bool,
    pub dataset_id: String,
    pub dataset_checksum_sha256: String,
    #[serde(default)]
    pub overall: Vec<BaselineArmSummary>,
    #[serde(default)]
    pub regression_thresholds: BTreeMap<String, RegressionThresholds>,
    pub run: RunMetadata,
}

#[allow(missing_docs)]
#[derive(serde::Serialize, serde::Deserialize, Clone, Default)]
pub struct BaselineArmSummary {
    pub arm: String,
    pub answerable_instances: usize,
    pub unanswerable_instances: usize,
}

#[allow(missing_docs)]
#[derive(serde::Serialize, serde::Deserialize, Clone)]
pub struct QualityTargets {
    pub hit_rate_at_5_min: f64,
    pub recall_at_5_min: f64,
    pub provenance_coverage_at_5_min: f64,
    pub false_positive_rate_at_5_max: f64,
    pub abstention_separation_at_5_min: f64,
    pub mrr_min: f64,
}

#[allow(missing_docs)]
#[derive(serde::Serialize, Clone)]
pub struct RegressionReport {
    pub passed: bool,
    pub failures: Vec<String>,
}

#[allow(missing_docs)]
#[derive(serde::Serialize, serde::Deserialize, Clone)]
pub struct RunMetadata {
    pub captured_at_utc: String,
    pub git_commit: String,
    pub git_dirty_at_start: bool,
    pub branch: String,
    pub command: String,
    pub arguments: Vec<String>,
    pub rustc_version: String,
    pub cargo_version: String,
    pub os_name: String,
    pub os_version: String,
    pub os_build: String,
    pub architecture: String,
    pub hardware_model: Option<String>,
    pub hardware_chip: Option<String>,
    pub ram_bytes: Option<u64>,
    pub compute_mode: String,
    pub model_family: Option<String>,
    pub model_path: Option<String>,
    pub model_checksum_sha256: Option<String>,
    pub requested_arms: Vec<String>,
    pub ks: Vec<usize>,
    pub limit: Option<usize>,
    pub original_instances: usize,
    pub evaluated_instances: usize,
}

#[derive(Clone)]
struct EventMeta {
    session_id: String,
    app_bundle_id: Option<String>,
    window_title: Option<String>,
    url: Option<String>,
    excerpt: String,
}

/// Parse `2023/05/20 (Sat) 02:21` into microseconds since the epoch.
///
/// The weekday is ignored: it is redundant with the date and the dataset
/// is internally consistent, so trusting it would only add a way to be
/// wrong. A date that will not parse is an error rather than a guess,
/// because a silently wrong timestamp corrupts the recency term in fusion
/// and would show up as an unexplained score change.
///
/// # Errors
/// Returns the offending string when it does not match the expected shape.
pub fn parse_dataset_ts(s: &str) -> Result<u64, String> {
    let bad = || format!("unparseable timestamp: {s:?}");
    // "2023/05/20 (Sat) 02:21" -> ["2023/05/20", "(Sat)", "02:21"].
    let mut parts = s.split_whitespace();
    let date = parts.next().ok_or_else(bad)?;
    let time = parts.next_back().ok_or_else(bad)?;
    if date == time {
        return Err(bad());
    }

    let mut d = date.split('/');
    let y: i64 = d.next().ok_or_else(bad)?.parse().map_err(|_| bad())?;
    let mo: i64 = d.next().ok_or_else(bad)?.parse().map_err(|_| bad())?;
    let da: i64 = d.next().ok_or_else(bad)?.parse().map_err(|_| bad())?;
    if d.next().is_some() || !(1..=12).contains(&mo) || !(1..=31).contains(&da) {
        return Err(bad());
    }

    let (hh, mm) = time.split_once(':').ok_or_else(bad)?;
    let hh: i64 = hh.parse().map_err(|_| bad())?;
    let mm: i64 = mm.parse().map_err(|_| bad())?;
    if hh > 23 || mm > 59 {
        return Err(bad());
    }

    // Howard Hinnant's days_from_civil.
    let y_adj = if mo <= 2 { y - 1 } else { y };
    let era = if y_adj >= 0 { y_adj } else { y_adj - 399 } / 400;
    let yoe = y_adj - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + da - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;

    let secs = days * 86_400 + hh * 3_600 + mm * 60;
    u64::try_from(secs)
        .map(|s| s * 1_000_000)
        .map_err(|_| bad())
}

fn validate_optional_axis(
    inst: &Instance,
    label: &str,
    values: &[String],
    expected: usize,
) -> Result<(), String> {
    if !values.is_empty() && values.len() != expected {
        return Err(format!(
            "{}: {label} has {} entries for {expected} sessions",
            inst.question_id,
            values.len()
        ));
    }
    Ok(())
}

fn validate_instance_shape(inst: &Instance) -> Result<(), String> {
    if inst.question_id.is_empty()
        || inst.question_id.len() > 256
        || inst
            .question_id
            .chars()
            .any(|ch| ch.is_control() || ch == '/' || ch == '\\')
    {
        return Err(format!(
            "invalid question_id {:?}: ids must be 1-256 characters without path separators or control characters",
            inst.question_id
        ));
    }
    let sessions = inst.haystack_sessions.len();
    if inst.haystack_dates.len() != sessions {
        return Err(format!(
            "{}: haystack_dates has {} entries for {sessions} sessions",
            inst.question_id,
            inst.haystack_dates.len()
        ));
    }
    if inst.haystack_session_ids.len() != sessions {
        return Err(format!(
            "{}: haystack_session_ids has {} entries for {sessions} sessions",
            inst.question_id,
            inst.haystack_session_ids.len()
        ));
    }
    validate_optional_axis(inst, "haystack_app_ids", &inst.haystack_app_ids, sessions)?;
    validate_optional_axis(
        inst,
        "haystack_window_titles",
        &inst.haystack_window_titles,
        sessions,
    )?;
    validate_optional_axis(inst, "haystack_urls", &inst.haystack_urls, sessions)?;
    Ok(())
}

fn stable_id_hash(value: &str) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for byte in value.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

static SCRATCH_RUN_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Unique scratch directory owned by one benchmark process.
#[derive(Debug)]
pub struct ScratchRun {
    path: PathBuf,
}

impl ScratchRun {
    /// Create a unique run directory below the configured scratch base.
    ///
    /// # Errors
    /// Returns an error when the base or a unique child directory cannot be
    /// created.
    pub fn create(base: &Path) -> Result<Self, String> {
        std::fs::create_dir_all(base)
            .map_err(|error| format!("create scratch base {}: {error}", base.display()))?;
        let epoch_nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |duration| duration.as_nanos());
        for _ in 0..100 {
            let sequence = SCRATCH_RUN_COUNTER.fetch_add(1, Ordering::Relaxed);
            let path = base.join(format!(
                "run-{}-{epoch_nanos:032x}-{sequence:016x}",
                std::process::id()
            ));
            match std::fs::create_dir(&path) {
                Ok(()) => return Ok(Self { path }),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(error) => {
                    return Err(format!("create scratch run {}: {error}", path.display()));
                }
            }
        }
        Err(format!(
            "could not allocate a unique scratch run below {}",
            base.display()
        ))
    }

    /// Directory to use for this run's per-instance databases.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for ScratchRun {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

fn scratch_db_path(dir: &Path, prefix: &str, question_id: &str) -> std::path::PathBuf {
    dir.join(format!(
        "{prefix}-{:016x}.sqlite",
        stable_id_hash(question_id)
    ))
}

fn sqlite_artifact_paths(path: &Path) -> [PathBuf; 3] {
    let sidecar = |suffix: &str| {
        let mut value = path.as_os_str().to_os_string();
        value.push(suffix);
        PathBuf::from(value)
    };
    [path.to_path_buf(), sidecar("-wal"), sidecar("-shm")]
}

struct ScratchDatabase {
    path: PathBuf,
}

impl ScratchDatabase {
    fn new(path: PathBuf) -> Self {
        Self { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }

    fn retrieval_footprint_bytes(&self, key: &DbKey) -> Result<u64, String> {
        let db = mci_core::store::open_readonly(&self.path, key)
            .map_err(|error| format!("open retrieval index for measurement: {error}"))?;
        let bytes = db
            .conn()
            .query_row(
                "SELECT COALESCE(SUM(pgsize), 0) \
                   FROM dbstat \
                  WHERE name IN ( \
                        SELECT name \
                          FROM sqlite_master \
                         WHERE (tbl_name IN ('events', 'event_vectors', 'chunks') \
                                AND type IN ('table', 'index')) \
                            OR name GLOB 'events_fts*' \
                  )",
                [],
                |row| row.get::<_, i64>(0),
            )
            .map_err(|error| format!("measure retrieval index pages: {error}"))?;
        u64::try_from(bytes).map_err(|_| "retrieval index byte count was negative".to_string())
    }
}

impl Drop for ScratchDatabase {
    fn drop(&mut self) {
        for path in sqlite_artifact_paths(&self.path) {
            let _ = std::fs::remove_file(path);
        }
    }
}

fn event_excerpt(text: &str) -> String {
    let compact = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut excerpt = String::new();
    for ch in compact.chars().take(160) {
        excerpt.push(ch);
    }
    excerpt
}

#[cfg(test)]
fn seed_instance(
    inst: &Instance,
    db_path: &Path,
) -> Result<(SqlCipherBrainStore, BTreeMap<u64, EventMeta>, usize), String> {
    seed_instance_with_embedder(inst, db_path, None)
}

fn seed_instance_with_embedder(
    inst: &Instance,
    db_path: &Path,
    document_embedder: Option<&dyn Embedder>,
) -> Result<(SqlCipherBrainStore, BTreeMap<u64, EventMeta>, usize), String> {
    validate_instance_shape(inst)?;
    let key = DbKey::from_bytes([0x5a; 32]);
    let store = SqlCipherBrainStore::new(db_path, &key)
        .map_err(|e| format!("{}: open store: {e}", inst.question_id))?;
    let mut owner: BTreeMap<u64, EventMeta> = BTreeMap::new();
    let mut events_indexed = 0usize;
    let chunker = EventChunker::default();

    for (si, session) in inst.haystack_sessions.iter().enumerate() {
        let sid = inst
            .haystack_session_ids
            .get(si)
            .ok_or_else(|| format!("{}: session {si} has no id", inst.question_id))?;
        let base_ts = parse_dataset_ts(
            inst.haystack_dates
                .get(si)
                .ok_or_else(|| format!("{}: session {si} has no date", inst.question_id))?,
        )
        .map_err(|e| format!("{}: {e}", inst.question_id))?;
        let app_bundle_id = inst
            .haystack_app_ids
            .get(si)
            .cloned()
            .unwrap_or_else(|| "longmemeval".to_string());
        let window_title = inst
            .haystack_window_titles
            .get(si)
            .cloned()
            .unwrap_or_else(|| "session".to_string());
        let url = inst
            .haystack_urls
            .get(si)
            .cloned()
            .unwrap_or_else(|| sid.clone());

        for (ti, turn) in session.iter().enumerate() {
            let text = turn.content.trim();
            if text.is_empty() {
                continue;
            }
            let ts_us = base_ts + (ti as u64) * 1_000_000;
            let prepared = crate::brain_ingest::prepare_event_content(
                &chunker,
                Some(&app_bundle_id),
                Some(&window_title),
                Some(&url),
                ts_us,
                text,
            )
            .map_err(|e| format!("{}: prepare event: {e}", inst.question_id))?;
            let embedding = match (document_embedder, prepared.embedding_input.as_deref()) {
                (Some(embedder), Some(input)) if !input.is_empty() => Some(
                    embedder
                        .embed_one(input)
                        .map_err(|e| format!("{}: embed: {e}", inst.question_id))?,
                ),
                _ => None,
            };
            let event = Event {
                id: EventId(0),
                ts_us,
                app_bundle_id: Some(app_bundle_id.clone()),
                window_title: Some(window_title.clone()),
                url: Some(url.clone()),
                text: prepared.stored_text,
                embedding,
                summary: None,
                entities: None,
                episode_id: None,
                cascade_reason: 0,
                keyframe_blob: None,
                tab_id: None,
            };
            let id = store
                .put_event(&event)
                .map_err(|e| format!("{}: put_event: {e}", inst.question_id))?;
            owner.insert(
                id.0,
                EventMeta {
                    session_id: sid.clone(),
                    app_bundle_id: Some(app_bundle_id.clone()),
                    window_title: Some(window_title.clone()),
                    url: Some(url.clone()),
                    excerpt: event_excerpt(text),
                },
            );
            events_indexed += 1;
        }
    }

    Ok((store, owner, events_indexed))
}

/// The two embedder flavours, built once for a whole run.
///
/// Loading the Core ML model costs roughly 340 ms. Building these inside
/// the per-instance function meant a 500-instance run paid that 1,000
/// times, about five minutes of pure model loading and more under load.
/// A benchmark exists to be re-run after a change, so its own overhead is
/// worth removing.
pub struct Embedders {
    /// Embeds stored text.
    pub document: Arc<dyn mci_brain::Embedder>,
    /// Embeds the query, adding the model-card prefix (ADR-0011 §3).
    /// Using the document flavour here quietly degrades every result.
    pub query: Arc<dyn mci_brain::Embedder>,
    /// Resolved model bundle used by the production loader.
    pub model_path: PathBuf,
}

impl Embedders {
    /// Load both flavours once.
    ///
    /// # Errors
    /// When no real Core ML model resolves. The benchmark refuses rather
    /// than reporting a number for an arm that silently ran on a
    /// zero-vector stub.
    pub fn load() -> Result<Self, String> {
        let (document, is_real) = crate::embedder_load::load_embedder_backend();
        if !is_real {
            return Err(
                "the hybrid arm needs the real ArcticEmbedS model and none resolved; \
                 refusing to report a number for an arm that did not run"
                    .to_string(),
            );
        }
        let (query, _) = crate::embedder_load::load_query_embedder_backend();
        let model_path = resolved_arctic_model_path().ok_or_else(|| {
            "the Core ML embedder loaded but its resolved model path could not be identified"
                .to_string()
        })?;
        Ok(Self {
            document,
            query,
            model_path,
        })
    }
}

#[cfg(target_os = "macos")]
fn resolved_arctic_model_path() -> Option<PathBuf> {
    crate::embedder_load::arctic_embed_s_model_candidates()
        .into_iter()
        .find(|path| path.exists())
        .map(|path| path.canonicalize().unwrap_or(path))
}

#[cfg(not(target_os = "macos"))]
fn resolved_arctic_model_path() -> Option<PathBuf> {
    None
}

/// Build one instance's brain, then run the question against it.
///
/// # Errors
/// Any store, embed or retrieval failure, with the instance id attached.
#[allow(clippy::too_many_lines)] // One instance's resource lifecycle is clearest in one scope.
pub fn run_instance(
    inst: &Instance,
    arm: Arm,
    ks: &[usize],
    dir: &Path,
    embedders: Option<&Embedders>,
) -> Result<InstanceResult, String> {
    let started = Instant::now();
    let database = ScratchDatabase::new(scratch_db_path(dir, arm.label(), &inst.question_id));
    let document_embedder = match arm {
        Arm::Lexical => None,
        Arm::Hybrid => Some(
            embedders
                .ok_or_else(|| {
                    format!(
                        "{}: the hybrid arm needs an embedder and none was given",
                        inst.question_id
                    )
                })?
                .document
                .as_ref(),
        ),
    };
    let (store, owner, events_indexed) =
        seed_instance_with_embedder(inst, database.path(), document_embedder)?;

    let store = Arc::new(store);
    let now_us =
        parse_dataset_ts(&inst.question_date).map_err(|e| format!("{}: {e}", inst.question_id))?;

    let max_k = ks.iter().copied().max().unwrap_or(10);
    // Ask for more events than sessions wanted: several events collapse
    // into one session, so a top-k of events is a shorter list of
    // sessions. Over-fetching keeps the session list long enough to score
    // the deepest k honestly.
    let query = RetrievalQuery {
        text: inst.question.clone(),
        limit: max_k * 10,
        time_filter: None,
        app_filter: None,
    };

    let retrieval = match arm {
        // No embedder at all, rather than a zero-vector stub fed into
        // fusion: against a zero query every document scores an identical
        // cosine, which would add uniform noise on top of the lexical
        // signal and make this arm measure something that is neither
        // lexical nor hybrid.
        Arm::Lexical => {
            let sanitizing = crate::mcp::live::FtsSanitizingStore {
                inner: Arc::clone(&store),
            };
            typed_outcome_hits(
                lexical_retrieval_outcome(&sanitizing, &query)
                    .map_err(|e| format!("{}: lexical retrieve: {e}", inst.question_id))?,
                &inst.question_id,
            )?
        }
        Arm::Hybrid => {
            // The lexical arm needs no model, so the caller is allowed to
            // skip loading one entirely for a lexical-only run.
            let embedders = embedders.ok_or_else(|| {
                format!(
                    "{}: the hybrid arm needs an embedder and none was given",
                    inst.question_id
                )
            })?;
            let q_emb = Arc::clone(&embedders.query);
            // Both wrappers are the ones `mcp-serve` uses. `DynEmbedder`
            // because `HybridRetriever<S, E>` needs `E: Sized`, and
            // `FtsSanitizingStore` because the retriever hands raw query
            // text to FTS5 — without it a question containing an
            // apostrophe or a hyphen would error out of the lexical half
            // and the hybrid arm would quietly score as semantic-only.
            let sanitizing = crate::mcp::live::FtsSanitizingStore {
                inner: Arc::clone(&store),
            };
            let outcome = HybridRetriever::new(
                Arc::new(sanitizing),
                Arc::new(crate::mcp::live::DynEmbedder(q_emb)),
                now_us,
            )
            .retrieve_outcome(&query)
            .map_err(|e| format!("{}: retrieve: {e}", inst.question_id))?;
            typed_outcome_hits(outcome, &inst.question_id)?
        }
    };

    // Collapse the event ranking into a session ranking, first occurrence
    // wins. This is the granularity the labels are at.
    let mut ranked: Vec<String> = Vec::new();
    let answer_sessions: BTreeSet<&str> =
        inst.answer_session_ids.iter().map(String::as_str).collect();
    let mut top_hits: Vec<RankedHit> = Vec::new();
    for (id, score) in retrieval.hits {
        if let Some(meta) = owner.get(&id) {
            if !ranked.iter().any(|s| s == &meta.session_id) {
                ranked.push(meta.session_id.clone());
                top_hits.push(RankedHit {
                    rank: ranked.len(),
                    event_id: id,
                    session_id: meta.session_id.clone(),
                    app_bundle_id: meta.app_bundle_id.clone(),
                    window_title: meta.window_title.clone(),
                    url: meta.url.clone(),
                    relevant: answer_sessions.contains(meta.session_id.as_str()),
                    score,
                    excerpt: meta.excerpt.clone(),
                });
            }
        }
    }

    let is_unanswerable = inst.unanswerable || inst.answer_session_ids.is_empty();
    let answers: Vec<&String> = inst.answer_session_ids.iter().collect();
    let first_hit_rank = if is_unanswerable {
        None
    } else {
        ranked
            .iter()
            .position(|s| answers.contains(&s))
            .map(|p| p + 1)
    };

    let mut recall_at = BTreeMap::new();
    let mut provenance_coverage_at = BTreeMap::new();
    for &k in ks {
        let found = ranked
            .iter()
            .take(k)
            .filter(|s| answers.iter().any(|a| a == s))
            .count();
        recall_at.insert(
            k,
            if is_unanswerable {
                None
            } else {
                Some(count_as_f64(found) / count_as_f64(answers.len()))
            },
        );
        provenance_coverage_at.insert(
            k,
            if is_unanswerable {
                None
            } else {
                Some(
                    top_hits
                        .iter()
                        .take(k)
                        .any(|hit| hit.relevant && provenance_available(hit)),
                )
            },
        );
    }

    let outcome = if is_unanswerable {
        if top_hits.is_empty() {
            Outcome::Abstained
        } else {
            Outcome::FalsePositive
        }
    } else if first_hit_rank.is_some() {
        Outcome::Matched
    } else {
        Outcome::Missed
    };

    drop(store);
    let index_size_bytes = database.retrieval_footprint_bytes(&DbKey::from_bytes([0x5a; 32]))?;

    Ok(InstanceResult {
        arm: arm.label().to_string(),
        question_id: inst.question_id.clone(),
        question_type: inst.question_type.clone(),
        tags: inst.tags.clone(),
        unanswerable: is_unanswerable,
        outcome,
        retrieval_disposition: retrieval.disposition,
        first_hit_rank,
        recall_at,
        provenance_coverage_at,
        answer_sessions: answers.len(),
        sessions_in_haystack: inst.haystack_sessions.len(),
        events_indexed,
        top_hits,
        latency_ms: started.elapsed().as_secs_f64() * 1000.0,
        index_size_bytes,
    })
}

struct RetrievalMeasurement {
    hits: Vec<(u64, f64)>,
    disposition: RetrievalDisposition,
}

fn typed_outcome_hits(
    outcome: RetrievalOutcome,
    question_id: &str,
) -> Result<RetrievalMeasurement, String> {
    match outcome {
        RetrievalOutcome::Matched { matches } => Ok(RetrievalMeasurement {
            hits: matches
                .into_iter()
                .map(|value| (value.hit.event_id.0, f64::from(value.hit.score_combined)))
                .collect(),
            disposition: RetrievalDisposition::Matched,
        }),
        RetrievalOutcome::Contradicted { matches } => Ok(RetrievalMeasurement {
            hits: matches
                .into_iter()
                .map(|value| (value.hit.event_id.0, f64::from(value.hit.score_combined)))
                .collect(),
            disposition: RetrievalDisposition::Contradicted,
        }),
        RetrievalOutcome::NothingMatched { reason } => Ok(RetrievalMeasurement {
            hits: Vec::new(),
            disposition: match reason {
                NothingMatchedReason::NoCandidates => {
                    RetrievalDisposition::NothingMatchedNoCandidates
                }
                NothingMatchedReason::EvidenceFloor => {
                    RetrievalDisposition::NothingMatchedEvidenceFloor
                }
                NothingMatchedReason::ZeroLimit => RetrievalDisposition::NothingMatchedZeroLimit,
            },
        }),
        RetrievalOutcome::Degraded {
            degradation: RetrievalDegradation::EvidenceSufficiencyUnqualified,
            fallback_matches,
        } => Ok(RetrievalMeasurement {
            hits: fallback_matches
                .into_iter()
                .map(|value| (value.hit.event_id.0, f64::from(value.hit.score_combined)))
                .collect(),
            disposition: RetrievalDisposition::DegradedEvidenceSufficiencyUnqualified,
        }),
        RetrievalOutcome::Degraded {
            degradation: RetrievalDegradation::EvidenceVerifierUnavailable,
            fallback_matches,
        } => Ok(RetrievalMeasurement {
            hits: fallback_matches
                .into_iter()
                .map(|value| (value.hit.event_id.0, f64::from(value.hit.score_combined)))
                .collect(),
            disposition: RetrievalDisposition::DegradedEvidenceVerifierUnavailable,
        }),
        RetrievalOutcome::Degraded { degradation, .. } => Err(format!(
            "{question_id}: production retrieval degraded: {degradation:?}"
        )),
    }
}

fn provenance_available(hit: &RankedHit) -> bool {
    hit.app_bundle_id.is_some() || hit.window_title.is_some() || hit.url.is_some()
}

// ---------------------------------------------------------------------------
// Abstention probe
// ---------------------------------------------------------------------------

/// One measurement: the best raw semantic cosine a brain could offer for
/// a question, and whether that brain actually contained the answer.
#[derive(serde::Serialize, Clone, Copy)]
pub struct AbstentionSample {
    /// Best cosine over the brain's vectors, before fusion normalizes it.
    pub top_cosine: f32,
    /// True when the question was asked of its own haystack.
    pub answerable: bool,
}

/// Measure whether a relevance floor is possible, and where it should sit.
///
/// # Why this is a separate probe
///
/// `LongMemEval` contains no unanswerable questions: every one of the 500 is
/// answerable from its own haystack. So the dataset can score retrieval
/// but cannot, on its own, say when a system should decline to answer.
///
/// Cross-pairing supplies the missing half. Instance `i`'s brain is asked
/// its own question (answerable) and then the *next* instance's question
/// (not answerable, since that question is about a different person's
/// history). Both run against an identical corpus, so the only thing that
/// varies is whether the answer is present.
///
/// The measurement is the raw cosine rather than the fused score,
/// deliberately. The fused score is min-max normalized per query, which
/// rescales each query's own candidate pool so its best candidate lands
/// near 1 whether or not anything relevant exists. That makes it a
/// within-query rank and useless as a cross-query confidence. See
/// `examples/score_probe.rs`.
///
/// Cross-pairing is not perfectly clean: another instance's question could
/// coincidentally be answerable here. The questions are specific and
/// personal, so this should be rare, and it biases the result toward
/// *understating* the separation rather than inventing one.
///
/// # Errors
/// Any store or embed failure, with the instance id attached.
pub fn run_abstention_probe(
    inst: &Instance,
    foreign_question: &str,
    dir: &Path,
    embedders: &Embedders,
) -> Result<Vec<AbstentionSample>, String> {
    let database = ScratchDatabase::new(scratch_db_path(dir, "abstention", &inst.question_id));
    let (store, _owner, _events_indexed) =
        seed_instance_with_embedder(inst, database.path(), Some(embedders.document.as_ref()))?;
    let q_emb = &embedders.query;
    let mut out = Vec::with_capacity(2);
    for (text, answerable) in [(inst.question.as_str(), true), (foreign_question, false)] {
        let v = q_emb
            .embed_one(text)
            .map_err(|e| format!("{}: embed query: {e}", inst.question_id))?;
        let hits = store
            .vec_search(&v, 1)
            .map_err(|e| format!("{}: vec_search: {e}", inst.question_id))?;
        out.push(AbstentionSample {
            top_cosine: hits.first().map_or(0.0, |h| h.1),
            answerable,
        });
    }

    drop(store);
    Ok(out)
}

/// Pick the cosine threshold that best separates answerable from not, and
/// report what it costs.
///
/// Sweeps every midpoint between observed values rather than a fixed grid,
/// so the reported threshold is one the data actually supports.
#[must_use]
pub fn best_threshold(samples: &[AbstentionSample]) -> Option<ThresholdReport> {
    if samples.is_empty() {
        return None;
    }
    let mut vals: Vec<f32> = samples.iter().map(|s| s.top_cosine).collect();
    vals.sort_by(|a, b| a.partial_cmp(b).expect("no NaN cosines"));
    vals.dedup();

    let pos = samples.iter().filter(|s| s.answerable).count();
    let neg = samples.len() - pos;

    let mut best: Option<ThresholdReport> = None;
    for w in vals.windows(2) {
        let t = w[0] + (w[1] - w[0]) * 0.5;
        // Answer when cosine >= t.
        let kept_answerable = samples
            .iter()
            .filter(|s| s.answerable && s.top_cosine >= t)
            .count();
        let kept_junk = samples
            .iter()
            .filter(|s| !s.answerable && s.top_cosine >= t)
            .count();
        // Youden's J: how much better than chance the split is.
        let tpr = if pos == 0 {
            0.0
        } else {
            count_as_f64(kept_answerable) / count_as_f64(pos)
        };
        let fpr = if neg == 0 {
            0.0
        } else {
            count_as_f64(kept_junk) / count_as_f64(neg)
        };
        let j = tpr - fpr;
        if best.as_ref().is_none_or(|b| j > b.youden_j) {
            best = Some(ThresholdReport {
                threshold: t,
                answerable_kept: tpr,
                unanswerable_kept: fpr,
                youden_j: j,
                positives: pos,
                negatives: neg,
            });
        }
    }
    best
}

/// What a candidate relevance floor would do to real traffic.
#[derive(serde::Serialize, Clone, Copy)]
pub struct ThresholdReport {
    /// Answer when the top raw cosine is at least this.
    pub threshold: f32,
    /// Fraction of answerable questions still answered. Higher is better.
    pub answerable_kept: f64,
    /// Fraction of unanswerable questions still answered. Lower is better;
    /// these are the confident-nonsense cases the floor exists to stop.
    pub unanswerable_kept: f64,
    /// `answerable_kept - unanswerable_kept`. 0 is chance, 1 is perfect.
    pub youden_j: f64,
    /// Sample sizes, so the numbers can be read with their uncertainty.
    pub positives: usize,
    /// Count of unanswerable samples.
    pub negatives: usize,
}

fn distribution(values: &[f64]) -> DistributionStats {
    if values.is_empty() {
        return DistributionStats::default();
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).expect("no NaN distribution values"));
    let p50_index = nearest_percentile_index(sorted.len(), 50, 100);
    let p95_index = nearest_percentile_index(sorted.len(), 95, 100);
    let sum: f64 = sorted.iter().sum();
    DistributionStats {
        min: sorted[0],
        p50: sorted[p50_index],
        p95: sorted[p95_index],
        max: sorted[sorted.len() - 1],
        mean: sum / count_as_f64(sorted.len()),
    }
}

fn nearest_percentile_index(len: usize, numerator: usize, denominator: usize) -> usize {
    debug_assert!(len > 0);
    debug_assert!(denominator > 0);
    let last = len.saturating_sub(1);
    last.saturating_mul(numerator)
        .saturating_add(denominator / 2)
        .checked_div(denominator)
        .unwrap_or(0)
        .min(last)
}

fn count_as_f64(value: usize) -> f64 {
    f64::from(u32::try_from(value).expect("benchmark corpus count exceeds u32"))
}

#[allow(clippy::cast_precision_loss)]
fn byte_count_as_f64(value: u64) -> f64 {
    // Distribution summaries are approximate above f64's exact integer range.
    value as f64
}

fn counts(results: &[InstanceResult], outcome: Outcome) -> usize {
    results.iter().filter(|r| r.outcome == outcome).count()
}

fn threshold_floor(value: f64) -> f64 {
    (value - value.max(0.5) * 0.1).max(0.0)
}

fn separation_threshold_floor(value: f64) -> f64 {
    (value - value.abs().max(0.5) * 0.1).max(-1.0)
}

fn threshold_ceiling(value: f64) -> f64 {
    (value + 0.10).min(1.0)
}

fn latency_ceiling(value: f64) -> f64 {
    value + value.max(25.0)
}

fn size_ceiling(value: f64) -> f64 {
    value * 1.35 + 4096.0
}

fn map_threshold_min(source: &BTreeMap<usize, Option<f64>>, k: usize, dest: &mut Option<f64>) {
    *dest = source.get(&k).copied().flatten().map(threshold_floor);
}

fn map_threshold_max(source: &BTreeMap<usize, Option<f64>>, k: usize, dest: &mut Option<f64>) {
    *dest = source.get(&k).copied().flatten().map(threshold_ceiling);
}

fn map_separation_threshold_min(
    source: &BTreeMap<usize, Option<f64>>,
    k: usize,
    dest: &mut Option<f64>,
) {
    *dest = source
        .get(&k)
        .copied()
        .flatten()
        .map(separation_threshold_floor);
}

/// Derive material-regression thresholds from a measured baseline run.
#[must_use]
pub fn derive_regression_thresholds(summary: &Summary) -> RegressionThresholds {
    let mut out = RegressionThresholds {
        mrr_min: summary.mrr.map(threshold_floor),
        latency_p95_ms_max: Some(latency_ceiling(summary.latency_ms.p95)),
        index_size_p95_bytes_max: Some(size_ceiling(summary.index_size_bytes.p95)),
        ..RegressionThresholds::default()
    };
    map_threshold_min(&summary.hit_rate_at, 1, &mut out.hit_rate_at_1_min);
    map_threshold_min(&summary.hit_rate_at, 3, &mut out.hit_rate_at_3_min);
    map_threshold_min(&summary.hit_rate_at, 5, &mut out.hit_rate_at_5_min);
    map_threshold_min(&summary.hit_rate_at, 10, &mut out.hit_rate_at_10_min);
    map_threshold_min(&summary.recall_at, 1, &mut out.recall_at_1_min);
    map_threshold_min(&summary.recall_at, 3, &mut out.recall_at_3_min);
    map_threshold_min(&summary.recall_at, 5, &mut out.recall_at_5_min);
    map_threshold_min(&summary.recall_at, 10, &mut out.recall_at_10_min);
    map_threshold_min(
        &summary.provenance_coverage_at,
        1,
        &mut out.provenance_coverage_at_1_min,
    );
    map_threshold_min(
        &summary.provenance_coverage_at,
        3,
        &mut out.provenance_coverage_at_3_min,
    );
    map_threshold_min(
        &summary.provenance_coverage_at,
        5,
        &mut out.provenance_coverage_at_5_min,
    );
    map_threshold_min(
        &summary.provenance_coverage_at,
        10,
        &mut out.provenance_coverage_at_10_min,
    );
    map_threshold_max(
        &summary.false_positive_rate_at,
        1,
        &mut out.false_positive_rate_at_1_max,
    );
    map_threshold_max(
        &summary.false_positive_rate_at,
        3,
        &mut out.false_positive_rate_at_3_max,
    );
    map_threshold_max(
        &summary.false_positive_rate_at,
        5,
        &mut out.false_positive_rate_at_5_max,
    );
    map_threshold_max(
        &summary.false_positive_rate_at,
        10,
        &mut out.false_positive_rate_at_10_max,
    );
    map_separation_threshold_min(
        &summary.abstention_separation_at,
        1,
        &mut out.abstention_separation_at_1_min,
    );
    map_separation_threshold_min(
        &summary.abstention_separation_at,
        3,
        &mut out.abstention_separation_at_3_min,
    );
    map_separation_threshold_min(
        &summary.abstention_separation_at,
        5,
        &mut out.abstention_separation_at_5_min,
    );
    map_separation_threshold_min(
        &summary.abstention_separation_at,
        10,
        &mut out.abstention_separation_at_10_min,
    );
    out
}

fn compare_min(
    failures: &mut Vec<String>,
    arm: &str,
    label: &str,
    current: Option<f64>,
    min: Option<f64>,
) {
    match (current, min) {
        (Some(current), Some(min)) if current + 1e-9 < min => {
            failures.push(format!("{arm}: {label} {current:.3} < {min:.3}"));
        }
        (None, Some(_)) => failures.push(format!("{arm}: {label} is undefined in current run")),
        _ => {}
    }
}

fn compare_max(
    failures: &mut Vec<String>,
    arm: &str,
    label: &str,
    current: Option<f64>,
    max: Option<f64>,
) {
    match (current, max) {
        (Some(current), Some(max)) if current - 1e-9 > max => {
            failures.push(format!("{arm}: {label} {current:.3} > {max:.3}"));
        }
        (None, Some(_)) => failures.push(format!("{arm}: {label} is undefined in current run")),
        _ => {}
    }
}

fn map_value(map: &BTreeMap<usize, Option<f64>>, k: usize) -> Option<f64> {
    map.get(&k).copied().flatten()
}

impl RegressionThresholds {
    fn hit_min(&self, k: usize) -> Option<f64> {
        match k {
            1 => self.hit_rate_at_1_min,
            3 => self.hit_rate_at_3_min,
            5 => self.hit_rate_at_5_min,
            10 => self.hit_rate_at_10_min,
            _ => None,
        }
    }

    fn recall_min(&self, k: usize) -> Option<f64> {
        match k {
            1 => self.recall_at_1_min,
            3 => self.recall_at_3_min,
            5 => self.recall_at_5_min,
            10 => self.recall_at_10_min,
            _ => None,
        }
    }

    fn provenance_min(&self, k: usize) -> Option<f64> {
        match k {
            1 => self.provenance_coverage_at_1_min,
            3 => self.provenance_coverage_at_3_min,
            5 => self.provenance_coverage_at_5_min,
            10 => self.provenance_coverage_at_10_min,
            _ => None,
        }
    }

    fn false_positive_max(&self, k: usize) -> Option<f64> {
        match k {
            1 => self.false_positive_rate_at_1_max,
            3 => self.false_positive_rate_at_3_max,
            5 => self.false_positive_rate_at_5_max,
            10 => self.false_positive_rate_at_10_max,
            _ => None,
        }
    }

    fn separation_min(&self, k: usize) -> Option<f64> {
        match k {
            1 => self.abstention_separation_at_1_min,
            3 => self.abstention_separation_at_3_min,
            5 => self.abstention_separation_at_5_min,
            10 => self.abstention_separation_at_10_min,
            _ => None,
        }
    }
}

fn valid_git_commit(value: &str) -> bool {
    value.len() == 40 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn validate_threshold_shape(
    failures: &mut Vec<String>,
    arm: &BaselineArmSummary,
    thresholds: &RegressionThresholds,
    ks: &[usize],
) {
    for &k in ks {
        if arm.answerable_instances > 0 {
            for (label, value) in [
                ("hit", thresholds.hit_min(k)),
                ("recall", thresholds.recall_min(k)),
                ("provenance", thresholds.provenance_min(k)),
            ] {
                if value.is_none() {
                    failures.push(format!(
                        "baseline arm {} is missing required {label}@{k} threshold",
                        arm.arm
                    ));
                }
            }
        }
        if arm.unanswerable_instances > 0 && thresholds.false_positive_max(k).is_none() {
            failures.push(format!(
                "baseline arm {} is missing required false_positive@{k} threshold",
                arm.arm
            ));
        }
        if arm.answerable_instances > 0
            && arm.unanswerable_instances > 0
            && thresholds.separation_min(k).is_none()
        {
            failures.push(format!(
                "baseline arm {} is missing required abstention_separation@{k} threshold",
                arm.arm
            ));
        }
    }
    if arm.answerable_instances > 0 && thresholds.mrr_min.is_none() {
        failures.push(format!(
            "baseline arm {} is missing required mrr threshold",
            arm.arm
        ));
    }
    if thresholds.latency_p95_ms_max.is_none() {
        failures.push(format!(
            "baseline arm {} is missing required latency threshold",
            arm.arm
        ));
    }
    if thresholds.index_size_p95_bytes_max.is_none() {
        failures.push(format!(
            "baseline arm {} is missing required index-size threshold",
            arm.arm
        ));
    }
}

/// Compare measured summaries against a compatible committed baseline.
#[must_use]
#[allow(clippy::too_many_lines)] // The contract reads more safely as one ordered checklist.
pub fn compare_against_baseline(
    summaries: &[Summary],
    baseline: &BaselineFile,
    dataset_id: &str,
    dataset_checksum_sha256: &str,
    run: &RunMetadata,
) -> RegressionReport {
    let mut failures = Vec::new();
    if !baseline.complete {
        failures.push("baseline is incomplete".to_string());
    }
    if !baseline.publishable {
        failures.push("baseline is not publishable".to_string());
    }
    if baseline.dataset_id != dataset_id {
        failures.push(format!(
            "baseline dataset id {:?} does not match {:?}",
            baseline.dataset_id, dataset_id
        ));
    }
    if baseline.dataset_checksum_sha256 != dataset_checksum_sha256 {
        failures.push("baseline dataset checksum does not match current dataset".to_string());
    }
    if baseline.run.ks != run.ks {
        failures.push(format!(
            "baseline k set {:?} does not match requested {:?}",
            baseline.run.ks, run.ks
        ));
    }
    if baseline.run.git_dirty_at_start {
        failures.push("baseline code identity is dirty".to_string());
    }
    if !valid_git_commit(&baseline.run.git_commit) {
        failures.push("baseline git_commit is not a full commit id".to_string());
    }
    if !valid_git_commit(&run.git_commit) {
        failures.push("current git_commit is not a full commit id".to_string());
    }

    let required_arms: BTreeSet<&str> = run.requested_arms.iter().map(String::as_str).collect();
    let baseline_requested: BTreeSet<&str> = baseline
        .run
        .requested_arms
        .iter()
        .map(String::as_str)
        .collect();
    let baseline_summaries: BTreeMap<&str, &BaselineArmSummary> = baseline
        .overall
        .iter()
        .map(|summary| (summary.arm.as_str(), summary))
        .collect();
    let current_summaries: BTreeMap<&str, &Summary> = summaries
        .iter()
        .map(|summary| (summary.arm.as_str(), summary))
        .collect();

    for arm in &required_arms {
        if !baseline_requested.contains(arm) {
            failures.push(format!("baseline run is missing requested arm {arm}"));
        }
        let Some(baseline_summary) = baseline_summaries.get(arm).copied() else {
            failures.push(format!("baseline is missing requested arm {arm}"));
            continue;
        };
        let Some(thresholds) = baseline.regression_thresholds.get(*arm) else {
            failures.push(format!(
                "baseline is missing requested arm {arm} regression thresholds"
            ));
            continue;
        };
        validate_threshold_shape(&mut failures, baseline_summary, thresholds, &run.ks);
        if !current_summaries.contains_key(arm) {
            failures.push(format!("current run is missing requested arm {arm}"));
        }
    }

    if required_arms.contains("hybrid") {
        if baseline.run.model_family != run.model_family {
            failures.push("baseline model family does not match current model".to_string());
        }
        if baseline.run.model_checksum_sha256.is_none()
            || baseline.run.model_checksum_sha256 != run.model_checksum_sha256
        {
            failures.push("baseline model checksum does not match current model".to_string());
        }
        if baseline.run.compute_mode != run.compute_mode {
            failures.push("baseline compute mode does not match current run".to_string());
        }
    }

    if !failures.is_empty() {
        return RegressionReport {
            passed: false,
            failures,
        };
    }

    for summary in summaries {
        let thresholds = &baseline.regression_thresholds[&summary.arm];
        for &k in &run.ks {
            compare_min(
                &mut failures,
                &summary.arm,
                &format!("hit@{k}"),
                map_value(&summary.hit_rate_at, k),
                thresholds.hit_min(k),
            );
            compare_min(
                &mut failures,
                &summary.arm,
                &format!("recall@{k}"),
                map_value(&summary.recall_at, k),
                thresholds.recall_min(k),
            );
            compare_min(
                &mut failures,
                &summary.arm,
                &format!("provenance@{k}"),
                map_value(&summary.provenance_coverage_at, k),
                thresholds.provenance_min(k),
            );
            compare_max(
                &mut failures,
                &summary.arm,
                &format!("false_positive@{k}"),
                map_value(&summary.false_positive_rate_at, k),
                thresholds.false_positive_max(k),
            );
            compare_min(
                &mut failures,
                &summary.arm,
                &format!("abstention_separation@{k}"),
                map_value(&summary.abstention_separation_at, k),
                thresholds.separation_min(k),
            );
        }
        compare_min(
            &mut failures,
            &summary.arm,
            "mrr",
            summary.mrr,
            thresholds.mrr_min,
        );
        compare_max(
            &mut failures,
            &summary.arm,
            "latency_p95_ms",
            Some(summary.latency_ms.p95),
            thresholds.latency_p95_ms_max,
        );
        compare_max(
            &mut failures,
            &summary.arm,
            "index_size_p95_bytes",
            Some(summary.index_size_bytes.p95),
            thresholds.index_size_p95_bytes_max,
        );
    }
    RegressionReport {
        passed: failures.is_empty(),
        failures,
    }
}

/// Fixed product-quality targets, independent of any measured baseline.
#[must_use]
pub fn absolute_quality_targets() -> BTreeMap<String, QualityTargets> {
    [(
        "hybrid".to_string(),
        QualityTargets {
            hit_rate_at_5_min: 0.90,
            recall_at_5_min: 0.90,
            provenance_coverage_at_5_min: 0.90,
            false_positive_rate_at_5_max: 0.10,
            abstention_separation_at_5_min: 0.80,
            mrr_min: 0.85,
        },
    )]
    .into_iter()
    .collect()
}

/// Evaluate fixed launch-quality targets against measured summaries.
#[must_use]
pub fn evaluate_quality_gate(
    summaries: &[Summary],
    targets: &BTreeMap<String, QualityTargets>,
) -> RegressionReport {
    let mut failures = Vec::new();
    for (arm, target) in targets {
        let Some(summary) = summaries.iter().find(|summary| &summary.arm == arm) else {
            failures.push(format!("quality gate is missing required arm {arm}"));
            continue;
        };
        compare_min(
            &mut failures,
            arm,
            "absolute hit@5",
            map_value(&summary.hit_rate_at, 5),
            Some(target.hit_rate_at_5_min),
        );
        compare_min(
            &mut failures,
            arm,
            "absolute recall@5",
            map_value(&summary.recall_at, 5),
            Some(target.recall_at_5_min),
        );
        compare_min(
            &mut failures,
            arm,
            "absolute provenance@5",
            map_value(&summary.provenance_coverage_at, 5),
            Some(target.provenance_coverage_at_5_min),
        );
        compare_max(
            &mut failures,
            arm,
            "absolute false_positive@5",
            map_value(&summary.false_positive_rate_at, 5),
            Some(target.false_positive_rate_at_5_max),
        );
        compare_min(
            &mut failures,
            arm,
            "absolute abstention_separation@5",
            map_value(&summary.abstention_separation_at, 5),
            Some(target.abstention_separation_at_5_min),
        );
        compare_min(
            &mut failures,
            arm,
            "absolute mrr",
            summary.mrr,
            Some(target.mrr_min),
        );
    }
    RegressionReport {
        passed: failures.is_empty(),
        failures,
    }
}

/// Aggregate a set of per-instance results into one summary.
#[must_use]
pub fn summarize(results: &[InstanceResult], arm: Arm, ks: &[usize]) -> Summary {
    let n = results.len();
    let answerable: Vec<&InstanceResult> = results.iter().filter(|r| !r.unanswerable).collect();
    let unanswerable: Vec<&InstanceResult> = results.iter().filter(|r| r.unanswerable).collect();
    let answerable_denom = (!answerable.is_empty()).then(|| count_as_f64(answerable.len()));
    let unanswerable_denom = (!unanswerable.is_empty()).then(|| count_as_f64(unanswerable.len()));

    let mut hit_rate_at = BTreeMap::new();
    let mut recall_at = BTreeMap::new();
    let mut provenance_coverage_at = BTreeMap::new();
    let mut false_positive_rate_at = BTreeMap::new();
    let mut abstention_separation_at = BTreeMap::new();
    for &k in ks {
        let hits = answerable
            .iter()
            .filter(|r| r.first_hit_rank.is_some_and(|rank| rank <= k))
            .count();
        let hit_rate = answerable_denom.map(|denom| count_as_f64(hits) / denom);
        hit_rate_at.insert(k, hit_rate);
        let rec: f64 = answerable
            .iter()
            .map(|r| r.recall_at.get(&k).copied().flatten().unwrap_or(0.0))
            .sum();
        recall_at.insert(k, answerable_denom.map(|denom| rec / denom));
        let provenance_hits = answerable
            .iter()
            .filter(|r| {
                r.provenance_coverage_at
                    .get(&k)
                    .copied()
                    .flatten()
                    .unwrap_or(false)
            })
            .count();
        provenance_coverage_at.insert(
            k,
            answerable_denom.map(|denom| count_as_f64(provenance_hits) / denom),
        );
        let false_positives = unanswerable
            .iter()
            .filter(|r| r.top_hits.iter().take(k).next().is_some())
            .count();
        let fpr = unanswerable_denom.map(|denom| count_as_f64(false_positives) / denom);
        false_positive_rate_at.insert(k, fpr);
        abstention_separation_at.insert(
            k,
            hit_rate
                .zip(fpr)
                .map(|(answerable_tpr, unanswerable_fpr)| answerable_tpr - unanswerable_fpr),
        );
    }

    let mrr = answerable_denom.map(|denom| {
        answerable
            .iter()
            .map(|r| {
                r.first_hit_rank
                    .map_or(0.0, |rank| 1.0 / count_as_f64(rank))
            })
            .sum::<f64>()
            / denom
    });
    let latency_ms = distribution(&results.iter().map(|r| r.latency_ms).collect::<Vec<_>>());
    let index_size_bytes = distribution(
        &results
            .iter()
            .map(|r| byte_count_as_f64(r.index_size_bytes))
            .collect::<Vec<_>>(),
    );

    Summary {
        arm: arm.label().to_string(),
        instances: n,
        hit_rate_at,
        recall_at,
        provenance_coverage_at,
        false_positive_rate_at,
        abstention_separation_at,
        mrr,
        complete_misses: answerable
            .iter()
            .filter(|r| r.first_hit_rank.is_none())
            .count(),
        outcomes: OutcomeCounts {
            matched: counts(results, Outcome::Matched),
            missed: counts(results, Outcome::Missed),
            abstained: counts(results, Outcome::Abstained),
            false_positive: counts(results, Outcome::FalsePositive),
        },
        answerable_instances: answerable.len(),
        unanswerable_instances: unanswerable.len(),
        latency_ms,
        index_size_bytes,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn benchmark_seed_text_is_byte_identical_to_production_composition() {
        let inst = Instance {
            question_id: "header-parity".into(),
            question_type: "exact_recall".into(),
            question: "What did the production seeder store?".into(),
            question_date: "2026/08/31 (Mon) 12:00".into(),
            answer_session_ids: vec!["github://hippocampus/pull/431".into()],
            haystack_dates: vec!["2026/08/31 (Mon) 11:00".into()],
            haystack_session_ids: vec!["github://hippocampus/pull/431".into()],
            haystack_sessions: vec![vec![Turn {
                role: "assistant".into(),
                content: "PR 431 introduced complete false.".into(),
            }]],
            haystack_app_ids: vec!["com.github.GitHubClient".into()],
            haystack_window_titles: vec!["PR 431 benchmark honesty".into()],
            haystack_urls: vec!["github://hippocampus/pull/431".into()],
            tags: vec!["github".into()],
            unanswerable: false,
        };
        let dir = tempdir().expect("tempdir");
        let db_path = dir.path().join("seed.sqlite");
        let (store, owner, _) = seed_instance(&inst, &db_path).expect("seed instance");
        let event_id = EventId(*owner.keys().next().expect("seeded event id"));
        let event = store
            .get_event(event_id)
            .expect("read seeded event")
            .expect("seeded event");
        let ts_us = parse_dataset_ts(&inst.haystack_dates[0]).expect("timestamp");
        let expected = format!(
            "{}{}",
            crate::brain_ingest::compose_context_header(
                Some("com.github.GitHubClient"),
                Some("PR 431 benchmark honesty"),
                Some("github://hippocampus/pull/431"),
                ts_us,
            ),
            "PR 431 introduced complete false."
        );

        assert_eq!(event.text.as_bytes(), expected.as_bytes());
    }

    #[test]
    fn benchmark_scores_unavailable_verifier_fallback_without_certifying_it() {
        let result = typed_outcome_hits(
            RetrievalOutcome::Degraded {
                degradation: mci_brain::RetrievalDegradation::EvidenceVerifierUnavailable,
                fallback_matches: Vec::new(),
            },
            "unavailable-verifier",
        )
        .expect("ranking remains measurable");

        assert_eq!(result.hits, Vec::new());
        assert_eq!(
            result.disposition,
            RetrievalDisposition::DegradedEvidenceVerifierUnavailable
        );
    }

    #[test]
    fn retrieval_footprint_excludes_unrelated_projection_schema() {
        let inst = Instance {
            question_id: "retrieval-footprint".into(),
            question_type: "exact_recall".into(),
            question: "What was indexed?".into(),
            question_date: "2026/08/31 (Mon) 12:00".into(),
            answer_session_ids: vec!["files:///answer.txt".into()],
            haystack_dates: vec!["2026/08/31 (Mon) 11:00".into()],
            haystack_session_ids: vec!["files:///answer.txt".into()],
            haystack_sessions: vec![vec![Turn {
                role: "assistant".into(),
                content: "The indexed answer is cobalt.".into(),
            }]],
            haystack_app_ids: Vec::new(),
            haystack_window_titles: Vec::new(),
            haystack_urls: Vec::new(),
            tags: Vec::new(),
            unanswerable: false,
        };
        let dir = tempdir().expect("tempdir");
        let database = ScratchDatabase::new(dir.path().join("footprint.sqlite"));
        let (store, _, _) = seed_instance(&inst, database.path()).expect("seed instance");
        drop(store);
        let key = DbKey::from_bytes([0x5a; 32]);
        let before = database
            .retrieval_footprint_bytes(&key)
            .expect("measure retrieval footprint");

        let mut db = mci_core::store::open(database.path(), &key).expect("open scratch store");
        let tx = db.conn_mut().transaction().expect("start unrelated write");
        tx.execute_batch(
            "CREATE TABLE unrelated_projection(payload BLOB NOT NULL);\
             INSERT INTO unrelated_projection(payload) VALUES (zeroblob(262144));",
        )
        .expect("write unrelated projection data");
        tx.commit().expect("commit unrelated write");
        drop(db);

        let after = database
            .retrieval_footprint_bytes(&key)
            .expect("remeasure retrieval footprint");
        assert_eq!(
            after, before,
            "projection-only schema growth must not count as retrieval-index growth"
        );
    }

    #[test]
    fn best_threshold_finds_a_clean_split() {
        let mk = |c: f32, a: bool| AbstentionSample {
            top_cosine: c,
            answerable: a,
        };
        // Perfectly separable: answerable all above 0.62, junk all below.
        let samples = vec![
            mk(0.70, true),
            mk(0.68, true),
            mk(0.65, true),
            mk(0.63, true),
            mk(0.60, false),
            mk(0.55, false),
            mk(0.52, false),
            mk(0.50, false),
        ];
        let t = best_threshold(&samples).expect("a threshold exists");
        assert!(
            (0.60..0.63).contains(&t.threshold),
            "the split should land in the gap, got {}",
            t.threshold
        );
        assert!(
            (t.answerable_kept - 1.0).abs() < 1e-9,
            "keeps every real answer"
        );
        assert!(t.unanswerable_kept.abs() < 1e-9, "drops every junk answer");
        assert!((t.youden_j - 1.0).abs() < 1e-9, "perfect separation is J=1");
    }

    #[test]
    fn best_threshold_reports_weak_separation_honestly() {
        let mk = |c: f32, a: bool| AbstentionSample {
            top_cosine: c,
            answerable: a,
        };
        // Fully interleaved: no threshold can do better than chance-ish.
        let samples = vec![
            mk(0.60, true),
            mk(0.59, false),
            mk(0.58, true),
            mk(0.57, false),
            mk(0.56, true),
            mk(0.55, false),
            mk(0.54, true),
            mk(0.53, false),
        ];
        let t = best_threshold(&samples).expect("a threshold exists");
        assert!(
            t.youden_j < 0.5,
            "interleaved data must not report a usable split, got J={}",
            t.youden_j
        );
    }

    #[test]
    fn best_threshold_handles_no_samples() {
        assert!(best_threshold(&[]).is_none());
    }

    #[test]
    fn parses_a_dataset_timestamp() {
        // 2023-05-20 02:21 UTC = 1684549260
        assert_eq!(
            parse_dataset_ts("2023/05/20 (Sat) 02:21").unwrap(),
            1_684_549_260_000_000
        );
    }

    #[test]
    fn parses_the_epoch_and_a_leap_day() {
        assert_eq!(parse_dataset_ts("1970/01/01 (Thu) 00:00").unwrap(), 0);
        // 2024-02-29 exists; 2023-02-29 does not, but the dataset never
        // contains it and rejecting real dates would be worse than
        // accepting an impossible one here.
        assert_eq!(
            parse_dataset_ts("2024/02/29 (Thu) 12:00").unwrap(),
            1_709_208_000_000_000
        );
    }

    #[test]
    fn rejects_rather_than_guesses() {
        for bad in [
            "2023/13/01 (Sat) 02:21", // month 13
            "2023/05/32 (Sat) 02:21", // day 32
            "2023/05/20 (Sat) 25:00", // hour 25
            "2023/05/20 (Sat) 02:61", // minute 61
            "not a date",
            "2023/05/20",
        ] {
            assert!(
                parse_dataset_ts(bad).is_err(),
                "{bad:?} should not parse, a wrong timestamp corrupts the recency term silently"
            );
        }
    }

    #[test]
    fn derived_regression_thresholds_accept_their_source_summary() {
        let ks = [1, 3, 5, 10];
        let summary = Summary {
            arm: "hybrid".into(),
            instances: 24,
            hit_rate_at: ks
                .into_iter()
                .zip([Some(0.95), Some(1.0), Some(1.0), Some(1.0)])
                .collect(),
            recall_at: ks
                .into_iter()
                .zip([Some(0.88), Some(1.0), Some(1.0), Some(1.0)])
                .collect(),
            provenance_coverage_at: ks
                .into_iter()
                .zip([Some(0.95), Some(1.0), Some(1.0), Some(1.0)])
                .collect(),
            false_positive_rate_at: ks
                .into_iter()
                .zip([Some(1.0), Some(1.0), Some(1.0), Some(1.0)])
                .collect(),
            abstention_separation_at: ks
                .into_iter()
                .zip([Some(-0.05), Some(0.0), Some(0.0), Some(0.0)])
                .collect(),
            mrr: Some(0.97),
            complete_misses: 0,
            outcomes: OutcomeCounts::default(),
            answerable_instances: 21,
            unanswerable_instances: 3,
            latency_ms: DistributionStats {
                p95: 50.0,
                ..DistributionStats::default()
            },
            index_size_bytes: DistributionStats {
                p95: 256_000.0,
                ..DistributionStats::default()
            },
        };

        let thresholds = derive_regression_thresholds(&summary);
        for k in ks {
            assert!(
                map_value(&summary.hit_rate_at, k) >= thresholds.hit_min(k),
                "hit@{k} must accept its source metric"
            );
            assert!(
                map_value(&summary.recall_at, k) >= thresholds.recall_min(k),
                "recall@{k} must accept its source metric"
            );
            assert!(
                map_value(&summary.provenance_coverage_at, k) >= thresholds.provenance_min(k),
                "provenance@{k} must accept its source metric"
            );
            assert!(
                map_value(&summary.false_positive_rate_at, k) <= thresholds.false_positive_max(k),
                "false-positive@{k} must accept its source metric"
            );
            assert!(
                map_value(&summary.abstention_separation_at, k) >= thresholds.separation_min(k),
                "separation@{k} must accept its source metric"
            );
        }
        assert!(summary.mrr >= thresholds.mrr_min);
        assert!(
            Some(summary.latency_ms.p95) <= thresholds.latency_p95_ms_max,
            "latency threshold must accept its source metric"
        );
        assert!(
            Some(summary.index_size_bytes.p95) <= thresholds.index_size_p95_bytes_max,
            "index-size threshold must accept its source metric"
        );
    }

    #[test]
    fn summary_scores_a_known_ranking() {
        let mk = |rank: Option<usize>, rec: f64| InstanceResult {
            arm: "hybrid".into(),
            question_id: "q".into(),
            question_type: "t".into(),
            tags: Vec::new(),
            unanswerable: false,
            outcome: if rank.is_some() {
                Outcome::Matched
            } else {
                Outcome::Missed
            },
            retrieval_disposition: RetrievalDisposition::Matched,
            first_hit_rank: rank,
            recall_at: [(5usize, Some(rec))].into_iter().collect(),
            provenance_coverage_at: [(5usize, Some(rank.is_some()))].into_iter().collect(),
            answer_sessions: 2,
            sessions_in_haystack: 50,
            events_indexed: 100,
            top_hits: Vec::new(),
            latency_ms: 12.0,
            index_size_bytes: 4096,
        };
        // ranks 1 and 3 -> MRR = (1.0 + 0.3333)/3, one complete miss.
        let s = summarize(
            &[mk(Some(1), 1.0), mk(Some(3), 0.5), mk(None, 0.0)],
            Arm::Hybrid,
            &[5],
        );
        assert_eq!(s.instances, 3);
        assert_eq!(s.complete_misses, 1);
        assert!((s.hit_rate_at[&5].expect("hit denominator") - 2.0 / 3.0).abs() < 1e-9);
        assert!((s.recall_at[&5].expect("recall denominator") - 0.5).abs() < 1e-9);
        assert!((s.mrr.expect("mrr denominator") - (1.0 + 1.0 / 3.0) / 3.0).abs() < 1e-9);
    }

    #[test]
    fn hit_rate_respects_the_k_cutoff() {
        let r = InstanceResult {
            arm: "hybrid".into(),
            question_id: "q".into(),
            question_type: "t".into(),
            tags: Vec::new(),
            unanswerable: false,
            outcome: Outcome::Matched,
            retrieval_disposition: RetrievalDisposition::Matched,
            first_hit_rank: Some(7),
            recall_at: BTreeMap::new(),
            provenance_coverage_at: BTreeMap::new(),
            answer_sessions: 1,
            sessions_in_haystack: 50,
            events_indexed: 10,
            top_hits: Vec::new(),
            latency_ms: 8.0,
            index_size_bytes: 2048,
        };
        let s = summarize(std::slice::from_ref(&r), Arm::Hybrid, &[1, 5, 10]);
        assert!(
            (s.hit_rate_at[&1].expect("hit denominator") - 0.0).abs() < 1e-9,
            "rank 7 is not in top 1"
        );
        assert!(
            (s.hit_rate_at[&5].expect("hit denominator") - 0.0).abs() < 1e-9,
            "rank 7 is not in top 5"
        );
        assert!(
            (s.hit_rate_at[&10].expect("hit denominator") - 1.0).abs() < 1e-9,
            "rank 7 is in top 10"
        );
    }

    #[test]
    fn summary_tracks_false_positives_and_abstention_separation() {
        let matched = InstanceResult {
            arm: "lexical".into(),
            question_id: "a".into(),
            question_type: "exact".into(),
            tags: vec!["temporal".into()],
            unanswerable: false,
            outcome: Outcome::Matched,
            retrieval_disposition: RetrievalDisposition::Matched,
            first_hit_rank: Some(1),
            recall_at: [(1usize, Some(1.0))].into_iter().collect(),
            provenance_coverage_at: [(1usize, Some(true))].into_iter().collect(),
            answer_sessions: 1,
            sessions_in_haystack: 2,
            events_indexed: 2,
            top_hits: vec![RankedHit {
                rank: 1,
                event_id: 1,
                session_id: "s1".into(),
                app_bundle_id: Some("github".into()),
                window_title: Some("PR".into()),
                url: Some("github://1".into()),
                relevant: true,
                score: 1.0,
                excerpt: "hit".into(),
            }],
            latency_ms: 5.0,
            index_size_bytes: 1024,
        };
        let abstained = InstanceResult {
            arm: "lexical".into(),
            question_id: "b".into(),
            question_type: "unanswerable".into(),
            tags: vec!["contradiction".into()],
            unanswerable: true,
            outcome: Outcome::Abstained,
            retrieval_disposition: RetrievalDisposition::NothingMatchedEvidenceFloor,
            first_hit_rank: None,
            recall_at: [(1usize, None)].into_iter().collect(),
            provenance_coverage_at: [(1usize, None)].into_iter().collect(),
            answer_sessions: 0,
            sessions_in_haystack: 1,
            events_indexed: 1,
            top_hits: Vec::new(),
            latency_ms: 7.0,
            index_size_bytes: 2048,
        };
        let s = summarize(&[matched, abstained], Arm::Lexical, &[1]);
        assert!((s.provenance_coverage_at[&1].expect("provenance denominator") - 1.0).abs() < 1e-9);
        assert!(
            s.false_positive_rate_at[&1]
                .expect("false-positive denominator")
                .abs()
                < 1e-9
        );
        assert!(
            (s.abstention_separation_at[&1].expect("separation denominators") - 1.0).abs() < 1e-9
        );
        assert_eq!(s.outcomes.matched, 1);
        assert_eq!(s.outcomes.abstained, 1);
    }
}
