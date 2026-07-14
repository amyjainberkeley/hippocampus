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

pub mod arctic_embed_s;

/// ADR-0030 §3(a)–(c) OCR-time redaction layer for
/// `com.apple.MobileSMS` and `com.apple.mail`.
///
/// See [`redaction`] for the module-level overview, the app-bundle
/// gating constants, and the cascade-twice integration notes. The
/// redaction layer is **app-bundle-gated** at the call site —
/// callers MUST check [`redaction::bundle_is_in_scope`] before
/// invoking the redaction functions. The layer is zero-cost on
/// every other app's frames (the helper's hot path).
///
/// Phase-4 onramp wiring (cascade-twice OCR-time arm — the
/// integration point in the helper) lands in a follow-up PR; this
/// PR ships the stand-alone module + unit tests + corpus runner +
/// committed corpus-run artifact (the §1 gate-condition (4) of
/// ADR-0030).
pub mod redaction;

#[cfg(any(test, feature = "stubs"))]
pub mod stubs;

pub mod event_chunker;

/// V2-P3 — graph foundation: typed entities + provenance mentions +
/// cross-app episode edges. The types are the OS-free shape the new
/// `BrainStore::put_entity` / `put_entity_mention` / `put_episode_edge` /
/// `find_entity_by_alias` / `events_with_entity` methods exchange. See
/// the module doc for the **content-stable ULID** discipline that makes
/// the schema sync-ready ahead of Phase 8 (ADR-0023).
pub mod graph;

/// V2-P4 — entity-extraction layer. First writer to the V2-P3 graph
/// foundation. Tier 1 regex bank lives in [`extraction::tier1`];
/// Tier 2 Qwen NER (V2-P5) and the V2-P6 AliasResolver chain off the
/// same `BrainStore` trait surface in follow-on PRs.
///
/// See the module doc for the cascade-discipline invariant (Tier 1
/// runs POST-cascade so suppressed bytes never reach the regex bank)
/// and the token-shape REDACT discipline (JWT / API-key bytes never
/// land in `entities` or `entity_mentions`).
pub mod extraction;

pub use event_chunker::EventChunker;
pub use extraction::{
    mark_event_tier2_processed, mark_event_tier2_processed_as, persist_tier1_matches,
    persist_tier2_matches, persist_tier2_matches_as, MockNerBackend, NerBackend, NerError,
    Tier1Extractor, Tier1Match, Tier2Extractor, Tier2Match, Tier2RawMatch,
};
pub use graph::{
    Entity, EntityId, EntityIdentity, EntityIdentityId, EntityMention, EntityMentionId,
    EpisodeEdge, EpisodeEdgeId, IdentityId,
};

pub mod alias_resolver;
pub use alias_resolver::{
    AliasResolver, AliasResolverConfig, ResolvedIdentity, ResolvedMember, ResolverEntity,
};

pub mod consolidator;
pub use consolidator::{ConsolidatorConfig, DerivedEdge, EpisodeConsolidator, IdentityMentionSite};

pub mod fts_sanitizer;

pub mod retention_purger;
mod sqlcipher_brain_store;

pub use retention_purger::{PurgeStats, RetentionConfig};
pub use sqlcipher_brain_store::{IntegrityError, SqlCipherBrainStore};

pub mod integrity_scheduler;
pub use integrity_scheduler::{IntegrityScheduler, SchedulerClock, SchedulerHandle, SystemSchedulerClock};

// ---------------------------------------------------------------------------
// Read-only views used by the agent-API loopback (P3.10b) and recall UI
// ---------------------------------------------------------------------------

/// Compact, copy-friendly view of an `events` row.
///
/// Surface for the agent-API loopback (P3.10b MCP server) and the recall-UI
/// timeline. Distinct from [`Event`] (the producer/storage shape) because:
///
/// - It carries `event_id` already typed as [`EventId`] — convenient for
///   downstream `Display`.
/// - It elides the raw `embedding: Option<Vec<f32>>` and `episode_id`
///   columns the read API does not need to surface (the embedding is a 1.5
///   KB blob; episode mapping is an internal pointer the recall UX does
///   not show).
/// - It carries `text_snippet`, not the full `text`, so a query that asks
///   "give me the last 100 events" cannot accidentally page hundreds of
///   KB of OCR'd text through the MCP socket. Producers truncate to
///   [`EventRecord::SNIPPET_MAX_CHARS`] characters at the boundary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventRecord {
    /// Stable event id.
    pub event_id: EventId,
    /// Capture-time timestamp in microseconds since UNIX epoch.
    pub ts_us: u64,
    /// `appBundleId` of the frontmost app at capture time.
    pub app_bundle_id: Option<String>,
    /// Focused window title at capture time.
    pub window_title: Option<String>,
    /// Active browser tab URL at capture time.
    pub url: Option<String>,
    /// First [`Self::SNIPPET_MAX_CHARS`] characters of the event's text,
    /// truncated on a UTF-8 boundary. Callers wanting the full text should
    /// call [`crate::BrainStore::get_event`].
    pub text_snippet: String,
}

