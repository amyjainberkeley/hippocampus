//! `LiveBrainReader` — production `BrainReader` backed by
//! `SqlCipherBrainStore`.
//!
//! P3.10d wires the [`HybridRetriever`] into the recall path: when an
//! [`Embedder`] is available, `recall()` runs the full min-max CC fusion
//! (ADR-0010 §5) over FTS5 + semantic hits; when the embedder is `None`
//! (no `.mlpackage` bundled yet, or `MCI_EMBEDDER_DISABLED=1`), the
//! reader falls back to FTS5 lexical-only recall — identical to P3.10b
//! behaviour.
//!
//! # FTS5 query sanitization
//!
//! User queries pass through [`sanitize_fts5_query`] before hitting
//! `events_fts MATCH`. This prevents FTS5 operator characters from
//! causing errors or unexpected results (e.g. hyphens parsed as NOT,
//! which made `"sqlite-vec"` return wrong hits in the demo).
//!
//! # Read-only discipline (P3.10e — ADR-0016 §6 gap closure)
//!
//! The store handle is opened via `SqlCipherBrainStore::open_readonly`
//! which pins `SQLITE_OPEN_READ_ONLY` at the driver level — writes fail
//! with `SQLITE_READONLY` before touching disk. `FtsSanitizingStore`
//! implements `BrainStore` (required by `HybridRetriever`'s type bound)
//! but its `put_event` is `unreachable!` — defence-in-depth atop the
//! driver-level pin.
//!
//! After P3.10e, all four read surfaces (Recall UI + MCP + Brain CLI +
//! Hippocampus.app) use `open_readonly`.

use std::path::Path;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use mci_brain::{
    BrainStats, BrainStore, EmbedError, Embedder, Event, EventId, EventRecord, HybridRetriever,
    RetrievalQuery, Retriever, SqlCipherBrainStore, StoreError,
};
use mci_core::crypto::DbKey;

use crate::mcp::brain_reader::{BrainReader, BrainReaderError, McpHit};

// ---------------------------------------------------------------------------
// DynEmbedder — Sized wrapper for Arc<dyn Embedder>
// ---------------------------------------------------------------------------

/// Sized wrapper around `Arc<dyn Embedder>` so it can be used as the `E`
/// type parameter in `HybridRetriever<S, E>` (which requires `E: Sized`).
///
/// This is the "minimal adaptor" the PR prompt specifies — NOT a new
/// trait method on the core brain crate.
struct DynEmbedder(Arc<dyn Embedder>);

impl Embedder for DynEmbedder {
    fn dimension(&self) -> usize {
        self.0.dimension()
    }
    fn embed_one(&self, text: &str) -> Result<Vec<f32>, EmbedError> {
        self.0.embed_one(text)
    }
    fn embed_batch(&self, texts: &[&str]) -> Result<Vec<Vec<f32>>, EmbedError> {
        self.0.embed_batch(texts)
    }
}

// ---------------------------------------------------------------------------
// FtsSanitizingStore — transparent FTS5 query sanitization
// ---------------------------------------------------------------------------

/// Wrapper that sanitizes FTS5 queries before delegating to the inner
/// store. Used so `HybridRetriever` (which passes raw query text to
/// `fts5_search`) gets safe FTS5 input without modifying the retriever
/// or the embedder's query text.
struct FtsSanitizingStore {
    inner: Arc<SqlCipherBrainStore>,
}

impl BrainStore for FtsSanitizingStore {
    fn put_event(&self, _event: &Event) -> Result<EventId, StoreError> {
        unreachable!("MCP server is read-only (P3.10e — ADR-0016 §6)")
    }
    fn get_event(&self, id: EventId) -> Result<Option<Event>, StoreError> {
        self.inner.get_event(id)
    }
    fn fts5_search(&self, query: &str, limit: usize) -> Result<Vec<(EventId, f32)>, StoreError> {
        let sanitized = sanitize_fts5_query(query);
        if sanitized.is_empty() {
            return Ok(Vec::new());
        }
        self.inner.fts5_search(&sanitized, limit)
    }
    fn vec_search(
        &self,
        query_embedding: &[f32],
        limit: usize,
    ) -> Result<Vec<(EventId, f32)>, StoreError> {
        self.inner.vec_search(query_embedding, limit)
    }
}

// ---------------------------------------------------------------------------
// FTS5 query sanitization
// ---------------------------------------------------------------------------

