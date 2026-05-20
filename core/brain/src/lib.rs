//! MCI brain — OS-free traits + types for the Phase 3 memory layer.
//!
//! # What this crate is
//!
//! The Phase 3 *shape*: the four traits (chunker, embedder, store, retriever)
//! and the value types they exchange. Nothing in this crate runs OCR, runs an
//! embedder, opens a `SQLCipher` database, or fuses retrieval scores in
//! anger — those are the production impls that land in the Phase 3 PR
//! sequence (P3.x), each individually CSO-reviewable under `AGENT_PROTOCOL`
//! §5. This crate is the trait surface those impls will satisfy, plus stubs
//! to keep upstream wiring honest while they're being written.
//!
//! # Binding decisions
//!
//! - `docs/DESIGN.md` §8 — pipeline shape: state-transition event → OCR/text
//!   → episode segmenter → embed event text with prepended context header →
//!   one `SQLite` file (FTS5 + sqlite-vec) → hybrid lexical+semantic retrieval
//!   fused by **min-max Convex Combination**.
//! - `docs/DESIGN.md` §12 — data model: `events`, `episodes`, `event_text`
//!   (+ FTS5), `event_vectors` (sqlite-vec, 384-d), `chunks` (only over-long
//!   events).
//! - `docs/DESIGN.md` §13 — tech stack: `snowflake-arctic-embed-s` (384-d) via
//!   `Core ML` / ANE on macOS, `ONNX Runtime` + `DirectML` on Windows.
//! - `docs/decisions/0009-pin-sqlite-vec-dimension-384.md` — embedding
//!   dimension is **384**, vectors L2-normalized.
//! - `docs/decisions/0010-event-episode-retrieval-unit-cc-fusion.md` — **the
//!   retrieval and index unit is the event**, not the flat chunk; fusion is
//!   min-max Convex Combination, not Reciprocal Rank Fusion. Resolved Phase 0
//!   fork "Director-Brain — Memory unit" (`docs/AGENT_QUESTIONS.md`,
//!   ACCEPTED 2026-05-18).
//! - `docs/decisions/0011-embedding-model-snowflake-arctic-embed-s.md` —
//!   embedder is `snowflake-arctic-embed-s` (Apache-2.0, 384-d). Resolved
//!   Phase 0 fork "Director-Brain — Embedding model" (`docs/AGENT_QUESTIONS.md`,
//!   ACCEPTED 2026-05-18).
//!
//! ADR-0016 (parallel doc PR currently in flight) is the binding ratification
//! document for the full Phase 3 architecture. If the ADR mandates trait
//! shape changes after this scaffold lands, a follow-up rebase PR adjusts
//! the traits — this scaffold does not block on it.
//!
//! # OS-purity
//!
//! Nothing here may contain OS-specific code (`AGENT_PROTOCOL` §4 cross-
//! platform-seam invariant). No `cfg(target_os = ...)`, no `objc2::...`,
//! no `windows::...`. Production impls in Phase 3 keep this discipline:
//! Core ML / ONNX runtimes live behind the trait under `adapters/<os>/`
//! (analogous to the `CaptureSource` seam in `mci-core::capture`).

#![forbid(unsafe_code)]
#![deny(missing_docs)]

use std::fmt;

use thiserror::Error;

#[cfg(any(test, feature = "stubs"))]
pub mod stubs;

pub mod event_chunker;

pub use event_chunker::EventChunker;

// ---------------------------------------------------------------------------
// Newtype ids — keep `events` / `chunks` PKs out of arithmetic with raw u64
// ---------------------------------------------------------------------------

/// Stable identifier for one stored [`Chunk`].
///
/// Newtype over `u64` so chunk ids cannot be accidentally mixed with event
/// ids or used in arithmetic. Production impls map this to the `chunks.id`
/// rowid in the `SQLite` schema (`docs/DESIGN.md` §12).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ChunkId(pub u64);

impl fmt::Display for ChunkId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "chunk:{}", self.0)
    }
}

/// Stable identifier for one captured state-transition event.
///
/// The event is the **retrieval and index unit** per ADR-0010; chunks exist
/// only as a sub-unit for over-long events. Production impls map this to the
/// `events.id` rowid in the `SQLite` schema (`docs/DESIGN.md` §12).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct EventId(pub u64);

