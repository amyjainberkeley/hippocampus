//! Test-only stub impls of the four brain traits.
//!
//! These are **not** production impls — production lands in the Phase 3 PR
//! sequence (P3.x) per `docs/decisions/0010-event-episode-retrieval-unit-cc-fusion.md`
//! and `docs/decisions/0011-embedding-model-snowflake-arctic-embed-s.md`. The
//! stubs exist so upstream wiring (`apps/agent` and friends) can compile and
//! exercise the trait shapes while the production impls are being written.
//!
//! Module is `#[cfg(any(test, feature = "stubs"))]`-gated. Never in a release
//! binary; the `compile_error!`-style guard is the test-build itself —
//! `apps/agent` never enables the `stubs` feature.

use std::{
    collections::{HashMap, HashSet},
    sync::Mutex,
};

use crate::{
    BrainStore, Chunk, ChunkId, Chunker, ChunkerError, EmbedError, Embedder, EventId,
    RetrievalHit, RetrievalQuery, RetrieveError, Retriever, StoreError,
};

// ---------------------------------------------------------------------------
// NoopChunker — paragraph-boundary split, no semantic awareness
// ---------------------------------------------------------------------------

/// Trivial chunker that splits on `"\n\n"`. Useful for shape tests; never
/// production.
#[derive(Debug, Default, Clone, Copy)]
pub struct NoopChunker;

impl Chunker for NoopChunker {
    fn chunk(&self, event_text: &str) -> Result<Vec<String>, ChunkerError> {
        if event_text.is_empty() {
            return Ok(Vec::new());
        }
        Ok(event_text.split("\n\n").map(str::to_string).collect())
    }
}

// ---------------------------------------------------------------------------
// FixedDimEmbedder — deterministic, seeded, L2-normalized
// ---------------------------------------------------------------------------

/// Deterministic embedder for retrieval-shape tests.
///
/// Given the same `(seed, text)` it always produces the same vector. The
/// vector is L2-normalized to match the ADR-0009 invariant. Default
/// dimension is **384** to match the production embedder
/// (`snowflake-arctic-embed-s`, ADR-0011) so a test using the default
/// dimension catches accidental dimension-mismatch regressions.
#[derive(Debug, Clone, Copy)]
pub struct FixedDimEmbedder {
    /// Output dimension. Default 384 per ADR-0009.
    pub dim: usize,
    /// Seed mixed into the per-text hash before generating coordinates.
    pub seed: u64,
}

impl Default for FixedDimEmbedder {
    fn default() -> Self {
        Self {
            dim: 384,
            seed: 0x00C0_FFEE_C0FF_EE00,
        }
    }
}

impl Embedder for FixedDimEmbedder {
    fn dimension(&self) -> usize {
        self.dim
    }

    fn embed_one(&self, text: &str) -> Result<Vec<f32>, EmbedError> {
        if self.dim == 0 {
            return Err(EmbedError::InvalidInput("dimension must be > 0".into()));
        }
        let mut state = self.seed ^ fnv1a(text.as_bytes());
        if state == 0 {
            // xorshift64 traps at 0; seed away from it.
            state = 0x9E37_79B9_7F4A_7C15;
        }
        let mut v: Vec<f32> = (0..self.dim).map(|_| next_signed_unit_f32(&mut state)).collect();
        // L2-normalize so cosine collapses to dot product (ADR-0009).
        let mag_sq: f32 = v.iter().map(|x| x * x).sum();
        let mag = mag_sq.sqrt();
        if mag > 0.0 {
            for x in &mut v {
                *x /= mag;
            }
        }
        Ok(v)
    }
}