impl EventRecord {
    /// Maximum length of [`EventRecord::text_snippet`], in **bytes** (the
    /// truncation respects UTF-8 boundaries so the resulting string is
    /// always valid). 512 bytes ≈ a paragraph; the MCP / recall-UI surface
    /// never needs more, and the cap prevents a single response from
    /// ballooning the local socket.
    pub const SNIPPET_MAX_CHARS: usize = 512;

    /// Truncate `text` to at most [`Self::SNIPPET_MAX_CHARS`] bytes on a
    /// UTF-8 character boundary. Public so callers building `EventRecord`
    /// outside of this crate (e.g. test fixtures, stub readers) follow the
    /// same discipline.
    #[must_use]
    pub fn truncate_snippet(text: &str) -> String {
        if text.len() <= Self::SNIPPET_MAX_CHARS {
            return text.to_owned();
        }
        // Walk back to the previous UTF-8 boundary at or before the limit.
        let mut end = Self::SNIPPET_MAX_CHARS;
        while end > 0 && !text.is_char_boundary(end) {
            end -= 1;
        }
        text[..end].to_owned()
    }
}

/// Content-free aggregate counts the agent-API surface exposes.
///
/// Returned by [`SqlCipherBrainStore::stats`] and the `mci_stats` MCP tool.
/// "How much memory is in the brain?" — a content-free answer (counts +
/// timestamps; never row content).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BrainStats {
    /// Total number of rows in `events`.
    pub event_count: u64,
    /// Smallest `events.ts_us`. `None` when the store is empty.
    pub oldest_ts_us: Option<u64>,
    /// Largest `events.ts_us`. `None` when the store is empty.
    pub newest_ts_us: Option<u64>,
    /// Total rows in `entities` — the V2-P6 graph node count (people,
    /// orgs, locations, urls, …). `0` on a store with no graph tables
    /// written yet.
    pub entity_count: u64,
    /// Total rows in `entity_mentions` — the event→entity provenance
    /// edges the extractors (regex + NER) wrote.
    pub entity_mention_count: u64,
    /// Total rows in `entity_identities` — the alias→canonical-identity
    /// memberships the `AliasResolver` (V2-P6) clustered.
    pub entity_identity_count: u64,
    /// Total rows in `episode_edges` — the cross-app dot-connect links
    /// the Consolidator (V2-P6) derived (`shared_identity` + reserved
    /// kinds).
    pub episode_edge_count: u64,
}

pub mod episode_segmenter;
pub mod hybrid_retriever;

pub use episode_segmenter::EpisodeId;
pub use hybrid_retriever::{FusionWeights, HybridRetriever, RetrievalShape};

/// One daily brief — the row shape stored in the `briefs` table per
/// migration `0002_briefs.sql`.
///
/// Read surface for the Recall UI's Brief tab (`apps/recall-ui/`). One row
/// per `date_local`; regeneration is an INSERT-OR-REPLACE on that column.
/// This struct is the OS-free shape the FFI shim and write path both speak.
///
/// # Privacy
///
/// Briefs are user content. They live inside the SQLCipher store under
/// the same key-wrap as `events` (ADR-0008) — no new crypto surface. The
/// retention purger ([`crate::retention_purger::purge_once`]) honors the
/// user's existing retention window on briefs in the same DELETE pass it
/// runs on events.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BriefRow {
    /// Stable row id (`briefs.id`).
    pub id: u64,
    /// ISO 8601 local date `YYYY-MM-DD`. The unique key under which the
    /// briefs table looks rows up. UNIQUE-constrained in DDL.
    pub date_local: String,
    /// Generation wall-clock, microseconds since UNIX epoch (matches
    /// `events.ts_us` so the retention purger can use one cutoff).
    pub generated_ts_us: u64,
    /// Author model identifier — e.g. `"qwen3-1.7b-int4"` per ADR-0028.
    /// Surfaced in the brief header.
    pub model_id: String,
    /// Author model version string — surfaced in the brief header.
    pub model_version: String,
    /// Title rendered above the body.
    pub title: String,
    /// Markdown body. The reader renders; the author writes.
    pub body: String,
    /// Word count for the header. Stored (not derived) so list rendering
    /// is cheap.
    pub word_count: u32,
    /// How many events the author saw when composing — surfaces in the
    /// footer. 0 is allowed for stub/synthetic briefs.
    pub source_event_count: u32,
}

/// Compact view of an `episodes` row for the MCP / recall-UI surface.
///
/// Includes a derived `event_count` (number of events assigned to this
/// episode) so the consumer can gauge episode size without a second query.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EpisodeRecord {
    /// Episode id (maps to `episodes.id` rowid).
    pub id: u64,
    /// App bundle identifier for the episode's primary app.
    pub app_bundle_id: Option<String>,
    /// Episode start timestamp (microseconds since UNIX epoch).
    pub ts_start: u64,
    /// Episode end timestamp (microseconds since UNIX epoch).
    pub ts_end: u64,
    /// Number of events assigned to this episode.
    pub event_count: u64,
}

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
// Event — the retrieval and index unit (ADR-0010 / ADR-0016 §1.4)
// ---------------------------------------------------------------------------