impl fmt::Display for EventId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "event:{}", self.0)
    }
}

// ---------------------------------------------------------------------------
// Chunk — the unit the store actually holds
// ---------------------------------------------------------------------------

/// One stored piece of text + (optional) embedding, with a back-pointer to
/// its source event.
///
/// Per ADR-0010 the *retrieval* unit is the event. The brain still stores a
/// `Chunk` per row in the vector table because sub-chunking kicks in for
/// over-long events. For most events `text` is the event text (with the
/// embedded-time context header already prepended); for over-long events
/// `text` is a paragraph-boundary sub-chunk inheriting the parent's context
/// header (ADR-0010 §4).
#[derive(Debug, Clone, PartialEq)]
pub struct Chunk {
    /// Store-assigned id. Zero until [`BrainStore::put_chunk`] returns.
    pub id: ChunkId,
    /// The text the embedder sees and FTS5 indexes. Already includes the
    /// `[app=... | title=... | url=... | ts=...]\n` context header per
    /// ADR-0010 §3 when the upstream pipeline applied one.
    pub text: String,
    /// The event this chunk belongs to. Multiple chunks share an
    /// `EventId` only when the event was over-long and sub-chunked.
    pub source_event_id: EventId,
    /// Capture-time timestamp in **microseconds since UNIX epoch**, copied
    /// from `events.ts` at insert time. Used by the recency term in the
    /// fusion (ADR-0010 §5) without a join.
    pub created_at_us: u64,
    /// L2-normalized embedding, dimension fixed at 384 (ADR-0009). `None`
    /// when the chunk has not yet been embedded (insert is allowed without
    /// an embedding so capture-time inserts don't block on the idle-batch
    /// embedder; the chunk falls back to lexical-only until embedded).
    pub embedding: Option<Vec<f32>>,
}

// ---------------------------------------------------------------------------
// Chunker — text → chunks
// ---------------------------------------------------------------------------

/// Splits one event's text into sub-chunks.
///
/// Per ADR-0010 §4 sub-chunking only happens when an event exceeds the
/// embedder's effective context (e.g. > ~1500 tokens for arctic-embed-s).
/// Production impls split on semantic / paragraph boundaries. For events
/// under the threshold a chunker returns one element (the event text
/// itself).
///
/// # Caller-prepends-header invariant (LOAD-BEARING per ADR-0010 §1.3 +
/// ADR-0016 §1.2)
///
/// The `Chunker` trait deliberately takes only `event_text: &str` — **no
/// per-event context**. The context header
/// `[app=… | title=… | url=… | ts=…]\n<text>` (the LongMemEval-validated
/// "key expansion" prefix that ADR-0010 §1.3 mandates as part of the
/// embedded string) is **the caller's responsibility**:
///
/// - the [`BrainStore`] writer / OCR-event ingestor prepends the header
///   to `event_text` **before** calling [`Chunker::chunk`], so the
///   chunker's output already carries the header on the (only) chunk
///   for short events;
/// - for long events, the same `event_text` (header + body) is what the
///   chunker subdivides — the header naturally appears on the first
///   sub-chunk. Sub-chunks past the first inherit the parent's header
///   by upstream re-prepend at embedder-call time (the chunker itself
///   does not, and cannot, re-emit it).
///
/// Embedding any chunk **without** the header is a §4 invariant
/// regression (recall quality drops materially per `LongMemEval` +9.4%
/// recall@5 ablation). The trait surface keeps the invariant a
/// structural convention here in Phase 3; a follow-up PR (out of
/// P3.4 scope, recommended in the P3.4 PR body) is expected to lift
/// the header onto a typed `EventContext { app, title, url, ts }`
/// argument so the discipline becomes type-checked.
pub trait Chunker: Send + Sync {
    /// Split `event_text` into one-or-more sub-chunks. Returning an empty
    /// `Vec` is allowed for empty / whitespace-only input.
    ///
    /// **The caller MUST prepend the ADR-0010 §1.3 context header to
    /// `event_text` before calling.** The chunker performs the
    /// chunking math only; see the trait doc above for the
    /// caller-prepends invariant.
    fn chunk(&self, event_text: &str) -> Result<Vec<String>, ChunkerError>;
}

