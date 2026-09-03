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

use std::collections::{BTreeSet, HashMap};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

use crate::alias_resolver::{ResolverEntity, RESOLVABLE_KINDS};
use crate::episode_segmenter::EpisodeId;
use crate::graph::{
    Entity, EntityId, EntityIdentity, EntityIdentityId, EntityMention, EpisodeEdge, EpisodeEdgeId,
    IdentityId,
};
use mci_core::crypto::DbKey;
use mci_core::store::{
    open as mci_core_open, open_readonly as mci_core_open_readonly, Db,
    StoreError as CoreStoreError,
};
use rusqlite::types::Value;
use rusqlite::{params, params_from_iter, OptionalExtension};

use crate::{
    BlobReconciliationStats, BrainStats, ConsolidationWatermark, Event, EventId, EventRecord,
    ExpansionBudget, IdentityMentionSite, MemoryClaim, MemoryClaimId, MemoryDelta, MemoryExpansion,
    MemoryRetraction, ResolutionWatermark, StoreError, TimeRange,
};

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
    blob_dir: PathBuf,
}

/// A best-effort maintenance stage that runs only after deletion commits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeletionCleanupStage {
    /// Reclaim free database pages with `VACUUM`.
    Vacuum,
    /// Remove encrypted keyframe blobs that no surviving event references.
    KeyframeBlobs,
}

/// One non-fatal maintenance warning from a committed deletion.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeletionCleanupWarning {
    /// Maintenance stage that did not finish.
    pub stage: DeletionCleanupStage,
    /// Content-free diagnostic for local logs and engineering support.
    pub diagnostic: String,
}

/// Durable outcome of a deletion transaction and its post-commit maintenance.
///
/// Returning this value means the SQL transaction committed. Cleanup warnings
/// never change that fact and must not be presented as a rolled-back deletion.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeletionOutcome {
    /// Rows removed from the `events` table.
    pub events_deleted: u64,
    /// Independent best-effort maintenance failures observed after commit.
    pub cleanup_warnings: Vec<DeletionCleanupWarning>,
}

impl DeletionOutcome {
    /// Whether database free-page reclamation completed.
    #[must_use]
    pub fn vacuum_ok(&self) -> bool {
        !self
            .cleanup_warnings
            .iter()
            .any(|warning| warning.stage == DeletionCleanupStage::Vacuum)
    }

    /// Whether stale encrypted keyframe candidates were removed.
    #[must_use]
    pub fn blob_cleanup_ok(&self) -> bool {
        !self
            .cleanup_warnings
            .iter()
            .any(|warning| warning.stage == DeletionCleanupStage::KeyframeBlobs)
    }
}

