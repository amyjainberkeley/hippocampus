//! `HybridRetriever` — the Phase 3 production [`Retriever`] impl.
//!
//! Implements ADR-0010 §3 + §6 and ADR-0016 §1.5 in full:
//!
//! - **Query router** picks one of three retrieval shapes from the
//!   natural-language query:
//!   - [`RetrievalShape::AnchorThenWindow`] for "right before X" / "just
//!     before X" / "right after X" / "just after X" — locate the anchor
//!     event by top-1 semantic, then re-rank inside a `±5 min` time
//!     window around its `ts_us`.
//!   - [`RetrievalShape::TimeRangeExtraction`] for natural-language
//!     temporal queries ("last Tuesday afternoon", "yesterday",
//!     "this morning") — pre-filter events to the extracted range,
//!     then run plain recall inside it.
//!   - [`RetrievalShape::Plain`] for everything else.
//! - **Lexical:** [`BrainStore::fts5_search`] over the candidate pool
//!   (default `k_lex = 200`).
//! - **Semantic:** query embedded with the query-side prefix per
//!   ADR-0011 §3, then [`BrainStore::vec_search`] over the candidate
//!   pool (default `k_sem = 200`).
//! - **Rank-aware normalization** maps lexical and semantic positions to
//!   reciprocal ranks. Tied raw scores share a rank, and raw cosine remains
//!   available separately to the evidence critic.
//! - **Fuse** per ADR-0010 §5 + the Phase-6-close recall-surface fusion:
//!   `score = w_sem * rr_sem + w_lex * rr_lex + w_rec * decay + w_entity * ent_hat + w_src * src`
//!   with default weights
//!   [`FusionWeights::default`] = `0.40 / 0.30 / 0.10 / 0.15 / 0.05`.
//!   `ent̂` is the query-aware deterministic entity-match signal (see
//!   [`HybridRetriever::derive_query_entity_ids`]): the query is run
//!   through the Tier-1 regex extractor + an exact alias lookup, the
//!   matched entities are expanded across their canonical identities, and
//!   each candidate event is scored by how many of those entities it
//!   mentions (normalized to `[0, 1]` across the pool). Entity-free
//!   queries leave the arm at `0` for every candidate — a pure read-only
//!   no-op vs. the four-arm fusion.
//! - **App / time pre-filter** drops candidate hits whose `app_bundle_id`
//!   or `ts_us` does not match the [`RetrievalQuery::app_filter`] /
//!   [`RetrievalQuery::time_filter`] (the OS-free analog of the SQL
//!   `WHERE` pre-filter the production `SqlCipherBrainStore` will
//!   eventually push into the store layer).
//!
//! # Recency decay — ADR-0010 §5 exponential arm
//!
//! The recency term uses a configurable exponential decay:
//!
//! ```text
//! recency(e) = exp(−λ · Δt_h)
//! λ          = ln(2) / half_life_hours
//! ```
//!
//! Default [`RecencyConfig::half_life_hours`] = [`DEFAULT_HALF_LIFE_HOURS`]
//! (24.0) so an event's recency score drops to 0.5 at 24 hours, ~0.25 at
//! 48 hours, and ~0.125 at 72 hours. The score stays bounded in `[0, 1]`
//! by construction (`exp(−x)` for `x ≥ 0`).
//!
//! The prior `0.99^Δt_h` formula (half-life ≈ 69 hours) decayed too slowly
//! for a lifelog where "what I saw this morning" should rank materially
//! higher than "what I saw 3 days ago." The configurable half-life lets
//! the eval gate at P3.7 close (ADR-0010 §7) tune the decay curve without
//! a code change.
//!
//! # OS-purity (ADR-0003 / `AGENT_PROTOCOL` §4)
//!
//! Pure Rust above the [`BrainStore`] + [`Embedder`] traits — no
//! `cfg(target_os = ...)`, no FFI, no OS-specific deps. Composes with any
//! `BrainStore` + `Embedder` impl (production `SqlCipherBrainStore` +
//! `ArcticEmbedSEmbedder`; or `InMemoryBrainStore` + `FixedDimEmbedder`
//! in headless tests). The Phase-6-close entity-match arm uses the
//! pure-Rust [`Tier1Extractor`] (regex bank, no OS deps) plus the
//! existing `BrainStore` entity reads — it adds no OS surface, and on a
//! backend without graph tables every entity read degrades to "no
//! signal" (the arm goes to `0`) rather than erroring recall.
//!
//! # Privacy invariants (ADR-0016 §4)
//!
//! No protected-set surface in this module — embeddings of suppressed
//! events never reach this code path because the IPC enum-dispatch from
//! P3.6 prevents `PrivacyTombstone` reaching the brain ingestor, and the
//! brain only stores `OCREvent`-derived rows. The retriever reads what
//! `BrainStore` exposes; it cannot widen the store's row-set.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use crate::extraction::tier1::{Tier1Extractor, KIND_REDACTED_TOKEN};
use crate::extraction::tier2::{KIND_LOCATION, KIND_ORGANIZATION, KIND_PERSON_NAME};
use crate::{
    evidence_features_for_candidates, explicit_evidence_signal, BrainStore, Embedder, EntityId,
    EventId, EvidenceCandidate, EvidenceExcerpt, EvidenceSufficiencyPolicy, EvidenceVerdict,
    EvidenceVerifier, ExplicitEvidenceSignal, RetrievalHit, RetrievalQuery, RetrieveError,
    Retriever, TimeRange,
};

// ---------------------------------------------------------------------------
// Tunables — default fusion weights + candidate-pool sizes
// ---------------------------------------------------------------------------

/// Default lexical candidate-pool size (`k_lex` in ADR-0010 §5 / ADR-0016
/// §1.5). 200 hits before fusion gives enough headroom for rank-aware
/// fusion on a corpus of any size while staying
/// well inside the brute-force regime for `vec_search` at `<10⁶` events
/// (ADR-0011 §5 scaling ladder).
pub const DEFAULT_K_LEX: usize = 200;

/// Default semantic candidate-pool size (`k_sem` in ADR-0010 §5 / ADR-0016
/// §1.5). Symmetric with [`DEFAULT_K_LEX`].
pub const DEFAULT_K_SEM: usize = 200;

/// Maximum number of ranked events presented to the semantic verifier.
///
/// This is intentionally independent of [`RetrievalQuery::limit`], which is
/// a display/output preference. Verification may need a small evidence set to
/// resolve multi-event support or contradiction even when a caller only wants
/// one visible result.
pub const DEFAULT_VERIFICATION_CANDIDATE_LIMIT: usize = 8;

/// Anchor-then-window half-width, microseconds. ADR-0010 §6 specifies
/// `±5 min` around the anchor's `ts_us`; this constant is that bound.
pub const ANCHOR_WINDOW_US: u64 = 5 * 60 * 1_000_000;

/// Default recency half-life in hours. An event 24 hours old scores 0.5
/// on the recency arm; 48 hours → ~0.25; 72 hours → ~0.125. Tunable via
/// [`RecencyConfig`] and the eval gate at P3.7 close (ADR-0010 §7).
pub const DEFAULT_HALF_LIFE_HOURS: f32 = 24.0;

/// Capture fidelity used as an additive ranking prior.
///
/// The ordering reflects how directly the stored bytes represent the source:
/// an explicit user assertion, typed structured-app record, local artifact,
/// browser page text, accessibility text, then OCR. It affects ordering only;
/// source quality cannot turn unsupported evidence into a match.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum SourceQuality {
    /// User-authored correction or annotation.
    UserAuthored,
    /// Typed record from GitHub, Linear, Slack, mail, or similar application.
    StructuredApp,
    /// Local file or terminal transcript.
    LocalArtifact,
    /// Browser page text with an attributable URL.
    BrowserPage,
    /// Accessibility-tree text with application attribution.
    Accessibility,
    /// OCR-only text without a stronger source identity.
    Ocr,
}

