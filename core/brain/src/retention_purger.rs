//! Retention purger — ADR-0017 §4.
//!
//! Honors the retention policy the user chose during onboarding
//! (`~/Library/Application Support/MCI/retention.json`, written by
//! `DiskRetentionStore.swift`). DELETE only — never INSERT.
//!
//! # Safety floor
//!
//! Events younger than [`SAFETY_FLOOR_US`] (1 hour) are **never** purged,
//! regardless of the retention config. Guards against config bugs or
//! clock skew that would otherwise wipe the live capture stream.
//!
//! # Privacy invariants
//!
//! - DELETE only — this module never inserts rows.
//! - `RetentionStore` (Swift onboarding) is the SOLE source of truth
//!   for the retention policy. The purger reads; never writes.
//! - CSO sign-off required on any change per ADR-0017 §7.4.

use crate::sqlcipher_brain_store::delete_projected_memory_for_events;
use crate::{SqlCipherBrainStore, StoreError};
use rusqlite::params;

/// User-chosen retention policy, parsed from `retention.json`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RetentionConfig {
    /// Keep events forever. Purger is a no-op.
    Forever,
    /// Keep events for at most `N` days, then purge.
    Days(u64),
}

/// Content-free stats from one purge cycle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct PurgeStats {
    /// Number of `events` rows deleted.
    pub events_deleted: u64,
    /// Number of `event_vectors` rows removed (via ON DELETE CASCADE).
    pub vectors_deleted: u64,
    /// Number of orphaned `episodes` rows cleaned up.
    pub episodes_deleted: u64,
    /// Number of `briefs` rows deleted (migration 0002). Briefs honor
    /// the same retention cutoff as events per
    /// `docs/design/brief-viewer-spec.md` §"Storage + retention".
    pub briefs_deleted: u64,
    /// Number of unreferenced encrypted keyframe files removed.
    pub blobs_deleted: u64,
}

/// 1 hour in microseconds — events younger than this are never purged.
pub const SAFETY_FLOOR_US: u64 = 3_600_000_000;