impl SqlCipherBrainStore {
    pub(crate) fn remove_unreferenced_keyframe_candidates(
        &self,
        candidates: &[String],
    ) -> Result<u64, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        remove_unreferenced_keyframe_blobs(guard.conn(), &self.blob_dir, candidates)
    }

    /// Reconcile the managed encrypted keyframe directory against live event references.
    ///
    /// Canonical unreferenced blobs and writer temporary files are removed only after
    /// `minimum_orphan_age`. Unknown names, symlinks, and non-regular entries are never
    /// removed. A non-zero grace period prevents racing the capture helper between its
    /// durable blob publication and the corresponding event insert.
    pub fn reconcile_keyframe_blobs(
        &self,
        minimum_orphan_age: Duration,
    ) -> Result<BlobReconciliationStats, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        reconcile_keyframe_blob_directory(
            guard.conn(),
            &self.blob_dir,
            minimum_orphan_age,
            SystemTime::now(),
        )
    }

    /// Apply one governed memory delta atomically.
    pub fn project_memory_delta(&self, delta: &MemoryDelta) -> Result<(), StoreError> {
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|e| StoreError::Backend(format!("begin memory projection: {e}")))?;
        crate::memory_projector::apply_delta(&tx, delta)?;
        tx.commit()
            .map_err(|e| StoreError::Backend(format!("commit memory projection: {e}")))
    }

    /// Append retraction transitions for claims evidenced by one event.
    pub fn retract_memory_event(&self, value: &MemoryRetraction) -> Result<(), StoreError> {
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|e| StoreError::Backend(format!("begin memory retraction: {e}")))?;
        crate::memory_projector::apply_retraction(&tx, value)?;
        tx.commit()
            .map_err(|e| StoreError::Backend(format!("commit memory retraction: {e}")))
    }

    /// Return active claims valid at `valid_at_us` and known by
    /// `asserted_as_of_us`, in deterministic order.
    pub fn memory_claims_as_of(
        &self,
        valid_at_us: u64,
        asserted_as_of_us: u64,
        limit: usize,
    ) -> Result<Vec<MemoryClaim>, StoreError> {
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|e| StoreError::Backend(format!("begin memory read: {e}")))?;
        let claims =
            crate::memory_projector::read_claims_as_of(&tx, valid_at_us, asserted_as_of_us, limit)?;
        tx.commit()
            .map_err(|e| StoreError::Backend(format!("commit memory read: {e}")))?;
        Ok(claims)
    }

    /// Return one claim's append-only status history.
    pub fn memory_claim_history(
        &self,
        claim_id: &MemoryClaimId,
    ) -> Result<Vec<crate::ClaimStatusRecord>, StoreError> {
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|e| StoreError::Backend(format!("begin memory history read: {e}")))?;
        let history = crate::memory_projector::read_claim_history(&tx, claim_id)?;
        tx.commit()
            .map_err(|e| StoreError::Backend(format!("commit memory history read: {e}")))?;
        Ok(history)
    }

    /// Expand seed claims across extant evidence, episodes, entities, and
    /// identities under explicit deterministic budgets.
    pub fn expand_memory(
        &self,
        seed_claim_ids: &[MemoryClaimId],
        budget: ExpansionBudget,
    ) -> Result<MemoryExpansion, StoreError> {
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|e| StoreError::Backend(format!("begin memory expansion: {e}")))?;
        let expansion = crate::memory_projector::expand_memory(&tx, seed_claim_ids, budget)?;
        tx.commit()
            .map_err(|e| StoreError::Backend(format!("commit memory expansion: {e}")))?;
        Ok(expansion)
    }

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
        Ok(Self {
            db: Mutex::new(db),
            blob_dir: blob_dir_for_brain(path),
        })
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
        Ok(Self {
            db: Mutex::new(db),
            blob_dir: blob_dir_for_brain(path),
        })
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

    /// Read a bounded, evenly distributed sample from a half-open time window.
    ///
    /// Unlike [`Self::events_since`], this does not bias a capped result toward
    /// the beginning of the window. When the window contains more than `limit`
    /// rows, the first and newest rows are retained and the remainder are spread
    /// across the interval in timestamp order. This is the daily-brief read path:
    /// a busy morning must not make the afternoon disappear from the summary.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any underlying `SQLite` failure.
    pub fn sampled_events_between(
        &self,
        since_ts_us: u64,
        until_ts_us: u64,
        limit: usize,
    ) -> Result<Vec<EventRecord>, StoreError> {
        if limit == 0 || since_ts_us >= until_ts_us {
            return Ok(Vec::new());
        }
        let since = i64::try_from(since_ts_us).unwrap_or(i64::MAX);
        let until = i64::try_from(until_ts_us).unwrap_or(i64::MAX);
        let lim = i64::try_from(limit).unwrap_or(i64::MAX);
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare(
                "WITH ranked AS (
                    SELECT id, ts_us, app_bundle_id, window_title, url, text,
                           ROW_NUMBER() OVER (ORDER BY ts_us ASC, id ASC) AS rn,
                           COUNT(*) OVER () AS total
                    FROM events
                    WHERE ts_us >= ?1 AND ts_us < ?2
                 )
                 SELECT id, ts_us, app_bundle_id, window_title, url, text
                 FROM ranked
                 WHERE total <= ?3
                    OR (?3 = 1 AND rn = total)
                    OR (
                        ?3 > 1 AND (
                            rn = 1 OR
                            ((rn - 1) * (?3 - 1)) / NULLIF(total - 1, 0) >
                            ((rn - 2) * (?3 - 1)) / NULLIF(total - 1, 0)
                        )
                    )
                 ORDER BY ts_us ASC, id ASC",
            )
            .map_err(|e| StoreError::Backend(format!("prepare sampled_events_between: {e}")))?;
        let rows = stmt
            .query_map(params![since, until, lim], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, String>(5)?,
                ))
            })
            .map_err(|e| StoreError::Backend(format!("query sampled_events_between: {e}")))?;

        let mut out = Vec::new();
        for row in rows {
            let (id, ts_us, app, title, url, text) =
                row.map_err(|e| StoreError::Backend(format!("row sampled_events_between: {e}")))?;
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
        let conn = guard.conn();
        // One query — COUNT + MIN + MAX over the same events scan.
        let row = conn
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
        // Four scalar counts over the V2-P6 graph tables (Phase-6 close).
        // Each is a cheap COUNT(*) over a table the current schema (0004 +
        // 0005) always provides; the readers only ever open a migrated DB.
        let table_count = |sql: &str| -> Result<u64, StoreError> {
            let n: i64 = conn
                .query_row(sql, [], |r| r.get(0))
                .map_err(|e| StoreError::Backend(format!("query stats graph count: {e}")))?;
            Ok(u64::try_from(n).unwrap_or(0))
        };
        let entity_count = table_count("SELECT COUNT(*) FROM entities")?;
        let entity_mention_count = table_count("SELECT COUNT(*) FROM entity_mentions")?;
        let entity_identity_count = table_count("SELECT COUNT(*) FROM entity_identities")?;
        let episode_edge_count = table_count("SELECT COUNT(*) FROM episode_edges")?;
        Ok(BrainStats {
            event_count: u64::try_from(count).unwrap_or(0),
            oldest_ts_us: min_ts.map(|v| u64::try_from(v).unwrap_or(0)),
            newest_ts_us: max_ts.map(|v| u64::try_from(v).unwrap_or(0)),
            entity_count,
            entity_mention_count,
            entity_identity_count,
            episode_edge_count,
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
                   AND length(trim(e.text, ' ' || char(9) || char(10) || char(11) || char(12) || char(13))) > 0
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
    /// `SQLite` query-planner friendliness on large `entity_mentions`
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
    /// O(episodes × `events_per_episode`) which is fine inside Phase 3's
    /// corpus regime; the `events_episode` index covers it.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any underlying `SQLite` failure.
    pub fn recent_episodes(&self, limit: usize) -> Result<Vec<crate::EpisodeRecord>, StoreError> {
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

    /// Return every distinct non-null `url` belonging to events tagged
    /// with exactly `app_bundle_id`. SELECT-only — no write side.
    ///
    /// The MCP one-shot sync (`mci-agent mcp-sync`) uses this to rebuild
    /// its already-ingested set across process boundaries. The aggregator
    /// dedupes resources through an in-memory set that lives for one
    /// process lifetime, which is right for the long-running agent and
    /// wrong for a command that runs once and exits: without a durable
    /// signal the second run would re-read every resource and write a
    /// duplicate event for each one. The aggregator stores the MCP
    /// resource URI verbatim in `events.url`, so for an `mcp:<server>`
    /// bundle id this URL set IS the already-ingested set.
    ///
    /// Uses the `events_app` index. `DISTINCT` is applied in `SQLite` so
    /// a server with many events per resource still returns one row per
    /// resource.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any underlying `SQLite` failure.
    pub fn distinct_urls_for_app(&self, app_bundle_id: &str) -> Result<Vec<String>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare(
                "SELECT DISTINCT url
                 FROM events
                 WHERE app_bundle_id = ?1
                   AND url IS NOT NULL",
            )
            .map_err(|e| StoreError::Backend(format!("prepare distinct_urls_for_app: {e}")))?;
        let rows = stmt
            .query_map(params![app_bundle_id], |r| r.get::<_, String>(0))
            .map_err(|e| StoreError::Backend(format!("query distinct_urls_for_app: {e}")))?;
        let mut out: Vec<String> = Vec::new();
        for r in rows {
            out.push(
                r.map_err(|e| StoreError::Backend(format!("row distinct_urls_for_app: {e}")))?,
            );
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
    /// The row id is stable across regenerates because `SQLite` reuses the
    /// primary key on REPLACE only when the conflicting row was already
    /// the primary-key target — here the conflict is on a UNIQUE index,
    /// not the PK, so `SQLite` deletes the conflicting row and inserts a
    /// fresh one. Callers that hold a brief id across a regenerate should
    /// re-look-up by `date_local` after writing.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any rusqlite failure.
    pub fn put_brief(&self, brief: &crate::BriefRow) -> Result<u64, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let generated_i64 = i64::try_from(brief.generated_ts_us).unwrap_or(i64::MAX);
        let word_count_i64 = i64::from(brief.word_count);
        let src_count_i64 = i64::from(brief.source_event_count);
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
        let id_i64 = guard.conn().last_insert_rowid();
        Ok(u64::try_from(id_i64).unwrap_or(0))
    }

    /// Look up the brief for one local date. `Ok(None)` if absent.
    pub fn brief_for_date(&self, date_local: &str) -> Result<Option<crate::BriefRow>, StoreError> {
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

    /// Boot-time `SQLCipher` integrity gate — the wrapper `apps/agent`
    /// calls immediately after [`SqlCipherBrainStore::new`] and BEFORE
    /// serving any read/write.
    ///
    /// Runs [`SqlCipherBrainStore::integrity_check`] (`PRAGMA
    /// integrity_check`) and enforces the healthy-DB contract: a valid
    /// store returns exactly `["ok"]`. Any deviation (backend error,
    /// non-`"ok"` row, or an unexpected row count) is corruption and
    /// surfaces as an [`IntegrityError`] with the raw pragma output
    /// preserved for the caller's debug log + follow-up repair UX.
    ///
    /// The pragma output is content-free (schema / index diagnostics
    /// only — no user event text) so callers may safely log it to
    /// stderr and the helper-health JSON log.
    ///
    /// Cycle 8.44 audit — closes breakage risk #3 (silent-data-loss on
    /// a corrupted DB). Wraps `integrity_check` per PR-body constraint;
    /// does not alter the underlying pragma path.
    ///
    /// # Errors
    /// - [`IntegrityError::Backend`] if the pragma itself failed
    ///   (driver-level; the underlying `StoreError::Backend` is
    ///   preserved verbatim).
    /// - [`IntegrityError::Corrupted`] if any pragma row is not
    ///   exactly `"ok"`. The full row set is preserved so the agent
    ///   can log it before refusing to serve.
    pub fn verify_integrity_on_boot(&self) -> Result<(), IntegrityError> {
        let rows = self
            .integrity_check()
            .map_err(|e| IntegrityError::Backend(format!("{e}")))?;
        if rows.len() == 1 && rows[0] == "ok" {
            // Observability signal — the boot path's caller (apps/agent)
            // additionally emits a `helper_health` line via its
            // structured logger. This crate stays log-framework-free.
            eprintln!("brain: integrity_check ok");
            Ok(())
        } else {
            Err(IntegrityError::Corrupted(rows))
        }
    }

    // ---------------------------------------------------------------
    // Cycle 8.47 — Privacy Dashboard delete surface (PR #76 follow-up).
    //
    // These are the enumerated mutation entry points the FFI's
    // `mci_brain_ffi_delete_event` / `_delete_events_in_range` /
    // `_wipe_brain` methods call. They live on the writer-side store
    // (`SqlCipherBrainStore::new` handle) so the FFI's read-only handle
    // remains structurally incapable of writing. Every method:
    //
    //   1. Runs the DELETE inside a transaction.
    //   2. Commits the transaction.
    //   3. Runs `VACUUM` outside the transaction to reclaim disk pages.
    //
    // CASCADE cleanup (event_vectors, chunks, entity_mentions,
    // episode_edges) is handled by the ON DELETE CASCADE clauses in
    // migrations 0001 + 0004 + 0005. Governed-memory rows deliberately
    // use RESTRICT FKs, so each path stages its event ids and removes the
    // corresponding projection inside the same transaction first.
    // ---------------------------------------------------------------

    /// Delete one event by id. Returns the number of committed `events`
    /// rows deleted (0 or 1).
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any driver failure (missing row is
    /// NOT an error — it returns 0).
    pub fn delete_event(&self, id: EventId) -> Result<u64, StoreError> {
        self.delete_event_with_outcome(id)
            .map(|outcome| outcome.events_deleted)
    }

    /// Delete one event and report post-commit maintenance separately.
    ///
    /// An `Ok` value proves the deletion transaction committed. A failed
    /// `VACUUM` or keyframe unlink is recorded in `cleanup_warnings` rather
    /// than converted into an error that could falsely imply rollback.
    ///
    /// # Errors
    /// [`StoreError::Backend`] when work fails before or during commit.
    pub fn delete_event_with_outcome(&self, id: EventId) -> Result<DeletionOutcome, StoreError> {
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|e| StoreError::Backend(format!("begin delete_event tx: {e}")))?;
        let id_i = i64::try_from(id.0).unwrap_or(i64::MAX);
        let event = tx
            .query_row(
                "SELECT id, keyframe_blob FROM events WHERE id = ?1",
                params![id_i],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, Option<String>>(1)?)),
            )
            .optional()
            .map_err(|e| StoreError::Backend(format!("select delete event: {e}")))?;
        let event_ids = event
            .as_ref()
            .map(|(event_id, _)| vec![*event_id])
            .unwrap_or_default();
        let blob_digests = event
            .and_then(|(_, digest)| digest)
            .into_iter()
            .collect::<Vec<_>>();
        delete_projected_memory_for_events(&tx, &event_ids)?;
        let n = tx
            .execute("DELETE FROM events WHERE id = ?1", params![id_i])
            .map_err(|e| StoreError::Backend(format!("DELETE events: {e}")))?;
        tx.commit()
            .map_err(|e| StoreError::Backend(format!("commit delete_event tx: {e}")))?;
        Ok(run_post_delete_cleanup(
            guard.conn(),
            &self.blob_dir,
            &blob_digests,
            n as u64,
        ))
    }

    /// Delete every event whose `ts_us` falls in the inclusive range
    /// `[start_ts_us, end_ts_us]`. Returns the number of `events` rows
    /// deleted. `VACUUM`s after commit.
    ///
    /// Powers the Privacy Dashboard's "Delete last 24 hours" range action.
    /// The caller is expected to have already presented the typed-word
    /// "DELETE" confirmation UI; this method does no additional gating.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any driver failure.
    pub fn delete_events_in_range(
        &self,
        start_ts_us: u64,
        end_ts_us: u64,
    ) -> Result<u64, StoreError> {
        self.delete_events_in_range_with_outcome(start_ts_us, end_ts_us)
            .map(|outcome| outcome.events_deleted)
    }

    /// Delete an inclusive event range and report post-commit maintenance.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on invalid bounds or failure before commit.
    pub fn delete_events_in_range_with_outcome(
        &self,
        start_ts_us: u64,
        end_ts_us: u64,
    ) -> Result<DeletionOutcome, StoreError> {
        if start_ts_us > end_ts_us {
            return Err(StoreError::Backend(
                "delete_events_in_range: start_ts_us > end_ts_us".into(),
            ));
        }
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|e| StoreError::Backend(format!("begin delete_range tx: {e}")))?;
        let s_i = i64::try_from(start_ts_us).unwrap_or(i64::MAX);
        let e_i = i64::try_from(end_ts_us).unwrap_or(i64::MAX);
        let blob_digests = keyframe_digests_matching(
            &tx,
            "SELECT keyframe_blob FROM events
             WHERE ts_us >= ?1 AND ts_us <= ?2 AND keyframe_blob IS NOT NULL
             ORDER BY keyframe_blob",
            params![s_i, e_i],
            "select delete range keyframe blobs",
        )?;
        let event_ids = event_ids_matching(
            &tx,
            "SELECT id FROM events WHERE ts_us >= ?1 AND ts_us <= ?2 ORDER BY id",
            params![s_i, e_i],
            "select delete range events",
        )?;
        delete_projected_memory_for_events(&tx, &event_ids)?;
        let n = tx
            .execute(
                "DELETE FROM events WHERE ts_us >= ?1 AND ts_us <= ?2",
                params![s_i, e_i],
            )
            .map_err(|e| StoreError::Backend(format!("DELETE events range: {e}")))?;
        tx.commit()
            .map_err(|e| StoreError::Backend(format!("commit delete_range tx: {e}")))?;
        Ok(run_post_delete_cleanup(
            guard.conn(),
            &self.blob_dir,
            &blob_digests,
            n as u64,
        ))
    }

    /// Wipe every user-content row from the brain. Returns the number of
    /// `events` rows deleted (the primary user-visible count).
    ///
    /// Drops all rows from: `events`, `episodes`, `briefs`, `entities`,
    /// `entity_mentions`, `entity_identities`, `episode_edges`.
    /// Leaves the `meta` schema-version stamps intact so the DB remains
    /// a valid MCI store, just empty. `VACUUM`s after commit.
    ///
    /// # Errors
    /// [`StoreError::Backend`] on any driver failure. The DELETEs are
    /// wrapped in one transaction so a mid-wipe failure rolls back
    /// atomically — the store is either fully wiped or unchanged, never
    /// partially wiped.
    pub fn wipe_all(&self) -> Result<u64, StoreError> {
        self.wipe_all_with_outcome()
            .map(|outcome| outcome.events_deleted)
    }

    /// Wipe user content and report post-commit maintenance separately.
    ///
    /// # Errors
    /// [`StoreError::Backend`] when any transactional wipe step fails.
    pub fn wipe_all_with_outcome(&self) -> Result<DeletionOutcome, StoreError> {
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|e| StoreError::Backend(format!("begin wipe_all tx: {e}")))?;
        // Order: children with FK NOT ON DELETE CASCADE-safe first
        // (briefs is FK-free; entity_* is a parent-child chain). Then
        // events, then episodes. CASCADE covers event_vectors + chunks
        // + entity_mentions (children of events / entities).
        tx.execute("DELETE FROM briefs", [])
            .map_err(|e| StoreError::Backend(format!("DELETE briefs: {e}")))?;
        tx.execute("DELETE FROM episode_edges", [])
            .map_err(|e| StoreError::Backend(format!("DELETE episode_edges: {e}")))?;
        tx.execute("DELETE FROM entity_identities", [])
            .map_err(|e| StoreError::Backend(format!("DELETE entity_identities: {e}")))?;
        tx.execute("DELETE FROM entity_mentions", [])
            .map_err(|e| StoreError::Backend(format!("DELETE entity_mentions: {e}")))?;
        tx.execute("DELETE FROM entities", [])
            .map_err(|e| StoreError::Backend(format!("DELETE entities: {e}")))?;
        let blob_digests = keyframe_digests_matching(
            &tx,
            "SELECT keyframe_blob FROM events
             WHERE keyframe_blob IS NOT NULL ORDER BY keyframe_blob",
            [],
            "select wipe keyframe blobs",
        )?;
        let event_ids = event_ids_matching(
            &tx,
            "SELECT id FROM events ORDER BY id",
            [],
            "select wipe events",
        )?;
        delete_projected_memory_for_events(&tx, &event_ids)?;
        let n = tx
            .execute("DELETE FROM events", [])
            .map_err(|e| StoreError::Backend(format!("DELETE events: {e}")))?;
        tx.execute("DELETE FROM episodes", [])
            .map_err(|e| StoreError::Backend(format!("DELETE episodes: {e}")))?;
        tx.commit()
            .map_err(|e| StoreError::Backend(format!("commit wipe_all tx: {e}")))?;
        Ok(run_post_delete_cleanup(
            guard.conn(),
            &self.blob_dir,
            &blob_digests,
            n as u64,
        ))
    }
}