/// One captured state-transition moment — the **retrieval and index unit**
/// per ADR-0010 / ADR-0016 §1.4.
///
/// Phase 3 production stores Events directly: `text` is OCR'd page content
/// (with the embedding-time context header `[app=… | title=… | url=… |
/// ts=…]\n` prepended per ADR-0010 §3 by the upstream chunker) and the FTS5
/// virtual table indexes `text + summary + window_title + url`. Sub-chunking
/// into [`Chunk`] only kicks in when one Event's text exceeds the embedder's
/// effective context (ADR-0016 §1.2); chunks reference the parent Event via
/// `event_id` in the `chunks` table.
#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    /// Store-assigned id. Zero until [`BrainStore::put_event`] returns.
    pub id: EventId,
    /// Capture-time timestamp in **microseconds since UNIX epoch**
    /// (ADR-0016 §1.4 `events.ts_us`).
    pub ts_us: u64,
    /// `appBundleId` of the frontmost app when the event was captured
    /// (`None` pre-P2.5 wiring; populated post-ADR-0015).
    pub app_bundle_id: Option<String>,
    /// Focused window title (`None` until ADR-0015 P2.2 lands AX wiring).
    pub window_title: Option<String>,
    /// Active browser tab URL (`None` for non-browser apps or pre-ADR-0015
    /// wiring).
    pub url: Option<String>,
    /// The text the embedder sees and FTS5 indexes. Already includes the
    /// `[app=… | title=… | url=… | ts=…]\n` context header per ADR-0010 §3
    /// when the upstream pipeline applied one.
    pub text: String,
    /// Idle-batch-generated extractive summary (ADR-0016 §1.3).
    /// `None` until the idle-batch worker fills it (P3.8).
    pub summary: Option<String>,
    /// Idle-batch-generated entity list (JSON array string). `None` until
    /// the idle-batch worker fills it (P3.8).
    pub entities: Option<String>,
    /// Backfilled by the episode segmenter (ADR-0010 §1). `None` for events
    /// not yet assigned to an episode.
    pub episode_id: Option<u64>,
    /// Always `0` for events in the store: `.suppress`-decided frames never
    /// reach `put_event` (ADR-0016 §4.3). The column exists so a future
    /// allowlist policy can carry a richer reason code without a schema
    /// bump; the invariant "no row with `cascade_reason != 0`" is asserted
    /// at insert time.
    pub cascade_reason: i64,
    /// Content-addressed blob path for the keyframe (`None` for text-only
    /// events). The blob is encrypted separately per ADR-0008 §1.5.
    pub keyframe_blob: Option<String>,
    /// Browser-assigned tab identifier the event came from. V2-P2 — fills
    /// the per-tab attribution gap the cycle 8.18 memo
    /// (`docs/research/tab-attribution-mix-2026-05-29.md` §5) opens.
    /// `None` for OCREvents (no tab signal from the helper) and for
    /// pre-V2-P2 browser events; `Some(id)` for V2-P2 `PageContentEvent`
    /// ingests where the extension shipped a non-zero tab id. The
    /// brain store column is `INTEGER NULL`; the brain_ingest path
    /// converts a wire-level `0` (extension default = "no tab id
    /// available") to `None` before insert.
    pub tab_id: Option<u32>,
    /// L2-normalized 384-d embedding (ADR-0009 / ADR-0011). `None` when
    /// the event has not yet been embedded — insert is allowed without an
    /// embedding so capture-time inserts don't block on the embedder; the
    /// event falls back to lexical-only until the idle-batch worker fills
    /// it. When `Some`, the production impl writes to `event_vectors` in
    /// the same transaction as `events`.
    pub embedding: Option<Vec<f32>>,
}

// ---------------------------------------------------------------------------
// Chunk — sub-units for over-long events
// ---------------------------------------------------------------------------

/// Sub-unit of an over-long [`Event`]. Stored in the `chunks` table (ADR-0016
/// §1.4); kicks in only when one event's text exceeds the embedder's
/// effective context window. For shorter events the `Event` row itself is
/// the retrieval unit and no Chunk is materialized.
///
/// The trait surface in [`BrainStore`] is **event-centric** per ADR-0016
/// §2 — sub-chunk readers/writers land at P3.4 / P3.8. This struct is
/// reserved for that surface.
#[derive(Debug, Clone, PartialEq)]
pub struct Chunk {
    /// Store-assigned id. Zero until the chunk is inserted.
    pub id: ChunkId,
    /// The text the embedder sees and FTS5 indexes. Inherits the parent
    /// event's context header per ADR-0010 §4.
    pub text: String,
    /// The event this chunk belongs to.
    pub source_event_id: EventId,
    /// Capture-time timestamp in **microseconds since UNIX epoch**,
    /// copied from the parent `events.ts_us` at insert time.
    pub created_at_us: u64,
    /// L2-normalized embedding, dimension fixed at 384 (ADR-0009). `None`
    /// when not yet embedded.
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
    /// Insert an event and return the assigned id. Production impl writes
    /// the `events` row + (when `event.embedding.is_some()`) the
    /// `event_vectors` row in the same transaction so a half-indexed event
    /// can never be observed. The `events_fts` virtual table syncs via
    /// trigger inside the same transaction (ADR-0016 §1.4).
    ///
    /// Per ADR-0016 §4.3 only `.allow`-decided events ever reach this
    /// surface — `.suppress` paths dead-end in the cascade before the
    /// brain ingestor sees them. The trait does not enforce that
    /// structurally (it's an IPC-seam-level invariant); production impls
    /// reject `event.cascade_reason != 0` as a defence-in-depth tripwire.
    fn put_event(&self, event: &Event) -> Result<EventId, StoreError>;

