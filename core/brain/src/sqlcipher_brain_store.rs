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

use mci_core::crypto::DbKey;
use mci_core::store::{open as mci_core_open, Db, StoreError as CoreStoreError};
use rusqlite::params;

use crate::{Event, EventId, StoreError};

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
    db: Mutex<Db>,
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
        Ok(Self {
            db: Mutex::new(db),
        })
    }
}

/// Schema migration — ADR-0016 §1.4. Idempotent: every `CREATE` is
/// `IF NOT EXISTS`, every meta stamp is `INSERT OR REPLACE`. Runs inside
/// one transaction so a partial migration cannot leave the store in a
/// torn state (`SQLCipher` rolls back DDL on commit failure).
fn run_brain_migration(db: &mut Db) -> Result<(), StoreError> {
    let sql = include_str!("../migrations/0001_phase_3_brain_schema.sql");
    let tx = db
        .conn_mut()
        .transaction()
        .map_err(|e| StoreError::Backend(format!("begin migration tx: {e}")))?;
    tx.execute_batch(sql)
        .map_err(|e| StoreError::Backend(format!("apply migration 0001: {e}")))?;
    tx.commit()
        .map_err(|e| StoreError::Backend(format!("commit migration tx: {e}")))?;
    Ok(())
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
/// items_after_statements`).
type EventRow = (
    i64,                // id
    i64,                // ts_us
    Option<String>,     // app_bundle_id
    Option<String>,     // window_title
    Option<String>,     // url
    String,             // text
    Option<String>,     // summary
    Option<String>,     // entities
    Option<i64>,        // episode_id
    i64,                // cascade_reason
    Option<String>,     // keyframe_blob
);

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
        tx.execute(
            "INSERT INTO events (
                ts_us, app_bundle_id, window_title, url,
                text, summary, entities, episode_id,
                cascade_reason, keyframe_blob
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                i64::try_from(event.ts_us).unwrap_or(i64::MAX),
                &event.app_bundle_id,
                &event.window_title,
                &event.url,
                &event.text,
                &event.summary,
                &event.entities,
                event.episode_id.map(|v| i64::try_from(v).unwrap_or(i64::MAX)),
                event.cascade_reason,
                &event.keyframe_blob,
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
        let row: Option<EventRow> = guard
            .conn()
            .query_row(
                "SELECT id, ts_us, app_bundle_id, window_title, url,
                        text, summary, entities, episode_id,
                        cascade_reason, keyframe_blob
                 FROM events WHERE id = ?1",
                params![row_id],
                |r| {
                    Ok((
                        r.get(0)?,
                        r.get(1)?,
                        r.get(2)?,
                        r.get(3)?,
                        r.get(4)?,
                        r.get(5)?,
                        r.get(6)?,
                        r.get(7)?,
                        r.get(8)?,
                        r.get(9)?,
                        r.get(10)?,
                    ))
                },
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
            let (row_id, rank) =
                r.map_err(|e| StoreError::Backend(format!("row fts5: {e}")))?;
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
        hits.sort_by(|a, b| {
            b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal)
        });
        hits.truncate(limit);
        Ok(hits)
    }
}