fn run_post_delete_cleanup(
    connection: &rusqlite::Connection,
    blob_dir: &Path,
    blob_digests: &[String],
    events_deleted: u64,
) -> DeletionOutcome {
    let mut cleanup_warnings = Vec::new();
    if let Err(error) = connection.execute_batch("VACUUM") {
        cleanup_warnings.push(DeletionCleanupWarning {
            stage: DeletionCleanupStage::Vacuum,
            diagnostic: format!("VACUUM after committed deletion: {error}"),
        });
    }
    if let Err(error) = remove_unreferenced_keyframe_blobs(connection, blob_dir, blob_digests) {
        cleanup_warnings.push(DeletionCleanupWarning {
            stage: DeletionCleanupStage::KeyframeBlobs,
            diagnostic: format!("keyframe cleanup after committed deletion: {error}"),
        });
    }
    DeletionOutcome {
        events_deleted,
        cleanup_warnings,
    }
}

fn event_ids_matching<P: rusqlite::Params>(
    tx: &rusqlite::Transaction<'_>,
    sql: &str,
    params: P,
    operation: &str,
) -> Result<Vec<i64>, StoreError> {
    let mut statement = tx
        .prepare(sql)
        .map_err(|error| StoreError::Backend(format!("prepare {operation}: {error}")))?;
    let rows = statement
        .query_map(params, |row| row.get::<_, i64>(0))
        .map_err(|error| StoreError::Backend(format!("query {operation}: {error}")))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| StoreError::Backend(format!("read {operation}: {error}")))
}

fn keyframe_digests_matching<P: rusqlite::Params>(
    tx: &rusqlite::Transaction<'_>,
    sql: &str,
    params: P,
    operation: &str,
) -> Result<Vec<String>, StoreError> {
    let mut statement = tx
        .prepare(sql)
        .map_err(|error| StoreError::Backend(format!("prepare {operation}: {error}")))?;
    let rows = statement
        .query_map(params, |row| row.get::<_, String>(0))
        .map_err(|error| StoreError::Backend(format!("query {operation}: {error}")))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| StoreError::Backend(format!("read {operation}: {error}")))
}

fn blob_dir_for_brain(brain_path: &Path) -> PathBuf {
    brain_path
        .parent()
        .map_or_else(|| PathBuf::from("blobs"), |parent| parent.join("blobs"))
}

fn is_keyframe_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn managed_blob_digest(file_name: &str) -> Option<&str> {
    let digest = file_name.strip_suffix(".bin")?;
    is_keyframe_digest(digest).then_some(digest)
}

fn is_managed_temporary_file(file_name: &str) -> bool {
    let Some(body) = file_name.strip_prefix('.') else {
        return false;
    };
    let Some(body) = body.strip_suffix(".tmp") else {
        return false;
    };
    let Some((digest, nonce)) = body.split_once('.') else {
        return false;
    };
    is_keyframe_digest(digest)
        && nonce.len() == 36
        && nonce.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn entry_is_old_enough(metadata: &std::fs::Metadata, grace: Duration, now: SystemTime) -> bool {
    if grace.is_zero() {
        return true;
    }
    metadata
        .modified()
        .ok()
        .and_then(|modified| now.duration_since(modified).ok())
        .is_some_and(|age| age >= grace)
}

fn reconcile_keyframe_blob_directory(
    connection: &rusqlite::Connection,
    blob_dir: &Path,
    minimum_orphan_age: Duration,
    now: SystemTime,
) -> Result<BlobReconciliationStats, StoreError> {
    let mut referenced = {
        let mut statement = connection
            .prepare(
                "SELECT DISTINCT keyframe_blob FROM events
                 WHERE keyframe_blob IS NOT NULL ORDER BY keyframe_blob",
            )
            .map_err(|error| {
                StoreError::Backend(format!("prepare keyframe blob references: {error}"))
            })?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|error| {
                StoreError::Backend(format!("query keyframe blob references: {error}"))
            })?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| {
                StoreError::Backend(format!("read keyframe blob references: {error}"))
            })?
            .into_iter()
            .filter(|digest| is_keyframe_digest(digest))
            .collect::<BTreeSet<_>>()
    };

    let directory_metadata = match std::fs::symlink_metadata(blob_dir) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(BlobReconciliationStats {
                referenced_blobs_missing: u64::try_from(referenced.len()).unwrap_or(u64::MAX),
                ..BlobReconciliationStats::default()
            })
        }
        Err(error) => {
            return Err(StoreError::Backend(format!(
                "inspect keyframe blob directory: {error}"
            )))
        }
    };
    if directory_metadata.file_type().is_symlink() || !directory_metadata.is_dir() {
        return Err(StoreError::Backend(
            "keyframe blob directory is not a regular directory".into(),
        ));
    }

    let mut stats = BlobReconciliationStats::default();
    let entries = std::fs::read_dir(blob_dir)
        .map_err(|error| StoreError::Backend(format!("read keyframe blob directory: {error}")))?;
    for entry in entries {
        let Ok(entry) = entry else {
            stats.cleanup_errors = stats.cleanup_errors.saturating_add(1);
            continue;
        };
        let Some(file_name) = entry.file_name().to_str().map(str::to_owned) else {
            stats.unmanaged_entries_skipped = stats.unmanaged_entries_skipped.saturating_add(1);
            continue;
        };
        let managed_digest = managed_blob_digest(&file_name);
        let managed_temporary = is_managed_temporary_file(&file_name);
        if managed_digest.is_none() && !managed_temporary {
            stats.unmanaged_entries_skipped = stats.unmanaged_entries_skipped.saturating_add(1);
            continue;
        }

        let Ok(metadata) = std::fs::symlink_metadata(entry.path()) else {
            stats.cleanup_errors = stats.cleanup_errors.saturating_add(1);
            continue;
        };
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            stats.unmanaged_entries_skipped = stats.unmanaged_entries_skipped.saturating_add(1);
            continue;
        }

        if let Some(digest) = managed_digest {
            stats.managed_blobs_seen = stats.managed_blobs_seen.saturating_add(1);
            if referenced.remove(digest) {
                continue;
            }
        }
        if !entry_is_old_enough(&metadata, minimum_orphan_age, now) {
            stats.recent_orphans_retained = stats.recent_orphans_retained.saturating_add(1);
            continue;
        }

        match std::fs::remove_file(entry.path()) {
            Ok(()) if managed_temporary => {
                stats.stale_temporary_files_deleted =
                    stats.stale_temporary_files_deleted.saturating_add(1);
            }
            Ok(()) => {
                stats.orphaned_blobs_deleted = stats.orphaned_blobs_deleted.saturating_add(1);
            }
            Err(_) => {
                stats.cleanup_errors = stats.cleanup_errors.saturating_add(1);
            }
        }
    }
    stats.referenced_blobs_missing = u64::try_from(referenced.len()).unwrap_or(u64::MAX);
    Ok(stats)
}

fn remove_unreferenced_keyframe_blobs(
    connection: &rusqlite::Connection,
    blob_dir: &Path,
    candidates: &[String],
) -> Result<u64, StoreError> {
    let unique = candidates
        .iter()
        .map(String::as_str)
        .filter(|digest| is_keyframe_digest(digest))
        .collect::<BTreeSet<_>>();
    if unique.is_empty() {
        return Ok(0);
    }

    let directory_metadata = match std::fs::symlink_metadata(blob_dir) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(error) => {
            return Err(StoreError::Backend(format!(
                "inspect keyframe blob directory: {error}"
            )))
        }
    };
    if directory_metadata.file_type().is_symlink() || !directory_metadata.is_dir() {
        return Err(StoreError::Backend(
            "keyframe blob directory is not a regular directory".into(),
        ));
    }

    let mut deleted = 0_u64;
    for digest in unique {
        let references: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM events WHERE keyframe_blob = ?1",
                params![digest],
                |row| row.get(0),
            )
            .map_err(|error| {
                StoreError::Backend(format!("count keyframe blob references: {error}"))
            })?;
        if references > 0 {
            continue;
        }

        let path = blob_dir.join(format!("{digest}.bin"));
        let metadata = match std::fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(StoreError::Backend(format!(
                    "inspect keyframe blob candidate: {error}"
                )))
            }
        };
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(StoreError::Backend(
                "keyframe blob candidate is not a regular file".into(),
            ));
        }
        std::fs::remove_file(&path)
            .map_err(|error| StoreError::Backend(format!("delete keyframe blob: {error}")))?;
        deleted = deleted.saturating_add(1);
    }

    Ok(deleted)
}

pub(crate) fn delete_projected_memory_for_events(
    tx: &rusqlite::Transaction<'_>,
    event_ids: &[i64],
) -> Result<(), StoreError> {
    if event_ids.is_empty() {
        return Ok(());
    }
    prepare_memory_deletion_staging(tx)?;
    stage_deleted_event_ids(tx, event_ids)?;
    stage_memory_deletion_closure(tx)?;
    delete_staged_memory(tx)?;
    clear_memory_deletion_staging(tx)
}

fn prepare_memory_deletion_staging(tx: &rusqlite::Transaction<'_>) -> Result<(), StoreError> {
    tx.execute_batch(
        "CREATE TEMP TABLE IF NOT EXISTS memory_events_pending_delete (
             id INTEGER PRIMARY KEY
         ) WITHOUT ROWID;
         CREATE TEMP TABLE IF NOT EXISTS memory_deltas_pending_delete (
             id TEXT PRIMARY KEY
         ) WITHOUT ROWID;
         CREATE TEMP TABLE IF NOT EXISTS memory_claims_pending_delete (
             id TEXT PRIMARY KEY
         ) WITHOUT ROWID;
         CREATE TEMP TABLE IF NOT EXISTS memory_evidence_pending_delete (
             id TEXT PRIMARY KEY
         ) WITHOUT ROWID;
         DELETE FROM memory_events_pending_delete;
         DELETE FROM memory_deltas_pending_delete;
         DELETE FROM memory_claims_pending_delete;
         DELETE FROM memory_evidence_pending_delete;",
    )
    .map_err(|error| StoreError::Backend(format!("prepare memory deletion: {error}")))
}

fn stage_deleted_event_ids(
    tx: &rusqlite::Transaction<'_>,
    event_ids: &[i64],
) -> Result<(), StoreError> {
    let mut insert = tx
        .prepare("INSERT INTO memory_events_pending_delete (id) VALUES (?1)")
        .map_err(|error| StoreError::Backend(format!("prepare staged event deletion: {error}")))?;
    for event_id in event_ids {
        insert.execute(params![event_id]).map_err(|error| {
            StoreError::Backend(format!("stage event {event_id} for deletion: {error}"))
        })?;
    }
    Ok(())
}

