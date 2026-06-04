//! `SqlCipherBrainStore` — the Phase 3 production `BrainStore` impl.
//!
//! Wraps `mci_core::store::open()` (PR #15) to obtain an encrypted
//! `SQLCipher` connection, then runs the brain schema migration (ADR-0016
//! §1.4) on first open. After the migration is in place, the four
//! trait methods (`put_event` / `get_event` / `fts5_search` / `vec_search`)
//! drive an event-centric index with:
//!
//! - Atomic `events` + `event_vectors` + trigger-driven `events_fts` writes
//!   in a single transaction (so a half-indexed event is never observable).
//! - BM25-ranked `events_fts MATCH` over `text + summary + window_title + url`.
//! - Brute-force cosine over `event_vectors.embedding` (a 384×f32 BLOB column).
//!
//! # Why brute-force cosine, not `vec0`?
//!
//! `mci_core::store::open()` deliberately does NOT enable the
//! `rusqlite/load_extension` feature (see `core/src/store/open.rs`
//! module docs — the dlopen ships with the bundled binary in a later
//! cycle). A `CREATE VIRTUAL TABLE … USING vec0(…)` would fail with
//! "no such module: vec0" without the runtime extension. P3.2 stores
//! the 384×f32 L2-normalized embedding as a regular BLOB column and
//! brute-forces cosine in Rust; the `vec_events` mirror over
//! `event_vectors.embedding` lands together with the bundled sqlite-vec
//! binary in a follow-on cycle (the brain schema's `meta` table records
//! `vec_events_mirror = 'deferred'` so the upgrade path is unambiguous).
//! ADR-0011's scaling ladder is unaffected — Phase 3 is well inside the
//! brute-force regime (≪ 10⁶ vectors on a single user's session).
//!
//! # Protected set
//!
//! This file is **protected-set** per `AGENT_PROTOCOL` §5 — it writes to
//! the `mci.sqlite` store and wraps the at-rest crypto seam. The CSO
//! sign-off block on PR P3.2 asserts the ADR-0008 + ADR-0016 §4
//! invariants in source (see the PR body).

use std::path::Path;
use std::sync::Mutex;

use crate::alias_resolver::{ResolverEntity, RESOLVABLE_KINDS};
use crate::episode_segmenter::EpisodeId;
use crate::graph::{Entity, EntityId, EntityIdentity, EntityIdentityId, EntityMention, EpisodeEdge, IdentityId};
use mci_core::crypto::DbKey;
use mci_core::store::{
    open as mci_core_open, open_readonly as mci_core_open_readonly, Db,
    StoreError as CoreStoreError,
};
use rusqlite::{params, params_from_iter};

use crate::{BrainStats, Event, EventId, EventRecord, ResolutionWatermark, StoreError};

/// Phase 3 production `BrainStore`.
///
/// Holds one writer connection inside a `Mutex` so the producer side of
/// the pipeline can `put_event` from any thread without callers needing
/// to thread `&mut`. ADR-0008 §1.4's "one file, one writer" discipline is
/// preserved at this level — the agent process owns exactly one
/// `SqlCipherBrainStore`; recall-UI / agent-API readers open separate
/// read-only connections via a different ctor (P3.9 / P3.10).
///
/// The inner type is `mci_core::store::Db`, not a raw `rusqlite::Connection`,
/// so that the encryption + WAL + `foreign_keys` setup mci-core baked into
/// `open()` (ADR-0008 protected-set code) is reused exactly. mci-brain
/// never reimplements `PRAGMA key` or the wrong-key probe; we inherit it.
pub struct SqlCipherBrainStore {
    pub(crate) db: Mutex<Db>,
}

impl SqlCipherBrainStore {
    /// Open (or create) the encrypted brain store at `path` with `key`.
    ///
    /// Wraps `mci_core::store::open` for the encryption + WAL +
    /// `foreign_keys` set-up; on a fresh DB also runs the Phase 3 brain
    /// migration (ADR-0016 §1.4). On a previously-initialized DB the
    /// migration is a no-op — every `CREATE TABLE` / `CREATE INDEX` /
    /// `CREATE TRIGGER` carries `IF NOT EXISTS` so re-running is safe;
    /// the `INSERT OR REPLACE INTO meta` stamps are idempotent by key.
    ///
    /// # Errors
    /// - [`StoreError::Backend`] for any `mci_core::store::open` failure
    ///   (wrapped to preserve the brain trait's error surface).
    /// - [`StoreError::Backend`] if the migration DDL fails.
    pub fn new(path: &Path, key: &DbKey) -> Result<Self, StoreError> {
        let mut db = mci_core_open(path, key).map_err(|e| map_core_err(&e))?;
        run_brain_migration(&mut db)?;
        Ok(Self { db: Mutex::new(db) })
    }

    /// Open the brain store at `path` with `key` in **READ-ONLY** mode for
    /// consumers that must never mutate the brain (the recall UI through
    /// `adapters/macos/mci-brain-ffi`, the agent-API loopback `mcp-serve`
    /// subcommand from P3.10b).
    ///
    /// Wraps [`mci_core::store::open_readonly`] (PR P3.9b extension), which
    /// opens the underlying `SQLite` handle with `SQLITE_OPEN_READ_ONLY |
    /// SQLITE_OPEN_NO_MUTEX | SQLITE_OPEN_URI`. The migration is **NOT**
    /// run — a read-only handle cannot apply DDL anyway, and the production
    /// agent (writer-side) is expected to have applied the brain schema
    /// first via [`SqlCipherBrainStore::new`]. Calling `put_event` on a
    /// store constructed this way fails at the driver level with
    /// `SQLITE_READONLY` (the CSO invariant in ADR-0017 §5 / ADR-0016 §4.3
    /// that the recall UI cannot tamper with the brain).
    ///
    /// # Errors
    /// - [`StoreError::Backend`] for driver-level open failures (missing
    ///   file, EPERM, etc.) — wraps `mci_core::store::open_readonly`.
    /// - [`StoreError::Backend`] for wrong-key / not-an-MCI-database
    ///   (the inner error is intentionally indistinguishable per ADR-0008).
    pub fn open_readonly(path: &Path, key: &DbKey) -> Result<Self, StoreError> {
        let db = mci_core_open_readonly(path, key).map_err(|e| map_core_err(&e))?;
        Ok(Self { db: Mutex::new(db) })
    }