    /// Fetch a single event by id. `Ok(None)` for unknown ids — a
    /// concurrent delete or a hit-set reference past a tombstone is not
    /// an error; the recall UI elides absent rows.
    fn get_event(&self, id: EventId) -> Result<Option<Event>, StoreError>;

    /// FTS5 lexical search over `events_fts` (`text` + `summary` +
    /// `window_title` + `url`, `porter unicode61 remove_diacritics 2`
    /// tokenizer per ADR-0016 §1.4). Returns at most `limit` hits,
    /// ordered by descending BM25 / FTS5 rank. The `f32` is the raw
    /// lexical score (production impl uses `bm25(events_fts)`); the
    /// [`Retriever`] min-max-normalizes it across the candidate pool
    /// before fusion (ADR-0010 §5 `lex_hat`).
    fn fts5_search(&self, query: &str, limit: usize) -> Result<Vec<(EventId, f32)>, StoreError>;

    /// Semantic KNN over `event_vectors`. Returns at most `limit` hits,
    /// ordered by descending cosine similarity. Per ADR-0009 stored
    /// vectors are L2-normalized so cosine == dot product. The `f32` is
    /// the raw cosine score in `[-1.0, 1.0]`; the [`Retriever`]
    /// min-max-normalizes it across the candidate pool before fusion
    /// (ADR-0010 §5 `sem_hat`).
    ///
    /// Production impls MUST reject `query_embedding` whose length does
    /// not match the schema-pinned dimension (384 per ADR-0009) with
    /// [`StoreError::InvalidInput`]. The hard wall is the schema pin —
    /// silently truncating / padding a mis-dim query was the
    /// "almost-right-rank" failure mode the pin was authored against.
    fn vec_search(
        &self,
        query_embedding: &[f32],
        limit: usize,
    ) -> Result<Vec<(EventId, f32)>, StoreError>;

    /// Semantic KNN over `event_vectors`, restricted to events whose
    /// `ts_us` falls inside `time_filter` and/or whose `app_bundle_id`
    /// matches `app_filter`. This is the ADR-0011 §5 candidate-pool
    /// pre-filter — instead of brute-forcing the whole `event_vectors`
    /// table it first narrows the candidate set via the indexed
    /// `events_ts` / `events_app` columns, then dots the query
    /// embedding against only those vectors.
    ///
    /// Returns at most `limit` hits, ordered by descending cosine
    /// similarity, same as [`Self::vec_search`]. When both filters are
    /// `None` the surface is byte-identical to [`Self::vec_search`] and
    /// the default impl simply delegates. Production impls (the
    /// `SqlCipherBrainStore`) push the filters into a SQL `WHERE`
    /// clause backed by the `events_ts` / `events_app` indexes, which
    /// closes the sqlite-vec brute-force gap measured in the
    /// `recall_perf_100k` harness at 100K events (PR #111).
    ///
    /// # Errors
    /// - [`StoreError::InvalidInput`] if `query_embedding.len()` does
    ///   not match the schema-pinned dimension (384 per ADR-0009).
    /// - [`StoreError::Backend`] on SQLite failure.
    fn vec_search_filtered(
        &self,
        query_embedding: &[f32],
        limit: usize,
        time_filter: Option<TimeRange>,
        app_filter: Option<&str>,
    ) -> Result<Vec<(EventId, f32)>, StoreError> {
        // Default impl: ignore filters, fall back to the full KNN. The
        // retriever re-applies the filters post-fetch anyway (the row-
        // level app/time guard in `plain_retrieve`) — the pre-filter
        // is a latency lever, not a correctness lever. Stores that
        // haven't overridden this pay the brute-force cost but return
        // correct results.
        let _ = (time_filter, app_filter);
        self.vec_search(query_embedding, limit)
    }

    // -----------------------------------------------------------------------
    // V2-P3 — graph foundation write+read path
    //
    // The default impls return [`StoreError::Other`] so the trait extension
    // does not break the existing in-memory / recording / sanitizing
    // wrappers that pre-date V2-P3 (`InMemoryBrainStore` in `stubs`,
    // `FtsSanitizingStore` in `apps/agent/src/mcp/live.rs`, and
    // `RecordingStore` in `apps/agent/src/runner.rs`'s tests). The
    // production [`SqlCipherBrainStore`] overrides each one.
    //
    // See `core/brain/src/graph.rs` module doc for the sync-ready ULID
    // discipline every writer above this trait MUST follow.
    // -----------------------------------------------------------------------