fn stage_memory_deletion_closure(tx: &rusqlite::Transaction<'_>) -> Result<(), StoreError> {
    tx.execute(
        "INSERT OR IGNORE INTO memory_deltas_pending_delete (id)
         SELECT id FROM memory_deltas
         WHERE source_event_id IN (SELECT id FROM memory_events_pending_delete)",
        [],
    )
    .map_err(|error| StoreError::Backend(format!("stage source memory deltas: {error}")))?;
    tx.execute(
        "INSERT OR IGNORE INTO memory_claims_pending_delete (id)
         SELECT claim.id
         FROM memory_claims claim
         WHERE claim.source_event_id IN (SELECT id FROM memory_events_pending_delete)
            OR EXISTS (
                SELECT 1
                FROM memory_claim_evidence link
                JOIN memory_evidence evidence ON evidence.id = link.evidence_id
                WHERE link.claim_id = claim.id
                  AND evidence.event_id IN (SELECT id FROM memory_events_pending_delete)
            )",
        [],
    )
    .map_err(|error| StoreError::Backend(format!("stage directly affected claims: {error}")))?;

    loop {
        let deltas_added = tx
            .execute(
                "INSERT OR IGNORE INTO memory_deltas_pending_delete (id)
                 SELECT delta_id FROM memory_claims
                 WHERE delta_id IS NOT NULL
                   AND id IN (SELECT id FROM memory_claims_pending_delete)
                 UNION
                 SELECT transition.delta_id
                 FROM memory_claim_transitions transition
                 WHERE transition.delta_id IS NOT NULL
                   AND transition.claim_id IN (SELECT id FROM memory_claims_pending_delete)",
                [],
            )
            .map_err(|error| StoreError::Backend(format!("close owned memory deltas: {error}")))?;
        let claims_added = tx
            .execute(
                "INSERT OR IGNORE INTO memory_claims_pending_delete (id)
                 SELECT id FROM memory_claims
                 WHERE delta_id IN (SELECT id FROM memory_deltas_pending_delete)
                 UNION
                 SELECT child.id
                 FROM memory_claims child
                 WHERE child.supersedes_claim_id IN (
                     SELECT id FROM memory_claims_pending_delete
                 )",
                [],
            )
            .map_err(|error| StoreError::Backend(format!("close owned memory claims: {error}")))?;
        if deltas_added + claims_added == 0 {
            break;
        }
    }

    tx.execute(
        "INSERT OR IGNORE INTO memory_evidence_pending_delete (id)
         SELECT id FROM memory_evidence
         WHERE event_id IN (SELECT id FROM memory_events_pending_delete)
         UNION
         SELECT link.evidence_id
         FROM memory_claim_evidence link
         WHERE link.claim_id IN (SELECT id FROM memory_claims_pending_delete)",
        [],
    )
    .map_err(|error| StoreError::Backend(format!("stage affected memory evidence: {error}")))?;
    Ok(())
}

fn delete_staged_memory(tx: &rusqlite::Transaction<'_>) -> Result<(), StoreError> {
    tx.execute(
        "DELETE FROM memory_claim_transitions
         WHERE delta_id IN (SELECT id FROM memory_deltas_pending_delete)
            OR claim_id IN (SELECT id FROM memory_claims_pending_delete)",
        [],
    )
    .map_err(|error| StoreError::Backend(format!("delete memory transitions: {error}")))?;
    tx.execute(
        "DELETE FROM memory_claim_transitions
         WHERE source_event_id IN (SELECT id FROM memory_events_pending_delete)",
        [],
    )
    .map_err(|error| StoreError::Backend(format!("delete event-owned transitions: {error}")))?;
    tx.execute(
        "DELETE FROM memory_claim_evidence
         WHERE claim_id IN (SELECT id FROM memory_claims_pending_delete)
            OR evidence_id IN (SELECT id FROM memory_evidence_pending_delete)",
        [],
    )
    .map_err(|error| StoreError::Backend(format!("delete memory evidence links: {error}")))?;

    loop {
        let remaining: i64 = tx
            .query_row(
                "SELECT COUNT(*) FROM memory_claims_pending_delete",
                [],
                |row| row.get(0),
            )
            .map_err(|error| StoreError::Backend(format!("count staged memory claims: {error}")))?;
        if remaining == 0 {
            break;
        }
        let deleted = tx
            .execute(
                "DELETE FROM memory_claims
                 WHERE id IN (SELECT id FROM memory_claims_pending_delete)
                   AND NOT EXISTS (
                       SELECT 1 FROM memory_claims child
                       WHERE child.supersedes_claim_id = memory_claims.id
                   )",
                [],
            )
            .map_err(|error| StoreError::Backend(format!("delete memory claims: {error}")))?;
        if deleted == 0 {
            return Err(StoreError::Backend(
                "delete memory claims: dependent claim graph did not make progress".into(),
            ));
        }
        tx.execute(
            "DELETE FROM memory_claims_pending_delete
             WHERE id NOT IN (SELECT id FROM memory_claims)",
            [],
        )
        .map_err(|error| StoreError::Backend(format!("advance memory claim deletion: {error}")))?;
    }

    tx.execute(
        "DELETE FROM memory_evidence
         WHERE id IN (SELECT id FROM memory_evidence_pending_delete)
           AND NOT EXISTS (
                SELECT 1 FROM memory_claim_evidence link
                WHERE link.evidence_id = memory_evidence.id
            )",
        [],
    )
    .map_err(|error| StoreError::Backend(format!("delete memory evidence: {error}")))?;
    tx.execute(
        "DELETE FROM memory_event_retractions
         WHERE target_event_id IN (SELECT id FROM memory_events_pending_delete)
            OR retraction_event_id IN (SELECT id FROM memory_events_pending_delete)",
        [],
    )
    .map_err(|error| StoreError::Backend(format!("delete memory retractions: {error}")))?;
    tx.execute(
        "DELETE FROM memory_deltas
         WHERE id IN (SELECT id FROM memory_deltas_pending_delete)",
        [],
    )
    .map_err(|error| StoreError::Backend(format!("delete memory deltas: {error}")))?;
    Ok(())
}

fn clear_memory_deletion_staging(tx: &rusqlite::Transaction<'_>) -> Result<(), StoreError> {
    tx.execute_batch(
        "DELETE FROM memory_claims_pending_delete;
         DELETE FROM memory_deltas_pending_delete;
         DELETE FROM memory_evidence_pending_delete;
         DELETE FROM memory_events_pending_delete;
        ",
    )
    .map_err(|error| StoreError::Backend(format!("clear memory deletion staging: {error}")))
}

/// Typed outcome of [`SqlCipherBrainStore::verify_integrity_on_boot`].
///
/// A `Corrupted` variant is the trigger for the agent's refuse-to-serve
/// path (cycle 8.44 audit breakage risk #3): on this error the agent
/// MUST NOT accept MCP requests or start ingest pumps. The raw pragma
/// output is preserved so the caller can log it + surface it to the
/// menu-bar red-pill / repair modal.
#[derive(Debug, thiserror::Error)]
pub enum IntegrityError {
    /// The underlying `PRAGMA integrity_check` query itself failed
    /// (driver / SQLCipher-level error). The wrapped string is the
    /// original [`StoreError`] `Display`.
    #[error("integrity: backend: {0}")]
    Backend(String),
    /// The pragma completed but reported at least one non-`"ok"` row —
    /// the DB is corrupted. All rows are preserved verbatim; a healthy
    /// DB is exactly `["ok"]` per `SQLite` semantics.
    #[error("integrity: corrupted ({0:?})")]
    Corrupted(Vec<String>),
}

/// Schema migration — ADR-0016 §1.4. Idempotent: every `CREATE` is
/// `IF NOT EXISTS`, every meta stamp is `INSERT OR REPLACE`. Runs inside
/// one transaction so a partial migration cannot leave the store in a
/// torn state (`SQLCipher` rolls back DDL on commit failure).
fn run_brain_migration(db: &mut Db) -> Result<(), StoreError> {
    // Every brain migration, including memory ownership rebuilds, runs
    // inside one transaction so a partial apply cannot leave a mixed schema.
    let sql_0001 = include_str!("../migrations/0001_phase_3_brain_schema.sql");
    let sql_0002 = include_str!("../migrations/0002_briefs.sql");
    let sql_0003 = include_str!("../migrations/0003_events_tab_id.sql");
    let sql_0004 = include_str!("../migrations/0004_v2_graph_schema.sql");
    let sql_0005 = include_str!("../migrations/0005_entity_identities.sql");
    let sql_0006 = include_str!("../migrations/0006_memory_claims.sql");
    let tx = db
        .conn_mut()
        .transaction()
        .map_err(|e| StoreError::Backend(format!("begin migration tx: {e}")))?;
    let meta_exists = tx
        .query_row(
            "SELECT EXISTS(
                 SELECT 1 FROM sqlite_master WHERE type='table' AND name='meta'
             )",
            [],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|error| StoreError::Backend(format!("probe starting schema version: {error}")))?;
    let starting_version = if meta_exists {
        tx.query_row(
            "SELECT value FROM meta WHERE key='brain_schema_version'",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(|error| StoreError::Backend(format!("read starting schema version: {error}")))?
    } else {
        None
    };
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
    if matches!(starting_version.as_deref(), Some("6" | "7")) {
        upgrade_memory_schema_to_v8(
            &tx,
            sql_0006,
            starting_version.as_deref().expect("matched legacy version"),
        )?;
    } else {
        tx.execute_batch(sql_0006)
            .map_err(|e| StoreError::Backend(format!("apply migration 0006: {e}")))?;
    }
    validate_memory_schema(&tx)
        .map_err(|error| StoreError::Backend(format!("validate migration 0008: {error}")))?;
    tx.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES ('brain_schema_version', '8')",
        [],
    )
    .map_err(|error| StoreError::Backend(format!("stamp migration 0008: {error}")))?;
    tx.commit()
        .map_err(|e| StoreError::Backend(format!("commit migration tx: {e}")))?;
    Ok(())
}

fn upgrade_memory_schema_to_v8(
    tx: &rusqlite::Transaction<'_>,
    canonical_schema: &str,
    starting_version: &str,
) -> Result<(), StoreError> {
    let has_event_retractions = backup_legacy_memory_rows(tx, starting_version)?;
    clear_legacy_memory_rows(tx, has_event_retractions)?;
    if has_event_retractions {
        tx.execute_batch("DROP TABLE memory_event_retractions;")
            .map_err(|error| {
                StoreError::Backend(format!("replace legacy retraction ledger: {error}"))
            })?;
    }
    tx.execute_batch(
        "DROP TABLE memory_claim_transitions;
         DROP TABLE memory_claim_evidence;
         DROP TABLE memory_claims;
         DROP TABLE memory_evidence;
         DROP TABLE memory_deltas;",
    )
    .map_err(|error| StoreError::Backend(format!("replace migration 0007 tables: {error}")))?;
    tx.execute_batch(canonical_schema)
        .map_err(|error| StoreError::Backend(format!("create migration 0008 tables: {error}")))?;
    restore_legacy_memory_rows(tx)
}

fn backup_legacy_memory_rows(
    tx: &rusqlite::Transaction<'_>,
    starting_version: &str,
) -> Result<bool, StoreError> {
    tx.execute_batch(
        "CREATE TEMP TABLE memory_deltas_v7_backup AS
             SELECT id, source_event_id, asserted_at_us, projector_version
             FROM memory_deltas;
         CREATE TEMP TABLE memory_evidence_v7_backup AS
             SELECT id, event_id, source_kind, source_locator, source_scope,
                    observed_at_us, content_hash
             FROM memory_evidence;
         CREATE TEMP TABLE memory_claims_v7_backup AS
             SELECT id, source_event_id, subject, predicate, object, scope,
                    attribution, confidence, asserted_at_us, valid_from_us,
                    valid_to_us, projector_version, initial_status, supersedes_claim_id
             FROM memory_claims;
         CREATE TEMP TABLE memory_claim_evidence_v7_backup AS
             SELECT claim_id, evidence_id FROM memory_claim_evidence;
         CREATE TEMP TABLE memory_claim_transitions_v7_backup AS
             SELECT id, claim_id, status, asserted_at_us, effective_at_us, reason,
                    source_event_id, projector_version
             FROM memory_claim_transitions;",
    )
    .map_err(|error| StoreError::Backend(format!("backup legacy memory rows: {error}")))?;

    let has_event_retractions = table_exists(tx, "memory_event_retractions")?;
    match (starting_version, has_event_retractions) {
        ("6", false) => tx
            .execute_batch(
                "CREATE TEMP TABLE memory_event_retractions_v7_backup (
                     id TEXT,
                     target_event_id INTEGER,
                     retraction_event_id INTEGER,
                     asserted_at_us INTEGER,
                     effective_at_us INTEGER,
                     reason TEXT,
                     projector_version TEXT
                 );",
            )
            .map_err(|error| {
                StoreError::Backend(format!("create empty v6 retraction backup: {error}"))
            })?,
        ("6" | "7", true) => tx
            .execute_batch(
                "CREATE TEMP TABLE memory_event_retractions_v7_backup AS
                     SELECT id, target_event_id, retraction_event_id, asserted_at_us,
                            effective_at_us, reason, projector_version
                     FROM memory_event_retractions;",
            )
            .map_err(|error| {
                StoreError::Backend(format!("backup legacy retraction rows: {error}"))
            })?,
        ("7", false) => {
            return Err(StoreError::Backend(
                "schema v7 is missing memory_event_retractions".into(),
            ));
        }
        (version, _) => {
            return Err(StoreError::Backend(format!(
                "unsupported legacy memory schema version {version}"
            )));
        }
    }
    Ok(has_event_retractions)
}