    /// Read the N most-recent events ordered by `ts_us` DESC.
    ///
    /// Used by the recall UI's timeline view via the FFI shim. The
    /// `embedding` field on each returned [`Event`] is `None` — the
    /// timeline only needs metadata + snippet text. Vector data is opened
    /// lazily by [`BrainStore::vec_search`] / [`BrainStore::get_event`].
    ///
    /// # Errors
    /// [`StoreError::Backend`] for any underlying `SQLite` failure.
    pub fn recent_events(&self, limit: usize) -> Result<Vec<Event>, StoreError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare(
                "SELECT id, ts_us, app_bundle_id, window_title, url,
                        text, summary, entities, episode_id,
                        cascade_reason, keyframe_blob, tab_id
                 FROM events
                 ORDER BY ts_us DESC
                 LIMIT ?1",
            )
            .map_err(|e| StoreError::Backend(format!("prepare recent_events: {e}")))?;
        let lim = i64::try_from(limit).unwrap_or(i64::MAX);
        let rows = stmt
            .query_map(params![lim], row_to_event_tuple)
            .map_err(|e| StoreError::Backend(format!("query recent_events: {e}")))?;
        let mut out: Vec<Event> = Vec::new();
        for r in rows {
            let (
                ev_id,
                ts_us,
                app,
                title,
                url,
                text,
                summary,
                entities,
                episode_id,
                cascade_reason,
                keyframe_blob,
                tab_id,
            ) = r.map_err(|e| StoreError::Backend(format!("row recent_events: {e}")))?;
            out.push(Event {
                id: EventId(u64::try_from(ev_id).unwrap_or(0)),
                ts_us: u64::try_from(ts_us).unwrap_or(0),
                app_bundle_id: app,
                window_title: title,
                url,
                text,
                summary,
                entities,
                episode_id: episode_id.map(|v| u64::try_from(v).unwrap_or(0)),
                cascade_reason,
                keyframe_blob,
                tab_id: tab_id.and_then(|v| u32::try_from(v).ok()),
                embedding: None,
            });
        }
        Ok(out)
    }

    /// Read-only timeline cursor: events with `ts_us > since_ts_us`, ordered
    /// by `ts_us` ascending, capped at `limit`. SELECT-only — no write side.
    ///
    /// Surface for the agent-API loopback (`mci_events_since` MCP tool,
    /// P3.10b) and the recall-UI timeline view (P3.9/P4.7). The `text`
    /// column is truncated to [`EventRecord::SNIPPET_MAX_CHARS`] on a
    /// UTF-8 boundary so a "give me the last 100 events" call cannot
    /// page hundreds of KB through the local socket.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any rusqlite failure. `limit == 0`
    /// returns `Ok(Vec::new())` without touching `SQLite`.
    pub fn events_since(
        &self,
        since_ts_us: u64,
        limit: usize,
    ) -> Result<Vec<EventRecord>, StoreError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let since = i64::try_from(since_ts_us).unwrap_or(i64::MAX);
        let lim = i64::try_from(limit).unwrap_or(i64::MAX);
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare(
                "SELECT id, ts_us, app_bundle_id, window_title, url, text
                 FROM events
                 WHERE ts_us > ?1
                 ORDER BY ts_us ASC
                 LIMIT ?2",
            )
            .map_err(|e| StoreError::Backend(format!("prepare events_since: {e}")))?;
        let rows = stmt
            .query_map(params![since, lim], |r| {
                let id: i64 = r.get(0)?;
                let ts_us: i64 = r.get(1)?;
                let app: Option<String> = r.get(2)?;
                let title: Option<String> = r.get(3)?;
                let url: Option<String> = r.get(4)?;
                let text: String = r.get(5)?;
                Ok((id, ts_us, app, title, url, text))
            })
            .map_err(|e| StoreError::Backend(format!("query events_since: {e}")))?;
        let mut out: Vec<EventRecord> = Vec::new();
        for r in rows {
            let (id, ts_us, app, title, url, text) =
                r.map_err(|e| StoreError::Backend(format!("row events_since: {e}")))?;
            out.push(EventRecord {
                event_id: EventId(u64::try_from(id).unwrap_or(0)),
                ts_us: u64::try_from(ts_us).unwrap_or(0),
                app_bundle_id: app,
                window_title: title,
                url,
                text_snippet: EventRecord::truncate_snippet(&text),
            });
        }
        Ok(out)
    }

    /// Content-free aggregate counts. SELECT-only — no write side.
    ///
    /// Surface for the agent-API loopback (`mci_stats` MCP tool, P3.10b)
    /// so a local agent can know "how much memory is available" without
    /// reading any row content. Returns `(0, None, None)` on an empty
    /// store.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any rusqlite failure.
    pub fn stats(&self) -> Result<BrainStats, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        // One query — COUNT + MIN + MAX over the same scan.
        let row = guard
            .conn()
            .query_row(
                "SELECT COUNT(*), MIN(ts_us), MAX(ts_us) FROM events",
                [],
                |r| {
                    let count: i64 = r.get(0)?;
                    let min_ts: Option<i64> = r.get(1)?;
                    let max_ts: Option<i64> = r.get(2)?;
                    Ok((count, min_ts, max_ts))
                },
            )
            .map_err(|e| StoreError::Backend(format!("query stats: {e}")))?;
        let (count, min_ts, max_ts) = row;
        Ok(BrainStats {
            event_count: u64::try_from(count).unwrap_or(0),
            oldest_ts_us: min_ts.map(|v| u64::try_from(v).unwrap_or(0)),
            newest_ts_us: max_ts.map(|v| u64::try_from(v).unwrap_or(0)),
        })
    }

    /// Return up to `limit` events that have no row in `event_vectors`.
    ///
    /// The idle-batch embedder polls this to find work. Uses a LEFT JOIN
    /// anti-pattern (`WHERE ev.event_id IS NULL`) rather than `NOT IN`
    /// for `SQLite` query-planner friendliness on large tables.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any underlying `SQLite` failure.
    pub fn unembedded_events(&self, limit: usize) -> Result<Vec<Event>, StoreError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare(
                "SELECT e.id, e.ts_us, e.app_bundle_id, e.window_title, e.url,
                        e.text, e.summary, e.entities, e.episode_id,
                        e.cascade_reason, e.keyframe_blob, e.tab_id
                 FROM events e
                 LEFT JOIN event_vectors ev ON ev.event_id = e.id
                 WHERE ev.event_id IS NULL
                 ORDER BY e.ts_us ASC
                 LIMIT ?1",
            )
            .map_err(|e| StoreError::Backend(format!("prepare unembedded_events: {e}")))?;
        let lim = i64::try_from(limit).unwrap_or(i64::MAX);
        let rows = stmt
            .query_map(params![lim], row_to_event_tuple)
            .map_err(|e| StoreError::Backend(format!("query unembedded_events: {e}")))?;
        let mut out: Vec<Event> = Vec::new();
        for r in rows {
            let (
                ev_id,
                ts_us,
                app,
                title,
                url,
                text,
                summary,
                entities,
                episode_id,
                cascade_reason,
                keyframe_blob,
                tab_id,
            ) = r.map_err(|e| StoreError::Backend(format!("row unembedded_events: {e}")))?;
            out.push(Event {
                id: EventId(u64::try_from(ev_id).unwrap_or(0)),
                ts_us: u64::try_from(ts_us).unwrap_or(0),
                app_bundle_id: app,
                window_title: title,
                url,
                text,
                summary,
                entities,
                episode_id: episode_id.map(|v| u64::try_from(v).unwrap_or(0)),
                cascade_reason,
                keyframe_blob,
                tab_id: tab_id.and_then(|v| u32::try_from(v).ok()),
                embedding: None,
            });
        }
        Ok(out)
    }

    /// Return events that have not yet been scanned by the V2-P5 Tier 2
    /// Qwen NER pass, ordered by `events.id ASC`, capped at `limit`.
    ///
    /// Inverse of the sentinel `(extractor_status, qwen_tier2_processed)`
    /// mention written by
    /// [`mark_event_tier2_processed`](crate::mark_event_tier2_processed).
    /// Same LEFT-JOIN anti-pattern as [`Self::unembedded_events`] for
    /// SQLite query-planner friendliness on large `entity_mentions`
    /// tables.
    ///
    /// The idle-batch worker (`apps/agent/src/tier2_worker.rs`) polls
    /// this to find work. Sentinel mention guarantees an event whose
    /// NER output is empty is still marked "done" and not re-scanned
    /// every cycle.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any underlying `SQLite` failure.
    pub fn events_pending_tier2(&self, limit: usize) -> Result<Vec<Event>, StoreError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let guard = self.db.lock().expect("brain store mutex poisoned");
        // The sentinel entity has a deterministic content-stable ULID
        // derived from `("extractor_status", "qwen_tier2_processed")`.
        // We materialise it via the `extraction::tier2` module's
        // `Entity::derive_id` to keep the value in lock-step with the
        // writer (no risk of a typo in the SQL literal here drifting
        // from the constant in `tier2.rs`).
        let sentinel_id = crate::graph::Entity::derive_id(
            crate::extraction::tier2::SENTINEL_KIND,
            crate::extraction::tier2::SENTINEL_NAME,
        );
        let sentinel_id_str = sentinel_id.0;
        let mut stmt = guard
            .conn()
            .prepare(
                "SELECT e.id, e.ts_us, e.app_bundle_id, e.window_title, e.url,
                        e.text, e.summary, e.entities, e.episode_id,
                        e.cascade_reason, e.keyframe_blob, e.tab_id
                 FROM events e
                 LEFT JOIN entity_mentions m
                   ON m.event_id = e.id
                   AND m.entity_id = ?1
                 WHERE m.event_id IS NULL
                 ORDER BY e.id ASC
                 LIMIT ?2",
            )
            .map_err(|e| StoreError::Backend(format!("prepare events_pending_tier2: {e}")))?;
        let lim = i64::try_from(limit).unwrap_or(i64::MAX);
        let rows = stmt
            .query_map(params![sentinel_id_str, lim], row_to_event_tuple)
            .map_err(|e| StoreError::Backend(format!("query events_pending_tier2: {e}")))?;
        let mut out: Vec<Event> = Vec::new();
        for r in rows {
            let (
                ev_id,
                ts_us,
                app,
                title,
                url,
                text,
                summary,
                entities,
                episode_id,
                cascade_reason,
                keyframe_blob,
                tab_id,
            ) = r.map_err(|e| StoreError::Backend(format!("row events_pending_tier2: {e}")))?;
            out.push(Event {
                id: EventId(u64::try_from(ev_id).unwrap_or(0)),
                ts_us: u64::try_from(ts_us).unwrap_or(0),
                app_bundle_id: app,
                window_title: title,
                url,
                text,
                summary,
                entities,
                episode_id: episode_id.map(|v| u64::try_from(v).unwrap_or(0)),
                cascade_reason,
                keyframe_blob,
                tab_id: tab_id.and_then(|v| u32::try_from(v).ok()),
                embedding: None,
            });
        }
        Ok(out)
    }

    /// Paginated full-column cursor: events strictly AFTER `(ts_us, after_id)`
    /// ordered by `(ts_us ASC, id ASC)`, capped at `limit`.
    ///
    /// Handles timestamp ties by breaking on `id` — the cursor is stable
    /// across calls even when multiple events share the same `ts_us`.
    /// When `after_id` is `None`, returns events with `ts_us > ts_us_cursor`
    /// (first page of an export starting at a given timestamp).
    ///
    /// Returns full [`Event`] rows (embedding = `None`; callers wanting
    /// vectors should use [`BrainStore::get_event`] per-id). Replaces the
    /// N+1 pattern the export subcommand previously used
    /// (`events_since` → `get_event` per row).
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any underlying `SQLite` failure.
    pub fn paged_events_since(
        &self,
        ts_us_cursor: u64,
        after_id: Option<EventId>,
        limit: usize,
    ) -> Result<Vec<Event>, StoreError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let ts = i64::try_from(ts_us_cursor).unwrap_or(i64::MAX);
        let aid = after_id.map_or(0_i64, |eid| i64::try_from(eid.0).unwrap_or(0));
        let lim = i64::try_from(limit).unwrap_or(i64::MAX);
        let guard = self.db.lock().expect("brain store mutex poisoned");

        let mut stmt = guard
            .conn()
            .prepare(if after_id.is_some() {
                "SELECT id, ts_us, app_bundle_id, window_title, url,
                        text, summary, entities, episode_id,
                        cascade_reason, keyframe_blob, tab_id
                 FROM events
                 WHERE ts_us > ?1 OR (ts_us = ?1 AND id > ?2)
                 ORDER BY ts_us ASC, id ASC
                 LIMIT ?3"
            } else {
                "SELECT id, ts_us, app_bundle_id, window_title, url,
                        text, summary, entities, episode_id,
                        cascade_reason, keyframe_blob, tab_id
                 FROM events
                 WHERE ts_us > ?1
                 ORDER BY ts_us ASC, id ASC
                 LIMIT ?2"
            })
            .map_err(|e| StoreError::Backend(format!("prepare paged_events_since: {e}")))?;

        let rows = if after_id.is_some() {
            stmt.query_map(params![ts, aid, lim], row_to_event_tuple)
                .map_err(|e| StoreError::Backend(format!("query paged_events_since: {e}")))?
        } else {
            stmt.query_map(params![ts, lim], row_to_event_tuple)
                .map_err(|e| StoreError::Backend(format!("query paged_events_since: {e}")))?
        };

        let mut out: Vec<Event> = Vec::new();
        for r in rows {
            let (
                ev_id,
                ts_us,
                app,
                title,
                url,
                text,
                summary,
                entities,
                episode_id,
                cascade_reason,
                keyframe_blob,
                tab_id,
            ) = r.map_err(|e| StoreError::Backend(format!("row paged_events_since: {e}")))?;
            out.push(Event {
                id: EventId(u64::try_from(ev_id).unwrap_or(0)),
                ts_us: u64::try_from(ts_us).unwrap_or(0),
                app_bundle_id: app,
                window_title: title,
                url,
                text,
                summary,
                entities,
                episode_id: episode_id.map(|v| u64::try_from(v).unwrap_or(0)),
                cascade_reason,
                keyframe_blob,
                tab_id: tab_id.and_then(|v| u32::try_from(v).ok()),
                embedding: None,
            });
        }
        Ok(out)
    }

    /// Write an embedding for an existing event into `event_vectors`.
    ///
    /// The idle-batch worker calls this after embedding an event's text.
    /// Only writes to `event_vectors` — never touches the `events` row
    /// (ADR-0016 §4.2 cascade-twice: no new write path into events).
    ///
    /// # Errors
    /// - [`StoreError::InvalidInput`] if `embedding.len() != 384` (ADR-0009).
    /// - [`StoreError::Backend`] on `SQLite` failure (including UNIQUE
    ///   constraint violation if the event already has a vector).
    pub fn set_event_embedding(&self, id: EventId, embedding: &[f32]) -> Result<(), StoreError> {
        if embedding.len() != EMBEDDING_DIM {
            return Err(StoreError::InvalidInput(format!(
                "embedding dimension must be {} (ADR-0009), got {}",
                EMBEDDING_DIM,
                embedding.len()
            )));
        }
        let row_id = i64::try_from(id.0).map_err(|e| {
            StoreError::InvalidInput(format!("event id {} out of i64 range: {e}", id.0))
        })?;
        let blob = embedding_to_blob(embedding);
        debug_assert_eq!(blob.len(), EMBEDDING_BYTES);

        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|e| StoreError::Backend(format!("begin set_event_embedding tx: {e}")))?;
        tx.execute(
            "INSERT INTO event_vectors (event_id, embedding) VALUES (?1, ?2)",
            params![row_id, blob],
        )
        .map_err(|e| StoreError::Backend(format!("INSERT event_vectors: {e}")))?;
        tx.commit()
            .map_err(|e| StoreError::Backend(format!("commit set_event_embedding tx: {e}")))?;
        Ok(())
    }

    /// Return up to `limit` events where `episode_id IS NULL`, ordered
    /// by `ts_us` ASC.
    ///
    /// The episode-segmenter worker polls this to find work.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any underlying `SQLite` failure.
    pub fn unsegmented_events(&self, limit: usize) -> Result<Vec<Event>, StoreError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare(
                "SELECT id, ts_us, app_bundle_id, window_title, url,
                        text, summary, entities, episode_id,
                        cascade_reason, keyframe_blob, tab_id
                 FROM events
                 WHERE episode_id IS NULL
                 ORDER BY ts_us ASC
                 LIMIT ?1",
            )
            .map_err(|e| StoreError::Backend(format!("prepare unsegmented_events: {e}")))?;
        let lim = i64::try_from(limit).unwrap_or(i64::MAX);
        let rows = stmt
            .query_map(params![lim], row_to_event_tuple)
            .map_err(|e| StoreError::Backend(format!("query unsegmented_events: {e}")))?;
        let mut out: Vec<Event> = Vec::new();
        for r in rows {
            let (
                ev_id,
                ts_us,
                app,
                title,
                url,
                text,
                summary,
                entities,
                episode_id,
                cascade_reason,
                keyframe_blob,
                tab_id,
            ) = r.map_err(|e| StoreError::Backend(format!("row unsegmented_events: {e}")))?;
            out.push(Event {
                id: EventId(u64::try_from(ev_id).unwrap_or(0)),
                ts_us: u64::try_from(ts_us).unwrap_or(0),
                app_bundle_id: app,
                window_title: title,
                url,
                text,
                summary,
                entities,
                episode_id: episode_id.map(|v| u64::try_from(v).unwrap_or(0)),
                cascade_reason,
                keyframe_blob,
                tab_id: tab_id.and_then(|v| u32::try_from(v).ok()),
                embedding: None,
            });
        }
        Ok(out)
    }

    /// Return the most-recent event that already has an `episode_id`,
    /// ordered by `ts_us DESC LIMIT 1`. Used by the episode-segmenter
    /// worker for continuity across batches.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any underlying `SQLite` failure.
    pub fn last_segmented_event(&self) -> Result<Option<Event>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let row: Option<EventRow> = guard
            .conn()
            .query_row(
                "SELECT id, ts_us, app_bundle_id, window_title, url,
                        text, summary, entities, episode_id,
                        cascade_reason, keyframe_blob, tab_id
                 FROM events
                 WHERE episode_id IS NOT NULL
                 ORDER BY ts_us DESC
                 LIMIT 1",
                [],
                row_to_event_tuple,
            )
            .map(Some)
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(StoreError::Backend(format!(
                    "SELECT last_segmented_event: {other}"
                ))),
            })?;

        let Some((
            ev_id,
            ts_us,
            app,
            title,
            url,
            text,
            summary,
            entities,
            episode_id,
            cascade_reason,
            keyframe_blob,
            tab_id,
        )) = row
        else {
            return Ok(None);
        };

        Ok(Some(Event {
            id: EventId(u64::try_from(ev_id).unwrap_or(0)),
            ts_us: u64::try_from(ts_us).unwrap_or(0),
            app_bundle_id: app,
            window_title: title,
            url,
            text,
            summary,
            entities,
            episode_id: episode_id.map(|v| u64::try_from(v).unwrap_or(0)),
            cascade_reason,
            keyframe_blob,
            tab_id: tab_id.and_then(|v| u32::try_from(v).ok()),
            embedding: None,
        }))
    }

    /// Return up to `limit` episodes ordered by `ts_start` DESC, with a
    /// derived `event_count` per episode. SELECT-only — no write side.
    ///
    /// Surface for the `mci_episodes` MCP tool. The correlated subquery is
    /// O(episodes × events_per_episode) which is fine inside Phase 3's
    /// corpus regime; the `events_episode` index covers it.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any underlying `SQLite` failure.
    pub fn recent_episodes(
        &self,
        limit: usize,
    ) -> Result<Vec<crate::EpisodeRecord>, StoreError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare(
                "SELECT e.id, e.app_bundle_id, e.ts_start, e.ts_end,
                        (SELECT COUNT(*) FROM events ev WHERE ev.episode_id = e.id) AS event_count
                 FROM episodes e
                 ORDER BY e.ts_start DESC
                 LIMIT ?1",
            )
            .map_err(|e| StoreError::Backend(format!("prepare recent_episodes: {e}")))?;
        let lim = i64::try_from(limit).unwrap_or(i64::MAX);
        let rows = stmt
            .query_map(params![lim], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, Option<String>>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, i64>(4)?,
                ))
            })
            .map_err(|e| StoreError::Backend(format!("query recent_episodes: {e}")))?;
        let mut out = Vec::new();
        for r in rows {
            let (id, app, ts_start, ts_end, event_count) =
                r.map_err(|e| StoreError::Backend(format!("row recent_episodes: {e}")))?;
            out.push(crate::EpisodeRecord {
                id: u64::try_from(id).unwrap_or(0),
                app_bundle_id: app,
                ts_start: u64::try_from(ts_start).unwrap_or(0),
                ts_end: u64::try_from(ts_end).unwrap_or(0),
                event_count: u64::try_from(event_count).unwrap_or(0),
            });
        }
        Ok(out)
    }

    /// Return up to `limit` events matching exact `app_bundle_id`, ordered
    /// by `ts_us` DESC. SELECT-only — no write side.
    ///
    /// Surface for the `mci_events_by_app` MCP tool. Uses the
    /// `events_app` index for efficient lookup.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any underlying `SQLite` failure.
    pub fn events_by_app_bundle_id(
        &self,
        app_bundle_id: &str,
        limit: usize,
    ) -> Result<Vec<EventRecord>, StoreError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let lim = i64::try_from(limit).unwrap_or(i64::MAX);
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare(
                "SELECT id, ts_us, app_bundle_id, window_title, url, text
                 FROM events
                 WHERE app_bundle_id = ?1
                 ORDER BY ts_us DESC
                 LIMIT ?2",
            )
            .map_err(|e| StoreError::Backend(format!("prepare events_by_app: {e}")))?;
        let rows = stmt
            .query_map(params![app_bundle_id, lim], |r| {
                let id: i64 = r.get(0)?;
                let ts_us: i64 = r.get(1)?;
                let app: Option<String> = r.get(2)?;
                let title: Option<String> = r.get(3)?;
                let url: Option<String> = r.get(4)?;
                let text: String = r.get(5)?;
                Ok((id, ts_us, app, title, url, text))
            })
            .map_err(|e| StoreError::Backend(format!("query events_by_app: {e}")))?;
        let mut out = Vec::new();
        for r in rows {
            let (id, ts_us, app, title, url, text) =
                r.map_err(|e| StoreError::Backend(format!("row events_by_app: {e}")))?;
            out.push(EventRecord {
                event_id: EventId(u64::try_from(id).unwrap_or(0)),
                ts_us: u64::try_from(ts_us).unwrap_or(0),
                app_bundle_id: app,
                window_title: title,
                url,
                text_snippet: EventRecord::truncate_snippet(&text),
            });
        }
        Ok(out)
    }

    /// Return the most-observed `app_bundle_id` values with their event
    /// counts, optionally bounded by a time window. Sorted by count DESC.
    /// SELECT-only — no write side. Rows with `app_bundle_id IS NULL` are
    /// excluded so the recall-UI filter pills never carry an unnamed entry.
    ///
    /// Surface for the recall-UI's dynamic per-app filter pills (`Director-
    /// Brain` audit, dogfood-v1 gap #1). Counts come from the `events` table
    /// (post-cascade only — suppressed events never reach the store, per
    /// ADR-0016 §4.3), so the result is content-free aggregate metadata.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any underlying `SQLite` failure.
    pub fn observed_apps(
        &self,
        limit: usize,
        time_from_us: Option<u64>,
    ) -> Result<Vec<(String, u64)>, StoreError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let lim = i64::try_from(limit).unwrap_or(i64::MAX);
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let (sql, has_from) = if time_from_us.is_some() {
            (
                "SELECT app_bundle_id, COUNT(*) AS n
                 FROM events
                 WHERE app_bundle_id IS NOT NULL
                   AND ts_us >= ?1
                 GROUP BY app_bundle_id
                 ORDER BY n DESC, app_bundle_id ASC
                 LIMIT ?2",
                true,
            )
        } else {
            (
                "SELECT app_bundle_id, COUNT(*) AS n
                 FROM events
                 WHERE app_bundle_id IS NOT NULL
                 GROUP BY app_bundle_id
                 ORDER BY n DESC, app_bundle_id ASC
                 LIMIT ?1",
                false,
            )
        };
        let mut stmt = guard
            .conn()
            .prepare(sql)
            .map_err(|e| StoreError::Backend(format!("prepare observed_apps: {e}")))?;
        let row_mapper = |r: &rusqlite::Row<'_>| -> rusqlite::Result<(String, i64)> {
            let app: String = r.get(0)?;
            let n: i64 = r.get(1)?;
            Ok((app, n))
        };
        let mut out: Vec<(String, u64)> = Vec::new();
        if has_from {
            let from = i64::try_from(time_from_us.unwrap()).unwrap_or(0);
            let rows = stmt
                .query_map(params![from, lim], row_mapper)
                .map_err(|e| StoreError::Backend(format!("query observed_apps: {e}")))?;
            for r in rows {
                let (app, n) =
                    r.map_err(|e| StoreError::Backend(format!("row observed_apps: {e}")))?;
                out.push((app, u64::try_from(n).unwrap_or(0)));
            }
        } else {
            let rows = stmt
                .query_map(params![lim], row_mapper)
                .map_err(|e| StoreError::Backend(format!("query observed_apps: {e}")))?;
            for r in rows {
                let (app, n) =
                    r.map_err(|e| StoreError::Backend(format!("row observed_apps: {e}")))?;
                out.push((app, u64::try_from(n).unwrap_or(0)));
            }
        }
        Ok(out)
    }

    /// Copy + defragment the encrypted brain to `dest` via `VACUUM INTO`.
    /// Output inherits this store's `SQLCipher` key.
    ///
    /// # Errors
    /// - [`StoreError::Backend`] if `VACUUM INTO` fails (disk full, dest
    ///   exists, permission denied, etc.).
    pub fn vacuum_into(&self, dest: &std::path::Path) -> Result<(), StoreError> {
        let dest_str = dest.to_str().ok_or_else(|| {
            StoreError::InvalidInput("destination path is not valid UTF-8".into())
        })?;
        let guard = self.db.lock().expect("brain store mutex poisoned");
        guard
            .conn()
            .execute(
                &format!("VACUUM INTO '{}'", dest_str.replace('\'', "''")),
                [],
            )
            .map_err(|e| StoreError::Backend(format!("VACUUM INTO: {e}")))?;
        Ok(())
    }

    // -------------------------------------------------------------------
    // Daily Brief storage (migration 0002, see brief-viewer-spec.md)
    // -------------------------------------------------------------------

    /// Upsert a daily brief keyed on `date_local`. Returns the row's id.
    ///
    /// Semantics: `INSERT OR REPLACE` on the UNIQUE(`date_local`) index.
    /// Regenerating the brief for the same local day overwrites the row.
    /// The row id is stable across regenerates because SQLite reuses the
    /// primary key on REPLACE only when the conflicting row was already
    /// the primary-key target — here the conflict is on a UNIQUE index,
    /// not the PK, so SQLite deletes the conflicting row and inserts a
    /// fresh one. Callers that hold a brief id across a regenerate should
    /// re-look-up by `date_local` after writing.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any rusqlite failure.
    pub fn put_brief(&self, brief: &crate::BriefRow) -> Result<u64, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let generated_i64 = i64::try_from(brief.generated_ts_us).unwrap_or(i64::MAX);
        let word_count_i64 = i64::try_from(brief.word_count).unwrap_or(0);
        let src_count_i64 = i64::try_from(brief.source_event_count).unwrap_or(0);
        guard
            .conn()
            .execute(
                "INSERT OR REPLACE INTO briefs
                    (date_local, generated_ts_us, model_id, model_version,
                     title, body, word_count, source_event_count)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    brief.date_local,
                    generated_i64,
                    brief.model_id,
                    brief.model_version,
                    brief.title,
                    brief.body,
                    word_count_i64,
                    src_count_i64,
                ],
            )
            .map_err(|e| StoreError::Backend(format!("put_brief: {e}")))?;
        let id_i64 = guard
            .conn()
            .last_insert_rowid();
        Ok(u64::try_from(id_i64).unwrap_or(0))
    }

    /// Look up the brief for one local date. `Ok(None)` if absent.
    pub fn brief_for_date(&self, date_local: &str)
        -> Result<Option<crate::BriefRow>, StoreError>
    {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let row_opt = guard
            .conn()
            .query_row(
                "SELECT id, date_local, generated_ts_us, model_id, model_version,
                        title, body, word_count, source_event_count
                 FROM briefs
                 WHERE date_local = ?1",
                params![date_local],
                row_to_brief,
            )
            .map(Some)
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok::<_, StoreError>(None),
                other => Err(StoreError::Backend(format!("brief_for_date: {other}"))),
            })?;
        Ok(row_opt)
    }

    /// Return the most-recently-generated brief, or `None` if the table is
    /// empty. Used for the Recall UI's "latest brief" default and for the
    /// first-brief notification check.
    pub fn latest_brief(&self) -> Result<Option<crate::BriefRow>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let row_opt = guard
            .conn()
            .query_row(
                "SELECT id, date_local, generated_ts_us, model_id, model_version,
                        title, body, word_count, source_event_count
                 FROM briefs
                 ORDER BY generated_ts_us DESC
                 LIMIT 1",
                [],
                row_to_brief,
            )
            .map(Some)
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok::<_, StoreError>(None),
                other => Err(StoreError::Backend(format!("latest_brief: {other}"))),
            })?;
        Ok(row_opt)
    }

    /// List the `date_local` strings of up to `limit` briefs, ordered most
    /// recent first. Powers the Recall UI's `<` / `>` date selector.
    pub fn brief_dates(&self, limit: usize) -> Result<Vec<String>, StoreError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let lim = i64::try_from(limit).unwrap_or(i64::MAX);
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare(
                "SELECT date_local FROM briefs
                 ORDER BY date_local DESC
                 LIMIT ?1",
            )
            .map_err(|e| StoreError::Backend(format!("prepare brief_dates: {e}")))?;
        let rows = stmt
            .query_map(params![lim], |r| r.get::<_, String>(0))
            .map_err(|e| StoreError::Backend(format!("query brief_dates: {e}")))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r.map_err(|e| StoreError::Backend(format!("row brief_dates: {e}")))?);
        }
        Ok(out)
    }

    /// Count of briefs in the store. Content-free aggregate. Used by tests
    /// + a future "Brain stats" panel.
    pub fn brief_count(&self) -> Result<u64, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let n: i64 = guard
            .conn()
            .query_row("SELECT COUNT(*) FROM briefs", [], |r| r.get(0))
            .map_err(|e| StoreError::Backend(format!("brief_count: {e}")))?;
        Ok(u64::try_from(n).unwrap_or(0))
    }

    /// Run `PRAGMA integrity_check` and return result lines.
    /// Healthy DB returns `["ok"]`; any other content indicates corruption.
    pub fn integrity_check(&self) -> Result<Vec<String>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare("PRAGMA integrity_check")
            .map_err(|e| StoreError::Backend(format!("prepare integrity_check: {e}")))?;
        let rows = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(|e| StoreError::Backend(format!("query integrity_check: {e}")))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r.map_err(|e| StoreError::Backend(format!("row integrity_check: {e}")))?);
        }
        Ok(out)
    }
}