    /// Insert or update an entity row. The row's `id` MUST be derived via
    /// [`Entity::derive_id`] so two devices that extract the same
    /// `(kind, canonical_name)` converge on the same PK in Phase 8 sync
    /// (ADR-0023).
    ///
    /// Semantics: upsert keyed on PK. Re-writing an entity with new
    /// `summary` / `summary_embedding` / `updated_ts_us` overwrites the
    /// stored row; `created_ts_us` on the existing row is preserved by
    /// the SQLCipher impl (the writer's `created_ts_us` is honored only
    /// on first insert).
    ///
    /// # Errors
    /// - [`StoreError::InvalidInput`] if the `summary_embedding` length
    ///   does not match the schema-pinned dimension (384 per ADR-0009).
    /// - [`StoreError::Backend`] on SQLite failure.
    fn put_entity(&self, _entity: &Entity) -> Result<(), StoreError> {
        Err(StoreError::Other(
            "put_entity not supported by this BrainStore impl (V2-P3)".into(),
        ))
    }

    /// Insert one entity-mention row. The row's `id` MUST be derived via
    /// [`EntityMention::derive_id`].
    ///
    /// Semantics: idempotent on PK collision (`INSERT OR IGNORE`) — a
    /// re-run of the same extractor on the same event does not duplicate.
    /// The mention's `entity_id` and `event_id` MUST reference existing
    /// rows; the SQLCipher impl enforces this via FOREIGN KEY (ADR-0008
    /// `PRAGMA foreign_keys = ON`).
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure (including FK violation
    /// if `entity_id` / `event_id` does not exist).
    fn put_entity_mention(&self, _mention: &EntityMention) -> Result<(), StoreError> {
        Err(StoreError::Other(
            "put_entity_mention not supported by this BrainStore impl (V2-P3)".into(),
        ))
    }

    /// Insert one episode-edge row. The row's `id` MUST be derived via
    /// [`EpisodeEdge::derive_id`].
    ///
    /// Semantics: idempotent on PK collision (`INSERT OR IGNORE`) — the
    /// consolidator (V2-P3-after) may re-derive the same edge on every
    /// pass without producing duplicates. Both endpoints MUST reference
    /// existing `episodes` rows.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure.
    fn put_episode_edge(&self, _edge: &EpisodeEdge) -> Result<(), StoreError> {
        Err(StoreError::Other(
            "put_episode_edge not supported by this BrainStore impl (V2-P3)".into(),
        ))
    }

    /// Look up an entity by `(kind, alias)`. V2-P3 ships the **exact-
    /// match-on-canonical-name** semantics — `alias` matches the
    /// canonical name. The alias / handle / phone-overlap clustering
    /// rides V2-P6 (`AliasResolver`); when it lands it will widen this
    /// surface (or a peer surface) to fuzzy match.
    ///
    /// Returns `Ok(None)` for an unknown pair — not an error, the
    /// extractor uses the `None` path to mint a fresh entity.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure.
    fn find_entity_by_alias(
        &self,
        _kind: &str,
        _alias: &str,
    ) -> Result<Option<Entity>, StoreError> {
        Err(StoreError::Other(
            "find_entity_by_alias not supported by this BrainStore impl (V2-P3)".into(),
        ))
    }

    /// Return events that have at least one [`EntityMention`] for `entity_id`,
    /// ordered by `events.ts_us DESC`, capped at `limit`.
    ///
    /// First read API the entity surface needs: "show me every event
    /// that mentions Person(John)" — the V2-P12 chat surface's
    /// entity-graph traversal step. The returned [`EventRecord`] carries
    /// only the snippet (truncated per
    /// [`EventRecord::SNIPPET_MAX_CHARS`]) — callers wanting the full
    /// text go through [`get_event`](Self::get_event).
    ///
    /// `limit == 0` returns `Ok(vec![])` without touching SQLite.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure.
    fn events_with_entity(
        &self,
        _entity_id: &EntityId,
        _limit: usize,
    ) -> Result<Vec<EventRecord>, StoreError> {
        Err(StoreError::Other(
            "events_with_entity not supported by this BrainStore impl (V2-P3)".into(),
        ))
    }

    // -----------------------------------------------------------------------
    // V2-P6 — AliasResolver read+write path
    //
    // Reads project the alias-allowlist entities + their co-occurrence;
    // the write upserts one grow-only `entity_identities` membership row.
    // All default impls return [`StoreError::Other`] so the pre-V2-P6
    // wrapper stores keep compiling; the production [`SqlCipherBrainStore`]
    // overrides each.
    // -----------------------------------------------------------------------

    /// Project every alias-allowlist entity (`person_name` /
    /// `organization` / `location` / `email` / `phone` / `url`) into the
    /// resolver's light input type, ordered by id for determinism.
    /// `redacted_token` (and every other kind) is excluded at the SQL
    /// `WHERE kind IN (…)` so a REDACT-classed token never reaches the
    /// resolver.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure.
    fn list_resolvable_entities(&self) -> Result<Vec<alias_resolver::ResolverEntity>, StoreError> {
        Err(StoreError::Other(
            "list_resolvable_entities not supported by this BrainStore impl (V2-P6)".into(),
        ))
    }

    /// Return, per event, the alias-allowlist entity ids mentioned in it
    /// — the co-occurrence signal the resolver uses for phone↔name
    /// linkage and email/domain tiebreaking. Only events with ≥1
    /// allowlist mention appear.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure.
    fn entity_cooccurrences(&self) -> Result<Vec<(EventId, Vec<EntityId>)>, StoreError> {
        Err(StoreError::Other(
            "entity_cooccurrences not supported by this BrainStore impl (V2-P6)".into(),
        ))
    }

    /// Insert one canonical-identity membership row. The row's `id` MUST
    /// be derived via [`EntityIdentity::derive_id`].
    ///
    /// Semantics: grow-only, idempotent on PK collision (`INSERT OR
    /// IGNORE`) — re-running the resolver on an unchanged store is a true
    /// row-level no-op. `entity_id` MUST reference an existing
    /// `entities` row (enforced by FOREIGN KEY); `identity_id` carries no
    /// FK (the identity is the set of rows sharing the value).
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure (incl. FK violation).
    fn put_entity_identity(&self, _membership: &EntityIdentity) -> Result<(), StoreError> {
        Err(StoreError::Other(
            "put_entity_identity not supported by this BrainStore impl (V2-P6)".into(),
        ))
    }

    /// Reconcile the ENTIRE `entity_identities` table to exactly `rows`:
    /// delete any membership whose PK is absent from `rows`, then `INSERT
    /// OR IGNORE` each row (preserving the first-write `ts_us` of rows
    /// that already exist).
    ///
    /// This is the production write path (the idle worker calls it each
    /// cycle): the AliasResolver's leaf-attachment rules are
    /// **non-monotonic** — a leaf (a single-token name, an email) that
    /// attached unambiguously in an earlier pass can become ambiguous and
    /// be dropped once a colliding core is later captured. A plain
    /// grow-only `put_entity_identity` would strand that stale membership
    /// forever (a persisted false-merge no future pass repairs). Pruning
    /// to the resolver's CURRENT output fixes that while keeping a re-run
    /// on an unchanged store a true row-level no-op (nothing deleted,
    /// nothing inserted, `ts_us` untouched).
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure.
    fn reconcile_entity_identities(
        &self,
        _rows: &[EntityIdentity],
    ) -> Result<ReconcileStats, StoreError> {
        Err(StoreError::Other(
            "reconcile_entity_identities not supported by this BrainStore impl (V2-P6)".into(),
        ))
    }

    /// Return the membership rows for one identity — the dot-connect
    /// walk: "give me every alias entity that is this Person/Org". Empty
    /// for an unknown id.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure.
    fn identity_members(
        &self,
        _identity_id: &IdentityId,
    ) -> Result<Vec<EntityIdentity>, StoreError> {
        Err(StoreError::Other(
            "identity_members not supported by this BrainStore impl (V2-P6)".into(),
        ))
    }

    /// Return the membership row(s) for one entity — "which identity does
    /// this alias belong to". At most one under the resolver's
    /// precision-first invariant, but a `Vec` so a future multi-identity
    /// model is not blocked. Empty when the entity is its own (implicit)
    /// identity.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure.
    fn identity_of_entity(&self, _entity_id: &EntityId) -> Result<Vec<EntityIdentity>, StoreError> {
        Err(StoreError::Other(
            "identity_of_entity not supported by this BrainStore impl (V2-P6)".into(),
        ))
    }

    /// Cheap change-detection watermark for the alias resolver's idle
    /// loop — `(entity_count, max_entity_ts, mention_count,
    /// max_mention_ts)`. When unchanged between cycles the worker sleeps
    /// instead of re-resolving (idle-batch, not hot-path).
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure.
    fn resolution_watermark(&self) -> Result<ResolutionWatermark, StoreError> {
        Err(StoreError::Other(
            "resolution_watermark not supported by this BrainStore impl (V2-P6)".into(),
        ))
    }

    // -----------------------------------------------------------------------
    // V2-P6 — Episode-edge Consolidator read+write path
    //
    // The consolidator reads `entity_identities ⋈ entity_mentions ⋈ events`
    // (post-cascade, segmented) and writes `episode_edges` (migration 0004,
    // NO new schema). All default impls return [`StoreError::Other`] so the
    // pre-existing wrapper stores keep compiling; [`SqlCipherBrainStore`]
    // overrides each.
    // -----------------------------------------------------------------------

    /// Project every (identity, member-entity, mentioning-event) tuple the
    /// edge consolidator needs: one [`IdentityMentionSite`] per mention of
    /// an identity-member entity, restricted to **segmented**
    /// (`episode_id IS NOT NULL`), **post-cascade** (`cascade_reason = 0`)
    /// events. `redacted_token` placeholders never appear (the join goes
    /// through `entity_identities`, which only holds the resolver's alias
    /// allowlist). Ordered by `(identity_id, ts_us)` for a single-pass
    /// grouping.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure.
    fn consolidation_candidates(&self) -> Result<Vec<IdentityMentionSite>, StoreError> {
        Err(StoreError::Other(
            "consolidation_candidates not supported by this BrainStore impl (V2-P6)".into(),
        ))
    }

    /// Insert a batch of episode edges in one transaction, `INSERT OR
    /// IGNORE` on the PK. Returns the count of **newly inserted** rows
    /// (re-deriving an existing edge contributes 0). Both endpoints of
    /// every edge MUST reference existing `episodes` rows (FK enforced).
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure (incl. FK violation).
    fn put_episode_edges(&self, _edges: &[EpisodeEdge]) -> Result<u64, StoreError> {
        Err(StoreError::Other(
            "put_episode_edges not supported by this BrainStore impl (V2-P6)".into(),
        ))
    }

    /// Reconcile the `episode_edges` rows OF ONE `kind` to exactly `edges`:
    /// delete any edge of that kind whose PK is absent from `edges`, then
    /// `INSERT OR IGNORE` each row (preserving the first-write `ts_us` of
    /// edges that already exist).
    ///
    /// This is the consolidator's production write path. The
    /// `AliasResolver`'s leaf-attachment is **non-monotonic** — a
    /// membership that justified a cross-app edge can later be dropped, at
    /// which point the edge is no longer derivable. A plain grow-only
    /// `put_episode_edges` would strand that stale edge forever; pruning to
    /// the consolidator's CURRENT output fixes that while keeping a re-run
    /// on an unchanged store a true row-level no-op. Mirrors
    /// [`Self::reconcile_entity_identities`] (the same pattern the alias
    /// resolver uses on its grow-only-framed `entity_identities` table).
    /// The DELETE is scoped to `edge_kind = kind`, so other edge kinds are
    /// untouched; every element of `edges` MUST carry that `edge_kind`.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure (incl. FK violation).
    fn reconcile_episode_edges(
        &self,
        _kind: &str,
        _edges: &[EpisodeEdge],
    ) -> Result<ReconcileStats, StoreError> {
        Err(StoreError::Other(
            "reconcile_episode_edges not supported by this BrainStore impl (V2-P6)".into(),
        ))
    }

    /// Cheap change-detection watermark for the consolidator's idle loop.
    /// When two snapshots compare equal, nothing the consolidator reads
    /// (identities, mentions, episode assignments) has changed, so the
    /// cycle sleeps instead of re-deriving (idle-batch, not hot-path).
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure.
    fn consolidation_watermark(&self) -> Result<ConsolidationWatermark, StoreError> {
        Err(StoreError::Other(
            "consolidation_watermark not supported by this BrainStore impl (V2-P6)".into(),
        ))
    }

    /// The dot-connect walk: every `shared_identity` edge that was derived
    /// for `identity_id`. Precise — an edge is returned only when its PK
    /// re-derives from `(src, dst, identity_id)` via
    /// [`EpisodeEdge::derive_shared_identity_id`], so an edge built for a
    /// *different* identity that happens to link the same episode pair is
    /// excluded. Empty for an identity with no cross-app links.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure.
    fn episode_edges_for_identity(
        &self,
        _identity_id: &IdentityId,
    ) -> Result<Vec<EpisodeEdge>, StoreError> {
        Err(StoreError::Other(
            "episode_edges_for_identity not supported by this BrainStore impl (V2-P6)".into(),
        ))
    }

    /// Return the events assigned to `episode_id`, newest first, capped at
    /// `limit` — the leaf step of the dot-connect walk (edge → episode →
    /// its events). `limit == 0` returns `Ok(vec![])` without touching
    /// SQLite.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure.
    fn events_in_episode(
        &self,
        _episode_id: EpisodeId,
        _limit: usize,
    ) -> Result<Vec<EventRecord>, StoreError> {
        Err(StoreError::Other(
            "events_in_episode not supported by this BrainStore impl (V2-P6)".into(),
        ))
    }

    // -----------------------------------------------------------------------
    // Recall-surface fusion (Phase-6 close) — query-side entity reads
    //
    // Unlike every V2-P3/P6 method above (which defaults to `Err` so a
    // pre-V2 wrapper asked to WRITE or traverse the graph fails loudly),
    // these are *additive read* surfaces for recall fusion + the `mci_recall`
    // output. They default to `Ok(empty)` so a backend with no graph tables
    // (`InMemoryBrainStore`, the headless-test store; the recording/
    // sanitizing wrappers) degrades to "no entity signal / no linked events"
    // rather than erroring the whole recall — recall must never regress
    // because the graph surface is unavailable. Real SQL lives only in the
    // production `SqlCipherBrainStore`.
    // -----------------------------------------------------------------------

    /// Count, per candidate event, how many of its `entity_mentions`
    /// reference one of `query_entity_ids` — the per-event signal the
    /// `w_entity` arm of the hybrid fusion (ADR-0010 §5 + the Phase-6-close
    /// recall-surface fusion) consumes. Backs
    /// `SELECT event_id, COUNT(*) FROM entity_mentions WHERE event_id IN (…)
    /// AND entity_id IN (…) GROUP BY event_id` in the production impl.
    ///
    /// Events with zero matching mentions are **absent** from the map (the
    /// caller treats a missing key as `0`). Returns an empty map when either
    /// input slice is empty.
    ///
    /// Default `Ok(HashMap::new())` — a backend without the graph tables
    /// contributes no entity signal, so the entity arm is inert.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure (production impl only).
    fn mention_match_for_events(
        &self,
        _query_entity_ids: &[EntityId],
        _candidate_ids: &[EventId],
    ) -> Result<std::collections::HashMap<EventId, u32>, StoreError> {
        Ok(std::collections::HashMap::new())
    }

    /// The canonical names of the resolver-allowlist entities (`person_name`
    /// / `organization` / `location` / `email` / `phone` / `url` — **never**
    /// a `redacted_token`) that `event_id` mentions, deduped and ordered,
    /// capped at `limit`. Powers the additive `entities[]` field of
    /// `mci_recall`.
    ///
    /// Restricting to the resolver allowlist mirrors
    /// [`Self::list_resolvable_entities`] so a REDACT-classed token's subkind
    /// label can never reach the recall surface. `limit == 0` returns
    /// `Ok(vec![])`.
    ///
    /// Default `Ok(vec![])`.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure (production impl only).
    fn entity_names_for_event(
        &self,
        _event_id: EventId,
        _limit: usize,
    ) -> Result<Vec<String>, StoreError> {
        Ok(Vec::new())
    }

    /// The cross-app dot-connect: event ids reachable from `event_id`'s
    /// episode via a `shared_identity` [`EpisodeEdge`] (the V2-P6
    /// Consolidator's link). Walks `event → episode → shared_identity edge →
    /// linked episode → its events`. Restricted to **post-cascade**
    /// (`cascade_reason = 0`) events, **excludes `event_id` itself**, newest
    /// first, capped at `limit`. Powers the additive `linked_event_ids[]`
    /// field of `mci_recall`.
    ///
    /// `limit == 0`, an unsegmented hit (`episode_id IS NULL`), or an episode
    /// with no cross-app link all return `Ok(vec![])`.
    ///
    /// Default `Ok(vec![])`.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on SQLite failure (production impl only).
    fn linked_event_ids_for_event(
        &self,
        _event_id: EventId,
        _limit: usize,
    ) -> Result<Vec<EventId>, StoreError> {
        Ok(Vec::new())
    }
}

/// Outcome of a [`BrainStore::reconcile_entity_identities`] pass.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ReconcileStats {
    /// Membership rows newly inserted this pass.
    pub inserted: u64,
    /// Stale membership rows pruned this pass (no longer in the resolver's
    /// output — e.g. a leaf that became ambiguous).
    pub deleted: u64,
}

