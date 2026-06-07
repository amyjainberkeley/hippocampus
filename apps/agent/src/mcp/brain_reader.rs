//! `BrainReader` trait — the read-only surface the MCP server speaks to.
//!
//! Defined here (in `apps/agent`, not in `mci-brain`) so the MCP wiring
//! can swap between a live `SqlCipherBrainStore`-backed reader and a
//! headless stub without exposing the test stub on the public mci-brain
//! API.

use mci_brain::{BrainStats, EpisodeRecord, EventRecord};
use thiserror::Error;

/// Compact recall hit shape the MCP server returns. Strictly a superset of
/// `EventRecord` (the timeline-cursor row) + a relevance score from the
/// underlying retriever. Distinct from `mci_brain::RetrievalHit` because
/// the MCP surface returns row content (snippet + `url` + `window_title`)
/// directly to the client — `RetrievalHit` only carries the `EventId` + the
/// four score components, expecting the caller to re-fetch the row.
#[derive(Debug, Clone, PartialEq)]
pub struct McpHit {
    /// The row itself (already snippet-truncated).
    pub record: EventRecord,
    /// Fused-or-lexical relevance score. P3.10b's `LiveBrainReader` runs
    /// **lexical-only** FTS5 (the Core-ML embedder lands at P3.3 → P3.7
    /// before hybrid recall reaches the MCP surface); this is the
    /// `-bm25(events_fts)` score from `BrainStore::fts5_search`. Higher
    /// is better.
    pub score: f32,
    /// **Additive (Phase-6 close).** Canonical names of the resolver-
    /// allowlist entities (person / org / location / email / phone / url —
    /// never a redacted token) this hit's event mentions. Empty when the
    /// store has no graph data or the event mentions nothing in the
    /// allowlist. Filled by `BrainStore::entity_names_for_event`.
    pub entities: Vec<String>,
    /// **Additive (Phase-6 close).** The cross-app dot-connect: event ids
    /// reachable from this hit's episode via a `shared_identity`
    /// `episode_edge` (the V2-P6 Consolidator's link). Empty when the hit's
    /// episode has no cross-app link. Filled by
    /// `BrainStore::linked_event_ids_for_event` (post-cascade only).
    pub linked_event_ids: Vec<u64>,
}

/// Errors a [`BrainReader`] may surface to the MCP dispatcher.
#[derive(Debug, Error)]
pub enum BrainReaderError {
    /// Caller violated a precondition (e.g. empty query, zero limit not
    /// allowed for this tool). Mapped to JSON-RPC `INVALID_PARAMS`.
    #[error("brain reader: invalid input: {0}")]
    InvalidInput(String),
    /// The underlying store / FFI failed. Mapped to JSON-RPC server
    /// error code (-32000).
    #[error("brain reader: backend: {0}")]
    Backend(String),
}

/// The trait the MCP server speaks to.
///
/// Read-only by definition — there is no `put_*` or `delete_*` method.
/// Implementors:
/// - `LiveBrainReader` wraps `SqlCipherBrainStore` and performs FTS5
///   lexical recall + the `events_since` / `stats` SELECTs.
/// - `StubBrainReader` (test-only) returns canned data so the JSON-RPC
///   framing can be exercised without a real `mci.sqlite`.
pub trait BrainReader: Send + Sync {
    /// Lexical+(eventually-semantic) recall. P3.10b ships lexical-only
    /// FTS5; the Core ML embedder lands ahead of hybrid recall reaching
    /// this surface.
    fn recall(&self, query: &str, limit: usize) -> Result<Vec<McpHit>, BrainReaderError>;

    /// Timeline cursor: events with `ts_us > since_ts_us`, ascending,
    /// capped at `limit`.
    fn events_since(
        &self,
        since_ts_us: u64,
        limit: usize,
    ) -> Result<Vec<EventRecord>, BrainReaderError>;

    /// Content-free aggregate.
    fn stats(&self) -> Result<BrainStats, BrainReaderError>;

    /// Recent episodes ordered by `ts_start` DESC, capped at `limit`.
    fn episodes(&self, limit: usize) -> Result<Vec<EpisodeRecord>, BrainReaderError>;

    /// Events matching exact `app_bundle_id`, ordered by `ts_us` DESC,
    /// capped at `limit`.
    fn events_by_app(
        &self,
        app_bundle_id: &str,
        limit: usize,
    ) -> Result<Vec<EventRecord>, BrainReaderError>;
}