/// Schema migration — ADR-0016 §1.4. Idempotent: every `CREATE` is
/// `IF NOT EXISTS`, every meta stamp is `INSERT OR REPLACE`. Runs inside
/// one transaction so a partial migration cannot leave the store in a
/// torn state (`SQLCipher` rolls back DDL on commit failure).
fn run_brain_migration(db: &mut Db) -> Result<(), StoreError> {
    // Both migrations run inside a single transaction so a partial apply
    // can never leave the store in a torn state. SQLCipher rolls back DDL
    // on commit failure; every statement is `CREATE … IF NOT EXISTS` /
    // `INSERT OR REPLACE` so a re-run on an already-migrated DB is a
    // no-op.
    let sql_0001 = include_str!("../migrations/0001_phase_3_brain_schema.sql");
    let sql_0002 = include_str!("../migrations/0002_briefs.sql");
    let sql_0003 = include_str!("../migrations/0003_events_tab_id.sql");
    let sql_0004 = include_str!("../migrations/0004_v2_graph_schema.sql");
    let sql_0005 = include_str!("../migrations/0005_entity_identities.sql");
    let tx = db
        .conn_mut()
        .transaction()
        .map_err(|e| StoreError::Backend(format!("begin migration tx: {e}")))?;
    tx.execute_batch(sql_0001)
        .map_err(|e| StoreError::Backend(format!("apply migration 0001: {e}")))?;
    tx.execute_batch(sql_0002)
        .map_err(|e| StoreError::Backend(format!("apply migration 0002: {e}")))?;
    // 0003 — V2-P2 events.tab_id. Forward-only nullable ALTER. Idempotent
    // re-apply is guarded by the column-exists check below: `ALTER TABLE
    // ADD COLUMN` is the one DDL SQLite does NOT make idempotent through
    // `IF NOT EXISTS` syntax, so we skip the batch if the column is
    // already present.
    let already_has_tab_id = tab_id_column_present(&tx)
        .map_err(|e| StoreError::Backend(format!("probe events.tab_id: {e}")))?;
    if !already_has_tab_id {
        tx.execute_batch(sql_0003)
            .map_err(|e| StoreError::Backend(format!("apply migration 0003: {e}")))?;
    }
    // 0004 — V2-P3 graph foundation. Every CREATE / INSERT in the batch is
    // `IF NOT EXISTS` / `INSERT OR REPLACE`, so the apply is idempotent on
    // re-open without a separate probe. The migration ships zero `ALTER
    // TABLE`s — only fresh tables — so SQLite's natural idempotence rules
    // apply directly.
    tx.execute_batch(sql_0004)
        .map_err(|e| StoreError::Backend(format!("apply migration 0004: {e}")))?;
    // 0005 — V2-P6 AliasResolver canonical-identity membership. Fresh
    // table + indexes only (zero `ALTER TABLE`), every statement
    // `IF NOT EXISTS` / `INSERT OR REPLACE`, so the apply is idempotent
    // on re-open with no separate probe (same discipline as 0004).
    tx.execute_batch(sql_0005)
        .map_err(|e| StoreError::Backend(format!("apply migration 0005: {e}")))?;
    tx.commit()
        .map_err(|e| StoreError::Backend(format!("commit migration tx: {e}")))?;
    Ok(())
}