/// FNV-1a 64-bit hash. Stable across Rust versions (unlike `DefaultHasher`),
/// which keeps the embedder deterministic for cross-machine test fixtures.
fn fnv1a(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

/// Single step of Marsaglia xorshift64.
fn xorshift64(state: &mut u64) -> u64 {
    let mut x = *state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *state = x;
    x
}

/// Produce one f32 in `[-1.0, 1.0)`.
fn next_signed_unit_f32(state: &mut u64) -> f32 {
    let bits = xorshift64(state);
    // 24 bits of mantissa → uniform in [0, 1), then shift to [-1, 1).
    // 24-bit value fits losslessly in an f32; the cast is exact.
    #[allow(clippy::cast_precision_loss)]
    let u01 = ((bits & 0x00FF_FFFF) as f32) / 16_777_216.0;
    u01.mul_add(2.0, -1.0)
}

// ---------------------------------------------------------------------------
// InMemoryBrainStore — Mutex<HashMap> backing for fts5_search + vec_search
// ---------------------------------------------------------------------------

/// In-memory store with a brute-force `fts5_search` (substring) and brute-
/// force `vec_search` (cosine over stored embeddings). Useful for
/// retrieval-shape tests without spinning up `SQLCipher`.
///
/// The production impl is `SQLCipher` + FTS5 + sqlite-vec (ADR-0008). This
/// stub deliberately does NOT implement the `events` join the production
/// store does — instead it exposes a small side-table the [`StubRetriever`]
/// reads to apply `app_filter`. Production retrievers use the join instead.
#[derive(Debug, Default)]
pub struct InMemoryBrainStore {
    inner: Mutex<Inner>,
}

#[derive(Debug, Default)]
struct Inner {
    next_id: u64,
    chunks: HashMap<ChunkId, Chunk>,
    event_app: HashMap<EventId, String>,
}

impl InMemoryBrainStore {
    /// Construct an empty store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Bind an event id to an `app_bundle` (e.g. `"com.apple.Safari"`) so
    /// the [`StubRetriever`]'s `app_filter` path has something to match
    /// against. Production stores join `events` for the same effect.
    pub fn set_event_app(&self, ev: EventId, bundle: impl Into<String>) {
        let mut inner = self.inner.lock().expect("poisoned");
        inner.event_app.insert(ev, bundle.into());
    }

    /// Look up an event's `app_bundle`, if known. Used by [`StubRetriever`].
    #[must_use]
    pub fn get_event_app(&self, ev: EventId) -> Option<String> {
        let inner = self.inner.lock().expect("poisoned");
        inner.event_app.get(&ev).cloned()
    }
}

impl BrainStore for InMemoryBrainStore {
    fn put_chunk(&self, chunk: &Chunk) -> Result<ChunkId, StoreError> {
        let mut inner = self.inner.lock().expect("poisoned");
        let id = ChunkId(inner.next_id);
        inner.next_id = inner.next_id.wrapping_add(1);
        let mut stored = chunk.clone();
        stored.id = id;
        inner.chunks.insert(id, stored);
        Ok(id)
    }

    fn get_chunk(&self, id: ChunkId) -> Result<Option<Chunk>, StoreError> {
        let inner = self.inner.lock().expect("poisoned");
        Ok(inner.chunks.get(&id).cloned())
    }

    fn fts5_search(&self, query: &str, limit: usize) -> Result<Vec<(ChunkId, f32)>, StoreError> {
        if query.is_empty() {
            return Err(StoreError::InvalidInput("empty FTS5 query".into()));
        }
        let inner = self.inner.lock().expect("poisoned");
        let q = query.to_lowercase();
        let mut hits: Vec<(ChunkId, f32)> = inner
            .chunks
            .values()
            .filter_map(|c| {
                let t = c.text.to_lowercase();
                let matches = t.matches(&q).count();
                if matches == 0 {
                    return None;
                }
                // Cheap pseudo-BM25: matches × query-len / text-len. Higher
                // for denser matches in shorter chunks. Production uses real
                // BM25 from FTS5. Precision loss is acceptable — this is the
                // stub's relative-ranking score, not stored anywhere.
                #[allow(clippy::cast_precision_loss)]
                let score =
                    (matches as f32) * (q.len() as f32) / (t.len().max(1) as f32);
                Some((c.id, score))
            })
            .collect();
        hits.sort_by(|a, b| {
            b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal)
        });
        hits.truncate(limit);
        Ok(hits)
    }

    fn vec_search(
        &self,
        query_embedding: &[f32],
        limit: usize,
    ) -> Result<Vec<(ChunkId, f32)>, StoreError> {
        if query_embedding.is_empty() {
            return Err(StoreError::InvalidInput(
                "empty query embedding".into(),
            ));
        }
        let inner = self.inner.lock().expect("poisoned");
        let mut hits: Vec<(ChunkId, f32)> = inner
            .chunks
            .values()
            .filter_map(|c| {
                let e = c.embedding.as_ref()?;
                if e.len() != query_embedding.len() {
                    return None;
                }
                // Vectors are L2-normalized per ADR-0009, so cosine == dot.
                let dot: f32 = e.iter().zip(query_embedding.iter()).map(|(a, b)| a * b).sum();
                Some((c.id, dot))
            })
            .collect();
        hits.sort_by(|a, b| {
            b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal)
        });
        hits.truncate(limit);
        Ok(hits)
    }
}

