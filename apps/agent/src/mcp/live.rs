//! `LiveBrainReader` — production `BrainReader` backed by
//! `SqlCipherBrainStore`.
//!
//! P3.10b ships **lexical-only** FTS5 recall via
//! `BrainStore::fts5_search` — the Core ML on-device embedder (P3.3) +
//! `HybridRetriever` query router (P3.7) extend this to true hybrid
//! recall in a follow-on PR. Lexical FTS5 is still better than nothing
//! for the demo and matches the CLAUDE.md "Embeddings deferred" stance
//! on gbrain.
//!
//! # Read-only discipline
//!
//! This wrapper exposes ONLY the three `BrainReader` methods. It does
//! not surface `BrainStore::put_event`. The store handle is private and
//! the trait impl performs SELECT-only calls.
//!
//! When P3.9b lands a read-only `SqlCipherBrainStore::open_read_only(...)`
//! opener (sqlite `SQLITE_OPEN_READ_ONLY | SQLITE_OPEN_URI`), this
//! reader's constructor swaps to that opener — preserving the trait
//! shape. The CSO sign-off on P3.10b notes this swap is binding.

use std::path::Path;
use std::sync::Arc;

use mci_brain::{BrainStats, BrainStore, EventRecord, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

use crate::mcp::brain_reader::{BrainReader, BrainReaderError, McpHit};

/// Wraps `SqlCipherBrainStore` and exposes the three `BrainReader`
/// methods only.
pub struct LiveBrainReader {
    store: Arc<SqlCipherBrainStore>,
}

impl LiveBrainReader {
    /// Open the brain at `path` with `key`. Wraps
    /// `SqlCipherBrainStore::new` today; swaps to the read-only opener
    /// when P3.9b lands.
    ///
    /// # Errors
    /// Returns `BrainReaderError::Backend` on any store-open failure
    /// (wrong key, missing file, schema migration failure).
    pub fn open(path: &Path, key: &DbKey) -> Result<Self, BrainReaderError> {
        let store = SqlCipherBrainStore::new(path, key)
            .map_err(|e| BrainReaderError::Backend(format!("open store: {e}")))?;
        Ok(Self {
            store: Arc::new(store),
        })
    }

    /// Construct from an already-opened store (used by tests that share
    /// a store between writer + reader fixtures).
    #[must_use]
    pub fn from_store(store: Arc<SqlCipherBrainStore>) -> Self {
        Self { store }
    }
}

impl BrainReader for LiveBrainReader {
    fn recall(&self, query: &str, limit: usize) -> Result<Vec<McpHit>, BrainReaderError> {
        if query.trim().is_empty() {
            return Err(BrainReaderError::InvalidInput("empty query".into()));
        }
        // FTS5 lexical recall — see CLAUDE.md "Embeddings deferred" +
        // module-level doc above. Returns Vec<(EventId, f32)>.
        let raw = self
            .store
            .fts5_search(query, limit)
            .map_err(|e| BrainReaderError::Backend(format!("fts5_search: {e}")))?;

        let mut out: Vec<McpHit> = Vec::with_capacity(raw.len());
        for (event_id, score) in raw {
            // Pull the row content via the existing read-only get_event
            // surface. Skip rows that vanish between FTS5 and get_event
            // (concurrent delete) rather than fail the whole call.
            let Some(event) = self
                .store
                .get_event(event_id)
                .map_err(|e| BrainReaderError::Backend(format!("get_event: {e}")))?
            else {
                continue;
            };
            out.push(McpHit {
                record: EventRecord {
                    event_id,
                    ts_us: event.ts_us,
                    app_bundle_id: event.app_bundle_id,
                    window_title: event.window_title,
                    url: event.url,
                    text_snippet: EventRecord::truncate_snippet(&event.text),
                },
                score,
            });
        }
        Ok(out)
    }

    fn events_since(
        &self,
        since_ts_us: u64,
        limit: usize,
    ) -> Result<Vec<EventRecord>, BrainReaderError> {
        self.store
            .events_since(since_ts_us, limit)
            .map_err(|e| BrainReaderError::Backend(format!("events_since: {e}")))
    }

    fn stats(&self) -> Result<BrainStats, BrainReaderError> {
        self.store
            .stats()
            .map_err(|e| BrainReaderError::Backend(format!("stats: {e}")))
    }
}