impl SourceQuality {
    /// Stable ranking score. These values are not confidence probabilities.
    #[must_use]
    pub const fn score(self) -> f32 {
        match self {
            Self::UserAuthored => 1.00,
            Self::StructuredApp => 0.95,
            Self::LocalArtifact => 0.88,
            Self::BrowserPage => 0.80,
            Self::Accessibility => 0.68,
            Self::Ocr => 0.52,
        }
    }
}

/// Extant canonical-event evidence attached to one retrieval match.
#[derive(Debug, Clone, PartialEq)]
pub struct RetrievalEvidence {
    /// Event that supports the match.
    pub event_id: EventId,
    /// Best available stable locator.
    pub source_locator: Option<String>,
    /// Capture-fidelity class used by ranking.
    pub source_quality: SourceQuality,
}

/// Cross-query-comparable signals used to decide whether evidence exists.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RetrievalSignals {
    /// Raw semantic cosine before any query-local normalization.
    pub raw_semantic_cosine: Option<f32>,
    /// Fraction of information-bearing query terms present in the event.
    pub query_coverage: f32,
    /// Fraction of information-bearing document terms present in the query.
    pub document_coverage: f32,
    /// Raw top-1 minus top-2 semantic margin for this query.
    pub semantic_margin: f32,
    /// Whether lexical and semantic retrieval selected the same event.
    pub lexical_semantic_agreement: bool,
}

/// One ranked hit with its evidence and abstention signals.
#[derive(Debug, Clone, PartialEq)]
pub struct RetrievalMatch {
    /// Ranked retrieval hit.
    pub hit: RetrievalHit,
    /// Canonical event evidence.
    pub evidence: RetrievalEvidence,
    /// Raw/calibrated match-decision signals.
    pub signals: RetrievalSignals,
}

/// Why retrieval intentionally returned no evidence.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NothingMatchedReason {
    /// No candidate events were available in scope.
    NoCandidates,
    /// Candidates existed, but none passed the evidence floor.
    EvidenceFloor,
    /// Caller requested zero results.
    ZeroLimit,
}

/// Named capability missing from a degraded retrieval.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RetrievalDegradation {
    /// Query embedding or vector search was unavailable.
    EmbeddingsUnavailable,
    /// Lexical search was unavailable.
    LexicalUnavailable,
    /// Neither lexical nor semantic retrieval was available.
    LexicalAndEmbeddingsUnavailable,
    /// The independently calibrated evidence-sufficiency critic did not
    /// qualify, so ranking is available but answerability is not.
    EvidenceSufficiencyUnqualified,
    /// A configured semantic verifier failed or returned malformed source
    /// attribution, so ranked context remains explicitly untrusted.
    EvidenceVerifierUnavailable,
}

/// Typed production retrieval result.
#[derive(Debug, Clone, PartialEq)]
pub enum RetrievalOutcome {
    /// Evidence passed the explicit relevance floor.
    Matched {
        /// Ranked, evidence-backed matches.
        matches: Vec<RetrievalMatch>,
    },
    /// Retrieved evidence directly contradicts an asserted query.
    Contradicted {
        /// Ranked events cited by the verifier as contradictory evidence.
        matches: Vec<RetrievalMatch>,
    },
    /// Retrieval completed normally and found no support.
    NothingMatched {
        /// Inspectable abstention reason.
        reason: NothingMatchedReason,
    },
    /// One retrieval capability was unavailable; fallback evidence is not
    /// relabeled as a full match.
    Degraded {
        /// Missing capability.
        degradation: RetrievalDegradation,
        /// Inspectable fallback ranking.
        fallback_matches: Vec<RetrievalMatch>,
    },
}

/// Run lexical-only retrieval through the same typed production boundary as
/// hybrid retrieval.
pub fn lexical_retrieval_outcome<S: BrainStore>(
    store: &S,
    query: &RetrievalQuery,
) -> Result<RetrievalOutcome, RetrieveError> {
    if query.text.trim().is_empty() {
        return Err(RetrieveError::InvalidInput("empty query text".into()));
    }
    if query.limit == 0 {
        return Ok(RetrievalOutcome::NothingMatched {
            reason: NothingMatchedReason::ZeroLimit,
        });
    }
    let Ok(raw) = store.fts5_search(&query.text, query.limit) else {
        return Ok(RetrievalOutcome::Degraded {
            degradation: RetrievalDegradation::LexicalUnavailable,
            fallback_matches: Vec::new(),
        });
    };
    let ranked = ranked_map(raw);
    let mut candidates: Vec<(EventId, (f32, usize))> = ranked.into_iter().collect();
    candidates.sort_by(|a, b| a.1 .1.cmp(&b.1 .1).then_with(|| a.0.cmp(&b.0)));
    let mut matches = Vec::new();
    for (id, (_, rank)) in candidates {
        let Some(event) = store
            .get_event(id)
            .map_err(|error| RetrieveError::Backend(error.to_string()))?
        else {
            continue;
        };
        if query
            .time_filter
            .is_some_and(|range| event.ts_us < range.from_us || event.ts_us > range.to_us)
            || query
                .app_filter
                .as_deref()
                .is_some_and(|app| event.app_bundle_id.as_deref() != Some(app))
        {
            continue;
        }
        let signals = RetrievalSignals {
            raw_semantic_cosine: None,
            query_coverage: lexical_coverage(&query.text, &event.text),
            document_coverage: lexical_coverage(&event.text, &query.text),
            semantic_margin: 0.0,
            lexical_semantic_agreement: true,
        };
        let quality = classify_source_quality(&event);
        let rank_value = rank_score(Some(rank));
        matches.push(RetrievalMatch {
            hit: RetrievalHit {
                event_id: id,
                score_lexical: rank_value,
                score_semantic: 0.0,
                score_recency: 0.0,
                score_source: quality.score(),
                score_combined: rank_value,
            },
            evidence: RetrievalEvidence {
                event_id: id,
                source_locator: event.url.clone(),
                source_quality: quality,
            },
            signals,
        });
    }
    if matches.is_empty() {
        Ok(RetrievalOutcome::NothingMatched {
            reason: NothingMatchedReason::EvidenceFloor,
        })
    } else {
        Ok(RetrievalOutcome::Matched { matches })
    }
}

// ---------------------------------------------------------------------------
// FusionWeights — defaults per ADR-0010 §5
// ---------------------------------------------------------------------------

/// Convex-combination weights for rank-aware fusion (ADR-0010 §5 +
/// the Phase-6-close recall-surface fusion).
///
/// Weights are convex (each in `[0, 1]`) but the impl does not enforce
/// `w_sem + w_lex + w_rec + w_entity + w_src == 1.0` — the fusion is
/// monotone in each term regardless, and the eval gate at P3.7 close
/// (ADR-0010 §7) established the existing defaults
/// `0.40 / 0.30 / 0.10 / 0.15 / 0.05` rebalance the ADR-0010 §5 starting
/// set (`0.5 / 0.3 / 0.15 / — / 0.05`) to fund the new `w_entity` arm:
/// `0.10` of the budget comes from `w_sem` (semantic stays the lead arm)
/// and `0.05` from `w_rec` (the query-aware entity match already
/// concentrates on the events a recency-seeking query is reaching for, so
/// a slightly lighter standalone recency weight avoids double-counting).
/// `w_lex` / `w_src` retain their established values.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FusionWeights {
    /// Weight on reciprocal semantic rank.
    pub w_sem: f32,
    /// Weight on reciprocal BM25 / FTS5 rank.
    pub w_lex: f32,
    /// Weight on the recency-decay term `exp(−λ · Δt_hours)`.
    pub w_rec: f32,
    /// Weight on the query-aware deterministic entity-match term `ent̂` ∈
    /// `[0, 1]` (Phase-6-close recall-surface fusion). `0` for every
    /// candidate when the query references no known entity, so the arm is
    /// inert on entity-free queries.
    pub w_entity: f32,
    /// Weight on the documented source-quality prior.
    pub w_src: f32,
}