fn table_exists(tx: &rusqlite::Transaction<'_>, table: &str) -> Result<bool, StoreError> {
    tx.query_row(
        "SELECT EXISTS(
             SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1
         )",
        params![table],
        |row| row.get(0),
    )
    .map_err(|error| StoreError::Backend(format!("probe legacy table {table}: {error}")))
}

fn restore_legacy_memory_rows(tx: &rusqlite::Transaction<'_>) -> Result<(), StoreError> {
    tx.execute_batch(
        "INSERT INTO memory_deltas (id, source_event_id, asserted_at_us, projector_version)
             SELECT id, source_event_id, asserted_at_us, projector_version
             FROM memory_deltas_v7_backup ORDER BY id;
         INSERT INTO memory_evidence
             (id, event_id, source_kind, source_locator, source_scope,
              observed_at_us, content_hash)
             SELECT id, event_id, source_kind, source_locator, source_scope,
                    observed_at_us, content_hash
             FROM memory_evidence_v7_backup ORDER BY id;
         WITH RECURSIVE ordered_claims(id, depth) AS (
             SELECT id, 0
             FROM memory_claims_v7_backup
             WHERE supersedes_claim_id IS NULL
             UNION ALL
             SELECT child.id, parent.depth + 1
             FROM memory_claims_v7_backup child
             JOIN ordered_claims parent
               ON child.supersedes_claim_id = parent.id
         )
         INSERT INTO memory_claims
             (id, delta_id, source_event_id, subject, predicate, object, scope,
              attribution, confidence, asserted_at_us, valid_from_us, valid_to_us,
              projector_version, initial_status, supersedes_claim_id)
             SELECT claim.id,
                    (SELECT CASE WHEN COUNT(*) = 1 THEN MIN(delta.id) END
                     FROM memory_deltas_v7_backup delta
                     WHERE delta.source_event_id = claim.source_event_id
                       AND delta.asserted_at_us = claim.asserted_at_us),
                    claim.source_event_id, claim.subject, claim.predicate, claim.object,
                    claim.scope, claim.attribution, claim.confidence, claim.asserted_at_us,
                    claim.valid_from_us, claim.valid_to_us, claim.projector_version,
                    claim.initial_status, claim.supersedes_claim_id
             FROM memory_claims_v7_backup claim
             JOIN ordered_claims ordering ON ordering.id = claim.id
             ORDER BY ordering.depth, claim.id;
         INSERT INTO memory_claim_evidence
             (claim_id, evidence_id)
             SELECT claim_id, evidence_id
             FROM memory_claim_evidence_v7_backup ORDER BY claim_id, evidence_id;
         INSERT INTO memory_claim_transitions
             (id, delta_id, claim_id, status, asserted_at_us, effective_at_us, reason,
              source_event_id, projector_version)
             SELECT transition.id,
                    (SELECT CASE WHEN COUNT(*) = 1 THEN MIN(delta.id) END
                     FROM memory_deltas_v7_backup delta
                     WHERE delta.source_event_id = transition.source_event_id
                       AND delta.asserted_at_us = transition.asserted_at_us),
                    transition.claim_id, transition.status, transition.asserted_at_us,
                    transition.effective_at_us, transition.reason,
                    transition.source_event_id, transition.projector_version
             FROM memory_claim_transitions_v7_backup transition
             ORDER BY transition.id;
         INSERT INTO memory_event_retractions
             (id, target_event_id, retraction_event_id, asserted_at_us,
              effective_at_us, reason, projector_version)
             SELECT id, target_event_id, retraction_event_id, asserted_at_us,
                    effective_at_us, reason, projector_version
             FROM memory_event_retractions_v7_backup ORDER BY id;
         DROP TABLE memory_claim_transitions_v7_backup;
         DROP TABLE memory_claim_evidence_v7_backup;
         DROP TABLE memory_event_retractions_v7_backup;
         DROP TABLE memory_claims_v7_backup;
         DROP TABLE memory_evidence_v7_backup;
         DROP TABLE memory_deltas_v7_backup;",
    )
    .map_err(|error| StoreError::Backend(format!("restore migration 0008 rows: {error}")))
}

fn clear_legacy_memory_rows(
    tx: &rusqlite::Transaction<'_>,
    has_event_retractions: bool,
) -> Result<(), StoreError> {
    tx.execute_batch("DELETE FROM memory_claim_transitions; DELETE FROM memory_claim_evidence;")
        .map_err(|error| StoreError::Backend(format!("clear migration 0007 children: {error}")))?;
    if has_event_retractions {
        tx.execute("DELETE FROM memory_event_retractions", [])
            .map_err(|error| {
                StoreError::Backend(format!("clear legacy event retractions: {error}"))
            })?;
    }
    loop {
        let remaining: i64 = tx
            .query_row("SELECT COUNT(*) FROM memory_claims", [], |row| row.get(0))
            .map_err(|error| StoreError::Backend(format!("count migration claims: {error}")))?;
        if remaining == 0 {
            break;
        }
        let deleted = tx
            .execute(
                "DELETE FROM memory_claims
                 WHERE NOT EXISTS (
                     SELECT 1 FROM memory_claims child
                     WHERE child.supersedes_claim_id = memory_claims.id
                 )",
                [],
            )
            .map_err(|error| StoreError::Backend(format!("clear migration claims: {error}")))?;
        if deleted == 0 {
            return Err(StoreError::Backend(
                "clear migration claims: correction graph contains a cycle".into(),
            ));
        }
    }
    tx.execute_batch(
        "DELETE FROM memory_evidence;
         DELETE FROM memory_deltas;",
    )
    .map_err(|error| StoreError::Backend(format!("clear migration 0007 roots: {error}")))
}

type ColumnShape = (&'static str, &'static str, bool, Option<&'static str>, i64);
type TableShape = (&'static str, &'static [ColumnShape]);
type ForeignKeyShape = (&'static str, &'static [&'static str]);
type IndexShape = (&'static str, &'static [&'static str]);
type TableIndexShape = (&'static str, &'static [IndexShape]);

const MEMORY_TABLE_SHAPES: &[TableShape] = &[
    (
        "memory_deltas",
        &[
            ("id", "TEXT", true, None, 1),
            ("source_event_id", "INTEGER", true, None, 0),
            ("asserted_at_us", "INTEGER", true, None, 0),
            ("projector_version", "TEXT", true, None, 0),
        ],
    ),
    (
        "memory_evidence",
        &[
            ("id", "TEXT", true, None, 1),
            ("event_id", "INTEGER", true, None, 0),
            ("source_kind", "TEXT", true, None, 0),
            ("source_locator", "TEXT", true, None, 0),
            ("source_scope", "TEXT", true, None, 0),
            ("observed_at_us", "INTEGER", true, None, 0),
            ("content_hash", "TEXT", true, None, 0),
        ],
    ),
    (
        "memory_claims",
        &[
            ("id", "TEXT", true, None, 1),
            ("delta_id", "TEXT", false, None, 0),
            ("source_event_id", "INTEGER", true, None, 0),
            ("subject", "TEXT", true, None, 0),
            ("predicate", "TEXT", true, None, 0),
            ("object", "TEXT", true, None, 0),
            ("scope", "TEXT", true, None, 0),
            ("attribution", "TEXT", false, None, 0),
            ("confidence", "REAL", true, None, 0),
            ("asserted_at_us", "INTEGER", true, None, 0),
            ("valid_from_us", "INTEGER", true, None, 0),
            ("valid_to_us", "INTEGER", false, None, 0),
            ("projector_version", "TEXT", true, None, 0),
            ("initial_status", "TEXT", true, None, 0),
            ("supersedes_claim_id", "TEXT", false, None, 0),
        ],
    ),
    (
        "memory_claim_evidence",
        &[
            ("claim_id", "TEXT", true, None, 1),
            ("evidence_id", "TEXT", true, None, 2),
        ],
    ),
    (
        "memory_claim_transitions",
        &[
            ("id", "TEXT", true, None, 1),
            ("delta_id", "TEXT", false, None, 0),
            ("claim_id", "TEXT", true, None, 0),
            ("status", "TEXT", true, None, 0),
            ("asserted_at_us", "INTEGER", true, None, 0),
            ("effective_at_us", "INTEGER", true, None, 0),
            ("reason", "TEXT", true, None, 0),
            ("source_event_id", "INTEGER", true, None, 0),
            ("projector_version", "TEXT", true, None, 0),
        ],
    ),
    (
        "memory_event_retractions",
        &[
            ("id", "TEXT", true, None, 1),
            ("target_event_id", "INTEGER", true, None, 0),
            ("retraction_event_id", "INTEGER", true, None, 0),
            ("asserted_at_us", "INTEGER", true, None, 0),
            ("effective_at_us", "INTEGER", true, None, 0),
            ("reason", "TEXT", true, None, 0),
            ("projector_version", "TEXT", true, None, 0),
        ],
    ),
];

const MEMORY_FOREIGN_KEYS: &[ForeignKeyShape] = &[
    (
        "memory_deltas",
        &["source_event_id:events:id:NO ACTION:RESTRICT:NONE"],
    ),
    (
        "memory_evidence",
        &["event_id:events:id:NO ACTION:RESTRICT:NONE"],
    ),
    (
        "memory_claims",
        &[
            "delta_id:memory_deltas:id:NO ACTION:RESTRICT:NONE",
            "source_event_id:events:id:NO ACTION:RESTRICT:NONE",
            "supersedes_claim_id:memory_claims:id:NO ACTION:RESTRICT:NONE",
        ],
    ),
    (
        "memory_claim_evidence",
        &[
            "claim_id:memory_claims:id:NO ACTION:RESTRICT:NONE",
            "evidence_id:memory_evidence:id:NO ACTION:RESTRICT:NONE",
        ],
    ),
    (
        "memory_claim_transitions",
        &[
            "claim_id:memory_claims:id:NO ACTION:RESTRICT:NONE",
            "delta_id:memory_deltas:id:NO ACTION:RESTRICT:NONE",
            "source_event_id:events:id:NO ACTION:RESTRICT:NONE",
        ],
    ),
    (
        "memory_event_retractions",
        &[
            "target_event_id:events:id:NO ACTION:RESTRICT:NONE",
            "retraction_event_id:events:id:NO ACTION:RESTRICT:NONE",
        ],
    ),
];

const MEMORY_INDEX_SHAPES: &[TableIndexShape] = &[
    ("memory_deltas", &[]),
    (
        "memory_evidence",
        &[("memory_evidence_event", &["event_id", "id"])],
    ),
    (
        "memory_claims",
        &[
            (
                "memory_claims_fact",
                &["subject", "predicate", "scope", "asserted_at_us", "id"],
            ),
            (
                "memory_claims_validity",
                &["valid_from_us", "valid_to_us", "asserted_at_us", "id"],
            ),
            (
                "memory_claims_supersedes",
                &["supersedes_claim_id", "asserted_at_us", "id"],
            ),
            ("memory_claims_delta", &["delta_id", "id"]),
        ],
    ),
    (
        "memory_claim_evidence",
        &[(
            "memory_claim_evidence_evidence",
            &["evidence_id", "claim_id"],
        )],
    ),
    (
        "memory_claim_transitions",
        &[
            (
                "memory_claim_transitions_latest",
                &["claim_id", "asserted_at_us", "effective_at_us", "id"],
            ),
            ("memory_claim_transitions_delta", &["delta_id", "id"]),
        ],
    ),
    (
        "memory_event_retractions",
        &[(
            "memory_event_retractions_target",
            &["target_event_id", "asserted_at_us", "effective_at_us", "id"],
        )],
    ),
];

fn validate_memory_schema(tx: &rusqlite::Transaction<'_>) -> Result<(), String> {
    validate_memory_columns(tx)?;
    validate_memory_foreign_keys(tx)?;
    validate_memory_constraints(tx)?;
    validate_memory_indexes(tx)
}

fn validate_memory_columns(tx: &rusqlite::Transaction<'_>) -> Result<(), String> {
    for (table, expected) in MEMORY_TABLE_SHAPES {
        let mut stmt = tx
            .prepare(&format!("PRAGMA table_xinfo({table})"))
            .map_err(|error| format!("prepare {table} columns: {error}"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)? != 0,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                ))
            })
            .map_err(|error| format!("query {table} columns: {error}"))?;
        let columns = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| format!("read {table} columns: {error}"))?;
        let expected = expected
            .iter()
            .enumerate()
            .map(|(cid, (name, kind, not_null, default, primary_key))| {
                (
                    i64::try_from(cid).expect("memory schema column count fits i64"),
                    (*name).to_owned(),
                    (*kind).to_owned(),
                    *not_null,
                    default.map(str::to_owned),
                    *primary_key,
                    0_i64,
                )
            })
            .collect::<Vec<_>>();
        if columns != expected {
            return Err(format!("{table} columns are incompatible: {columns:?}"));
        }
        drop(stmt);
        let column_names = expected
            .iter()
            .map(|(_, name, _, _, _, _, _)| name.as_str())
            .collect::<Vec<_>>();
        validate_column_collations(tx, table, &column_names)?;
    }
    Ok(())
}

fn validate_memory_foreign_keys(tx: &rusqlite::Transaction<'_>) -> Result<(), String> {
    for (table, expected) in MEMORY_FOREIGN_KEYS {
        let mut stmt = tx
            .prepare(&format!("PRAGMA foreign_key_list({table})"))
            .map_err(|error| format!("prepare {table} foreign keys: {error}"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok(format!(
                    "{}:{}:{}:{}:{}:{}",
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, String>(7)?,
                ))
            })
            .map_err(|error| format!("query {table} foreign keys: {error}"))?;
        let mut actual = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| format!("read {table} foreign keys: {error}"))?;
        actual.sort();
        let mut expected = expected.iter().map(ToString::to_string).collect::<Vec<_>>();
        expected.sort();
        if actual != expected {
            return Err(format!("{table} foreign keys are incompatible: {actual:?}"));
        }
    }
    Ok(())
}

