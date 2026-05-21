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
//! - **Min-max normalization** of both score lists across the
//!   response set (Bruch et al. ACM TOIS 2023, arXiv:2210.11934).
//! - **Fuse** per ADR-0010 §5:
//!   `score = w_sem · sem̂ + w_lex · lex̂ + w_rec · 0.99^Δt_h + w_src · src`
//!   with default weights [`FusionWeights::default`] =
//!   `0.5 / 0.3 / 0.15 / 0.05`.
//! - **App / time pre-filter** drops candidate hits whose `app_bundle_id`
//!   or `ts_us` does not match the [`RetrievalQuery::app_filter`] /
//!   [`RetrievalQuery::time_filter`] (the OS-free analog of the SQL
//!   `WHERE` pre-filter the production `SqlCipherBrainStore` will
//!   eventually push into the store layer).
//!
//! # OS-purity (ADR-0003 / `AGENT_PROTOCOL` §4)
//!
//! Pure Rust above the [`BrainStore`] + [`Embedder`] traits — no
//! `cfg(target_os = ...)`, no FFI, no OS-specific deps. Composes with any
//! `BrainStore` + `Embedder` impl (production `SqlCipherBrainStore` +
//! `ArcticEmbedSEmbedder`; or `InMemoryBrainStore` + `FixedDimEmbedder`
//! in headless tests).
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

use crate::{
    BrainStore, Embedder, EventId, RetrievalHit, RetrievalQuery, RetrieveError, Retriever,
    TimeRange,
};

// ---------------------------------------------------------------------------
// Tunables — default fusion weights + candidate-pool sizes
// ---------------------------------------------------------------------------

/// Default lexical candidate-pool size (`k_lex` in ADR-0010 §5 / ADR-0016
/// §1.5). 200 hits before fusion gives enough headroom for the min-max
/// normalization to be meaningful on a corpus of any size while staying
/// well inside the brute-force regime for `vec_search` at `<10⁶` events
/// (ADR-0011 §5 scaling ladder).
pub const DEFAULT_K_LEX: usize = 200;

/// Default semantic candidate-pool size (`k_sem` in ADR-0010 §5 / ADR-0016
/// §1.5). Symmetric with [`DEFAULT_K_LEX`].
pub const DEFAULT_K_SEM: usize = 200;

/// Anchor-then-window half-width, microseconds. ADR-0010 §6 specifies
/// `±5 min` around the anchor's `ts_us`; this constant is that bound.
pub const ANCHOR_WINDOW_US: u64 = 5 * 60 * 1_000_000;

// ---------------------------------------------------------------------------
// FusionWeights — defaults per ADR-0010 §5
// ---------------------------------------------------------------------------

/// Convex-combination weights for the min-max CC fusion (ADR-0010 §5).
///
/// Weights are convex (each in `[0, 1]`) but the impl does not enforce
/// `w_sem + w_lex + w_rec + w_src == 1.0` — the fusion is monotone in each
/// term regardless, and the eval gate at P3.7 close (ADR-0010 §7) tunes
/// the actual values. The defaults `0.5 / 0.3 / 0.15 / 0.05` are the
/// ADR-0010 §5 starting set.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FusionWeights {
    /// Weight on the min-max-normalized semantic cosine.
    pub w_sem: f32,
    /// Weight on the min-max-normalized BM25 / FTS5 rank.
    pub w_lex: f32,
    /// Weight on the recency-decay term `0.99^Δt_hours`.
    pub w_rec: f32,
    /// Weight on the source-quality prior. Reserved for Phase 7
    /// (browser-extension page-text > AX > OCR); the Phase-3
    /// retriever uses `src ≡ 0.0` for every event so the term
    /// contributes nothing until that prior lands.
    pub w_src: f32,
}