// ---------------------------------------------------------------------------
// StubRetriever — composes embedder + InMemoryBrainStore with min-max CC fusion
// ---------------------------------------------------------------------------

/// Default fusion weight: semantic term. Per ADR-0010 §5 production starts at
/// 0.5; the stub keeps the same.
pub const DEFAULT_W_SEM: f32 = 0.5;
/// Default fusion weight: lexical term. ADR-0010 §5 production starts at 0.3
/// (paired with a 0.05 `w_src` source-quality prior the stub doesn't model);
/// the stub absorbs the source weight into lexical at 0.4 for simplicity.
pub const DEFAULT_W_LEX: f32 = 0.4;
/// Default fusion weight: recency term. The stub holds the production 0.1
/// starting value (production splits 0.15 across recency + source).
pub const DEFAULT_W_REC: f32 = 0.1;
/// Default candidate-pool size — how many lexical / semantic hits the stub
/// pulls before fusion. Production uses a larger pool sized to the database.
pub const DEFAULT_CANDIDATE_POOL: usize = 64;

/// Retriever that composes a [`FixedDimEmbedder`]-shaped [`Embedder`] with
/// an [`InMemoryBrainStore`]: fetch top-pool lexical hits, fetch top-pool
/// semantic hits, min-max-normalize each list across the **union** of
/// candidate ids, apply optional `time_filter` and `app_filter`
/// post-fetch, fuse with the default convex weights, sort by combined
/// score, truncate to `query.limit`.
///
/// Production retriever has the same shape but joins `events` for app/time
/// filters and routes to the anchor-then-window or LLM-time-range paths
/// per ADR-0010 §6. The stub implements plain hybrid only.
pub struct StubRetriever<E: Embedder> {
    /// Embedder used at query time only. Stored by value so the retriever
    /// owns the runtime; production retrievers do the same.
    pub embedder: E,
    /// The store the retriever reads. Shared `&` reference so a test can
    /// `put_chunk` directly through the store and have the retriever see
    /// the inserts.
    pub store: std::sync::Arc<InMemoryBrainStore>,
    /// Wall-clock-equivalent "now", microseconds since UNIX epoch. Held on
    /// the retriever so tests can pin recency-decay computations to a
    /// deterministic instant. Production retrievers consult `SystemTime`.
    pub now_us: u64,
    /// Weight on the normalized semantic score.
    pub w_sem: f32,
    /// Weight on the normalized lexical score.
    pub w_lex: f32,
    /// Weight on the recency decay term.
    pub w_rec: f32,
    /// Per-half candidate-pool size before fusion.
    pub candidate_pool: usize,
}

impl<E: Embedder> StubRetriever<E> {
    /// Construct a retriever with the [`DEFAULT_W_SEM`] / [`DEFAULT_W_LEX`]
    /// / [`DEFAULT_W_REC`] weights and a [`DEFAULT_CANDIDATE_POOL`] pool.
    pub fn new(embedder: E, store: std::sync::Arc<InMemoryBrainStore>, now_us: u64) -> Self {
        Self {
            embedder,
            store,
            now_us,
            w_sem: DEFAULT_W_SEM,
            w_lex: DEFAULT_W_LEX,
            w_rec: DEFAULT_W_REC,
            candidate_pool: DEFAULT_CANDIDATE_POOL,
        }
    }
}