fn validate_memory_constraints(tx: &rusqlite::Transaction<'_>) -> Result<(), String> {
    tx.execute_batch("SAVEPOINT memory_constraint_validation")
        .map_err(|error| format!("start memory constraint probes: {error}"))?;
    let result = run_memory_constraint_probes(tx);
    let rollback = tx
        .execute_batch(
            "ROLLBACK TO memory_constraint_validation;
             RELEASE memory_constraint_validation;",
        )
        .map_err(|error| format!("roll back memory constraint probes: {error}"));
    result.and(rollback)
}

fn run_memory_constraint_probes(tx: &rusqlite::Transaction<'_>) -> Result<(), String> {
    let event_id = constraint_probe_event(tx)?;
    let proposed_id = unused_memory_id(tx, "memory_claims", "proposed")?;
    let active_id = unused_memory_id(tx, "memory_claims", "active")?;

    insert_constraint_probe_claim(tx, &proposed_id, event_id, "", 0.0, "proposed")
        .map_err(|error| format!("canonical proposed claim was rejected: {error}"))?;
    insert_constraint_probe_claim(tx, &active_id, event_id, "subject", 1.0, "active")
        .map_err(|error| format!("canonical active claim was rejected: {error}"))?;

    for (label, confidence, status) in [
        ("negative confidence", -0.01, "active"),
        ("confidence above one", 1.01, "active"),
        ("invalid initial status", 0.5, "invalid"),
    ] {
        let claim_id = unused_memory_id(tx, "memory_claims", label)?;
        expect_check_rejection(
            insert_constraint_probe_claim(tx, &claim_id, event_id, "subject", confidence, status),
            label,
        )?;
    }

    for status in ["superseded", "retracted", "contradicted"] {
        let transition_id = unused_memory_id(tx, "memory_claim_transitions", status)?;
        insert_constraint_probe_transition(tx, &transition_id, &active_id, event_id, status)
            .map_err(|error| {
                format!("canonical transition status {status} was rejected: {error}")
            })?;
    }
    let transition_id = unused_memory_id(tx, "memory_claim_transitions", "invalid")?;
    expect_check_rejection(
        insert_constraint_probe_transition(tx, &transition_id, &active_id, event_id, "invalid"),
        "invalid transition status",
    )
}

fn constraint_probe_event(tx: &rusqlite::Transaction<'_>) -> Result<i64, String> {
    if let Some(event_id) = tx
        .query_row("SELECT id FROM events ORDER BY id LIMIT 1", [], |row| {
            row.get(0)
        })
        .optional()
        .map_err(|error| format!("read constraint probe event: {error}"))?
    {
        return Ok(event_id);
    }
    tx.execute(
        "INSERT INTO events (id, ts_us, text, cascade_reason)
         VALUES (0, 0, 'memory schema constraint probe', 0)",
        [],
    )
    .map_err(|error| format!("insert constraint probe event: {error}"))?;
    Ok(0)
}

fn unused_memory_id(
    tx: &rusqlite::Transaction<'_>,
    table: &str,
    label: &str,
) -> Result<String, String> {
    for suffix in 0..1_000 {
        let id = format!("__memory_schema_probe_{label}_{suffix}");
        let exists = tx
            .query_row(
                &format!("SELECT EXISTS(SELECT 1 FROM {table} WHERE id=?1)"),
                params![&id],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|error| format!("probe {table} identity: {error}"))?;
        if !exists {
            return Ok(id);
        }
    }
    Err(format!(
        "could not allocate a constraint probe id in {table}"
    ))
}

fn insert_constraint_probe_claim(
    tx: &rusqlite::Transaction<'_>,
    id: &str,
    event_id: i64,
    subject: &str,
    confidence: f64,
    status: &str,
) -> rusqlite::Result<usize> {
    tx.execute(
        "INSERT INTO memory_claims
         (id, delta_id, source_event_id, subject, predicate, object, scope,
          attribution, confidence, asserted_at_us, valid_from_us, valid_to_us,
          projector_version, initial_status, supersedes_claim_id)
         VALUES (?1, NULL, ?2, ?3, 'predicate', 'object', 'scope', NULL, ?4,
                 0, 0, NULL, 'schema-probe', ?5, NULL)",
        params![id, event_id, subject, confidence, status],
    )
}

fn insert_constraint_probe_transition(
    tx: &rusqlite::Transaction<'_>,
    id: &str,
    claim_id: &str,
    event_id: i64,
    status: &str,
) -> rusqlite::Result<usize> {
    tx.execute(
        "INSERT INTO memory_claim_transitions
         (id, delta_id, claim_id, status, asserted_at_us, effective_at_us, reason,
          source_event_id, projector_version)
         VALUES (?1, NULL, ?2, ?3, 0, 0, 'schema probe', ?4, 'schema-probe')",
        params![id, claim_id, status, event_id],
    )
}

fn expect_check_rejection(result: rusqlite::Result<usize>, label: &str) -> Result<(), String> {
    match result {
        Err(rusqlite::Error::SqliteFailure(code, _))
            if code.extended_code == rusqlite::ffi::SQLITE_CONSTRAINT_CHECK =>
        {
            Ok(())
        }
        Err(error) => Err(format!("{label} hit a non-CHECK error: {error}")),
        Ok(_) => Err(format!("{label} was accepted")),
    }
}

fn validate_memory_indexes(tx: &rusqlite::Transaction<'_>) -> Result<(), String> {
    for (table, expected_indexes) in MEMORY_INDEX_SHAPES {
        let mut statement = tx
            .prepare(&format!("PRAGMA index_list({table})"))
            .map_err(|error| format!("prepare {table} indexes: {error}"))?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)? != 0,
                    row.get::<_, String>(3)?,
                    row.get::<_, i64>(4)? != 0,
                ))
            })
            .map_err(|error| format!("query {table} indexes: {error}"))?;
        let indexes = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| format!("read {table} indexes: {error}"))?;
        let primary = indexes
            .iter()
            .filter(|(_, unique, origin, partial)| origin == "pk" && *unique && !*partial)
            .count();
        if primary != 1 {
            return Err(format!("{table} must have exactly one primary-key index"));
        }
        let primary_index = indexes
            .iter()
            .find(|(_, unique, origin, partial)| origin == "pk" && *unique && !*partial)
            .map(|(name, _, _, _)| name)
            .ok_or_else(|| format!("{table} is missing its primary-key index"))?;
        let mut primary_columns = MEMORY_TABLE_SHAPES
            .iter()
            .find(|(name, _)| name == table)
            .expect("index table has a column shape")
            .1
            .iter()
            .filter(|(_, _, _, _, primary_key)| *primary_key > 0)
            .map(|(name, _, _, _, primary_key)| (*primary_key, *name))
            .collect::<Vec<_>>();
        primary_columns.sort_by_key(|(position, _)| *position);
        let primary_columns = primary_columns
            .iter()
            .map(|(_, name)| *name)
            .collect::<Vec<_>>();
        validate_index_xinfo(tx, primary_index, &primary_columns)?;
        let mut custom = indexes
            .iter()
            .filter(|(_, _, origin, _)| origin == "c")
            .map(|(name, unique, _, partial)| (name.clone(), *unique, *partial))
            .collect::<Vec<_>>();
        custom.sort();
        let mut expected_custom = expected_indexes
            .iter()
            .map(|(name, _)| ((*name).to_owned(), false, false))
            .collect::<Vec<_>>();
        expected_custom.sort();
        if custom != expected_custom || indexes.iter().any(|(_, _, origin, _)| origin == "u") {
            return Err(format!("{table} indexes are incompatible: {indexes:?}"));
        }
        for (index, expected_columns) in *expected_indexes {
            validate_index_xinfo(tx, index, expected_columns)?;
        }
    }
    Ok(())
}

fn validate_index_xinfo(
    tx: &rusqlite::Transaction<'_>,
    index: &str,
    expected_columns: &[&str],
) -> Result<(), String> {
    type IndexTerm = (Option<String>, bool, Option<String>, bool);
    let mut statement = tx
        .prepare(&format!("PRAGMA index_xinfo({index})"))
        .map_err(|error| format!("prepare {index}: {error}"))?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, Option<String>>(2)?,
                row.get::<_, i64>(3)? != 0,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, i64>(5)? != 0,
            ))
        })
        .map_err(|error| format!("query {index}: {error}"))?;
    let actual = rows
        .collect::<Result<Vec<IndexTerm>, _>>()
        .map_err(|error| format!("read {index}: {error}"))?;
    let mut expected = expected_columns
        .iter()
        .map(|column| {
            (
                Some((*column).to_owned()),
                false,
                Some("BINARY".into()),
                true,
            )
        })
        .collect::<Vec<_>>();
    expected.push((None, false, Some("BINARY".into()), false));
    if actual != expected {
        return Err(format!("{index} terms are incompatible: {actual:?}"));
    }
    Ok(())
}