impl Default for FusionWeights {
    fn default() -> Self {
        Self {
            w_sem: 0.5,
            w_lex: 0.3,
            w_rec: 0.15,
            w_src: 0.05,
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
    /// Microseconds since UNIX epoch — held on the retriever so tests
    /// pin recency-decay computations to a deterministic instant. The
    /// production agent shell refreshes this on each request from
    /// `SystemTime::now()`.
    now_us: u64,
    /// Lexical candidate-pool size (`k_lex`).
    k_lex: usize,
    /// Semantic candidate-pool size (`k_sem`).
    k_sem: usize,
}

impl<S: BrainStore, E: Embedder> HybridRetriever<S, E> {
    /// Construct a retriever with the [`FusionWeights::default`] weights
    /// (ADR-0010 §5 starting set) and the [`DEFAULT_K_LEX`] /
    /// [`DEFAULT_K_SEM`] candidate pools.
    pub fn new(store: Arc<S>, embedder: Arc<E>, now_us: u64) -> Self {
        Self {
            store,
            embedder,
            weights: FusionWeights::default(),
            now_us,
            k_lex: DEFAULT_K_LEX,
            k_sem: DEFAULT_K_SEM,
        }
    }

    /// Override the fusion weights. The eval gate at P3.7 close
    /// (ADR-0010 §7) is the canonical place to tune these.
    #[must_use]
    pub fn with_weights(mut self, weights: FusionWeights) -> Self {
        self.weights = weights;
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

    /// The currently-configured fusion weights.
    #[must_use]
    pub fn weights(&self) -> FusionWeights {
        self.weights
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
            return Ok(Vec::new());
        }

        match self.route(query) {
            RetrievalShape::Plain => self.plain_retrieve(query, query.time_filter),
            RetrievalShape::AnchorThenWindow => self.anchor_then_window_retrieve(query),
            RetrievalShape::TimeRangeExtraction(extracted) => {
                let effective = intersect_ranges(query.time_filter, Some(extracted));
                self.plain_retrieve(query, effective)
            }
        }
    }
}

impl<S: BrainStore, E: Embedder> HybridRetriever<S, E> {
    /// Plain hybrid recall with an optional pre-applied time-range filter
    /// (the router-derived range for `TimeRangeExtraction`, the
    /// caller's `query.time_filter` for `Plain`, or the anchor window
    /// for `AnchorThenWindow`).
    fn plain_retrieve(
        &self,
        query: &RetrievalQuery,
        time_filter: Option<TimeRange>,
    ) -> Result<Vec<RetrievalHit>, RetrieveError> {
        let q_emb = self
            .embedder
            .embed_one(&query.text)
            .map_err(|e| RetrieveError::Backend(e.to_string()))?;
        let lex = self
            .store
            .fts5_search(&query.text, self.k_lex)
            .map_err(|e| RetrieveError::Backend(e.to_string()))?;
        let sem = self
            .store
            .vec_search(&q_emb, self.k_sem)
            .map_err(|e| RetrieveError::Backend(e.to_string()))?;

        let lex_map: HashMap<EventId, f32> = lex.into_iter().collect();
        let sem_map: HashMap<EventId, f32> = sem.into_iter().collect();

        let lex_bounds = minmax(lex_map.values().copied());
        let sem_bounds = minmax(sem_map.values().copied());

        let mut candidate_ids: HashSet<EventId> = HashSet::new();
        candidate_ids.extend(lex_map.keys().copied());
        candidate_ids.extend(sem_map.keys().copied());

        let mut hits: Vec<RetrievalHit> = Vec::with_capacity(candidate_ids.len());
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

            let lex_raw = lex_map.get(&id).copied().unwrap_or(0.0);
            let sem_raw = sem_map.get(&id).copied().unwrap_or(0.0);
            let lex_hat = minmax_normalize(lex_raw, lex_bounds.0, lex_bounds.1);
            let sem_hat = minmax_normalize(sem_raw, sem_bounds.0, sem_bounds.1);
            let recency = recency_decay(self.now_us, event.ts_us);
            // Phase 3 has no source-quality prior wired yet (extension
            // page-text path is Phase 7; manual user-tag is later).
            // `src ≡ 0.0` for every event keeps the term inert until
            // that prior lands.
            let src = 0.0_f32;
            let combined = self.weights.w_sem.mul_add(
                sem_hat,
                self.weights.w_lex.mul_add(
                    lex_hat,
                    self.weights
                        .w_rec
                        .mul_add(recency, self.weights.w_src * src),
                ),
            );
            hits.push(RetrievalHit {
                event_id: id,
                score_lexical: lex_hat,
                score_semantic: sem_hat,
                score_recency: recency,
                score_combined: combined,
            });
        }
        hits.sort_by(|a, b| {
            b.score_combined
                .partial_cmp(&a.score_combined)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        hits.truncate(query.limit);
        Ok(hits)
    }

    /// Anchor-then-window per ADR-0010 §6: top-1 semantic locates the
    /// anchor; the anchor's `ts_us ± 5 min` becomes the time filter for
    /// a plain hybrid pass.
    ///
    /// If the semantic top-1 returns nothing (empty store) or the
    /// anchor event row is missing (rare race), falls back to plain
    /// hybrid with the caller's `time_filter` untouched.
    fn anchor_then_window_retrieve(
        &self,
        query: &RetrievalQuery,
    ) -> Result<Vec<RetrievalHit>, RetrieveError> {
        let q_emb = self
            .embedder
            .embed_one(&query.text)
            .map_err(|e| RetrieveError::Backend(e.to_string()))?;
        let sem_top = self
            .store
            .vec_search(&q_emb, 1)
            .map_err(|e| RetrieveError::Backend(e.to_string()))?;
        let Some((anchor_id, _)) = sem_top.into_iter().next() else {
            return self.plain_retrieve(query, query.time_filter);
        };
        let Some(anchor) = self
            .store
            .get_event(anchor_id)
            .map_err(|e| RetrieveError::Backend(e.to_string()))?
        else {
            return self.plain_retrieve(query, query.time_filter);
        };
        let window = TimeRange {
            from_us: anchor.ts_us.saturating_sub(ANCHOR_WINDOW_US),
            to_us: anchor.ts_us.saturating_add(ANCHOR_WINDOW_US),
        };
        let effective = intersect_ranges(query.time_filter, Some(window));
        self.plain_retrieve(query, effective)
    }
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

/// Recency decay term per ADR-0010 §5: `0.99^Δt_hours`. The event's
/// `ts_us` may be ahead of `now_us` in tests; `saturating_sub` keeps
/// that case from underflowing and returns `1.0` (max recency).
#[must_use]
pub fn recency_decay(now_us: u64, then_us: u64) -> f32 {
    #[allow(clippy::cast_precision_loss)]
    let dt_us = now_us.saturating_sub(then_us) as f32;
    let dt_h = dt_us / 3_600_000_000.0;
    0.99_f32.powf(dt_h)
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
        let r = TimeRange { from_us: 10, to_us: 20 };
        assert_eq!(intersect_ranges(Some(r), None), Some(r));
        assert_eq!(intersect_ranges(None, Some(r)), Some(r));
    }

    #[test]
    fn intersect_ranges_takes_overlap() {
        let a = TimeRange { from_us: 0, to_us: 100 };
        let b = TimeRange { from_us: 50, to_us: 150 };
        assert_eq!(
            intersect_ranges(Some(a), Some(b)),
            Some(TimeRange { from_us: 50, to_us: 100 })
        );
    }

    #[test]
    fn fusion_weights_default_matches_adr_0010() {
        let w = FusionWeights::default();
        assert!((w.w_sem - 0.5).abs() < f32::EPSILON);
        assert!((w.w_lex - 0.3).abs() < f32::EPSILON);
        assert!((w.w_rec - 0.15).abs() < f32::EPSILON);
        assert!((w.w_src - 0.05).abs() < f32::EPSILON);
    }
}