// ---------------------------------------------------------------------------
// Embedder — text → 384-d L2-normalized vector
// ---------------------------------------------------------------------------

/// Embeds text into a 384-d vector.
///
/// Per ADR-0011 the production impl is `snowflake-arctic-embed-s` (33M
/// params, 384-d, Apache-2.0, int8-quantized) via `Core ML` / ANE on macOS
/// and `ONNX Runtime` + `DirectML` on Windows. The wrapper is required to
/// prepend the query-side / document-side prefix per the model card;
/// without the prefix retrieval quality degrades. Per ADR-0009 every
/// returned vector is **L2-normalized**, so cosine similarity collapses
/// to dot product at retrieval time and any future Matryoshka-style swap
/// is a truncation rather than a re-train.
pub trait Embedder: Send + Sync {
    /// The fixed embedding dimension. Per ADR-0009 this is **384** for the
    /// production embedder; the trait exposes it so consumers can refuse a
    /// mismatched store at open time (`schema_version` discipline).
    fn dimension(&self) -> usize;

    /// Embed one text. Returned vector length MUST equal
    /// [`dimension`](Self::dimension) and MUST be L2-normalized.
    fn embed_one(&self, text: &str) -> Result<Vec<f32>, EmbedError>;

    /// Embed a batch. Default impl loops [`embed_one`](Self::embed_one);
    /// production impls override with a true batched forward pass (the
    /// only path that hits the ANE / `DirectML` batch-scaling regime).
    fn embed_batch(&self, texts: &[&str]) -> Result<Vec<Vec<f32>>, EmbedError> {
        let mut out = Vec::with_capacity(texts.len());
        for t in texts {
            out.push(self.embed_one(t)?);
        }
        Ok(out)
    }
}

// ---------------------------------------------------------------------------
// BrainStore — the two halves of the hybrid retrieval surface
// ---------------------------------------------------------------------------

/// Persistence + the two halves of the hybrid retrieval surface.
///
/// Production impl is `SQLCipher` + FTS5 + sqlite-vec atop the existing
/// `mci-core::store` seam (ADR-0008 / ADR-0009). FTS5 owns lexical recall;
/// sqlite-vec owns semantic recall; the [`Retriever`] fuses both via
/// min-max Convex Combination (ADR-0010 §5). Splitting the surface this way
/// lets the retriever issue both reads in parallel and unifies the score
/// space exactly once, in OS-free Rust above the trait.
pub trait BrainStore: Send + Sync {
    /// Insert (or upsert) a chunk and return the assigned id. Production
    /// impl writes the FTS5 + sqlite-vec rows in the same transaction so a
    /// half-indexed chunk can never be observed.
    fn put_chunk(&self, chunk: &Chunk) -> Result<ChunkId, StoreError>;

    /// Fetch a single chunk by id. `Ok(None)` for unknown ids. (Unknown is
    /// not an error — the retriever's hit set may reference a chunk a
    /// concurrent delete removed; the recall UI elides those.)
    fn get_chunk(&self, id: ChunkId) -> Result<Option<Chunk>, StoreError>;

    /// FTS5 lexical search. Returns at most `limit` hits, ordered by
    /// descending BM25 / FTS5 rank. The `f32` is the raw lexical score;
    /// the [`Retriever`] min-max-normalizes it across the candidate pool
    /// before fusion (ADR-0010 §5 `lex_hat`).
    fn fts5_search(&self, query: &str, limit: usize) -> Result<Vec<(ChunkId, f32)>, StoreError>;

    /// Semantic KNN over the sqlite-vec table. Returns at most `limit`
    /// hits, ordered by descending cosine similarity. Per ADR-0009 stored
    /// vectors are L2-normalized so cosine == dot product. The `f32` is
    /// the raw cosine score in `[-1.0, 1.0]`; the [`Retriever`]
    /// min-max-normalizes it across the candidate pool before fusion
    /// (ADR-0010 §5 `sem_hat`).
    fn vec_search(
        &self,
        query_embedding: &[f32],
        limit: usize,
    ) -> Result<Vec<(ChunkId, f32)>, StoreError>;
}