impl Default for FusionWeights {
    fn default() -> Self {
        Self {
            w_sem: 0.40,
            w_lex: 0.30,
            w_rec: 0.10,
            w_entity: 0.15,
            w_src: 0.05,
        }
    }
}

// ---------------------------------------------------------------------------
// RecencyConfig — exponential decay tuning
// ---------------------------------------------------------------------------

/// Configures the exponential decay for the recency arm of the
/// rank-aware fusion (ADR-0010 §5).
///
/// `recency(e) = exp(−λ · Δt_h)` where `λ = ln(2) / half_life_hours`.
/// The default [`DEFAULT_HALF_LIFE_HOURS`] = 24.0 gives a score of 0.5
/// at one day and ~0.0625 at four days.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecencyConfig {
    /// Hours until recency score drops to 0.5. Must be positive.
    pub half_life_hours: f32,
}

impl Default for RecencyConfig {
    fn default() -> Self {
        Self {
            half_life_hours: DEFAULT_HALF_LIFE_HOURS,
        }
    }
}

// ---------------------------------------------------------------------------
// RetrievalShape — the query router's three sub-paths
// ---------------------------------------------------------------------------

/// The retrieval sub-path the query router selected. Returned by
/// [`HybridRetriever::route`] and consumed by
/// [`HybridRetriever::retrieve`].
///
/// Per ADR-0010 §6 / ADR-0016 §1.5 the router picks one of:
///
/// - [`RetrievalShape::Plain`] — semantic + lexical hybrid over the
///   full corpus (modulo any caller-supplied
///   [`RetrievalQuery::app_filter`] / [`RetrievalQuery::time_filter`]).
/// - [`RetrievalShape::AnchorThenWindow`] — locate an anchor event by
///   top-1 semantic, then re-rank within a `±5 min` window around its
///   `ts_us`.
/// - [`RetrievalShape::TimeRangeExtraction`] — pre-filter events to the
///   extracted [`TimeRange`], then run plain hybrid inside it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum RetrievalShape {
    /// Plain hybrid recall over the full corpus.
    Plain,
    /// Anchor-then-window: top-1 semantic anchor, then `±5 min`
    /// re-rank.
    AnchorThenWindow,
    /// Natural-language time-range was extracted from the query;
    /// run plain hybrid inside the range.
    TimeRangeExtraction(TimeRange),
}

// ---------------------------------------------------------------------------
// HybridRetriever — the production composition
// ---------------------------------------------------------------------------

/// Phase 3 production [`Retriever`] composed of a [`BrainStore`] + an
/// [`Embedder`] (typically `SqlCipherBrainStore` + `ArcticEmbedSEmbedder`
/// in the daemon; `InMemoryBrainStore` + `FixedDimEmbedder` in headless
/// tests).
///
/// Held by `Arc` so the agent shell can share a single retriever across
/// the agent-API loopback (P3.10) and the recall UI (P3.9) without
/// re-instantiating embedder runtime / store handles.
pub struct HybridRetriever<S: BrainStore, E: Embedder> {
    store: Arc<S>,
    embedder: Arc<E>,
    weights: FusionWeights,
    recency: RecencyConfig,
    /// Microseconds since UNIX epoch — held on the retriever so tests
    /// pin recency-decay computations to a deterministic instant. The
    /// production agent shell refreshes this on each request from
    /// `SystemTime::now()`.
    now_us: u64,
    /// Lexical candidate-pool size (`k_lex`).
    k_lex: usize,
    /// Semantic candidate-pool size (`k_sem`).
    k_sem: usize,
    /// Ranked evidence-set size presented to the semantic verifier before the
    /// caller's display limit is applied.
    verification_candidate_limit: usize,
    /// Legacy score critic retained only for test/stub ranking mechanics.
    /// Production construction leaves this absent.
    evidence_policy: Option<EvidenceSufficiencyPolicy>,
    /// Optional local semantic verifier. When present, this source-attributed
    /// judgment replaces the legacy score-only critic.
    evidence_verifier: Option<Arc<dyn EvidenceVerifier>>,
}

enum CandidateArms {
    Ready {
        lexical: HashMap<EventId, (f32, usize)>,
        semantic: HashMap<EventId, (f32, usize)>,
    },
    Degraded(RetrievalOutcome),
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum EvidenceAssessment {
    Supported(Vec<u64>),
    Contradicted(Vec<u64>),
    Unsupported,
    Unqualified,
    VerifierUnavailable,
}

impl<S: BrainStore, E: Embedder> HybridRetriever<S, E> {
    /// Construct a retriever with the [`FusionWeights::default`] weights
    /// (ADR-0010 §5 starting set), [`RecencyConfig::default`] (24h
    /// half-life), and the [`DEFAULT_K_LEX`] / [`DEFAULT_K_SEM`]
    /// candidate pools.
    pub fn new(store: Arc<S>, embedder: Arc<E>, now_us: u64) -> Self {
        Self {
            store,
            embedder,
            weights: FusionWeights::default(),
            recency: RecencyConfig::default(),
            now_us,
            k_lex: DEFAULT_K_LEX,
            k_sem: DEFAULT_K_SEM,
            verification_candidate_limit: DEFAULT_VERIFICATION_CANDIDATE_LIMIT,
            evidence_policy: None,
            evidence_verifier: None,
        }
    }

    /// Override the fusion weights. Production changes require an independent
    /// calibration and regression review.
    #[must_use]
    pub fn with_weights(mut self, weights: FusionWeights) -> Self {
        self.weights = weights;
        self
    }

    /// Override the recency decay curve. Production changes require an
    /// independent calibration and regression review.
    #[must_use]
    pub fn with_recency(mut self, config: RecencyConfig) -> Self {
        self.recency = config;
        self
    }

    /// Override the candidate-pool sizes. Production keeps the
    /// `DEFAULT_K_LEX` / `DEFAULT_K_SEM` defaults; tests use smaller
    /// pools to keep fixtures dense.
    #[must_use]
    pub fn with_pools(mut self, k_lex: usize, k_sem: usize) -> Self {
        self.k_lex = k_lex;
        self.k_sem = k_sem;
        self
    }

    /// Override the bounded evidence-set size presented to the verifier.
    /// A zero value is clamped to one so a configured verifier is never called
    /// with an empty set after retrieval found candidates.
    #[must_use]
    pub fn with_verification_candidate_limit(mut self, limit: usize) -> Self {
        self.verification_candidate_limit = limit.max(1);
        self
    }

    /// Override the evidence critic in tests that exercise ranking mechanics.
    /// Production callers always use the independently frozen default.
    #[cfg(any(test, feature = "stubs"))]
    #[must_use]
    pub fn with_evidence_policy(mut self, policy: EvidenceSufficiencyPolicy) -> Self {
        self.evidence_policy = Some(policy);
        self
    }