/// Returns true if `events.tab_id` is already a column on the live DB
/// (a previously-migrated store) so the 0003 batch is skipped on
/// re-open. `PRAGMA table_info` row shape is
/// `(cid, name, type, notnull, dflt_value, pk)`; we only need `name`.
fn tab_id_column_present(tx: &rusqlite::Transaction<'_>) -> rusqlite::Result<bool> {
    let mut stmt = tx.prepare("PRAGMA table_info(events)")?;
    let mut rows = stmt.query([])?;
    while let Some(row) = rows.next()? {
        let name: String = row.get(1)?;
        if name == "tab_id" {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Map `mci_core::store::StoreError` into the brain's `StoreError`. Wrong
/// key / driver-level open failure / DDL errors all surface as
/// `Backend(_)` — callers above the brain trait don't need to distinguish
/// (they treat the store as opaque); the CSO-protected detail lives in
/// the `mci-core` log line.
fn map_core_err(e: &CoreStoreError) -> StoreError {
    StoreError::Backend(format!("mci-core store: {e}"))
}

/// Expected dimension of stored embeddings. Pinned at 384 per ADR-0009;
/// `vec_search` rejects queries of any other length.
const EMBEDDING_DIM: usize = 384;
/// Byte length of one stored embedding (384 × 4-byte f32, little-endian).
const EMBEDDING_BYTES: usize = EMBEDDING_DIM * std::mem::size_of::<f32>();

/// Tuple type for one `events` row read (column-positional). Pulled out of
/// `get_event` so the function body keeps its expression-shape (`clippy::
/// items_after_statements`). V2-P2 (migration 0003) appends `tab_id` as
/// the trailing column.
type EventRow = (
    i64,            // id
    i64,            // ts_us
    Option<String>, // app_bundle_id
    Option<String>, // window_title
    Option<String>, // url
    String,         // text
    Option<String>, // summary
    Option<String>, // entities
    Option<i64>,    // episode_id
    i64,            // cascade_reason
    Option<String>, // keyframe_blob
    Option<i64>,    // tab_id (V2-P2; INTEGER NULL on the wire)
);

/// Row mapper for the 9-column `briefs` SELECT used by `brief_for_date` +
/// `latest_brief`. Pure function so the SELECTs above stay narrow.
fn row_to_brief(r: &rusqlite::Row<'_>) -> rusqlite::Result<crate::BriefRow> {
    let id: i64 = r.get(0)?;
    let date_local: String = r.get(1)?;
    let generated_ts_us: i64 = r.get(2)?;
    let model_id: String = r.get(3)?;
    let model_version: String = r.get(4)?;
    let title: String = r.get(5)?;
    let body: String = r.get(6)?;
    let word_count: i64 = r.get(7)?;
    let source_event_count: i64 = r.get(8)?;
    Ok(crate::BriefRow {
        id: u64::try_from(id).unwrap_or(0),
        date_local,
        generated_ts_us: u64::try_from(generated_ts_us).unwrap_or(0),
        model_id,
        model_version,
        title,
        body,
        word_count: u32::try_from(word_count).unwrap_or(0),
        source_event_count: u32::try_from(source_event_count).unwrap_or(0),
    })
}

/// Row mapper for the 12-column `events` SELECT used by `recent_events`,
/// `paged_events_since`, `unembedded_events`, and `get_event` (V2-P2
/// added `tab_id` as the trailing column).
fn row_to_event_tuple(r: &rusqlite::Row<'_>) -> rusqlite::Result<EventRow> {
    Ok((
        r.get::<_, i64>(0)?,
        r.get::<_, i64>(1)?,
        r.get::<_, Option<String>>(2)?,
        r.get::<_, Option<String>>(3)?,
        r.get::<_, Option<String>>(4)?,
        r.get::<_, String>(5)?,
        r.get::<_, Option<String>>(6)?,
        r.get::<_, Option<String>>(7)?,
        r.get::<_, Option<i64>>(8)?,
        r.get::<_, i64>(9)?,
        r.get::<_, Option<String>>(10)?,
        r.get::<_, Option<i64>>(11)?,
    ))
}

/// Row mapper for the 8-column `entities` SELECT used by
/// `find_entity_by_alias` (V2-P3 migration 0004).
fn row_to_entity(r: &rusqlite::Row<'_>) -> rusqlite::Result<Entity> {
    let id: String = r.get(0)?;
    let kind: String = r.get(1)?;
    let canonical_name: String = r.get(2)?;
    let summary: Option<String> = r.get(3)?;
    let summary_blob: Option<Vec<u8>> = r.get(4)?;
    let content_hash: String = r.get(5)?;
    let created_ts_us: i64 = r.get(6)?;
    let updated_ts_us: i64 = r.get(7)?;
    let summary_embedding = summary_blob.and_then(|b| blob_to_embedding(&b));
    Ok(Entity {
        id: EntityId(id),
        kind,
        canonical_name,
        summary,
        summary_embedding,
        content_hash,
        created_ts_us: u64::try_from(created_ts_us).unwrap_or(0),
        updated_ts_us: u64::try_from(updated_ts_us).unwrap_or(0),
    })
}

/// Serialize a 384-d L2-normalized f32 vector to a little-endian BLOB.
fn embedding_to_blob(v: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(v.len() * 4);
    for x in v {
        out.extend_from_slice(&x.to_le_bytes());
    }
    out
}

/// Deserialize a little-endian f32 BLOB back into a `Vec<f32>`. Returns
/// `None` if the byte length is not a multiple of 4 (a corrupted row;
/// `vec_search` treats it as a non-match rather than failing the whole
/// query).
fn blob_to_embedding(blob: &[u8]) -> Option<Vec<f32>> {
    if blob.len() % 4 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(blob.len() / 4);
    for chunk in blob.chunks_exact(4) {
        // safety: chunks_exact(4) yields slices of exactly 4 bytes.
        let arr: [u8; 4] = chunk.try_into().ok()?;
        out.push(f32::from_le_bytes(arr));
    }
    Some(out)
}

impl crate::BrainStore for SqlCipherBrainStore {
    fn put_event(&self, event: &Event) -> Result<EventId, StoreError> {
        // ADR-0016 §4.3 defence-in-depth — `.suppress` events MUST NOT
        // reach the brain ingestor. The IPC seam enforces this
        // structurally upstream; this is the wall at the store boundary.
        if event.cascade_reason != 0 {
            return Err(StoreError::InvalidInput(format!(
                "cascade_reason must be 0 (`.suppress`-decided events MUST NOT reach put_event); got {}",
                event.cascade_reason
            )));
        }
        // Embedding pre-checks happen BEFORE we open a transaction so a
        // mis-dim event cannot leave a half-inserted `events` row +
        // missing `event_vectors` row on rollback failure.
        if let Some(emb) = &event.embedding {
            if emb.len() != EMBEDDING_DIM {
                return Err(StoreError::InvalidInput(format!(
                    "embedding dimension must be {} (ADR-0009), got {}",
                    EMBEDDING_DIM,
                    emb.len()
                )));
            }
        }

        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|e| StoreError::Backend(format!("begin put_event tx: {e}")))?;

        // INSERT events. The `events_ai` trigger syncs `events_fts` inside
        // this same transaction; we never INSERT to events_fts directly.
        // V2-P2: `tab_id` appended as the trailing column (migration 0003).
        tx.execute(
            "INSERT INTO events (
                ts_us, app_bundle_id, window_title, url,
                text, summary, entities, episode_id,
                cascade_reason, keyframe_blob, tab_id
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            params![
                i64::try_from(event.ts_us).unwrap_or(i64::MAX),
                &event.app_bundle_id,
                &event.window_title,
                &event.url,
                &event.text,
                &event.summary,
                &event.entities,
                event
                    .episode_id
                    .map(|v| i64::try_from(v).unwrap_or(i64::MAX)),
                event.cascade_reason,
                &event.keyframe_blob,
                event.tab_id.map(i64::from),
            ],
        )
        .map_err(|e| StoreError::Backend(format!("INSERT events: {e}")))?;

        let row_id = tx.last_insert_rowid();
        let id = EventId(u64::try_from(row_id).unwrap_or(0));

        if let Some(emb) = &event.embedding {
            let blob = embedding_to_blob(emb);
            debug_assert_eq!(blob.len(), EMBEDDING_BYTES);
            tx.execute(
                "INSERT INTO event_vectors (event_id, embedding) VALUES (?1, ?2)",
                params![row_id, blob],
            )
            .map_err(|e| StoreError::Backend(format!("INSERT event_vectors: {e}")))?;
            // vec_events (vec0 mirror) is deferred — see module docs.
        }

        tx.commit()
            .map_err(|e| StoreError::Backend(format!("commit put_event tx: {e}")))?;
        Ok(id)
    }

    fn get_event(&self, id: EventId) -> Result<Option<Event>, StoreError> {
        let row_id = i64::try_from(id.0).map_err(|e| {
            StoreError::InvalidInput(format!("event id {} out of i64 range: {e}", id.0))
        })?;
        let guard = self.db.lock().expect("brain store mutex poisoned");

        // Two-step: pull the events row, then the (optional) embedding.
        // Cheaper than a LEFT JOIN for this column set on a per-id read.
        // V2-P2: `tab_id` trails the SELECT column list (migration 0003).
        let row: Option<EventRow> = guard
            .conn()
            .query_row(
                "SELECT id, ts_us, app_bundle_id, window_title, url,
                        text, summary, entities, episode_id,
                        cascade_reason, keyframe_blob, tab_id
                 FROM events WHERE id = ?1",
                params![row_id],
                row_to_event_tuple,
            )
            .map(Some)
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(StoreError::Backend(format!("SELECT events: {other}"))),
            })?;

        let Some((
            ev_id,
            ts_us,
            app,
            title,
            url,
            text,
            summary,
            entities,
            episode_id,
            cascade_reason,
            keyframe_blob,
            tab_id,
        )) = row
        else {
            return Ok(None);
        };

        let embedding: Option<Vec<f32>> = guard
            .conn()
            .query_row(
                "SELECT embedding FROM event_vectors WHERE event_id = ?1",
                params![ev_id],
                |r| r.get::<_, Vec<u8>>(0),
            )
            .map(|blob| blob_to_embedding(&blob))
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(StoreError::Backend(format!(
                    "SELECT event_vectors: {other}"
                ))),
            })?;

        Ok(Some(Event {
            id: EventId(u64::try_from(ev_id).unwrap_or(0)),
            ts_us: u64::try_from(ts_us).unwrap_or(0),
            app_bundle_id: app,
            window_title: title,
            url,
            text,
            summary,
            entities,
            episode_id: episode_id.map(|v| u64::try_from(v).unwrap_or(0)),
            cascade_reason,
            keyframe_blob,
            tab_id: tab_id.and_then(|v| u32::try_from(v).ok()),
            embedding,
        }))
    }

    fn fts5_search(&self, query: &str, limit: usize) -> Result<Vec<(EventId, f32)>, StoreError> {
        if query.is_empty() {
            return Err(StoreError::InvalidInput("empty FTS5 query".into()));
        }
        if limit == 0 {
            return Ok(Vec::new());
        }
        let guard = self.db.lock().expect("brain store mutex poisoned");

        // FTS5's `rank` virtual column is the auto-computed BM25 cost —
        // *lower* (more-negative) is a better match; `ORDER BY rank ASC`
        // sorts best-first. We negate at the boundary so the trait's
        // "higher is better" contract holds (the retriever min-max-
        // normalizes anyway, but flipping here keeps the per-hit f32
        // monotone with relevance so test assertions read naturally).
        let mut stmt = guard
            .conn()
            .prepare(
                "SELECT rowid, rank
                 FROM events_fts
                 WHERE events_fts MATCH ?1
                 ORDER BY rank ASC
                 LIMIT ?2",
            )
            .map_err(|e| StoreError::Backend(format!("prepare fts5: {e}")))?;
        let lim = i64::try_from(limit).unwrap_or(i64::MAX);
        let rows = stmt
            .query_map(params![query, lim], |r| {
                let row_id: i64 = r.get(0)?;
                let rank: f64 = r.get(1)?;
                Ok((row_id, rank))
            })
            .map_err(|e| StoreError::Backend(format!("query fts5: {e}")))?;

        let mut out: Vec<(EventId, f32)> = Vec::new();
        for r in rows {
            let (row_id, rank) = r.map_err(|e| StoreError::Backend(format!("row fts5: {e}")))?;
            // Negate so larger-positive = better (monotone with relevance).
            #[allow(clippy::cast_possible_truncation)]
            let score = (-rank) as f32;
            out.push((EventId(u64::try_from(row_id).unwrap_or(0)), score));
        }
        Ok(out)
    }

    fn vec_search(
        &self,
        query_embedding: &[f32],
        limit: usize,
    ) -> Result<Vec<(EventId, f32)>, StoreError> {
        // ADR-0009 schema-pin: query must match the stored dimension
        // exactly. Silently truncating/padding mis-dim queries was the
        // exact "almost-right-rank" failure mode the pin was authored
        // against.
        if query_embedding.len() != EMBEDDING_DIM {
            return Err(StoreError::InvalidInput(format!(
                "query embedding dimension must be {} (ADR-0009), got {}",
                EMBEDDING_DIM,
                query_embedding.len()
            )));
        }
        if limit == 0 {
            return Ok(Vec::new());
        }

        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare("SELECT event_id, embedding FROM event_vectors")
            .map_err(|e| StoreError::Backend(format!("prepare vec scan: {e}")))?;

        // Brute-force cosine. Vectors are L2-normalized at insert time
        // (ADR-0009 / ADR-0011), so cosine == dot product. The full-table
        // scan is fine inside the Phase-3 corpus regime — ADR-0011 §3's
        // scaling ladder escalates to binary-quantized + recency pre-
        // filter past ~10⁶ events, which is well past Phase 3's reach.
        let rows = stmt
            .query_map([], |r| {
                let event_id: i64 = r.get(0)?;
                let blob: Vec<u8> = r.get(1)?;
                Ok((event_id, blob))
            })
            .map_err(|e| StoreError::Backend(format!("query vec scan: {e}")))?;

        let mut hits: Vec<(EventId, f32)> = Vec::new();
        for r in rows {
            let (event_id, blob) =
                r.map_err(|e| StoreError::Backend(format!("row vec scan: {e}")))?;
            if blob.len() != EMBEDDING_BYTES {
                // Mis-sized blob — skip rather than fail the whole query.
                // The CRS Telemetry-Gap analyst would catch this as a
                // schema regression; this branch is the run-time floor.
                continue;
            }
            let Some(stored) = blob_to_embedding(&blob) else {
                continue;
            };
            let dot: f32 = stored
                .iter()
                .zip(query_embedding.iter())
                .map(|(a, b)| a * b)
                .sum();
            hits.push((EventId(u64::try_from(event_id).unwrap_or(0)), dot));
        }
        hits.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        hits.truncate(limit);
        Ok(hits)
    }

    // -----------------------------------------------------------------------
    // V2-P3 — graph foundation writers + readers
    //
    // Each writer is an upsert / insert-or-ignore. Reads are SELECT-only.
    // FK enforcement on `entity_mentions.entity_id` / `event_id` and on
    // `episode_edges.{src,dst}_episode_id` is structural per ADR-0008
    // (mci-core's store open sets `PRAGMA foreign_keys = ON`) — a writer
    // that cites a non-existent entity / event / episode fails fast at
    // INSERT time rather than producing an unresolved row.
    // -----------------------------------------------------------------------

    fn put_entity(&self, entity: &Entity) -> Result<(), StoreError> {
        if let Some(emb) = &entity.summary_embedding {
            if emb.len() != EMBEDDING_DIM {
                return Err(StoreError::InvalidInput(format!(
                    "summary_embedding dimension must be {} (ADR-0009), got {}",
                    EMBEDDING_DIM,
                    emb.len()
                )));
            }
        }
        let summary_blob: Option<Vec<u8>> = entity
            .summary_embedding
            .as_ref()
            .map(|v| embedding_to_blob(v));
        let created = i64::try_from(entity.created_ts_us).unwrap_or(i64::MAX);
        let updated = i64::try_from(entity.updated_ts_us).unwrap_or(i64::MAX);

        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|e| StoreError::Backend(format!("begin put_entity tx: {e}")))?;
        // Upsert: preserve `created_ts_us` on conflict (the first writer's
        // wall clock is the canonical creation moment), bump everything
        // else. Mirrors the convention `briefs` uses for `INSERT OR
        // REPLACE` on its UNIQUE(date_local) — but here we want to keep
        // `created_ts_us` so a plain REPLACE won't do.
        tx.execute(
            "INSERT INTO entities (
                id, kind, canonical_name, summary, summary_embedding,
                content_hash, created_ts_us, updated_ts_us
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(id) DO UPDATE SET
                kind              = excluded.kind,
                canonical_name    = excluded.canonical_name,
                summary           = excluded.summary,
                summary_embedding = excluded.summary_embedding,
                content_hash      = excluded.content_hash,
                updated_ts_us     = excluded.updated_ts_us",
            params![
                &entity.id.0,
                &entity.kind,
                &entity.canonical_name,
                &entity.summary,
                &summary_blob,
                &entity.content_hash,
                created,
                updated,
            ],
        )
        .map_err(|e| StoreError::Backend(format!("UPSERT entities: {e}")))?;
        tx.commit()
            .map_err(|e| StoreError::Backend(format!("commit put_entity tx: {e}")))?;
        Ok(())
    }

    fn put_entity_mention(&self, mention: &EntityMention) -> Result<(), StoreError> {
        let event_id = i64::try_from(mention.event_id.0).map_err(|e| {
            StoreError::InvalidInput(format!(
                "event id {} out of i64 range: {e}",
                mention.event_id.0
            ))
        })?;
        let ts = i64::try_from(mention.ts_us).unwrap_or(i64::MAX);
        let confidence = f64::from(mention.confidence);

        let guard = self.db.lock().expect("brain store mutex poisoned");
        guard
            .conn()
            .execute(
                "INSERT OR IGNORE INTO entity_mentions (
                    id, entity_id, event_id, mention_text,
                    confidence, extractor_kind, ts_us
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    &mention.id.0,
                    &mention.entity_id.0,
                    event_id,
                    &mention.mention_text,
                    confidence,
                    &mention.extractor_kind,
                    ts,
                ],
            )
            .map_err(|e| StoreError::Backend(format!("INSERT entity_mentions: {e}")))?;
        Ok(())
    }

    fn put_episode_edge(&self, edge: &EpisodeEdge) -> Result<(), StoreError> {
        let src = i64::try_from(edge.src_episode_id.0).map_err(|e| {
            StoreError::InvalidInput(format!(
                "src episode id {} out of i64 range: {e}",
                edge.src_episode_id.0
            ))
        })?;
        let dst = i64::try_from(edge.dst_episode_id.0).map_err(|e| {
            StoreError::InvalidInput(format!(
                "dst episode id {} out of i64 range: {e}",
                edge.dst_episode_id.0
            ))
        })?;
        let ts = i64::try_from(edge.ts_us).unwrap_or(i64::MAX);

        let guard = self.db.lock().expect("brain store mutex poisoned");
        guard
            .conn()
            .execute(
                "INSERT OR IGNORE INTO episode_edges (
                    id, src_episode_id, dst_episode_id, edge_kind,
                    evidence_entity_ids, ts_us
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    &edge.id.0,
                    src,
                    dst,
                    &edge.edge_kind,
                    &edge.evidence_entity_ids,
                    ts,
                ],
            )
            .map_err(|e| StoreError::Backend(format!("INSERT episode_edges: {e}")))?;
        Ok(())
    }

    fn find_entity_by_alias(
        &self,
        kind: &str,
        alias: &str,
    ) -> Result<Option<Entity>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let row_opt = guard
            .conn()
            .query_row(
                "SELECT id, kind, canonical_name, summary, summary_embedding,
                        content_hash, created_ts_us, updated_ts_us
                 FROM entities
                 WHERE kind = ?1 AND canonical_name = ?2
                 LIMIT 1",
                params![kind, alias],
                row_to_entity,
            )
            .map(Some)
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(StoreError::Backend(format!(
                    "SELECT find_entity_by_alias: {other}"
                ))),
            })?;
        Ok(row_opt)
    }

    fn events_with_entity(
        &self,
        entity_id: &EntityId,
        limit: usize,
    ) -> Result<Vec<EventRecord>, StoreError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let lim = i64::try_from(limit).unwrap_or(i64::MAX);
        let guard = self.db.lock().expect("brain store mutex poisoned");
        // DISTINCT defends against the (rare but legal) case where two
        // extractor passes wrote two mention rows for the same event ×
        // entity pair (e.g. regex span "John" + qwen mention with text
        // "John Smith" both pointing at the same entity). Without
        // DISTINCT the read would surface the parent event twice.
        let mut stmt = guard
            .conn()
            .prepare(
                "SELECT DISTINCT e.id, e.ts_us, e.app_bundle_id, e.window_title, e.url, e.text
                 FROM events e
                 JOIN entity_mentions m ON m.event_id = e.id
                 WHERE m.entity_id = ?1
                 ORDER BY e.ts_us DESC
                 LIMIT ?2",
            )
            .map_err(|e| StoreError::Backend(format!("prepare events_with_entity: {e}")))?;
        let rows = stmt
            .query_map(params![&entity_id.0, lim], |r| {
                let id: i64 = r.get(0)?;
                let ts_us: i64 = r.get(1)?;
                let app: Option<String> = r.get(2)?;
                let title: Option<String> = r.get(3)?;
                let url: Option<String> = r.get(4)?;
                let text: String = r.get(5)?;
                Ok((id, ts_us, app, title, url, text))
            })
            .map_err(|e| StoreError::Backend(format!("query events_with_entity: {e}")))?;
        let mut out = Vec::new();
        for r in rows {
            let (id, ts_us, app, title, url, text) =
                r.map_err(|e| StoreError::Backend(format!("row events_with_entity: {e}")))?;
            out.push(EventRecord {
                event_id: EventId(u64::try_from(id).unwrap_or(0)),
                ts_us: u64::try_from(ts_us).unwrap_or(0),
                app_bundle_id: app,
                window_title: title,
                url,
                text_snippet: EventRecord::truncate_snippet(&text),
            });
        }
        Ok(out)
    }

    // -----------------------------------------------------------------------
    // V2-P6 — AliasResolver read+write path
    // -----------------------------------------------------------------------

    fn list_resolvable_entities(&self) -> Result<Vec<ResolverEntity>, StoreError> {
        let placeholders = resolvable_kinds_placeholders();
        let sql = format!(
            "SELECT id, kind, canonical_name FROM entities
             WHERE kind IN ({placeholders}) ORDER BY id"
        );
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare(&sql)
            .map_err(|e| StoreError::Backend(format!("prepare list_resolvable_entities: {e}")))?;
        let rows = stmt
            .query_map(params_from_iter(RESOLVABLE_KINDS.iter()), |r| {
                Ok(ResolverEntity {
                    id: EntityId(r.get::<_, String>(0)?),
                    kind: r.get::<_, String>(1)?,
                    canonical_name: r.get::<_, String>(2)?,
                })
            })
            .map_err(|e| StoreError::Backend(format!("query list_resolvable_entities: {e}")))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r.map_err(|e| StoreError::Backend(format!("row resolvable: {e}")))?);
        }
        Ok(out)
    }

    fn entity_cooccurrences(&self) -> Result<Vec<(EventId, Vec<EntityId>)>, StoreError> {
        let placeholders = resolvable_kinds_placeholders();
        // DISTINCT collapses the (rare) two-extractor-passes-same-entity
        // case so an entity is not double-counted as co-occurring with
        // itself. Ordered by event so we can group with a single pass.
        let sql = format!(
            "SELECT DISTINCT m.event_id, m.entity_id
             FROM entity_mentions m JOIN entities e ON e.id = m.entity_id
             WHERE e.kind IN ({placeholders})
             ORDER BY m.event_id, m.entity_id"
        );
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare(&sql)
            .map_err(|e| StoreError::Backend(format!("prepare entity_cooccurrences: {e}")))?;
        let rows = stmt
            .query_map(params_from_iter(RESOLVABLE_KINDS.iter()), |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
            })
            .map_err(|e| StoreError::Backend(format!("query entity_cooccurrences: {e}")))?;
        let mut out: Vec<(EventId, Vec<EntityId>)> = Vec::new();
        for r in rows {
            let (event_id, entity_id) =
                r.map_err(|e| StoreError::Backend(format!("row cooccurrence: {e}")))?;
            let eid = EventId(u64::try_from(event_id).unwrap_or(0));
            match out.last_mut() {
                Some((last_eid, members)) if *last_eid == eid => {
                    members.push(EntityId(entity_id));
                }
                _ => out.push((eid, vec![EntityId(entity_id)])),
            }
        }
        Ok(out)
    }

    fn put_entity_identity(&self, membership: &EntityIdentity) -> Result<(), StoreError> {
        let ts = i64::try_from(membership.ts_us).unwrap_or(i64::MAX);
        let confidence = f64::from(membership.confidence);
        let guard = self.db.lock().expect("brain store mutex poisoned");
        // Grow-only: INSERT OR IGNORE preserves the first-write row (incl.
        // its ts_us) so a re-run on an unchanged store is a true no-op.
        guard
            .conn()
            .execute(
                "INSERT OR IGNORE INTO entity_identities (
                    id, entity_id, identity_id, identity_kind,
                    identity_canonical_name, rule, confidence, ts_us
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    &membership.id.0,
                    &membership.entity_id.0,
                    &membership.identity_id.0,
                    &membership.identity_kind,
                    &membership.identity_canonical_name,
                    &membership.rule,
                    confidence,
                    ts,
                ],
            )
            .map_err(|e| StoreError::Backend(format!("INSERT entity_identities: {e}")))?;
        Ok(())
    }

    fn reconcile_entity_identities(
        &self,
        rows: &[EntityIdentity],
    ) -> Result<crate::ReconcileStats, StoreError> {
        let keep: std::collections::BTreeSet<&str> =
            rows.iter().map(|r| r.id.0.as_str()).collect();
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|e| StoreError::Backend(format!("begin reconcile tx: {e}")))?;

        // Read the currently-persisted PKs, then prune any not in `keep`.
        let existing: Vec<String> = {
            let mut stmt = tx
                .prepare("SELECT id FROM entity_identities")
                .map_err(|e| StoreError::Backend(format!("prepare reconcile select: {e}")))?;
            let mapped = stmt
                .query_map([], |r| r.get::<_, String>(0))
                .map_err(|e| StoreError::Backend(format!("query reconcile select: {e}")))?;
            let mut out = Vec::new();
            for r in mapped {
                out.push(r.map_err(|e| StoreError::Backend(format!("row reconcile: {e}")))?);
            }
            out
        };

        let mut deleted = 0u64;
        for id in &existing {
            if !keep.contains(id.as_str()) {
                tx.execute("DELETE FROM entity_identities WHERE id = ?1", params![id])
                    .map_err(|e| StoreError::Backend(format!("DELETE entity_identities: {e}")))?;
                deleted += 1;
            }
        }

        // INSERT OR IGNORE the current set — preserves the first-write
        // ts_us of rows that already exist, so an unchanged re-run is a
        // true row-level no-op (zero inserts, zero deletes).
        let mut inserted = 0u64;
        for membership in rows {
            let ts = i64::try_from(membership.ts_us).unwrap_or(i64::MAX);
            let confidence = f64::from(membership.confidence);
            let changed = tx
                .execute(
                    "INSERT OR IGNORE INTO entity_identities (
                        id, entity_id, identity_id, identity_kind,
                        identity_canonical_name, rule, confidence, ts_us
                     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                    params![
                        &membership.id.0,
                        &membership.entity_id.0,
                        &membership.identity_id.0,
                        &membership.identity_kind,
                        &membership.identity_canonical_name,
                        &membership.rule,
                        confidence,
                        ts,
                    ],
                )
                .map_err(|e| StoreError::Backend(format!("INSERT reconcile: {e}")))?;
            inserted += u64::try_from(changed).unwrap_or(0);
        }

        tx.commit()
            .map_err(|e| StoreError::Backend(format!("commit reconcile tx: {e}")))?;
        Ok(crate::ReconcileStats { inserted, deleted })
    }

    fn identity_members(
        &self,
        identity_id: &IdentityId,
    ) -> Result<Vec<EntityIdentity>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare(
                "SELECT id, entity_id, identity_id, identity_kind,
                        identity_canonical_name, rule, confidence, ts_us
                 FROM entity_identities WHERE identity_id = ?1 ORDER BY id",
            )
            .map_err(|e| StoreError::Backend(format!("prepare identity_members: {e}")))?;
        let rows = stmt
            .query_map(params![&identity_id.0], row_to_entity_identity)
            .map_err(|e| StoreError::Backend(format!("query identity_members: {e}")))?;
        collect_entity_identities(rows)
    }

    fn identity_of_entity(
        &self,
        entity_id: &EntityId,
    ) -> Result<Vec<EntityIdentity>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare(
                "SELECT id, entity_id, identity_id, identity_kind,
                        identity_canonical_name, rule, confidence, ts_us
                 FROM entity_identities WHERE entity_id = ?1 ORDER BY id",
            )
            .map_err(|e| StoreError::Backend(format!("prepare identity_of_entity: {e}")))?;
        let rows = stmt
            .query_map(params![&entity_id.0], row_to_entity_identity)
            .map_err(|e| StoreError::Backend(format!("query identity_of_entity: {e}")))?;
        collect_entity_identities(rows)
    }

    fn resolution_watermark(&self) -> Result<ResolutionWatermark, StoreError> {
        let placeholders = resolvable_kinds_placeholders();
        let ent_sql = format!(
            "SELECT COUNT(*), COALESCE(MAX(updated_ts_us), 0)
             FROM entities WHERE kind IN ({placeholders})"
        );
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let (entity_count, max_entity_ts_us): (i64, i64) = guard
            .conn()
            .query_row(&ent_sql, params_from_iter(RESOLVABLE_KINDS.iter()), |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .map_err(|e| StoreError::Backend(format!("watermark entities: {e}")))?;
        let (mention_count, max_mention_ts_us): (i64, i64) = guard
            .conn()
            .query_row(
                "SELECT COUNT(*), COALESCE(MAX(ts_us), 0) FROM entity_mentions",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .map_err(|e| StoreError::Backend(format!("watermark mentions: {e}")))?;
        Ok(ResolutionWatermark {
            entity_count,
            max_entity_ts_us,
            mention_count,
            max_mention_ts_us,
        })
    }
}

/// Build the `?,?,…` placeholder list for the `RESOLVABLE_KINDS` IN-clause.
fn resolvable_kinds_placeholders() -> String {
    vec!["?"; RESOLVABLE_KINDS.len()].join(",")
}

/// rusqlite row → [`EntityIdentity`].
fn row_to_entity_identity(r: &rusqlite::Row<'_>) -> rusqlite::Result<EntityIdentity> {
    let confidence: f64 = r.get(6)?;
    let ts_us: i64 = r.get(7)?;
    Ok(EntityIdentity {
        id: EntityIdentityId(r.get::<_, String>(0)?),
        entity_id: EntityId(r.get::<_, String>(1)?),
        identity_id: IdentityId(r.get::<_, String>(2)?),
        identity_kind: r.get::<_, String>(3)?,
        identity_canonical_name: r.get::<_, String>(4)?,
        rule: r.get::<_, String>(5)?,
        #[allow(clippy::cast_possible_truncation)]
        confidence: confidence as f32,
        ts_us: u64::try_from(ts_us).unwrap_or(0),
    })
}

/// Drain a mapped-row iterator of [`EntityIdentity`] into a `Vec`.
fn collect_entity_identities(
    rows: impl Iterator<Item = rusqlite::Result<EntityIdentity>>,
) -> Result<Vec<EntityIdentity>, StoreError> {
    let mut out = Vec::new();
    for r in rows {
        out.push(r.map_err(|e| StoreError::Backend(format!("row entity_identity: {e}")))?);
    }
    Ok(out)
}

impl crate::episode_segmenter::EpisodeWriter for SqlCipherBrainStore {
    fn create_episode(
        &self,
        ts_start: u64,
        ts_end: u64,
        app_bundle_id: Option<&str>,
    ) -> Result<EpisodeId, StoreError> {
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|e| StoreError::Backend(format!("begin create_episode tx: {e}")))?;
        tx.execute(
            "INSERT INTO episodes (ts_start, ts_end, app_bundle_id) VALUES (?1, ?2, ?3)",
            params![
                i64::try_from(ts_start).unwrap_or(i64::MAX),
                i64::try_from(ts_end).unwrap_or(i64::MAX),
                app_bundle_id,
            ],
        )
        .map_err(|e| StoreError::Backend(format!("INSERT episodes: {e}")))?;
        let row_id = tx.last_insert_rowid();
        tx.commit()
            .map_err(|e| StoreError::Backend(format!("commit create_episode tx: {e}")))?;
        Ok(EpisodeId(u64::try_from(row_id).unwrap_or(0)))
    }

    fn set_event_episode(
        &self,
        event_id: EventId,
        episode_id: EpisodeId,
    ) -> Result<(), StoreError> {
        let ev = i64::try_from(event_id.0).map_err(|e| {
            StoreError::InvalidInput(format!("event id {} out of i64 range: {e}", event_id.0))
        })?;
        let ep = i64::try_from(episode_id.0).map_err(|e| {
            StoreError::InvalidInput(format!("episode id {} out of i64 range: {e}", episode_id.0))
        })?;
        let guard = self.db.lock().expect("brain store mutex poisoned");
        guard
            .conn()
            .execute(
                "UPDATE events SET episode_id = ?1 WHERE id = ?2",
                params![ep, ev],
            )
            .map_err(|e| StoreError::Backend(format!("UPDATE events.episode_id: {e}")))?;
        Ok(())
    }

    fn extend_episode(&self, episode_id: EpisodeId, ts_end: u64) -> Result<(), StoreError> {
        let ep = i64::try_from(episode_id.0).map_err(|e| {
            StoreError::InvalidInput(format!("episode id {} out of i64 range: {e}", episode_id.0))
        })?;
        let guard = self.db.lock().expect("brain store mutex poisoned");
        guard
            .conn()
            .execute(
                "UPDATE episodes SET ts_end = ?1 WHERE id = ?2",
                params![i64::try_from(ts_end).unwrap_or(i64::MAX), ep],
            )
            .map_err(|e| StoreError::Backend(format!("UPDATE episodes.ts_end: {e}")))?;
        Ok(())
    }
}