impl<E: Embedder> Retriever for StubRetriever<E> {
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

        let pool = self.candidate_pool.max(query.limit);

        let q_emb = self
            .embedder
            .embed_one(&query.text)
            .map_err(|e| RetrieveError::Backend(e.to_string()))?;
        let lex = self
            .store
            .fts5_search(&query.text, pool)
            .map_err(|e| RetrieveError::Backend(e.to_string()))?;
        let sem = self
            .store
            .vec_search(&q_emb, pool)
            .map_err(|e| RetrieveError::Backend(e.to_string()))?;

        let lex_map: HashMap<ChunkId, f32> = lex.into_iter().collect();
        let sem_map: HashMap<ChunkId, f32> = sem.into_iter().collect();
        let lex_bounds = minmax(lex_map.values().copied());
        let sem_bounds = minmax(sem_map.values().copied());

        let mut candidate_ids: HashSet<ChunkId> = HashSet::new();
        candidate_ids.extend(lex_map.keys().copied());
        candidate_ids.extend(sem_map.keys().copied());

        let mut hits: Vec<RetrievalHit> = Vec::with_capacity(candidate_ids.len());
        for id in candidate_ids {
            let chunk_opt = self
                .store
                .get_chunk(id)
                .map_err(|e| RetrieveError::Backend(e.to_string()))?;
            let Some(chunk) = chunk_opt else { continue };

            if let Some(tr) = &query.time_filter {
                if chunk.created_at_us < tr.from_us || chunk.created_at_us > tr.to_us {
                    continue;
                }
            }
            if let Some(target) = &query.app_filter {
                let app = self.store.get_event_app(chunk.source_event_id);
                if app.as_deref() != Some(target.as_str()) {
                    continue;
                }
            }

            let lex_raw = lex_map.get(&id).copied().unwrap_or(0.0);
            let sem_raw = sem_map.get(&id).copied().unwrap_or(0.0);
            let lex_hat = minmax_normalize(lex_raw, lex_bounds.0, lex_bounds.1);
            let sem_hat = minmax_normalize(sem_raw, sem_bounds.0, sem_bounds.1);
            let recency = recency_decay(self.now_us, chunk.created_at_us);
            let combined = self
                .w_sem
                .mul_add(sem_hat, self.w_lex.mul_add(lex_hat, self.w_rec * recency));
            hits.push(RetrievalHit {
                chunk_id: id,
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
}

/// Min / max of an iterator of `f32`. `(0.0, 0.0)` for an empty iterator —
/// callers should treat empty as "no signal" anyway.
fn minmax(it: impl Iterator<Item = f32>) -> (f32, f32) {
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

/// Min-max normalize `v` into `[0, 1]`. When `max == min` (degenerate pool —
/// one hit, or all-equal), returns the midpoint `0.5` so the term neither
/// dominates nor disappears.
fn minmax_normalize(v: f32, mn: f32, mx: f32) -> f32 {
    if mx <= mn {
        return 0.5;
    }
    ((v - mn) / (mx - mn)).clamp(0.0, 1.0)
}

/// Recency decay term per ADR-0010 §5: `0.99^Δt_hours`. The chunk's
/// `created_at_us` may be ahead of `now_us` in tests; `saturating_sub`
/// keeps that case from underflowing and returns `1.0` (max recency).
fn recency_decay(now_us: u64, then_us: u64) -> f32 {
    // f32 precision is fine: 0.99^Δt_h is bounded in [0, 1] and we only
    // need ranking accuracy, not exact arithmetic.
    #[allow(clippy::cast_precision_loss)]
    let dt_us = now_us.saturating_sub(then_us) as f32;
    let dt_h = dt_us / 3_600_000_000.0;
    0.99_f32.powf(dt_h)
}