    /// Attach a local semantic evidence verifier.
    ///
    /// Verifier output is checked for confidence bounds and source provenance
    /// before it can promote retrieval output to [`RetrievalOutcome::Matched`].
    #[must_use]
    pub fn with_evidence_verifier(mut self, verifier: Arc<dyn EvidenceVerifier>) -> Self {
        self.evidence_verifier = Some(verifier);
        self
    }

    /// The currently-configured fusion weights.
    #[must_use]
    pub fn weights(&self) -> FusionWeights {
        self.weights
    }

    /// The currently-configured recency decay.
    #[must_use]
    pub fn recency_config(&self) -> RecencyConfig {
        self.recency
    }

    /// Classify a [`RetrievalQuery`] into one of the three
    /// [`RetrievalShape`] sub-paths per ADR-0010 §6 / ADR-0016 §1.5.
    ///
    /// Decision order:
    ///
    /// 1. Anchor-then-window patterns (`"right before"`, `"just before"`,
    ///    `"right after"`, `"just after"`) — take precedence so the
    ///    anchor structure is preserved even when the query also
    ///    mentions a date.
    /// 2. Time-range patterns (`"yesterday"`, `"this morning"`,
    ///    `"last <weekday>"`, etc.) — extract a [`TimeRange`] anchored
    ///    on [`HybridRetriever::now_us`]. If the parser cannot resolve
    ///    a range, falls back to [`RetrievalShape::Plain`].
    /// 3. Otherwise [`RetrievalShape::Plain`].
    ///
    /// Lower-cased substring matching keeps the dependency footprint
    /// to zero — neither `regex` nor `chrono` are on the workspace
    /// lockfile (ADR-0008 §1 dependency-addition gate). A follow-on
    /// PR may swap in a proper grammar; the trait shape and the
    /// router's place above the store stay the same.
    #[must_use]
    pub fn route(&self, query: &RetrievalQuery) -> RetrievalShape {
        let q = query.text.to_lowercase();

        if contains_any(
            &q,
            &[
                "right before ",
                "just before ",
                "right after ",
                "just after ",
            ],
        ) {
            return RetrievalShape::AnchorThenWindow;
        }

        if let Some(range) = extract_time_range(&q, self.now_us) {
            return RetrievalShape::TimeRangeExtraction(range);
        }

        RetrievalShape::Plain
    }
}

impl<S: BrainStore, E: Embedder> Retriever for HybridRetriever<S, E> {
    fn retrieve(&self, query: &RetrievalQuery) -> Result<Vec<RetrievalHit>, RetrieveError> {
        match self.retrieve_outcome(query)? {
            RetrievalOutcome::Matched { matches } => {
                Ok(matches.into_iter().map(|value| value.hit).collect())
            }
            RetrievalOutcome::Contradicted { .. } | RetrievalOutcome::NothingMatched { .. } => {
                Ok(Vec::new())
            }
            RetrievalOutcome::Degraded { degradation, .. } => Err(RetrieveError::Backend(format!(
                "retrieval degraded: {degradation:?}"
            ))),
        }
    }
}

impl<S: BrainStore, E: Embedder> HybridRetriever<S, E> {
    /// Run retrieval through the typed production outcome boundary.
    pub fn retrieve_outcome(
        &self,
        query: &RetrievalQuery,
    ) -> Result<RetrievalOutcome, RetrieveError> {
        if query.text.is_empty() {
            return Err(RetrieveError::InvalidInput("empty query text".into()));
        }
        if let Some(tr) = &query.time_filter {
            if tr.from_us > tr.to_us {
                return Err(RetrieveError::InvalidInput(
                    "inverted time_filter range".into(),
                ));
            }
        }
        if query.limit == 0 {
            return Ok(RetrievalOutcome::NothingMatched {
                reason: NothingMatchedReason::ZeroLimit,
            });
        }

        match self.route(query) {
            RetrievalShape::Plain => self.plain_retrieve_outcome(query, query.time_filter),
            RetrievalShape::AnchorThenWindow => self.anchor_then_window_outcome(query),
            RetrievalShape::TimeRangeExtraction(extracted) => {
                let effective = intersect_ranges(query.time_filter, Some(extracted));
                self.plain_retrieve_outcome(query, effective)
            }
        }
    }

    /// Plain hybrid recall with an optional pre-applied time-range filter
    /// (the router-derived range for `TimeRangeExtraction`, the
    /// caller's `query.time_filter` for `Plain`, or the anchor window
    /// for `AnchorThenWindow`).
    fn plain_retrieve_outcome(
        &self,
        query: &RetrievalQuery,
        time_filter: Option<TimeRange>,
    ) -> Result<RetrievalOutcome, RetrieveError> {
        let (lex_map, sem_map) = match self.candidate_arms(query, time_filter)? {
            CandidateArms::Ready { lexical, semantic } => (lexical, semantic),
            CandidateArms::Degraded(outcome) => return Ok(outcome),
        };

        let mut candidate_ids: HashSet<EventId> = HashSet::new();
        candidate_ids.extend(lex_map.keys().copied());
        candidate_ids.extend(sem_map.keys().copied());

        let (entity_counts, entity_max) = self.entity_match_counts(&query.text, &candidate_ids);

        let mut semantic_scores: Vec<f32> = sem_map.values().map(|value| value.0).collect();
        semantic_scores.sort_by(|left, right| right.total_cmp(left));
        let semantic_margin = semantic_scores
            .first()
            .zip(semantic_scores.get(1))
            .map_or(0.0, |(top, second)| (top - second).max(0.0));
        let mut critic_rows: Vec<(EventId, String, f32)> = Vec::new();
        let mut evidence_rows: Vec<(EventId, String)> = Vec::new();
        let mut matches: Vec<RetrievalMatch> = Vec::with_capacity(candidate_ids.len());
        for id in candidate_ids {
            let event_opt = self
                .store
                .get_event(id)
                .map_err(|e| RetrieveError::Backend(e.to_string()))?;
            let Some(event) = event_opt else { continue };

            if let Some(tr) = &time_filter {
                if event.ts_us < tr.from_us || event.ts_us > tr.to_us {
                    continue;
                }
            }
            if let Some(target) = &query.app_filter {
                if event.app_bundle_id.as_deref() != Some(target.as_str()) {
                    continue;
                }
            }

            let lex_rank = lex_map.get(&id).map(|value| value.1);
            let sem_raw = sem_map.get(&id).map(|value| value.0);
            let sem_rank = sem_map.get(&id).map(|value| value.1);
            let lex_rank_score = rank_score(lex_rank);
            let sem_rank_score = rank_score(sem_rank);
            let recency = recency_decay(self.now_us, event.ts_us, self.recency.half_life_hours);
            // Query-aware entity match, normalized across the candidate pool
            // by the pool max. A genuine zero (no matching mention) stays a
            // zero. "Mentions none of the query's entities" is a meaningful
            // absence, not missing rank information. When `entity_max == 0`
            // (entity-free query) the arm is `0` for every candidate.
            let entity_hat = if entity_max > 0 {
                #[allow(clippy::cast_precision_loss)]
                let n = entity_counts.get(&id).copied().unwrap_or(0) as f32;
                #[allow(clippy::cast_precision_loss)]
                let d = entity_max as f32;
                n / d
            } else {
                0.0
            };
            let quality = classify_source_quality(&event);
            let src = quality.score();
            let combined = self.weights.w_sem.mul_add(
                sem_rank_score,
                self.weights.w_lex.mul_add(
                    lex_rank_score,
                    self.weights.w_rec.mul_add(
                        recency,
                        self.weights
                            .w_entity
                            .mul_add(entity_hat, self.weights.w_src * src),
                    ),
                ),
            );
            let query_coverage = lexical_coverage(&query.text, &event.text);
            let document_coverage = lexical_coverage(&event.text, &query.text);
            let signals = RetrievalSignals {
                raw_semantic_cosine: sem_raw,
                query_coverage,
                document_coverage,
                semantic_margin,
                lexical_semantic_agreement: lex_rank == Some(1) && sem_rank == Some(1),
            };
            if let Some(raw_semantic_cosine) = sem_raw {
                critic_rows.push((id, event.text.clone(), raw_semantic_cosine));
            }
            evidence_rows.push((id, event.text.clone()));
            matches.push(RetrievalMatch {
                hit: RetrievalHit {
                    event_id: id,
                    score_lexical: lex_rank_score,
                    score_semantic: sem_rank_score,
                    score_recency: recency,
                    score_source: src,
                    score_combined: combined,
                },
                evidence: RetrievalEvidence {
                    event_id: id,
                    source_locator: event.url.clone(),
                    source_quality: quality,
                },
                signals,
            });
        }
        let evidence_assessment =
            self.rank_and_assess(query, &mut matches, &critic_rows, &evidence_rows);
        Ok(Self::finalize_retrieval_outcome(
            matches,
            evidence_assessment,
            lex_map.is_empty() && sem_map.is_empty(),
            query.limit,
        ))
    }