fn validate_column_collations(
    tx: &rusqlite::Transaction<'_>,
    table: &str,
    columns: &[&str],
) -> Result<(), String> {
    let probe = format!("mci_schema_collation_probe_{table}");
    for column in columns {
        tx.execute_batch(&format!(
            "DROP INDEX IF EXISTS \"{probe}\";
             CREATE INDEX \"{probe}\" ON \"{table}\"(\"{column}\");"
        ))
        .map_err(|error| format!("create {table}.{column} collation probe: {error}"))?;
        let validation = validate_index_xinfo(tx, &probe, &[*column]);
        tx.execute_batch(&format!("DROP INDEX \"{probe}\";"))
            .map_err(|error| format!("drop {table}.{column} collation probe: {error}"))?;
        validation?;
    }
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
        // Pre-parse sanitization — see `fts_sanitizer` module docs.
        // Without this, a raw user query containing `:` (URLs, emails,
        // `key:value` shapes) triggers SQLite FTS5's `column:term`
        // parser and bubbles a `row fts5: no such column: <token>`
        // error up through the retriever (cycle 8.55 PR #111 panic).
        // Clean keyword queries pass through byte-identical, so
        // ranking / scoring for the common path is unaffected.
        let sanitized = crate::fts_sanitizer::sanitize_fts5_query(query);
        if sanitized.trim().is_empty() {
            // All-whitespace or purely stripped input — nothing left
            // to match. Treat as an empty pool (not an error) so a
            // benign whitespace-only paste degrades to "zero hits"
            // instead of the harsher `InvalidInput` panic on the
            // raw-empty branch above.
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
                 ORDER BY rank ASC, rowid ASC
                 LIMIT ?2",
            )
            .map_err(|e| StoreError::Backend(format!("prepare fts5: {e}")))?;
        let lim = i64::try_from(limit).unwrap_or(i64::MAX);
        let rows = stmt
            .query_map(params![sanitized, lim], |r| {
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
            .prepare("SELECT event_id, embedding FROM event_vectors ORDER BY event_id ASC")
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
        hits.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        hits.truncate(limit);
        Ok(hits)
    }

    /// ADR-0011 §5 candidate-pool pre-filter. Narrows the vector KNN to
    /// the event ids that satisfy the caller-supplied time / app filter
    /// **before** we do the O(N·d) cosine dot-product loop. On the 100K-
    /// event perf harness (PR #111) the brute-force `vec_search` blows
    /// the cold-P50 budget (200ms → 607ms) because it dots against every
    /// `event_vectors` row; the two indexes `events_ts` and `events_app`
    /// let `SQLite` narrow the pool to O(hundreds…thousands) rows in
    /// microseconds, at which point the cosine loop fits inside budget.
    ///
    /// Correctness: the WHERE clause is a candidate-pool narrowing, NOT
    /// a scoring change. When both filters are `None` this method is
    /// byte-identical to `vec_search` (delegates to it directly). When
    /// filters are set the returned top-k is a subset of what an
    /// unbounded KNN would return followed by the same post-filter — the
    /// retriever's row-level `if event.ts_us < tr.from_us ...` guard is
    /// still authoritative for the app/time invariant.
    fn vec_search_filtered(
        &self,
        query_embedding: &[f32],
        limit: usize,
        time_filter: Option<TimeRange>,
        app_filter: Option<&str>,
    ) -> Result<Vec<(EventId, f32)>, StoreError> {
        // Fast path: no filters → the default trait impl delegates to
        // `vec_search`, but calling that here forces one extra vtable
        // hop; skip it by delegating directly.
        if time_filter.is_none() && app_filter.is_none() {
            return self.vec_search(query_embedding, limit);
        }
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

        // Build the WHERE clause dynamically. Both `events_ts` and
        // `events_app` are ordinary btree indexes (see migration 0001);
        // SQLite's query planner picks the more selective one and the
        // JOIN back to event_vectors on `event_id` uses the FK's implicit
        // index. Positional params keep the prepared-statement cache
        // hot across calls.
        let mut sql = String::from(
            "SELECT ev.event_id, ev.embedding \
             FROM event_vectors ev \
             INNER JOIN events e ON e.id = ev.event_id \
             WHERE 1=1",
        );
        let mut param_idx: usize = 0;
        if time_filter.is_some() {
            let _ = write!(
                sql,
                " AND e.ts_us >= ?{} AND e.ts_us <= ?{}",
                param_idx + 1,
                param_idx + 2
            );
            param_idx += 2;
        }
        if app_filter.is_some() {
            let _ = write!(sql, " AND e.app_bundle_id = ?{}", param_idx + 1);
        }
        sql.push_str(" ORDER BY ev.event_id ASC");

        let mut stmt = guard
            .conn()
            .prepare(&sql)
            .map_err(|e| StoreError::Backend(format!("prepare vec_filtered: {e}")))?;

        // Assemble param values as a homogeneous `Vec<Value>` — same
        // pattern the graph reads use (`mention_match_for_events` in
        // this file). Positional binds keep the prepared-statement
        // cache hot across time-only / app-only / both-set call shapes.
        let mut binds: Vec<Value> = Vec::with_capacity(3);
        if let Some(tr) = time_filter {
            binds.push(Value::Integer(
                i64::try_from(tr.from_us).unwrap_or(i64::MAX),
            ));
            binds.push(Value::Integer(i64::try_from(tr.to_us).unwrap_or(i64::MAX)));
        }
        if let Some(app) = app_filter {
            binds.push(Value::Text(app.to_string()));
        }

        let rows = stmt
            .query_map(params_from_iter(binds.iter()), |r| {
                let event_id: i64 = r.get(0)?;
                let blob: Vec<u8> = r.get(1)?;
                Ok((event_id, blob))
            })
            .map_err(|e| StoreError::Backend(format!("query vec_filtered: {e}")))?;

        let mut hits: Vec<(EventId, f32)> = Vec::new();
        for r in rows {
            let (event_id, blob) =
                r.map_err(|e| StoreError::Backend(format!("row vec_filtered: {e}")))?;
            if blob.len() != EMBEDDING_BYTES {
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
        hits.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
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

    fn find_entity_by_alias(&self, kind: &str, alias: &str) -> Result<Option<Entity>, StoreError> {
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
        let keep: std::collections::BTreeSet<&str> = rows.iter().map(|r| r.id.0.as_str()).collect();
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

    fn identity_of_entity(&self, entity_id: &EntityId) -> Result<Vec<EntityIdentity>, StoreError> {
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

    // -----------------------------------------------------------------------
    // V2-P6 — Episode-edge Consolidator read+write path
    // -----------------------------------------------------------------------

    fn consolidation_candidates(&self) -> Result<Vec<IdentityMentionSite>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        // Join identities → their member entities' mentions → the
        // mentioning events. Restricted to SEGMENTED (episode_id NOT NULL)
        // and POST-cascade (cascade_reason = 0) events. `redacted_token`
        // never appears: `entity_identities` only ever holds the resolver's
        // alias allowlist. Ordered for the consolidator's single-pass group.
        //
        // FORWARD NOTE (CSO): the `episodes` table has no per-episode
        // privacy flag today. When V2-P7+ adds one (incognito / excluded
        // episodes), this WHERE clause MUST gain `AND ep.is_private = 0`
        // (joining `episodes`) so a private episode is never linked. Until
        // that column exists there is nothing to filter on; the existing
        // event-level cascade wall + the identity-allowlist join are the
        // current containment.
        let mut stmt = guard
            .conn()
            .prepare(
                "SELECT ei.identity_id, m.entity_id, e.episode_id, e.ts_us
                 FROM entity_identities ei
                 JOIN entity_mentions m ON m.entity_id = ei.entity_id
                 JOIN events e ON e.id = m.event_id
                 WHERE e.episode_id IS NOT NULL AND e.cascade_reason = 0
                 ORDER BY ei.identity_id, e.ts_us",
            )
            .map_err(|e| StoreError::Backend(format!("prepare consolidation_candidates: {e}")))?;
        let rows = stmt
            .query_map([], |r| {
                let identity_id: String = r.get(0)?;
                let entity_id: String = r.get(1)?;
                let episode_id: i64 = r.get(2)?;
                let ts_us: i64 = r.get(3)?;
                Ok(IdentityMentionSite {
                    identity_id: IdentityId(identity_id),
                    entity_id: EntityId(entity_id),
                    episode_id: EpisodeId(u64::try_from(episode_id).unwrap_or(0)),
                    ts_us: u64::try_from(ts_us).unwrap_or(0),
                })
            })
            .map_err(|e| StoreError::Backend(format!("query consolidation_candidates: {e}")))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r.map_err(|e| StoreError::Backend(format!("row candidate: {e}")))?);
        }
        Ok(out)
    }

    fn put_episode_edges(&self, edges: &[EpisodeEdge]) -> Result<u64, StoreError> {
        if edges.is_empty() {
            return Ok(0);
        }
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|e| StoreError::Backend(format!("begin put_episode_edges tx: {e}")))?;
        let mut inserted = 0u64;
        {
            let mut stmt = tx
                .prepare(
                    "INSERT OR IGNORE INTO episode_edges (
                        id, src_episode_id, dst_episode_id, edge_kind,
                        evidence_entity_ids, ts_us
                     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                )
                .map_err(|e| StoreError::Backend(format!("prepare put_episode_edges: {e}")))?;
            for edge in edges {
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
                let changed = stmt
                    .execute(params![
                        &edge.id.0,
                        src,
                        dst,
                        &edge.edge_kind,
                        &edge.evidence_entity_ids,
                        ts,
                    ])
                    .map_err(|e| StoreError::Backend(format!("INSERT episode_edges: {e}")))?;
                inserted += u64::try_from(changed).unwrap_or(0);
            }
        }
        tx.commit()
            .map_err(|e| StoreError::Backend(format!("commit put_episode_edges tx: {e}")))?;
        Ok(inserted)
    }

    fn reconcile_episode_edges(
        &self,
        kind: &str,
        edges: &[EpisodeEdge],
    ) -> Result<crate::ReconcileStats, StoreError> {
        let keep: std::collections::BTreeSet<&str> =
            edges.iter().map(|e| e.id.0.as_str()).collect();
        let mut guard = self.db.lock().expect("brain store mutex poisoned");
        let tx = guard
            .conn_mut()
            .transaction()
            .map_err(|e| StoreError::Backend(format!("begin reconcile edges tx: {e}")))?;

        // Read the currently-persisted PKs OF THIS KIND only, then prune any
        // not in `keep`. Scoping the DELETE to `edge_kind = ?1` means this
        // reconcile never touches edges of another kind (a future
        // `co_active` / `referenced` writer is independent).
        let existing: Vec<String> = {
            let mut stmt = tx
                .prepare("SELECT id FROM episode_edges WHERE edge_kind = ?1")
                .map_err(|e| StoreError::Backend(format!("prepare reconcile edges select: {e}")))?;
            let mapped = stmt
                .query_map(params![kind], |r| r.get::<_, String>(0))
                .map_err(|e| StoreError::Backend(format!("query reconcile edges select: {e}")))?;
            let mut out = Vec::new();
            for r in mapped {
                out.push(r.map_err(|e| StoreError::Backend(format!("row reconcile edge: {e}")))?);
            }
            out
        };

        let mut deleted = 0u64;
        for id in &existing {
            if !keep.contains(id.as_str()) {
                tx.execute("DELETE FROM episode_edges WHERE id = ?1", params![id])
                    .map_err(|e| StoreError::Backend(format!("DELETE episode_edges: {e}")))?;
                deleted += 1;
            }
        }

        // INSERT OR IGNORE the current set — preserves the first-write ts_us
        // of edges that already exist, so an unchanged re-run is a true
        // row-level no-op (zero inserts, zero deletes).
        let mut inserted = 0u64;
        {
            let mut stmt = tx
                .prepare(
                    "INSERT OR IGNORE INTO episode_edges (
                        id, src_episode_id, dst_episode_id, edge_kind,
                        evidence_entity_ids, ts_us
                     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                )
                .map_err(|e| StoreError::Backend(format!("prepare reconcile edges insert: {e}")))?;
            for edge in edges {
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
                let changed = stmt
                    .execute(params![
                        &edge.id.0,
                        src,
                        dst,
                        &edge.edge_kind,
                        &edge.evidence_entity_ids,
                        ts,
                    ])
                    .map_err(|e| StoreError::Backend(format!("INSERT reconcile edges: {e}")))?;
                inserted += u64::try_from(changed).unwrap_or(0);
            }
        }

        tx.commit()
            .map_err(|e| StoreError::Backend(format!("commit reconcile edges tx: {e}")))?;
        Ok(crate::ReconcileStats { inserted, deleted })
    }

    fn consolidation_watermark(&self) -> Result<ConsolidationWatermark, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let (identity_member_count, max_identity_ts_us): (i64, i64) = guard
            .conn()
            .query_row(
                "SELECT COUNT(*), COALESCE(MAX(ts_us), 0) FROM entity_identities",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .map_err(|e| StoreError::Backend(format!("watermark identities: {e}")))?;
        let (mention_count, max_mention_ts_us): (i64, i64) = guard
            .conn()
            .query_row(
                "SELECT COUNT(*), COALESCE(MAX(ts_us), 0) FROM entity_mentions",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .map_err(|e| StoreError::Backend(format!("watermark mentions: {e}")))?;
        let (segmented_event_count, max_episode_id): (i64, i64) = guard
            .conn()
            .query_row(
                "SELECT COUNT(*), COALESCE(MAX(episode_id), 0)
                 FROM events WHERE episode_id IS NOT NULL",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .map_err(|e| StoreError::Backend(format!("watermark episodes: {e}")))?;
        Ok(ConsolidationWatermark {
            identity_member_count,
            max_identity_ts_us,
            mention_count,
            max_mention_ts_us,
            segmented_event_count,
            max_episode_id,
        })
    }

    fn episode_edges_for_identity(
        &self,
        identity_id: &IdentityId,
    ) -> Result<Vec<EpisodeEdge>, StoreError> {
        let guard = self.db.lock().expect("brain store mutex poisoned");
        // Scan the `shared_identity` edges (the `episode_edges_kind` index
        // serves the predicate), then keep only the ones whose
        // content-stable PK re-derives for THIS identity. The PK folds the
        // identity in, so the re-derivation is an exact per-identity filter
        // — an edge built for a different identity over the same episode
        // pair has a different PK and is excluded. No episode-set
        // sub-query needed (and no SQLite variable-limit exposure).
        //
        // COST: O(|shared_identity edges|) per call (scan + in-Rust PK
        // re-derive), returning the few that match. Fine at single-user
        // Phase-6 scale; if the cross-app graph grows large, a future
        // migration could denormalize `identity_id` into an indexed column
        // and pre-filter in SQL (the PK fold is what blocks an index today).
        let mut stmt = guard
            .conn()
            .prepare(
                "SELECT id, src_episode_id, dst_episode_id, edge_kind,
                        evidence_entity_ids, ts_us
                 FROM episode_edges
                 WHERE edge_kind = ?1
                 ORDER BY src_episode_id, dst_episode_id",
            )
            .map_err(|e| StoreError::Backend(format!("prepare episode_edges_for_identity: {e}")))?;
        let rows = stmt
            .query_map(
                params![EpisodeEdge::KIND_SHARED_IDENTITY],
                row_to_episode_edge,
            )
            .map_err(|e| StoreError::Backend(format!("query episode_edges_for_identity: {e}")))?;
        let mut out = Vec::new();
        for r in rows {
            let edge = r.map_err(|e| StoreError::Backend(format!("row episode_edge: {e}")))?;
            let expect = EpisodeEdge::derive_shared_identity_id(
                edge.src_episode_id,
                edge.dst_episode_id,
                identity_id,
            );
            if expect.0 == edge.id.0 {
                out.push(edge);
            }
        }
        Ok(out)
    }

    fn events_in_episode(
        &self,
        episode_id: EpisodeId,
        limit: usize,
    ) -> Result<Vec<EventRecord>, StoreError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let ep = i64::try_from(episode_id.0).map_err(|e| {
            StoreError::InvalidInput(format!("episode id {} out of i64 range: {e}", episode_id.0))
        })?;
        let lim = i64::try_from(limit).unwrap_or(i64::MAX);
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare(
                "SELECT id, ts_us, app_bundle_id, window_title, url, text
                 FROM events
                 WHERE episode_id = ?1
                 ORDER BY ts_us DESC
                 LIMIT ?2",
            )
            .map_err(|e| StoreError::Backend(format!("prepare events_in_episode: {e}")))?;
        let rows = stmt
            .query_map(params![ep, lim], |r| {
                let id: i64 = r.get(0)?;
                let ts_us: i64 = r.get(1)?;
                let app: Option<String> = r.get(2)?;
                let title: Option<String> = r.get(3)?;
                let url: Option<String> = r.get(4)?;
                let text: String = r.get(5)?;
                Ok((id, ts_us, app, title, url, text))
            })
            .map_err(|e| StoreError::Backend(format!("query events_in_episode: {e}")))?;
        let mut out = Vec::new();
        for r in rows {
            let (id, ts_us, app, title, url, text) =
                r.map_err(|e| StoreError::Backend(format!("row events_in_episode: {e}")))?;
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
    // Recall-surface fusion (Phase-6 close) — query-side entity reads
    // -----------------------------------------------------------------------

    fn mention_match_for_events(
        &self,
        query_entity_ids: &[EntityId],
        candidate_ids: &[EventId],
    ) -> Result<HashMap<EventId, u32>, StoreError> {
        if query_entity_ids.is_empty() || candidate_ids.is_empty() {
            return Ok(HashMap::new());
        }
        // Two positional IN-lists: candidate event ids (INTEGER) then
        // query entity ids (TEXT). Bound counts are small — candidate_ids
        // ≤ k_lex + k_sem (default 400) and query_entity_ids is a handful —
        // so the total stays far under SQLite's variable limit.
        let events_in = vec!["?"; candidate_ids.len()].join(",");
        let entities_in = vec!["?"; query_entity_ids.len()].join(",");
        let sql = format!(
            "SELECT event_id, COUNT(*) FROM entity_mentions
             WHERE event_id IN ({events_in}) AND entity_id IN ({entities_in})
             GROUP BY event_id"
        );
        let mut binds: Vec<Value> =
            Vec::with_capacity(candidate_ids.len() + query_entity_ids.len());
        for id in candidate_ids {
            binds.push(Value::Integer(i64::try_from(id.0).unwrap_or(i64::MAX)));
        }
        for eid in query_entity_ids {
            binds.push(Value::Text(eid.0.clone()));
        }
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare(&sql)
            .map_err(|e| StoreError::Backend(format!("prepare mention_match_for_events: {e}")))?;
        let rows = stmt
            .query_map(params_from_iter(binds.iter()), |r| {
                let event_id: i64 = r.get(0)?;
                let count: i64 = r.get(1)?;
                Ok((event_id, count))
            })
            .map_err(|e| StoreError::Backend(format!("query mention_match_for_events: {e}")))?;
        let mut out: HashMap<EventId, u32> = HashMap::new();
        for r in rows {
            let (event_id, count) =
                r.map_err(|e| StoreError::Backend(format!("row mention_match: {e}")))?;
            out.insert(
                EventId(u64::try_from(event_id).unwrap_or(0)),
                u32::try_from(count).unwrap_or(u32::MAX),
            );
        }
        Ok(out)
    }

    fn entity_names_for_event(
        &self,
        event_id: EventId,
        limit: usize,
    ) -> Result<Vec<String>, StoreError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        // Restrict to the resolver allowlist (person/org/location/email/
        // phone/url) so a `redacted_token` subkind label can never surface.
        let placeholders = resolvable_kinds_placeholders();
        let sql = format!(
            "SELECT DISTINCT en.canonical_name
             FROM entity_mentions m JOIN entities en ON en.id = m.entity_id
             WHERE m.event_id = ? AND en.kind IN ({placeholders})
             ORDER BY en.canonical_name
             LIMIT ?"
        );
        let mut binds: Vec<Value> = Vec::with_capacity(RESOLVABLE_KINDS.len() + 2);
        binds.push(Value::Integer(
            i64::try_from(event_id.0).unwrap_or(i64::MAX),
        ));
        for k in RESOLVABLE_KINDS {
            binds.push(Value::Text((*k).to_string()));
        }
        binds.push(Value::Integer(i64::try_from(limit).unwrap_or(i64::MAX)));
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare(&sql)
            .map_err(|e| StoreError::Backend(format!("prepare entity_names_for_event: {e}")))?;
        let rows = stmt
            .query_map(params_from_iter(binds.iter()), |r| r.get::<_, String>(0))
            .map_err(|e| StoreError::Backend(format!("query entity_names_for_event: {e}")))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r.map_err(|e| StoreError::Backend(format!("row entity_name: {e}")))?);
        }
        Ok(out)
    }

    fn linked_event_ids_for_event(
        &self,
        event_id: EventId,
        limit: usize,
    ) -> Result<Vec<EventId>, StoreError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let ev = i64::try_from(event_id.0).unwrap_or(i64::MAX);
        let lim = i64::try_from(limit).unwrap_or(i64::MAX);
        // Walk: hit event e0 → its episode → every `shared_identity` edge
        // touching that episode → the OTHER endpoint episode → its events e2.
        // Post-cascade only (`e2.cascade_reason = 0`, mirroring the
        // consolidation_candidates wall at this file's L1969-1974), excludes
        // the hit itself, newest first.
        let sql = "SELECT DISTINCT e2.id
             FROM events e0
             JOIN episode_edges ee
               ON ee.edge_kind = ?1
              AND (ee.src_episode_id = e0.episode_id OR ee.dst_episode_id = e0.episode_id)
             JOIN events e2
               ON e2.episode_id = CASE WHEN ee.src_episode_id = e0.episode_id
                                       THEN ee.dst_episode_id ELSE ee.src_episode_id END
             WHERE e0.id = ?2
               AND e0.episode_id IS NOT NULL
               AND e2.cascade_reason = 0
               AND e2.id <> e0.id
             ORDER BY e2.ts_us DESC
             LIMIT ?3";
        let guard = self.db.lock().expect("brain store mutex poisoned");
        let mut stmt = guard
            .conn()
            .prepare(sql)
            .map_err(|e| StoreError::Backend(format!("prepare linked_event_ids_for_event: {e}")))?;
        let rows = stmt
            .query_map(params![EpisodeEdge::KIND_SHARED_IDENTITY, ev, lim], |r| {
                r.get::<_, i64>(0)
            })
            .map_err(|e| StoreError::Backend(format!("query linked_event_ids_for_event: {e}")))?;
        let mut out = Vec::new();
        for r in rows {
            let id = r.map_err(|e| StoreError::Backend(format!("row linked_event: {e}")))?;
            out.push(EventId(u64::try_from(id).unwrap_or(0)));
        }
        Ok(out)
    }
}

/// Build the `?,?,…` placeholder list for the `RESOLVABLE_KINDS` IN-clause.
fn resolvable_kinds_placeholders() -> String {
    vec!["?"; RESOLVABLE_KINDS.len()].join(",")
}

/// rusqlite row → [`EpisodeEdge`]. Column order:
/// `id, src_episode_id, dst_episode_id, edge_kind, evidence_entity_ids, ts_us`.
fn row_to_episode_edge(r: &rusqlite::Row<'_>) -> rusqlite::Result<EpisodeEdge> {
    let src: i64 = r.get(1)?;
    let dst: i64 = r.get(2)?;
    let ts_us: i64 = r.get(5)?;
    Ok(EpisodeEdge {
        id: EpisodeEdgeId(r.get::<_, String>(0)?),
        src_episode_id: EpisodeId(u64::try_from(src).unwrap_or(0)),
        dst_episode_id: EpisodeId(u64::try_from(dst).unwrap_or(0)),
        edge_kind: r.get::<_, String>(3)?,
        evidence_entity_ids: r.get::<_, Option<String>>(4)?,
        ts_us: u64::try_from(ts_us).unwrap_or(0),
    })
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