/// Purge expired events per `config`, respecting the 1-hour safety floor.
///
/// - `Forever` → immediate no-op, zero stats.
/// - `Days(N)` → computes cutoff = `now_us - N×86_400_000_000`, clamped
///   to never delete events younger than 1 hour. Deletes events,
///   cascades to vectors/chunks/FTS5, cleans orphaned episodes, VACUUMs.
///
/// `now_us` is the caller-supplied current time in microseconds since
/// UNIX epoch (injectable for tests).
pub fn purge_once(
    store: &SqlCipherBrainStore,
    config: &RetentionConfig,
    now_us: u64,
) -> Result<PurgeStats, StoreError> {
    let retention_days = match config {
        RetentionConfig::Forever => {
            return Ok(PurgeStats::default());
        }
        RetentionConfig::Days(d) => *d,
    };

    let retention_cutoff = now_us.saturating_sub(retention_days.saturating_mul(86_400_000_000));
    let safety_cutoff = now_us.saturating_sub(SAFETY_FLOOR_US);
    // Take the earlier cutoff: safety floor prevents deleting recent events
    // even if retention_days is very small (or zero).
    let cutoff = retention_cutoff.min(safety_cutoff);

    let cutoff_i64 = i64::try_from(cutoff).unwrap_or(i64::MAX);

    let mut guard = store.db.lock().expect("brain store mutex poisoned");

    let tx = guard
        .conn_mut()
        .transaction()
        .map_err(|e| StoreError::Backend(format!("begin purge tx: {e}")))?;

    // Pre-count vectors (CASCADE won't be tracked by changes()).
    let vectors_count: i64 = tx
        .query_row(
            "SELECT COUNT(*) FROM event_vectors \
             WHERE event_id IN (SELECT id FROM events WHERE ts_us < ?1)",
            params![cutoff_i64],
            |r| r.get(0),
        )
        .map_err(|e| StoreError::Backend(format!("count event_vectors for purge: {e}")))?;

    let blob_digests = {
        let mut statement = tx
            .prepare(
                "SELECT keyframe_blob FROM events
                 WHERE ts_us < ?1 AND keyframe_blob IS NOT NULL
                 ORDER BY keyframe_blob",
            )
            .map_err(|e| StoreError::Backend(format!("prepare purge keyframe blobs: {e}")))?;
        let rows = statement
            .query_map(params![cutoff_i64], |row| row.get::<_, String>(0))
            .map_err(|e| StoreError::Backend(format!("query purge keyframe blobs: {e}")))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| StoreError::Backend(format!("read purge keyframe blobs: {e}")))?
    };

    let event_ids = {
        let mut statement = tx
            .prepare("SELECT id FROM events WHERE ts_us < ?1 ORDER BY id")
            .map_err(|e| StoreError::Backend(format!("prepare purge event ids: {e}")))?;
        let rows = statement
            .query_map(params![cutoff_i64], |row| row.get::<_, i64>(0))
            .map_err(|e| StoreError::Backend(format!("query purge event ids: {e}")))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| StoreError::Backend(format!("read purge event ids: {e}")))?
    };
    delete_projected_memory_for_events(&tx, &event_ids)?;
    crate::activity::delete_activity_in_range(&tx, 0, cutoff_i64)?;

    // DELETE events. ON DELETE CASCADE auto-removes event_vectors + chunks.
    // FTS5 trigger (events_ad) auto-removes from events_fts.
    let events_deleted = tx
        .execute("DELETE FROM events WHERE ts_us < ?1", params![cutoff_i64])
        .map_err(|e| StoreError::Backend(format!("DELETE events for purge: {e}")))?;

    // Delete orphaned episodes (no remaining events reference them).
    let episodes_deleted = tx
        .execute(
            "DELETE FROM episodes WHERE id NOT IN \
             (SELECT episode_id FROM events WHERE episode_id IS NOT NULL)",
            [],
        )
        .map_err(|e| StoreError::Backend(format!("DELETE orphaned episodes: {e}")))?;

    // Briefs honor the same retention cutoff per
    // `docs/design/brief-viewer-spec.md` §"Storage + retention". Independent
    // DELETE (no FK from events) — briefs that fall outside the retention
    // window disappear in the same purge pass as events. The 1-hour safety
    // floor applies (we share `cutoff` with the events DELETE above).
    let briefs_deleted = tx
        .execute(
            "DELETE FROM briefs WHERE generated_ts_us < ?1",
            params![cutoff_i64],
        )
        .map_err(|e| StoreError::Backend(format!("DELETE briefs for purge: {e}")))?;

    tx.commit()
        .map_err(|e| StoreError::Backend(format!("commit purge tx: {e}")))?;

    // VACUUM to reclaim disk space. Must run outside transaction.
    guard
        .conn()
        .execute_batch("VACUUM")
        .map_err(|e| StoreError::Backend(format!("VACUUM after purge: {e}")))?;
    drop(guard);
    let blobs_deleted = store.remove_unreferenced_keyframe_candidates(&blob_digests)?;

    Ok(PurgeStats {
        events_deleted: events_deleted as u64,
        vectors_deleted: u64::try_from(vectors_count).unwrap_or(0),
        episodes_deleted: episodes_deleted as u64,
        briefs_deleted: briefs_deleted as u64,
        blobs_deleted,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::episode_segmenter::EpisodeWriter;
    use crate::{
        project_event, BrainStore, ClaimStatus, Event, EventId, EvidenceRef, MemoryClaim,
        MemoryDelta,
    };
    use mci_core::crypto::DbKey;

    fn temp_store() -> (SqlCipherBrainStore, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.sqlite");
        let key = DbKey::from_bytes([0xAA; 32]);
        let store = SqlCipherBrainStore::new(&path, &key).unwrap();
        (store, dir)
    }

    fn make_event(ts_us: u64, text: &str) -> Event {
        Event {
            id: EventId(0),
            ts_us,
            app_bundle_id: Some("com.test.app".into()),
            window_title: None,
            url: None,
            text: text.into(),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
            embedding: None,
        }
    }

    #[test]
    fn forever_is_noop() {
        let (store, _dir) = temp_store();
        let stats = purge_once(&store, &RetentionConfig::Forever, 1_000_000_000_000).unwrap();
        assert_eq!(stats.events_deleted, 0);
        assert_eq!(stats.vectors_deleted, 0);
        assert_eq!(stats.episodes_deleted, 0);
        assert_eq!(stats.briefs_deleted, 0);
        assert_eq!(stats.blobs_deleted, 0);
    }

    #[test]
    fn purge_respects_retention_days() {
        let (store, _dir) = temp_store();
        let day_us: u64 = 86_400_000_000;
        let now = 60 * day_us;

        // Insert 100 events spanning 60 days (one per day).
        for i in 0_u64..100 {
            // Events at day 0, day 0.6, day 1.2, ... day 59.4
            let ts = i * (60 * day_us / 100);
            store
                .put_event(&make_event(ts, &format!("event {i}")))
                .unwrap();
        }
        assert_eq!(store.stats().unwrap().event_count, 100);

        // Retention = 30 days. Events older than now - 30 days should be purged.
        let stats = purge_once(&store, &RetentionConfig::Days(30), now).unwrap();
        assert!(stats.events_deleted > 0);

        let remaining = store.stats().unwrap().event_count;
        // Events at ts >= (60-30)*day_us = 30*day_us should remain.
        // That's events with i >= 50 (ts = 50 * 60*day/100 = 30*day).
        assert_eq!(remaining, 50);
    }

    #[test]
    fn purge_removes_expired_keyframe_blobs_and_keeps_live_blobs() {
        let (store, dir) = temp_store();
        let day_us = 86_400_000_000_u64;
        let now = 100 * day_us;
        let blob_dir = dir.path().join("blobs");
        std::fs::create_dir(&blob_dir).expect("create blob dir");

        let expired_digest = "1".repeat(64);
        let live_digest = "2".repeat(64);
        let expired_path = blob_dir.join(format!("{expired_digest}.bin"));
        let live_path = blob_dir.join(format!("{live_digest}.bin"));
        std::fs::write(&expired_path, b"expired").expect("write expired blob");
        std::fs::write(&live_path, b"live").expect("write live blob");

        let mut expired = make_event(now - 40 * day_us, "expired");
        expired.keyframe_blob = Some(expired_digest);
        store.put_event(&expired).expect("put expired event");
        let mut live = make_event(now - day_us, "live");
        live.keyframe_blob = Some(live_digest);
        store.put_event(&live).expect("put live event");

        let stats = purge_once(&store, &RetentionConfig::Days(30), now).expect("purge");

        assert_eq!(stats.events_deleted, 1);
        assert_eq!(stats.blobs_deleted, 1);
        assert!(!expired_path.exists(), "expired blob must be removed");
        assert!(live_path.exists(), "retained blob must remain");
    }

    #[test]
    fn purge_removes_memory_projected_from_expired_events() {
        let (store, _dir) = temp_store();
        let day_us = 86_400_000_000_u64;
        let now = 100 * day_us;
        let source = store
            .put_event(&make_event(now - 40 * day_us, "expired source"))
            .unwrap();
        let claim = MemoryClaim::new(
            source,
            "retention fixture",
            "status",
            "expired",
            "local/test",
            Some("model".into()),
            0.5,
            now - 39 * day_us,
            now - 40 * day_us,
            None,
            "projector-v1",
            ClaimStatus::Proposed,
            None,
            Vec::new(),
        );
        project_event(
            &store,
            &MemoryDelta::new(
                source,
                now - 39 * day_us,
                "projector-v1",
                vec![claim.clone()],
                Vec::new(),
            ),
        )
        .unwrap();

        let stats = purge_once(&store, &RetentionConfig::Days(30), now).unwrap();

        assert_eq!(stats.events_deleted, 1);
        assert!(store.memory_claim_history(&claim.id).unwrap().is_empty());
    }

    #[test]
    fn purge_of_secondary_evidence_preserves_independent_same_source_delta() {
        let (store, _dir) = temp_store();
        let day_us = 86_400_000_000_u64;
        let now = 100 * day_us;
        let expired = store
            .put_event(&make_event(now - 40 * day_us, "expired support"))
            .unwrap();
        let source = store
            .put_event(&make_event(now - day_us, "current source"))
            .unwrap();
        let source_event = store.get_event(source).unwrap().unwrap();
        let expired_event = store.get_event(expired).unwrap().unwrap();
        let source_evidence = EvidenceRef::from_event(source, &source_event, "structured_app");
        let expired_evidence = EvidenceRef::from_event(expired, &expired_event, "structured_app");
        let source_scope = source_evidence.source_scope.clone();
        let affected = MemoryClaim::new(
            source,
            "retention fixture",
            "status",
            "affected",
            &source_scope,
            Some("source".into()),
            0.9,
            now - 1_000,
            now - day_us,
            None,
            "projector-v1",
            ClaimStatus::Active,
            None,
            vec![source_evidence.clone(), expired_evidence],
        );
        project_event(
            &store,
            &MemoryDelta::new(
                source,
                now - 1_000,
                "projector-v1",
                vec![affected.clone()],
                Vec::new(),
            ),
        )
        .unwrap();
        let independent = MemoryClaim::new(
            source,
            "retention fixture",
            "status",
            "independent",
            &source_scope,
            Some("source".into()),
            0.9,
            now - 500,
            now - day_us,
            None,
            "projector-v1",
            ClaimStatus::Active,
            None,
            vec![source_evidence],
        );
        project_event(
            &store,
            &MemoryDelta::new(
                source,
                now - 500,
                "projector-v1",
                vec![independent.clone()],
                Vec::new(),
            ),
        )
        .unwrap();

        let stats = purge_once(&store, &RetentionConfig::Days(30), now).unwrap();

        assert_eq!(stats.events_deleted, 1);
        assert!(store.memory_claim_history(&affected.id).unwrap().is_empty());
        assert_eq!(
            store.memory_claim_history(&independent.id).unwrap().len(),
            1
        );
    }

    #[test]
    fn purge_30_days_leaves_recent() {
        let (store, _dir) = temp_store();
        let day_us: u64 = 86_400_000_000;
        let now = 60 * day_us;

        // Insert 60 events, one per day.
        for i in 0_u64..60 {
            let ts = i * day_us;
            store
                .put_event(&make_event(ts, &format!("day {i}")))
                .unwrap();
        }
        assert_eq!(store.stats().unwrap().event_count, 60);

        let stats = purge_once(&store, &RetentionConfig::Days(30), now).unwrap();
        assert_eq!(stats.events_deleted, 30);
        assert_eq!(store.stats().unwrap().event_count, 30);
    }

    #[test]
    fn forever_keeps_all_100() {
        let (store, _dir) = temp_store();
        let day_us: u64 = 86_400_000_000;

        for i in 0_u64..100 {
            let ts = i * day_us;
            store
                .put_event(&make_event(ts, &format!("event {i}")))
                .unwrap();
        }
        assert_eq!(store.stats().unwrap().event_count, 100);

        let stats = purge_once(&store, &RetentionConfig::Forever, 200 * day_us).unwrap();
        assert_eq!(stats.events_deleted, 0);
        assert_eq!(store.stats().unwrap().event_count, 100);
    }

    #[test]
    fn safety_floor_prevents_deleting_recent() {
        let (store, _dir) = temp_store();
        let now = 10_000_000_000_u64; // 10_000 seconds

        // Event at now - 30 minutes (inside safety floor)
        store
            .put_event(&make_event(now - 1_800_000_000, "recent"))
            .unwrap();
        // Event at now - 2 hours (outside safety floor, inside 0-day retention)
        store
            .put_event(&make_event(now - 7_200_000_000, "older"))
            .unwrap();

        // Retention = 0 days (delete everything). Safety floor should
        // protect the 30-minute-old event.
        let stats = purge_once(&store, &RetentionConfig::Days(0), now).unwrap();
        assert_eq!(stats.events_deleted, 1); // only the 2h-old one
        assert_eq!(store.stats().unwrap().event_count, 1);
    }

    #[test]
    fn purge_cascades_vectors() {
        let (store, _dir) = temp_store();
        let now = 200_000_000_000_u64;

        // Insert event and add embedding.
        let ev = make_event(1_000_000, "old event with vector");
        let id = store.put_event(&ev).unwrap();
        let embedding = vec![0.05_f32; 384];
        store.set_event_embedding(id, &embedding).unwrap();

        // Verify vector exists.
        let fetched = store.get_event(id).unwrap().unwrap();
        assert!(fetched.embedding.is_some());

        let stats = purge_once(&store, &RetentionConfig::Days(1), now).unwrap();
        assert_eq!(stats.events_deleted, 1);
        assert_eq!(stats.vectors_deleted, 1);
        assert!(store.get_event(id).unwrap().is_none());
    }

    #[test]
    fn purge_cleans_orphaned_episodes() {
        let (store, _dir) = temp_store();
        let now = 200_000_000_000_u64;

        // Insert two old events and assign them to an episode.
        let id1 = store
            .put_event(&make_event(1_000_000, "old ep event 1"))
            .unwrap();
        let id2 = store
            .put_event(&make_event(2_000_000, "old ep event 2"))
            .unwrap();

        let ep_id = store
            .create_episode(1_000_000, 2_000_000, Some("com.test.app"))
            .unwrap();
        store.set_event_episode(id1, ep_id).unwrap();
        store.set_event_episode(id2, ep_id).unwrap();

        // Insert a recent event (should survive).
        store
            .put_event(&make_event(now - 1_000_000, "recent"))
            .unwrap();

        let stats = purge_once(&store, &RetentionConfig::Days(1), now).unwrap();
        assert_eq!(stats.events_deleted, 2);
        assert_eq!(stats.episodes_deleted, 1);
        assert_eq!(store.stats().unwrap().event_count, 1);
    }

    #[test]
    fn empty_store_purge_is_noop() {
        let (store, _dir) = temp_store();
        let stats = purge_once(&store, &RetentionConfig::Days(7), 1_000_000_000_000).unwrap();
        assert_eq!(stats.events_deleted, 0);
        assert_eq!(stats.vectors_deleted, 0);
        assert_eq!(stats.episodes_deleted, 0);
        assert_eq!(stats.briefs_deleted, 0);
    }

    // -----------------------------------------------------------------
    // Briefs retention — `docs/design/brief-viewer-spec.md`.
    // -----------------------------------------------------------------

    fn make_brief(date_local: &str, generated_ts_us: u64) -> crate::BriefRow {
        crate::BriefRow {
            id: 0,
            date_local: date_local.into(),
            generated_ts_us,
            model_id: "qwen3-1.7b-int4".into(),
            model_version: "1.0".into(),
            title: format!("Brief for {date_local}"),
            body: "## Highlights\n\nA day.\n".into(),
            word_count: 4,
            source_event_count: 0,
        }
    }

    #[test]
    fn purge_deletes_old_briefs_outside_retention() {
        let (store, _dir) = temp_store();
        let day_us: u64 = 86_400_000_000;
        let now = 60 * day_us;

        // 60 briefs, one per day from day 0 to day 59.
        for i in 0..60u64 {
            let ts = i * day_us;
            // Use a synthetic date_local string keyed on the day index so
            // the unique constraint on date_local doesn't collide.
            let date = format!("2026-01-{:02}", (i % 28) + 1);
            // Avoid the date-unique constraint collision by appending i.
            let mut row = make_brief(&format!("{date}-{i:02}"), ts);
            row.body = format!("body {i}");
            store.put_brief(&row).unwrap();
        }
        assert_eq!(store.brief_count().unwrap(), 60);

        let stats = purge_once(&store, &RetentionConfig::Days(30), now).unwrap();
        assert_eq!(stats.briefs_deleted, 30);
        assert_eq!(store.brief_count().unwrap(), 30);
    }

    #[test]
    fn forever_keeps_all_briefs() {
        let (store, _dir) = temp_store();
        for i in 0..10u64 {
            let row = make_brief(&format!("2026-05-{:02}", i + 1), i * 86_400_000_000);
            store.put_brief(&row).unwrap();
        }
        let stats = purge_once(&store, &RetentionConfig::Forever, 200 * 86_400_000_000).unwrap();
        assert_eq!(stats.briefs_deleted, 0);
        assert_eq!(store.brief_count().unwrap(), 10);
    }

    #[test]
    fn briefs_purge_honors_safety_floor() {
        let (store, _dir) = temp_store();
        let now = 10_000_000_000_u64;

        // Brief inside the 1-hour safety floor (must survive).
        store
            .put_brief(&make_brief("today", now - 1_800_000_000))
            .unwrap();
        // Brief outside the safety floor (eligible for purge).
        store
            .put_brief(&make_brief("yesterday", now - 7_200_000_000))
            .unwrap();

        let stats = purge_once(&store, &RetentionConfig::Days(0), now).unwrap();
        assert_eq!(stats.briefs_deleted, 1);
        assert_eq!(store.brief_count().unwrap(), 1);
    }
}