// ---------------------------------------------------------------------------
// Retrieval query / hit / trait
// ---------------------------------------------------------------------------

/// Inclusive time range, in microseconds since UNIX epoch.
///
/// Matches the unit of [`Chunk::created_at_us`] so the retriever can apply
/// the filter without a wall-clock conversion. The lifelog query router
/// (ADR-0010 §6 "LLM time-range extraction") fills these from natural
/// language; for plain hybrid recall the field is `None`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TimeRange {
    /// Inclusive lower bound.
    pub from_us: u64,
    /// Inclusive upper bound.
    pub to_us: u64,
}

/// A natural-language query the [`Retriever`] hybrid-searches over.
///
/// Optional filters (`time_filter`, `app_filter`) are applied as pre-filters
/// on the candidate pool, before fusion. Per ADR-0011 §5 these pre-filters
/// are also the scaling-ladder lever past ~10⁶ vectors: shrinking the
/// candidate pool before brute-force vector KNN is what keeps sqlite-vec
/// inside the latency budget.
#[derive(Debug, Clone, PartialEq)]
pub struct RetrievalQuery {
    /// The user's natural-language query string. Production impl passes
    /// this through the query-side prefix of the embedder (per the model
    /// card; ADR-0011 §3) before vector search, and through FTS5 query
    /// tokenization before lexical search.
    pub text: String,
    /// Maximum hits to return. The retriever may scan a larger candidate
    /// pool internally before fusion.
    pub limit: usize,
    /// Restrict to chunks whose `created_at_us` falls inside this range.
    /// `None` ⇒ no time filter.
    pub time_filter: Option<TimeRange>,
    /// Restrict to chunks whose source event's `app_bundle` matches this
    /// bundle id (e.g. `"com.apple.Safari"`). Production impl joins
    /// `events` to apply the filter; the scaffold's stub store keeps the
    /// `app_bundle` in a side-table for the same effect. `None` ⇒ no
    /// app filter.
    pub app_filter: Option<String>,
}

/// One fused hit returned by [`Retriever::retrieve`].
///
/// All four score components are kept on the hit so the recall UI can
/// surface "why this was retrieved" debug info without re-running the
/// search. All scores are in `[0.0, 1.0]` after min-max normalization
/// across the candidate pool (ADR-0010 §5).
#[derive(Debug, Clone, PartialEq)]
pub struct RetrievalHit {
    /// The chunk this hit refers to.
    pub chunk_id: ChunkId,
    /// Min-max-normalized BM25 / FTS5 rank (`lex_hat` in ADR-0010 §5).
    pub score_lexical: f32,
    /// Min-max-normalized semantic cosine (`sem_hat` in ADR-0010 §5).
    pub score_semantic: f32,
    /// Recency decay `0.99^Δt_hours` (ADR-0010 §5). Computed at retrieval
    /// time against the wall clock the retriever was constructed with.
    pub score_recency: f32,
    /// Final fused score after the convex combination
    /// `w_sem · sem_hat + w_lex · lex_hat + w_rec · recency (+ w_src · src)`.
    /// Hits are returned ordered by this column, descending.
    pub score_combined: f32,
}

/// Orchestrates the hybrid retrieval: chunker stage-skip + embedder +
/// `BrainStore` (both halves) + min-max Convex Combination fusion + query
/// router.
///
/// Per ADR-0010 §6 production impls dispatch to one of three sub-paths:
///
/// - **Anchor-then-window** for "right before X" / "right after X" queries
///   (locate X via plain hybrid, then walk the timeline ±N minutes).
/// - **LLM time-range extraction** for natural-language temporal queries
///   ("last Tuesday afternoon"); on-device LLM only.
/// - **Plain hybrid recall** for everything else.
///
/// The scaffold's [`stubs::StubRetriever`] implements plain hybrid only;
/// the routing layer lands in Phase 3.
pub trait Retriever: Send + Sync {
    /// Run the query and return at most `query.limit` hits, ordered by
    /// `score_combined` descending.
    fn retrieve(&self, query: &RetrievalQuery) -> Result<Vec<RetrievalHit>, RetrieveError>;
}

// ---------------------------------------------------------------------------
// Error enums — each trait has room for invalid-input / backend / other
// ---------------------------------------------------------------------------