    fn entity_match_counts(
        &self,
        query_text: &str,
        candidate_ids: &HashSet<EventId>,
    ) -> (HashMap<EventId, u32>, u32) {
        let query_entity_ids = self.derive_query_entity_ids(query_text);
        let counts = if query_entity_ids.is_empty() {
            HashMap::new()
        } else {
            let query_ids = query_entity_ids.into_iter().collect::<Vec<_>>();
            let candidates = candidate_ids.iter().copied().collect::<Vec<_>>();
            self.store
                .mention_match_for_events(&query_ids, &candidates)
                .unwrap_or_default()
        };
        let maximum = counts.values().copied().max().unwrap_or(0);
        (counts, maximum)
    }

    fn rank_and_assess(
        &self,
        query: &RetrievalQuery,
        matches: &mut [RetrievalMatch],
        critic_rows: &[(EventId, String, f32)],
        evidence_rows: &[(EventId, String)],
    ) -> EvidenceAssessment {
        let candidates = critic_rows
            .iter()
            .map(|(event_id, text, raw_semantic_cosine)| EvidenceCandidate {
                stable_id: event_id.0,
                text,
                raw_semantic_cosine: *raw_semantic_cosine,
            })
            .collect::<Vec<_>>();
        matches.sort_by(|left, right| {
            right
                .hit
                .score_combined
                .total_cmp(&left.hit.score_combined)
                .then_with(|| left.hit.event_id.cmp(&right.hit.event_id))
        });

        if matches!(
            explicit_evidence_signal(&query.text, &candidates),
            ExplicitEvidenceSignal::RelationUnsupported
        ) {
            return EvidenceAssessment::Unsupported;
        }

        if let Some(verifier) = &self.evidence_verifier {
            let evidence_by_id = evidence_rows
                .iter()
                .map(|(event_id, text)| (*event_id, text.as_str()))
                .collect::<HashMap<_, _>>();
            let excerpts = matches
                .iter()
                .take(self.verification_candidate_limit)
                .filter_map(|value| {
                    evidence_by_id
                        .get(&value.hit.event_id)
                        .map(|text| EvidenceExcerpt {
                            stable_id: value.hit.event_id.0,
                            text,
                        })
                })
                .collect::<Vec<_>>();
            return match verifier.verify(&query.text, &excerpts) {
                Ok(verdict) if verdict.is_well_formed(&excerpts) => match verdict {
                    EvidenceVerdict::Supported { evidence_ids, .. } => {
                        EvidenceAssessment::Supported(evidence_ids)
                    }
                    EvidenceVerdict::Contradicted { evidence_ids, .. } => {
                        EvidenceAssessment::Contradicted(evidence_ids)
                    }
                    EvidenceVerdict::Insufficient { .. } => EvidenceAssessment::Unsupported,
                },
                Ok(_) | Err(_) => EvidenceAssessment::VerifierUnavailable,
            };
        }

        let Some(evidence_policy) = self.evidence_policy else {
            return EvidenceAssessment::VerifierUnavailable;
        };
        if !evidence_policy.validation_qualified {
            return EvidenceAssessment::Unqualified;
        }
        if evidence_features_for_candidates(&query.text, &candidates)
            .is_some_and(|features| evidence_policy.is_sufficient(features))
        {
            EvidenceAssessment::Supported(
                matches
                    .iter()
                    .take(query.limit)
                    .map(|value| value.hit.event_id.0)
                    .collect(),
            )
        } else {
            EvidenceAssessment::Unsupported
        }
    }

    fn candidate_arms(
        &self,
        query: &RetrievalQuery,
        time_filter: Option<TimeRange>,
    ) -> Result<CandidateArms, RetrieveError> {
        let lex_result = self.store.fts5_search(&query.text, self.k_lex);
        let Ok(q_emb) = self.embedder.embed_one(&query.text) else {
            return match lex_result {
                Ok(lex) => Ok(CandidateArms::Degraded(RetrievalOutcome::Degraded {
                    degradation: RetrievalDegradation::EmbeddingsUnavailable,
                    fallback_matches: self.fallback_matches(query, time_filter, lex, false)?,
                })),
                Err(_) => Ok(CandidateArms::Degraded(RetrievalOutcome::Degraded {
                    degradation: RetrievalDegradation::LexicalAndEmbeddingsUnavailable,
                    fallback_matches: Vec::new(),
                })),
            };
        };
        // ADR-0011 §5 candidate-pool pre-filter. When the query carries
        // a time / app scope (either from the router — anchor window,
        // extracted time range — or from the caller-supplied
        // `RetrievalQuery::app_filter`), push those into the store so
        // brute-force cosine walks only the in-scope vectors instead of
        // the whole `event_vectors` table. Semantic ranks are otherwise
        // unchanged: the pool narrowing is a subset of the row set the
        // full-KNN would have scored, and the retriever's row-level
        // app/time guard downstream is still authoritative. When both
        // filters are `None` the store's default impl delegates to
        // `vec_search` — byte-identical fallback (full KNN).
        let Ok(sem) = self.store.vec_search_filtered(
            &q_emb,
            self.k_sem,
            time_filter,
            query.app_filter.as_deref(),
        ) else {
            return match lex_result {
                Ok(lex) => Ok(CandidateArms::Degraded(RetrievalOutcome::Degraded {
                    degradation: RetrievalDegradation::EmbeddingsUnavailable,
                    fallback_matches: self.fallback_matches(query, time_filter, lex, false)?,
                })),
                Err(_) => Ok(CandidateArms::Degraded(RetrievalOutcome::Degraded {
                    degradation: RetrievalDegradation::LexicalAndEmbeddingsUnavailable,
                    fallback_matches: Vec::new(),
                })),
            };
        };
        let Ok(lex) = lex_result else {
            return Ok(CandidateArms::Degraded(RetrievalOutcome::Degraded {
                degradation: RetrievalDegradation::LexicalUnavailable,
                fallback_matches: self.fallback_matches(query, time_filter, sem, true)?,
            }));
        };
        Ok(CandidateArms::Ready {
            lexical: ranked_map(lex),
            semantic: ranked_map(sem),
        })
    }