/// Cheap change-detection watermark for the V2-P6 alias-resolver idle
/// loop. Two snapshots that compare equal mean nothing the resolver reads
/// has changed, so the cycle can sleep without re-resolving.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ResolutionWatermark {
    /// Count of alias-allowlist entities.
    pub entity_count: i64,
    /// Max `entities.updated_ts_us` over the allowlist (0 if none).
    pub max_entity_ts_us: i64,
    /// Count of all entity mentions.
    pub mention_count: i64,
    /// Max `entity_mentions.ts_us` (0 if none).
    pub max_mention_ts_us: i64,
}

/// Cheap change-detection watermark for the V2-P6 episode-edge
/// **Consolidator** idle loop. The consolidator's output is a pure
/// function of the canonical identities, the entity mentions, and the
/// event→episode assignments; this snapshot captures all three cheaply
/// (COUNT/MAX aggregates over indexed columns). Two equal snapshots ⇒
/// nothing the consolidator reads has changed ⇒ the cycle sleeps without
/// re-deriving.
///
/// # Sensitivity to membership *shrink*
///
/// A pure delete (the `AliasResolver` reconcile dropping a stale leaf)
/// lowers `identity_member_count`, and any add stamps a fresh monotonic
/// `ts_us` that raises `max_identity_ts_us` — so every real change to the
/// membership set moves at least one field. The one shape this misses is a
/// same-cycle delete+add whose re-add reuses an OLD `ts_us`, which the
/// alias worker never produces (it stamps `now_us()` on every new row). A
/// missed tick only *delays* a re-derive to the next detected change; it
/// never corrupts an edge, and because the consolidator
/// [`reconcile`](BrainStore::reconcile_episode_edges)s (not appends), that
/// next run self-heals any edge the shrink left stale.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ConsolidationWatermark {
    /// Count of `entity_identities` membership rows.
    pub identity_member_count: i64,
    /// Max `entity_identities.ts_us` (0 if none).
    pub max_identity_ts_us: i64,
    /// Count of all entity mentions.
    pub mention_count: i64,
    /// Max `entity_mentions.ts_us` (0 if none).
    pub max_mention_ts_us: i64,
    /// Count of events that have been assigned to an episode
    /// (`episode_id IS NOT NULL`).
    pub segmented_event_count: i64,
    /// Max `episodes.id` seen (0 if none) — bumps when the segmenter mints
    /// a new episode.
    pub max_episode_id: i64,
}

// ---------------------------------------------------------------------------
// Retrieval query / hit / trait
// ---------------------------------------------------------------------------

/// Inclusive time range, in microseconds since UNIX epoch.
///
/// Matches the unit of [`Event::ts_us`] so the retriever can apply
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
    /// Restrict to events whose `ts_us` falls inside this range.
    /// `None` ⇒ no time filter.
    pub time_filter: Option<TimeRange>,
    /// Restrict to events whose `app_bundle_id` matches this bundle id
    /// (e.g. `"com.apple.Safari"`). Production impl applies the filter
    /// as a SQL `WHERE` pre-filter on the candidate pool. `None` ⇒ no
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
    /// The event this hit refers to.
    pub event_id: EventId,
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