/// Errors a [`Chunker`] may return.
///
/// The three-variant shape (`InvalidInput` / `Backend` / `Other`) is shared
/// across the brain error enums so Phase 3 production impls have room to
/// collapse their crate-specific errors without changing the trait surface.
#[derive(Debug, Error)]
pub enum ChunkerError {
    /// The input could not be chunked because it was malformed (e.g. not
    /// valid UTF-8 boundary at a sub-chunk cut). The string carries the
    /// adapter-specific reason for the recall UI / `tracing` log.
    #[error("chunker: invalid input: {0}")]
    InvalidInput(String),
    /// A chunker backend (e.g. a sentence-segmenter native lib) failed.
    #[error("chunker: backend: {0}")]
    Backend(String),
    /// Catch-all for adapter-specific errors that don't fit the other
    /// two variants. Production impls should reach for this last.
    #[error("chunker: {0}")]
    Other(String),
}

/// Errors an [`Embedder`] may return.
///
/// Same shape as [`ChunkerError`] — see that type for rationale.
#[derive(Debug, Error)]
pub enum EmbedError {
    /// Input was rejected before reaching the model (e.g. empty string,
    /// over-long even for sub-chunking, non-UTF-8).
    #[error("embed: invalid input: {0}")]
    InvalidInput(String),
    /// The embedder backend (`Core ML` / ANE / `ONNX Runtime` / `DirectML`)
    /// failed. The string carries the adapter-specific reason.
    #[error("embed: backend: {0}")]
    Backend(String),
    /// Catch-all for adapter-specific errors.
    #[error("embed: {0}")]
    Other(String),
}

/// Errors a [`BrainStore`] may return.
///
/// Same shape as [`ChunkerError`]. Distinct from `mci_core::store::StoreError`
/// (the encrypted `SQLite` open path) — that one is protected-set and lives
/// behind `AGENT_PROTOCOL` §5. The brain's `StoreError` is the OS-free
/// trait-surface error a future `SQLCipher` impl collapses into.
#[derive(Debug, Error)]
pub enum StoreError {
    /// Caller violated a precondition (e.g. embedding dimension mismatch,
    /// embedding not L2-normalized, FTS5 query syntax error).
    #[error("store: invalid input: {0}")]
    InvalidInput(String),
    /// The storage backend (`SQLCipher` / FTS5 / sqlite-vec) failed.
    #[error("store: backend: {0}")]
    Backend(String),
    /// Catch-all for adapter-specific errors.
    #[error("store: {0}")]
    Other(String),
}

/// Errors a [`Retriever`] may return.
///
/// Same shape as [`ChunkerError`]. Production retrievers also wrap embedder
/// and store failures internally, but surface them as `Backend` here so
/// the recall API has a single error type to surface.
#[derive(Debug, Error)]
pub enum RetrieveError {
    /// The query was malformed (e.g. empty `text`, zero `limit`, inverted
    /// `TimeRange`).
    #[error("retrieve: invalid input: {0}")]
    InvalidInput(String),
    /// An embedder or store call inside the retriever failed.
    #[error("retrieve: backend: {0}")]
    Backend(String),
    /// Catch-all for adapter-specific errors.
    #[error("retrieve: {0}")]
    Other(String),
}

// ---------------------------------------------------------------------------
// Unit tests — narrow surface checks; the heavy tests live in
// `tests/scaffold.rs` against the public API + the `stubs` feature.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_display_with_namespace_prefix() {
        assert_eq!(ChunkId(7).to_string(), "chunk:7");
        assert_eq!(EventId(42).to_string(), "event:42");
    }

    #[test]
    fn traits_are_dyn_compatible() {
        // Compile-time check: the four traits must be object-safe so the
        // production retriever can hold `Box<dyn Chunker>` / `Box<dyn
        // Embedder>` / `Box<dyn BrainStore>` without generics leaking
        // into the agent shell. If someone adds a generic method, these
        // lines stop compiling — a clear signal the seam shape changed.
        fn _c(_: Box<dyn Chunker>) {}
        fn _e(_: Box<dyn Embedder>) {}
        fn _s(_: Box<dyn BrainStore>) {}
        fn _r(_: Box<dyn Retriever>) {}
    }
}