    fn finalize_retrieval_outcome(
        mut matches: Vec<RetrievalMatch>,
        assessment: EvidenceAssessment,
        candidate_arms_empty: bool,
        display_limit: usize,
    ) -> RetrievalOutcome {
        if matches.is_empty() {
            return RetrievalOutcome::NothingMatched {
                reason: if candidate_arms_empty {
                    NothingMatchedReason::NoCandidates
                } else {
                    NothingMatchedReason::EvidenceFloor
                },
            };
        }
        match assessment {
            EvidenceAssessment::Supported(evidence_ids) => {
                retain_cited_matches(&mut matches, &evidence_ids);
                RetrievalOutcome::Matched { matches }
            }
            EvidenceAssessment::Contradicted(evidence_ids) => {
                retain_cited_matches(&mut matches, &evidence_ids);
                RetrievalOutcome::Contradicted { matches }
            }
            EvidenceAssessment::Unsupported => RetrievalOutcome::NothingMatched {
                reason: NothingMatchedReason::EvidenceFloor,
            },
            EvidenceAssessment::Unqualified => RetrievalOutcome::Degraded {
                degradation: RetrievalDegradation::EvidenceSufficiencyUnqualified,
                fallback_matches: {
                    matches.truncate(display_limit);
                    matches
                },
            },
            EvidenceAssessment::VerifierUnavailable => RetrievalOutcome::Degraded {
                degradation: RetrievalDegradation::EvidenceVerifierUnavailable,
                fallback_matches: {
                    matches.truncate(display_limit);
                    matches
                },
            },
        }
    }

    fn fallback_matches(
        &self,
        query: &RetrievalQuery,
        time_filter: Option<TimeRange>,
        raw: Vec<(EventId, f32)>,
        semantic: bool,
    ) -> Result<Vec<RetrievalMatch>, RetrieveError> {
        let mut out = Vec::new();
        for (index, (id, score)) in raw.into_iter().enumerate() {
            let Some(event) = self
                .store
                .get_event(id)
                .map_err(|e| RetrieveError::Backend(e.to_string()))?
            else {
                continue;
            };
            if time_filter
                .is_some_and(|range| event.ts_us < range.from_us || event.ts_us > range.to_us)
                || query
                    .app_filter
                    .as_deref()
                    .is_some_and(|app| event.app_bundle_id.as_deref() != Some(app))
            {
                continue;
            }
            let rank = Some(index + 1);
            let rank_value = rank_score(rank);
            let quality = classify_source_quality(&event);
            out.push(RetrievalMatch {
                hit: RetrievalHit {
                    event_id: id,
                    score_lexical: if semantic { 0.0 } else { rank_value },
                    score_semantic: if semantic { rank_value } else { 0.0 },
                    score_recency: recency_decay(
                        self.now_us,
                        event.ts_us,
                        self.recency.half_life_hours,
                    ),
                    score_source: quality.score(),
                    score_combined: rank_value,
                },
                evidence: RetrievalEvidence {
                    event_id: id,
                    source_locator: event.url.clone(),
                    source_quality: quality,
                },
                signals: RetrievalSignals {
                    raw_semantic_cosine: semantic.then_some(score),
                    query_coverage: lexical_coverage(&query.text, &event.text),
                    document_coverage: lexical_coverage(&event.text, &query.text),
                    semantic_margin: 0.0,
                    lexical_semantic_agreement: false,
                },
            });
            if out.len() == query.limit {
                break;
            }
        }
        Ok(out)
    }

    /// Derive the set of [`EntityId`]s a query references, via the
    /// **in-fence deterministic** path only (Phase-6-close Option A — this
    /// is NOT the Qwen NER tier and NOT the `AliasResolver` worker):
    ///
    /// 1. Run the pure-Rust [`Tier1Extractor`] over the query string and
    ///    look each non-redacted match (`email` / `phone` / `url` / …) up by
    ///    its `(kind, canonical_name)` via [`BrainStore::find_entity_by_alias`].
    /// 2. Pull the query's capitalized tokens + adjacent-capitalized bigrams
    ///    (candidate person / org / location names) and look each up under
    ///    the three name kinds.
    /// 3. **Identity-expand**: for every directly-matched entity, add every
    ///    co-member of its canonical identity
    ///    ([`BrainStore::identity_of_entity`] → [`BrainStore::identity_members`]).
    ///    This is what lets a query naming "Alice" also match an event that
    ///    only mentions her `alice@corp.com` alias once the resolver has
    ///    clustered them.
    ///
    /// **Best-effort:** every store read here is one of the pre-existing
    /// V2-P3/P6 methods that default to `Err` on a graph-less backend
    /// (`InMemoryBrainStore`). Such an `Err` is swallowed (`.ok()` /
    /// `.unwrap_or_default()`) and treated as "no match" so the entity arm
    /// silently goes to `0` rather than failing recall — the read-only
    /// no-regression contract. A genuine `SqlCipher` backend error likewise
    /// only forfeits the additive boost; lexical + semantic recall still
    /// returns.
    fn derive_query_entity_ids(&self, query_text: &str) -> HashSet<EntityId> {
        // Bound the work: a pathological query cannot fan out into an
        // unbounded number of indexed lookups.
        const MAX_CANDIDATES: usize = 24;

        let mut ids: HashSet<EntityId> = HashSet::new();

        // (1) Tier-1 regex matches → exact (kind, canonical_name) lookup.
        for m in Tier1Extractor::new().extract(query_text) {
            if m.kind == KIND_REDACTED_TOKEN {
                continue; // never key recall on a redacted token
            }
            if let Some(ent) = self
                .store
                .find_entity_by_alias(&m.kind, &m.canonical_name)
                .ok()
                .flatten()
            {
                ids.insert(ent.id);
            }
        }

        // (2) Capitalized tokens + bigrams → person / org / location.
        for cand in capitalized_candidates(query_text)
            .into_iter()
            .take(MAX_CANDIDATES)
        {
            for kind in [KIND_PERSON_NAME, KIND_ORGANIZATION, KIND_LOCATION] {
                if let Some(ent) = self.store.find_entity_by_alias(kind, &cand).ok().flatten() {
                    ids.insert(ent.id);
                }
            }
        }

        // (3) Identity-expand the directly-matched entities.
        let direct: Vec<EntityId> = ids.iter().cloned().collect();
        for eid in direct {
            for membership in self.store.identity_of_entity(&eid).unwrap_or_default() {
                for member in self
                    .store
                    .identity_members(&membership.identity_id)
                    .unwrap_or_default()
                {
                    ids.insert(member.entity_id);
                }
            }
        }

        ids
    }