/// Sanitize a user query for FTS5 MATCH.
///
/// FTS5 interprets `-` as NOT, `*` as wildcard suffix, and `"` as phrase
/// delimiters. User queries from the MCP surface pass through here so
/// special characters don't cause errors or surprising results.
///
/// Strategy: split on whitespace; wrap tokens containing FTS5 operator
/// characters in double quotes so they're treated as literal phrases by
/// the tokenizer. Tokens without special chars pass through unquoted.
///
/// Examples:
/// - `"sqlite-vec"` → `"sqlite-vec"` (quoted; FTS5 tokenizes the phrase
///   content into `["sqlite", "vec"]` via `porter unicode61`)
/// - `"Cure53 audit"` → `Cure53 audit` (no quoting needed)
/// - `"what (was) that"` → `what "was" that` (parens quoted)
pub(crate) fn sanitize_fts5_query(query: &str) -> String {
    query
        .split_whitespace()
        .filter(|t| !t.is_empty())
        .filter_map(|token| {
            if needs_fts5_quoting(token) {
                let clean: String = token.chars().filter(|&c| c != '"').collect();
                if clean.is_empty() {
                    return None;
                }
                Some(format!("\"{clean}\""))
            } else {
                Some(token.to_string())
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn needs_fts5_quoting(token: &str) -> bool {
    token.contains('-')
        || token.contains('*')
        || token.contains('^')
        || token.contains('(')
        || token.contains(')')
        || token.contains('"')
        || token.contains('+')
        || token.contains('~')
}

// ---------------------------------------------------------------------------
// LiveBrainReader
// ---------------------------------------------------------------------------

/// Wraps `SqlCipherBrainStore` + optional `Embedder` and exposes the
/// three `BrainReader` methods only.
pub struct LiveBrainReader {
    store: Arc<SqlCipherBrainStore>,
    embedder: Option<Arc<dyn Embedder>>,
}

impl LiveBrainReader {
    /// Open the brain at `path` with `key`, no embedder (FTS5-only).
    ///
    /// # Errors
    /// Returns `BrainReaderError::Backend` on any store-open failure
    /// (wrong key, missing file, schema migration failure).
    pub fn open(path: &Path, key: &DbKey) -> Result<Self, BrainReaderError> {
        Self::open_with_embedder(path, key, None)
    }

    /// Open the brain with an optional embedder. When `embedder` is
    /// `Some`, `recall()` uses `HybridRetriever` (ADR-0010 min-max CC
    /// fusion). When `None`, falls back to FTS5 lexical-only.
    pub fn open_with_embedder(
        path: &Path,
        key: &DbKey,
        embedder: Option<Arc<dyn Embedder>>,
    ) -> Result<Self, BrainReaderError> {
        let store = SqlCipherBrainStore::open_readonly(path, key)
            .map_err(|e| BrainReaderError::Backend(format!("open store (read-only): {e}")))?;
        Ok(Self {
            store: Arc::new(store),
            embedder,
        })
    }

    /// Construct from an already-opened store, no embedder (FTS5-only).
    #[must_use]
    pub fn from_store(store: Arc<SqlCipherBrainStore>) -> Self {
        Self {
            store,
            embedder: None,
        }
    }

    /// Construct from an already-opened store with an optional embedder.
    #[must_use]
    pub fn from_store_with_embedder(
        store: Arc<SqlCipherBrainStore>,
        embedder: Option<Arc<dyn Embedder>>,
    ) -> Self {
        Self { store, embedder }
    }

    /// FTS5-only recall (Embedder=None fallback).
    fn recall_fts5_only(&self, query: &str, limit: usize) -> Result<Vec<McpHit>, BrainReaderError> {
        let sanitized = sanitize_fts5_query(query);
        if sanitized.is_empty() {
            return Ok(Vec::new());
        }
        let raw = self
            .store
            .fts5_search(&sanitized, limit)
            .map_err(|e| BrainReaderError::Backend(format!("fts5_search: {e}")))?;

        let mut out: Vec<McpHit> = Vec::with_capacity(raw.len());
        for (event_id, score) in raw {
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

    /// Hybrid recall via `HybridRetriever` (ADR-0010 min-max CC fusion).
    ///
    /// Wraps the store in `FtsSanitizingStore` so the retriever's
    /// `fts5_search` calls get sanitized input, while the embedder
    /// receives the raw query text for optimal embedding quality.
    fn recall_hybrid(
        &self,
        query: &str,
        limit: usize,
        embedder: &Arc<dyn Embedder>,
    ) -> Result<Vec<McpHit>, BrainReaderError> {
        #[allow(clippy::cast_possible_truncation)]
        let now_us = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_micros() as u64;

        let sanitizing_store = Arc::new(FtsSanitizingStore {
            inner: Arc::clone(&self.store),
        });
        let dyn_embedder = Arc::new(DynEmbedder(Arc::clone(embedder)));

        let retriever = HybridRetriever::new(sanitizing_store, dyn_embedder, now_us);

        let rq = RetrievalQuery {
            text: query.to_owned(),
            limit,
            time_filter: None,
            app_filter: None,
        };

        let hits = retriever
            .retrieve(&rq)
            .map_err(|e| BrainReaderError::Backend(format!("hybrid retrieve: {e}")))?;

        let mut out: Vec<McpHit> = Vec::with_capacity(hits.len());
        for hit in hits {
            let Some(event) = self
                .store
                .get_event(hit.event_id)
                .map_err(|e| BrainReaderError::Backend(format!("get_event: {e}")))?
            else {
                continue;
            };
            out.push(McpHit {
                record: EventRecord {
                    event_id: hit.event_id,
                    ts_us: event.ts_us,
                    app_bundle_id: event.app_bundle_id,
                    window_title: event.window_title,
                    url: event.url,
                    text_snippet: EventRecord::truncate_snippet(&event.text),
                },
                score: hit.score_combined,
            });
        }
        Ok(out)
    }
}

impl BrainReader for LiveBrainReader {
    fn recall(&self, query: &str, limit: usize) -> Result<Vec<McpHit>, BrainReaderError> {
        if query.trim().is_empty() {
            return Err(BrainReaderError::InvalidInput("empty query".into()));
        }
        match &self.embedder {
            Some(emb) => self.recall_hybrid(query, limit, emb),
            None => self.recall_fts5_only(query, limit),
        }
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

// ---------------------------------------------------------------------------
// Unit tests — sanitizer
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -----------------------------------------------------------------------
    // Read-only invariant tests (P3.10e — ADR-0016 §6)
    // -----------------------------------------------------------------------

    fn make_test_db() -> (tempfile::TempDir, std::path::PathBuf, DbKey) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.sqlite");
        let key = DbKey::from_bytes([0xAA; 32]);
        // Writer opens + applies migration so schema exists.
        let _writer = SqlCipherBrainStore::new(&path, &key).unwrap();
        (dir, path, key)
    }

    #[test]
    fn mcp_reader_opens_readonly_handle() {
        let (_dir, path, key) = make_test_db();
        let reader = LiveBrainReader::open_with_embedder(&path, &key, None);
        assert!(
            reader.is_ok(),
            "open_with_embedder should succeed on existing DB"
        );
        let reader = reader.unwrap();
        let stats = reader.stats().unwrap();
        assert_eq!(stats.event_count, 0);
    }

    #[test]
    fn mcp_server_readonly_handle_rejects_write() {
        let (_dir, path, key) = make_test_db();
        // Open via open_readonly — same path LiveBrainReader now uses.
        let ro_store = SqlCipherBrainStore::open_readonly(&path, &key).unwrap();
        let event = Event {
            id: EventId(0),
            ts_us: 1_000_000,
            app_bundle_id: Some("com.test".into()),
            window_title: Some("Test".into()),
            url: None,
            text: "hello world".into(),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            embedding: None,
        };
        let result = ro_store.put_event(&event);
        assert!(result.is_err(), "put_event on read-only handle must fail");
        let err_msg = format!("{}", result.unwrap_err());
        assert!(
            err_msg.contains("readonly")
                || err_msg.contains("READONLY")
                || err_msg.contains("read-only"),
            "error should indicate read-only rejection, got: {err_msg}"
        );
    }

    #[test]
    #[should_panic(expected = "MCP server is read-only")]
    fn fts_sanitizing_store_put_event_panics() {
        let (_dir, path, key) = make_test_db();
        let store = Arc::new(SqlCipherBrainStore::open_readonly(&path, &key).unwrap());
        let wrapper = FtsSanitizingStore { inner: store };
        let event = Event {
            id: EventId(0),
            ts_us: 1_000_000,
            app_bundle_id: None,
            window_title: None,
            url: None,
            text: "test".into(),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            embedding: None,
        };
        let _ = wrapper.put_event(&event);
    }

    // -----------------------------------------------------------------------
    // Sanitizer tests
    // -----------------------------------------------------------------------

    #[test]
    fn sanitize_plain_words_unchanged() {
        assert_eq!(sanitize_fts5_query("hello world"), "hello world");
    }

    #[test]
    fn sanitize_hyphenated_token_quoted() {
        assert_eq!(sanitize_fts5_query("sqlite-vec"), "\"sqlite-vec\"");
    }

    #[test]
    fn sanitize_mixed_tokens() {
        assert_eq!(
            sanitize_fts5_query("Cure53 sqlite-vec audit"),
            "Cure53 \"sqlite-vec\" audit"
        );
    }

    #[test]
    fn sanitize_embedded_quotes_stripped() {
        assert_eq!(sanitize_fts5_query("he\"llo"), "\"hello\"");
    }

    #[test]
    fn sanitize_only_quotes_dropped() {
        assert_eq!(sanitize_fts5_query("\"\"\""), "");
    }

    #[test]
    fn sanitize_parens_quoted() {
        assert_eq!(sanitize_fts5_query("(test)"), "\"(test)\"");
    }

    #[test]
    fn sanitize_empty_is_empty() {
        assert_eq!(sanitize_fts5_query(""), "");
        assert_eq!(sanitize_fts5_query("   "), "");
    }

    #[test]
    fn sanitize_asterisk_quoted() {
        assert_eq!(sanitize_fts5_query("test*"), "\"test*\"");
    }
}