    /// Anchor-then-window per ADR-0010 §6: top-1 semantic locates the
    /// anchor; the anchor's `ts_us ± 5 min` becomes the time filter for
    /// a plain hybrid pass.
    ///
    /// If the semantic top-1 returns nothing (empty store) or the
    /// anchor event row is missing (rare race), falls back to plain
    /// hybrid with the caller's `time_filter` untouched.
    fn anchor_then_window_outcome(
        &self,
        query: &RetrievalQuery,
    ) -> Result<RetrievalOutcome, RetrieveError> {
        let Ok(q_emb) = self.embedder.embed_one(&query.text) else {
            return self.plain_retrieve_outcome(query, query.time_filter);
        };
        let Ok(sem_top) = self.store.vec_search(&q_emb, 1) else {
            return match self.store.fts5_search(&query.text, self.k_lex) {
                Ok(lexical) => Ok(RetrievalOutcome::Degraded {
                    degradation: RetrievalDegradation::EmbeddingsUnavailable,
                    fallback_matches: self.fallback_matches(
                        query,
                        query.time_filter,
                        lexical,
                        false,
                    )?,
                }),
                Err(_) => Ok(RetrievalOutcome::Degraded {
                    degradation: RetrievalDegradation::LexicalAndEmbeddingsUnavailable,
                    fallback_matches: Vec::new(),
                }),
            };
        };
        let Some((anchor_id, _)) = sem_top.into_iter().next() else {
            return self.plain_retrieve_outcome(query, query.time_filter);
        };
        let Some(anchor) = self
            .store
            .get_event(anchor_id)
            .map_err(|e| RetrieveError::Backend(e.to_string()))?
        else {
            return self.plain_retrieve_outcome(query, query.time_filter);
        };
        let window = TimeRange {
            from_us: anchor.ts_us.saturating_sub(ANCHOR_WINDOW_US),
            to_us: anchor.ts_us.saturating_add(ANCHOR_WINDOW_US),
        };
        let effective = intersect_ranges(query.time_filter, Some(window));
        self.plain_retrieve_outcome(query, effective)
    }
}

fn retain_cited_matches(matches: &mut Vec<RetrievalMatch>, evidence_ids: &[u64]) {
    let cited = evidence_ids.iter().copied().collect::<HashSet<_>>();
    matches.retain(|value| cited.contains(&value.hit.event_id.0));
}

// ---------------------------------------------------------------------------
// Helpers — public for unit tests, doc-link reachable
// ---------------------------------------------------------------------------

/// Min / max of an iterator of `f32`. `(0.0, 0.0)` for an empty
/// iterator — callers treat empty as "no signal" anyway.
#[must_use]
pub fn minmax(it: impl Iterator<Item = f32>) -> (f32, f32) {
    let mut mn = f32::INFINITY;
    let mut mx = f32::NEG_INFINITY;
    for v in it {
        if v < mn {
            mn = v;
        }
        if v > mx {
            mx = v;
        }
    }
    if mn.is_infinite() {
        (0.0, 0.0)
    } else {
        (mn, mx)
    }
}

/// Min-max normalize `v` into `[0, 1]`. When `max == min` (degenerate
/// pool — one hit, or all-equal), returns the midpoint `0.5` so the
/// term neither dominates nor disappears.
#[must_use]
pub fn minmax_normalize(v: f32, mn: f32, mx: f32) -> f32 {
    if mx <= mn {
        return 0.5;
    }
    ((v - mn) / (mx - mn)).clamp(0.0, 1.0)
}

fn rank_score(rank: Option<usize>) -> f32 {
    match rank {
        Some(0) | None => 0.0,
        Some(value) => {
            #[allow(clippy::cast_precision_loss)]
            let value = value as f32;
            value.recip()
        }
    }
}

fn ranked_map(values: Vec<(EventId, f32)>) -> HashMap<EventId, (f32, usize)> {
    let mut out = HashMap::with_capacity(values.len());
    let mut previous_score: Option<f32> = None;
    let mut shared_rank = 0;
    for (index, (id, score)) in values.into_iter().enumerate() {
        if previous_score.is_none_or(|previous| previous.total_cmp(&score).is_ne()) {
            shared_rank = index + 1;
            previous_score = Some(score);
        }
        out.insert(id, (score, shared_rank));
    }
    out
}

fn classify_source_quality(event: &crate::Event) -> SourceQuality {
    let locator = event.url.as_deref().unwrap_or("").to_ascii_lowercase();
    if locator.starts_with("user://") {
        SourceQuality::UserAuthored
    } else if [
        "github://",
        "linear://",
        "slack://",
        "mail://",
        "calendar://",
        "notion://",
    ]
    .iter()
    .any(|prefix| locator.starts_with(prefix))
    {
        SourceQuality::StructuredApp
    } else if locator.starts_with("file://") || locator.starts_with("terminal://") {
        SourceQuality::LocalArtifact
    } else if locator.starts_with("http://")
        || locator.starts_with("https://")
        || locator.starts_with("browser://")
    {
        SourceQuality::BrowserPage
    } else if event.app_bundle_id.is_some() || event.window_title.is_some() {
        SourceQuality::Accessibility
    } else {
        SourceQuality::Ocr
    }
}

fn lexical_coverage(query: &str, evidence: &str) -> f32 {
    let query_terms = content_terms(query);
    if query_terms.is_empty() {
        return 0.0;
    }
    let evidence_terms: HashSet<String> = content_terms(evidence).into_iter().collect();
    let covered = query_terms
        .iter()
        .filter(|term| evidence_terms.contains(*term))
        .count();
    #[allow(clippy::cast_precision_loss)]
    let ratio = covered as f32 / query_terms.len() as f32;
    ratio
}

fn content_terms(text: &str) -> Vec<String> {
    const STOP: &[&str] = &[
        "a", "an", "and", "are", "as", "at", "be", "did", "do", "for", "from", "how", "i", "in",
        "is", "it", "of", "on", "or", "the", "to", "was", "we", "what", "where", "which", "who",
        "why", "with",
    ];
    let mut out = Vec::new();
    for raw in text.split(|c: char| !c.is_alphanumeric() && c != '_' && c != '-') {
        let term = raw.trim().to_ascii_lowercase();
        if term.len() < 2 || STOP.contains(&term.as_str()) || out.contains(&term) {
            continue;
        }
        out.push(term);
    }
    out
}

/// Exponential recency decay per ADR-0010 §5:
/// `exp(−λ · Δt_h)` where `λ = ln(2) / half_life_hours`.
///
/// The event's `ts_us` may be ahead of `now_us` in tests;
/// `saturating_sub` keeps that case from underflowing and returns
/// `1.0` (max recency). A non-positive `half_life_hours` collapses
/// to a step function (1.0 at Δt=0, 0.0 otherwise).
#[must_use]
pub fn recency_decay(now_us: u64, then_us: u64, half_life_hours: f32) -> f32 {
    #[allow(clippy::cast_precision_loss)]
    let dt_us = now_us.saturating_sub(then_us) as f32;
    if dt_us == 0.0 {
        return 1.0;
    }
    if half_life_hours <= 0.0 {
        return 0.0;
    }
    let lambda = std::f32::consts::LN_2 / half_life_hours;
    let dt_h = dt_us / 3_600_000_000.0;
    (-lambda * dt_h).exp()
}

/// Intersect two optional [`TimeRange`]s. `None ∩ None = None`;
/// `Some(a) ∩ None = Some(a)`; otherwise the intersection of the
/// closed intervals. An empty intersection collapses to an inverted
/// range that the caller's filter loop will reject every event for.
fn intersect_ranges(a: Option<TimeRange>, b: Option<TimeRange>) -> Option<TimeRange> {
    match (a, b) {
        (None, None) => None,
        (Some(r), None) | (None, Some(r)) => Some(r),
        (Some(a), Some(b)) => Some(TimeRange {
            from_us: a.from_us.max(b.from_us),
            to_us: a.to_us.min(b.to_us),
        }),
    }
}

fn contains_any(haystack: &str, needles: &[&str]) -> bool {
    needles.iter().any(|n| haystack.contains(n))
}

/// Capitalized single tokens + adjacent-capitalized bigrams from a query —
/// the candidate person / org / location surface forms for the exact alias
/// lookup in [`HybridRetriever::derive_query_entity_ids`]. Punctuation is
/// stripped from token edges; the original case is preserved (the NER
/// extractor stores title-cased `canonical_name`s, and
/// [`BrainStore::find_entity_by_alias`] is an exact match). Over-generation
/// is harmless — a non-entity capitalized word (a sentence-initial "What")
/// simply finds no entity row.
fn capitalized_candidates(query: &str) -> Vec<String> {
    let tokens: Vec<&str> = query
        .split_whitespace()
        .map(|t| t.trim_matches(|c: char| !c.is_alphanumeric()))
        .filter(|t| !t.is_empty())
        .collect();

    let is_cap = |t: &str| t.chars().next().is_some_and(char::is_uppercase);

    let mut out: Vec<String> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let mut push = |s: String, out: &mut Vec<String>| {
        if seen.insert(s.clone()) {
            out.push(s);
        }
    };

    for (i, &tok) in tokens.iter().enumerate() {
        if !is_cap(tok) {
            continue;
        }
        push(tok.to_string(), &mut out);
        if let Some(&next) = tokens.get(i + 1) {
            if is_cap(next) {
                push(format!("{tok} {next}"), &mut out);
            }
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Time-range extraction — pure-Rust, dependency-free
// ---------------------------------------------------------------------------

const MICROS_PER_HOUR: u64 = 3_600_000_000;
const MICROS_PER_DAY: u64 = 24 * MICROS_PER_HOUR;

const WEEKDAYS: &[&str] = &[
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
];

/// Best-effort natural-language time-range extraction over a lower-cased
/// query string. Returns `None` when no temporal cue is recognized.
///
/// Ranges are anchored on `now_us` and are deliberately coarse — the
/// production follow-on (ADR-0016 §1.5 step (3)) is a tiny on-device
/// classifier; this regex-free pass is the binding-first-cut. Recall
/// quality on temporally-anchored queries comes mostly from the
/// pre-filter being applied at all, not from sub-hour precision.
fn extract_time_range(q: &str, now_us: u64) -> Option<TimeRange> {
    // "yesterday" → previous day (24h..48h ago).
    if q.contains("yesterday") {
        return Some(TimeRange {
            from_us: now_us.saturating_sub(2 * MICROS_PER_DAY),
            to_us: now_us.saturating_sub(MICROS_PER_DAY),
        });
    }

    // "this morning" / "this afternoon" / "this evening" — last 24h
    // window. Coarser than the named slot but deterministic without
    // chrono.
    if q.contains("this morning") || q.contains("this afternoon") || q.contains("this evening") {
        return Some(TimeRange {
            from_us: now_us.saturating_sub(MICROS_PER_DAY),
            to_us: now_us,
        });
    }

    // "last week" → previous 7-day window.
    if q.contains("last week") {
        return Some(TimeRange {
            from_us: now_us.saturating_sub(14 * MICROS_PER_DAY),
            to_us: now_us.saturating_sub(7 * MICROS_PER_DAY),
        });
    }

    // "last <weekday>" → previous 7..14 day window. Without chrono we
    // cannot place the weekday exactly; the wider window keeps recall
    // honest at the cost of precision (the eval gate at P3.7 close is
    // the canonical place to swap in a real parser).
    for w in WEEKDAYS {
        let last_pat = format!("last {w}");
        if q.contains(&last_pat) {
            return Some(TimeRange {
                from_us: now_us.saturating_sub(14 * MICROS_PER_DAY),
                to_us: now_us.saturating_sub(7 * MICROS_PER_DAY),
            });
        }
    }

    // Bare weekday → previous 7 days.
    for w in WEEKDAYS {
        if q.contains(w) {
            return Some(TimeRange {
                from_us: now_us.saturating_sub(7 * MICROS_PER_DAY),
                to_us: now_us,
            });
        }
    }

    None
}

// ---------------------------------------------------------------------------
// Narrow unit tests — helper math only. The heavy retrieval-shape tests
// live in `core/brain/tests/hybrid_retriever.rs` against the public API.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn minmax_empty_iterator_is_zero_zero() {
        let (mn, mx) = minmax(std::iter::empty());
        assert!(mn.abs() < f32::EPSILON);
        assert!(mx.abs() < f32::EPSILON);
    }

    #[test]
    fn minmax_normalize_caps_to_unit_interval() {
        assert!((minmax_normalize(5.0, 0.0, 10.0) - 0.5).abs() < 1e-6);
        assert!((minmax_normalize(-100.0, 0.0, 10.0)).abs() < 1e-6);
        assert!((minmax_normalize(100.0, 0.0, 10.0) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn minmax_normalize_degenerate_pool_returns_midpoint() {
        // Single hit / all-equal pool: rank-info is zero so the term
        // collapses to 0.5 rather than the misleading 0.0 / 1.0.
        assert!((minmax_normalize(42.0, 42.0, 42.0) - 0.5).abs() < 1e-6);
    }

    #[test]
    fn intersect_ranges_empty_inputs() {
        assert_eq!(intersect_ranges(None, None), None);
    }

    #[test]
    fn intersect_ranges_carries_the_only_set_side() {
        let r = TimeRange {
            from_us: 10,
            to_us: 20,
        };
        assert_eq!(intersect_ranges(Some(r), None), Some(r));
        assert_eq!(intersect_ranges(None, Some(r)), Some(r));
    }

    #[test]
    fn intersect_ranges_takes_overlap() {
        let a = TimeRange {
            from_us: 0,
            to_us: 100,
        };
        let b = TimeRange {
            from_us: 50,
            to_us: 150,
        };
        assert_eq!(
            intersect_ranges(Some(a), Some(b)),
            Some(TimeRange {
                from_us: 50,
                to_us: 100
            })
        );
    }

    #[test]
    fn fusion_weights_default_matches_adr_0010() {
        let w = FusionWeights::default();
        assert!((w.w_sem - 0.40).abs() < f32::EPSILON);
        assert!((w.w_lex - 0.30).abs() < f32::EPSILON);
        assert!((w.w_rec - 0.10).abs() < f32::EPSILON);
        assert!((w.w_entity - 0.15).abs() < f32::EPSILON);
        assert!((w.w_src - 0.05).abs() < f32::EPSILON);
        // Rebalanced convex set still sums to 1.0.
        let sum = w.w_sem + w.w_lex + w.w_rec + w.w_entity + w.w_src;
        assert!((sum - 1.0).abs() < 1e-6, "weights sum to {sum}, want 1.0");
    }

    #[test]
    fn recency_config_default_is_24h() {
        let c = RecencyConfig::default();
        assert!((c.half_life_hours - 24.0).abs() < f32::EPSILON);
    }

    #[test]
    fn recency_decay_at_zero_delta_is_one() {
        let now = 1_000 * MICROS_PER_HOUR;
        assert!((recency_decay(now, now, DEFAULT_HALF_LIFE_HOURS) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn recency_decay_at_half_life_is_half() {
        let now = 1_000 * MICROS_PER_HOUR;
        let then = now - 24 * MICROS_PER_HOUR;
        let r = recency_decay(now, then, DEFAULT_HALF_LIFE_HOURS);
        assert!((r - 0.5).abs() < 1e-4, "at half-life got {r}, want ~0.5");
    }

    #[test]
    fn recency_decay_future_event_saturates_to_one() {
        let now = 100 * MICROS_PER_HOUR;
        let future = now + MICROS_PER_DAY;
        assert!((recency_decay(now, future, DEFAULT_HALF_LIFE_HOURS) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn recency_decay_very_old_event_approaches_zero() {
        let now = 100_000 * MICROS_PER_HOUR;
        let ancient = 0_u64;
        let r = recency_decay(now, ancient, DEFAULT_HALF_LIFE_HOURS);
        assert!(r < 1e-10, "ancient event should be near zero, got {r}");
    }

    #[test]
    fn recency_decay_nonpositive_half_life_is_step() {
        let now = 100 * MICROS_PER_HOUR;
        assert!((recency_decay(now, now, 0.0) - 1.0).abs() < 1e-6);
        assert!(recency_decay(now, now - MICROS_PER_HOUR, 0.0).abs() < 1e-6);
        assert!((recency_decay(now, now, -5.0) - 1.0).abs() < 1e-6);
        assert!(recency_decay(now, now - 1, -5.0).abs() < 1e-6);
    }
}
