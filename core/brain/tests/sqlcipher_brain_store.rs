//! Integration tests for the Phase 3 production `SqlCipherBrainStore`
//! (ADR-0016 §6 P3.2). Each test opens an ephemeral encrypted DB under a
//! `tempfile::tempdir()` with `mci_core::crypto::InMemoryKeyWrap`-derived
//! `DbKey` (test-only key wrap, gated by mci-core's
//! `insecure-test-keywrap` feature; the shipped agent binary cannot
//! construct it).

use std::path::{Path, PathBuf};

use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore, StoreError};
use mci_core::crypto::{DbKey, InMemoryKeyWrap, KeyWrap};
use mci_core::store::{open as mci_core_open, Db};
use rusqlite::params;
use tempfile::TempDir;

const EMBEDDING_DIM: usize = 384;

fn tmp(name: &str) -> (TempDir, PathBuf) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join(name);
    (dir, path)
}

/// Fresh `DbKey` via the test-only `InMemoryKeyWrap` round-trip — mirrors
/// mci-core's store-open tests.
fn test_key() -> DbKey {
    let k = DbKey::generate().expect("csprng");
    let wrap = InMemoryKeyWrap;
    let wrapped = wrap.wrap(&k).expect("wrap");
    wrap.unwrap_key(&wrapped).expect("unwrap")
}

/// Open a raw `mci_core::store::Db` against the same encrypted file with
/// the same key. Used by tests that need direct SQL access for cascade /
/// orphan verification.
fn raw_open(path: &Path, key: &DbKey) -> Db {
    mci_core_open(path, key).expect("mci_core::store::open")
}

fn blank_event(ts_us: u64, text: &str) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: None,
        window_title: None,
        url: None,
        text: text.into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        embedding: None,
    }
}

/// Unit-norm 384-d vector with 1.0 at `axis`, 0 elsewhere.
fn axis_unit_vec(axis: usize) -> Vec<f32> {
    let mut v = vec![0.0_f32; EMBEDDING_DIM];
    v[axis] = 1.0;
    v
}

// ---------------------------------------------------------------------------
// 1. Migration creates the expected schema (and defers vec_events)
// ---------------------------------------------------------------------------

#[test]
fn new_creates_encrypted_db_and_runs_migration() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    {
        let _store = SqlCipherBrainStore::new(&path, &key).expect("open");
    }

    let db = raw_open(&path, &key);
    for table in [
        "meta",
        "events",
        "episodes",
        "event_vectors",
        "chunks",
        "events_fts",
    ] {
        let n: i64 = db
            .conn()
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE name = ?1",
                params![table],
                |r| r.get(0),
            )
            .expect("query sqlite_master");
        assert_eq!(n, 1, "table {table} must be materialized by migration");
    }

    let v: String = db
        .conn()
        .query_row(
            "SELECT value FROM meta WHERE key = 'vec_events_mirror'",
            [],
            |r| r.get(0),
        )
        .expect("vec_events_mirror stamp");
    assert_eq!(v, "deferred");

    let vec0_count: i64 = db
        .conn()
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE name = 'vec_events'",
            [],
            |r| r.get(0),
        )
        .expect("vec_events count");
    assert_eq!(
        vec0_count, 0,
        "vec_events (vec0) must NOT be created in P3.2"
    );

    let v: String = db
        .conn()
        .query_row(
            "SELECT value FROM meta WHERE key = 'brain_schema_version'",
            [],
            |r| r.get(0),
        )
        .expect("brain_schema_version stamp");
    assert_eq!(v, "1");
}

// ---------------------------------------------------------------------------
// 2. Migration is idempotent (second open is a no-op and preserves data)
// ---------------------------------------------------------------------------

#[test]
fn migration_idempotent_on_second_open() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();

    let id = {
        let store = SqlCipherBrainStore::new(&path, &key).expect("open 1");
        store
            .put_event(&blank_event(1_000_000, "first session"))
            .expect("put")
    };

    let store2 = SqlCipherBrainStore::new(&path, &key).expect("open 2");
    let got = store2.get_event(id).expect("get").expect("event survives");
    assert_eq!(got.text, "first session");
}

// ---------------------------------------------------------------------------
// 3. put_event → get_event round-trip preserves every column
// ---------------------------------------------------------------------------

#[test]
fn put_event_then_get_event_round_trip() {
    let (_dir, path) = tmp("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");

    let mut ev = blank_event(12_345_678, "the quick brown fox");
    ev.app_bundle_id = Some("com.apple.Safari".into());
    ev.window_title = Some("Apple — Mac".into());
    ev.url = Some("https://www.apple.com/mac/".into());
    ev.summary = Some("apple landing page".into());
    ev.entities = Some(r#"["Apple","Mac"]"#.into());
    ev.keyframe_blob = Some("abcdef0123456789/keyframe-0001.bin".into());

    let id = store.put_event(&ev).expect("put");
    let got = store.get_event(id).expect("get").expect("present");
    assert_eq!(got.id, id);
    assert_eq!(got.ts_us, 12_345_678);
    assert_eq!(got.app_bundle_id.as_deref(), Some("com.apple.Safari"));
    assert_eq!(got.window_title.as_deref(), Some("Apple — Mac"));
    assert_eq!(got.url.as_deref(), Some("https://www.apple.com/mac/"));
    assert_eq!(got.text, "the quick brown fox");
    assert_eq!(got.summary.as_deref(), Some("apple landing page"));
    assert_eq!(got.entities.as_deref(), Some(r#"["Apple","Mac"]"#));
    assert_eq!(
        got.keyframe_blob.as_deref(),
        Some("abcdef0123456789/keyframe-0001.bin")
    );
    assert_eq!(got.cascade_reason, 0);
    assert!(got.embedding.is_none());
}

#[test]
fn get_event_returns_none_for_unknown_id() {
    let (_dir, path) = tmp("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");
    let got = store.get_event(EventId(9_999_999)).expect("get");
    assert!(got.is_none());
}

// ---------------------------------------------------------------------------
// 4. 384-d embedding survives round-trip (bytes preserved)
// ---------------------------------------------------------------------------

#[test]
fn put_event_persists_384d_embedding_and_get_returns_it() {
    let (_dir, path) = tmp("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");

    let v: Vec<f32> = (0..EMBEDDING_DIM)
        .map(|i| {
            #[allow(clippy::cast_precision_loss)]
            let f = i as f32;
            (f - 192.0) / 1000.0
        })
        .collect();
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    let v_n: Vec<f32> = v.iter().map(|x| x / norm).collect();

    let mut ev = blank_event(42_000_000, "embedding round-trip");
    ev.embedding = Some(v_n.clone());

    let id = store.put_event(&ev).expect("put");
    let got = store
        .get_event(id)
        .expect("get")
        .expect("present")
        .embedding
        .expect("embedding present");
    assert_eq!(got.len(), EMBEDDING_DIM);
    for (a, b) in got.iter().zip(v_n.iter()) {
        assert!((a - b).abs() < 1e-7, "byte-exact f32 round-trip");
    }
}

// ---------------------------------------------------------------------------
// 5. ADR-0016 §4.3 — `.suppress` events MUST NOT reach put_event
// ---------------------------------------------------------------------------

#[test]
fn put_event_rejects_nonzero_cascade_reason() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");
    let mut ev = blank_event(0, "should not land");
    ev.cascade_reason = 7;
    let err = store.put_event(&ev).unwrap_err();
    assert!(
        matches!(err, StoreError::InvalidInput(_)),
        "expected InvalidInput, got {err:?}"
    );

    // And no events row was written (rejected before any SQL ran).
    let db = raw_open(&path, &key);
    let n: i64 = db
        .conn()
        .query_row("SELECT count(*) FROM events", [], |r| r.get(0))
        .expect("count");
    assert_eq!(n, 0, "no events row may exist");
}

// ---------------------------------------------------------------------------
// 6. ADR-0009 schema pin — embedding dim must equal 384
// ---------------------------------------------------------------------------

#[test]
fn put_event_rejects_mis_dim_embedding() {
    let (_dir, path) = tmp("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");
    let mut ev = blank_event(1, "mis-dim");
    ev.embedding = Some(vec![0.5_f32; 100]);
    let err = store.put_event(&ev).unwrap_err();
    assert!(
        matches!(err, StoreError::InvalidInput(_)),
        "expected InvalidInput, got {err:?}"
    );
}

#[test]
fn vec_search_rejects_mis_dim_query() {
    let (_dir, path) = tmp("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");
    for bad_dim in [0, 1, 100, 383, 385, 768] {
        let q = vec![0.1_f32; bad_dim];
        let err = store.vec_search(&q, 10).unwrap_err();
        assert!(
            matches!(err, StoreError::InvalidInput(_)),
            "dim {bad_dim} must be rejected, got {err:?}"
        );
    }
}

// ---------------------------------------------------------------------------
// 7. FTS5 — empty query rejected; BM25 ranking holds
// ---------------------------------------------------------------------------

#[test]
fn fts5_search_empty_query_rejected() {
    let (_dir, path) = tmp("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");
    let err = store.fts5_search("", 5).unwrap_err();
    assert!(matches!(err, StoreError::InvalidInput(_)));
}

#[test]
fn fts5_search_returns_bm25_ranked_hits() {
    let (_dir, path) = tmp("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");

    let id_a = store
        .put_event(&blank_event(1, "rust async runtime"))
        .expect("put a");
    let id_b = store
        .put_event(&blank_event(
            2,
            "a long passage about many topics with the word rust appearing once buried in the middle of a much larger body of unrelated language",
        ))
        .expect("put b");
    let _id_c = store
        .put_event(&blank_event(3, "javascript react component hooks"))
        .expect("put c");

    let hits = store.fts5_search("rust", 10).expect("fts5");
    assert_eq!(hits.len(), 2, "miss event must be excluded; got {hits:?}");

    let ids: Vec<EventId> = hits.iter().map(|(id, _)| *id).collect();
    assert!(ids.contains(&id_a) && ids.contains(&id_b));
    assert_eq!(hits[0].0, id_a, "shorter doc with the term ranks first");

    for w in hits.windows(2) {
        assert!(w[0].1 >= w[1].1, "fts5 scores must be descending: {hits:?}");
    }
}

#[test]
fn fts5_indexes_summary_window_title_and_url_columns() {
    let (_dir, path) = tmp("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");

    let ev_t = blank_event(1, "main text mentions octopus");
    let mut ev_s = blank_event(2, "no match in text");
    ev_s.summary = Some("summary mentions octopus".into());
    let mut ev_w = blank_event(3, "no match in text");
    ev_w.window_title = Some("Window title octopus".into());
    let mut ev_u = blank_event(4, "no match in text");
    ev_u.url = Some("https://example.com/octopus-page".into());
    let mut ev_miss = blank_event(5, "nothing matches here");
    ev_miss.summary = Some("unrelated".into());
    ev_miss.window_title = Some("Unrelated".into());
    ev_miss.url = Some("https://example.com/nope".into());

    let id_t = store.put_event(&ev_t).expect("put t");
    let id_s = store.put_event(&ev_s).expect("put s");
    let id_w = store.put_event(&ev_w).expect("put w");
    let id_u = store.put_event(&ev_u).expect("put u");
    let _id_miss = store.put_event(&ev_miss).expect("put miss");

    let hits = store.fts5_search("octopus", 20).expect("fts5");
    let hit_ids: Vec<EventId> = hits.iter().map(|(id, _)| *id).collect();
    assert!(hit_ids.contains(&id_t), "text column must be searchable");
    assert!(hit_ids.contains(&id_s), "summary column must be searchable");
    assert!(
        hit_ids.contains(&id_w),
        "window_title column must be searchable"
    );
    assert!(hit_ids.contains(&id_u), "url column must be searchable");
    assert_eq!(hits.len(), 4, "exactly the 4 matching events");
}

// ---------------------------------------------------------------------------
// 8. vec_search — cosine ranking holds; zero-limit empty
// ---------------------------------------------------------------------------

#[test]
fn vec_search_returns_cosine_ranked_hits() {
    let (_dir, path) = tmp("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");

    let mut ev_a = blank_event(1, "axis 0");
    ev_a.embedding = Some(axis_unit_vec(0));
    let mut ev_b = blank_event(2, "axis 1");
    ev_b.embedding = Some(axis_unit_vec(1));
    let mut ev_c = blank_event(3, "axis 2");
    ev_c.embedding = Some(axis_unit_vec(2));

    let id_a = store.put_event(&ev_a).expect("put a");
    let id_b = store.put_event(&ev_b).expect("put b");
    let _id_c = store.put_event(&ev_c).expect("put c");

    let mut q = vec![0.0_f32; EMBEDDING_DIM];
    q[0] = 0.9;
    q[1] = 0.4;
    let qn = q.iter().map(|x| x * x).sum::<f32>().sqrt();
    let q_unit: Vec<f32> = q.iter().map(|x| x / qn).collect();

    let hits = store.vec_search(&q_unit, 3).expect("vec");
    assert_eq!(hits.len(), 3);
    assert_eq!(hits[0].0, id_a, "axis-0 has highest cosine");
    assert_eq!(hits[1].0, id_b, "axis-1 second");
    assert!(hits[0].1 > hits[1].1 && hits[1].1 > hits[2].1);
    assert!((hits[0].1 - 0.914).abs() < 1e-3);
    assert!((hits[1].1 - 0.406).abs() < 1e-3);
    assert!(hits[2].1.abs() < 1e-6);
}

#[test]
fn vec_search_zero_limit_returns_empty() {
    let (_dir, path) = tmp("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");
    let mut ev = blank_event(1, "x");
    ev.embedding = Some(axis_unit_vec(0));
    store.put_event(&ev).expect("put");
    let q = axis_unit_vec(0);
    let hits = store.vec_search(&q, 0).expect("vec");
    assert!(hits.is_empty());
}

// ---------------------------------------------------------------------------
// 9. ON DELETE CASCADE — event_vectors + chunks drop together with events
// ---------------------------------------------------------------------------

#[test]
fn on_delete_cascade_clears_event_vectors_and_chunks() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();

    let event_id_value = {
        let store = SqlCipherBrainStore::new(&path, &key).expect("open");
        let mut ev = blank_event(123, "cascade test");
        ev.embedding = Some(axis_unit_vec(0));
        let id = store.put_event(&ev).expect("put");
        id.0
    };

    // Re-open via mci_core::store::open (still encrypted, foreign_keys=ON
    // set by mci-core's open path) and exercise the cascade via raw SQL.
    let mut db = raw_open(&path, &key);
    let row_id = i64::try_from(event_id_value).unwrap();

    db.conn()
        .execute(
            "INSERT INTO chunks (event_id, text, embedding) VALUES (?1, ?2, NULL)",
            params![row_id, "sub-chunk text"],
        )
        .expect("insert chunk");

    let chunk_before: i64 = db
        .conn()
        .query_row(
            "SELECT count(*) FROM chunks WHERE event_id = ?1",
            params![row_id],
            |r| r.get(0),
        )
        .expect("chunk count before");
    assert_eq!(chunk_before, 1);
    let vec_before: i64 = db
        .conn()
        .query_row(
            "SELECT count(*) FROM event_vectors WHERE event_id = ?1",
            params![row_id],
            |r| r.get(0),
        )
        .expect("vec count before");
    assert_eq!(vec_before, 1);

    db.conn_mut()
        .execute("DELETE FROM events WHERE id = ?1", params![row_id])
        .expect("delete event");

    let chunk_after: i64 = db
        .conn()
        .query_row(
            "SELECT count(*) FROM chunks WHERE event_id = ?1",
            params![row_id],
            |r| r.get(0),
        )
        .expect("chunk count after");
    assert_eq!(chunk_after, 0, "chunks must cascade-delete");
    let vec_after: i64 = db
        .conn()
        .query_row(
            "SELECT count(*) FROM event_vectors WHERE event_id = ?1",
            params![row_id],
            |r| r.get(0),
        )
        .expect("vec count after");
    assert_eq!(vec_after, 0, "event_vectors must cascade-delete");
}

// ---------------------------------------------------------------------------
// 10. Transaction atomicity — FK violation rolls back cleanly
// ---------------------------------------------------------------------------

#[test]
fn put_event_atomicity_on_fk_failure_leaves_no_orphans() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let mut good = blank_event(1, "good");
    good.embedding = Some(axis_unit_vec(0));
    let good_id = store.put_event(&good).expect("put good");

    let mut bad = blank_event(2, "bad");
    bad.embedding = Some(axis_unit_vec(1));
    bad.episode_id = Some(999_999); // no episode row → FK violation
    let err = store
        .put_event(&bad)
        .expect_err("FK violation must surface");
    assert!(
        matches!(err, StoreError::Backend(_)),
        "expected Backend (FK violation), got {err:?}"
    );

    // Verify no orphans via a parallel raw connection.
    let db = raw_open(&path, &key);
    let events_n: i64 = db
        .conn()
        .query_row("SELECT count(*) FROM events", [], |r| r.get(0))
        .expect("events count");
    assert_eq!(events_n, 1, "only the good event must remain");

    let vec_n: i64 = db
        .conn()
        .query_row("SELECT count(*) FROM event_vectors", [], |r| r.get(0))
        .expect("vec count");
    assert_eq!(vec_n, 1, "no orphan event_vectors row");

    let g = store.get_event(good_id).expect("get").expect("present");
    assert_eq!(g.text, "good");
}

// ---------------------------------------------------------------------------
// events_since + stats (P3.10b — read-only views the MCP server uses)
// ---------------------------------------------------------------------------

#[test]
fn events_since_returns_rows_strictly_after_cursor_in_ts_order() {
    let (_dir, path) = tmp("events_since.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");
    for ts in [10_u64, 20, 30, 40, 50] {
        store
            .put_event(&blank_event(ts, &format!("e@{ts}")))
            .expect("put");
    }
    let out = store.events_since(20, 10).expect("events_since");
    let ts_seq: Vec<u64> = out.iter().map(|r| r.ts_us).collect();
    assert_eq!(ts_seq, vec![30, 40, 50], "strictly > cursor, ascending");
}

#[test]
fn events_since_respects_limit() {
    let (_dir, path) = tmp("events_since_limit.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");
    for ts in 1_u64..=10 {
        store
            .put_event(&blank_event(ts, &format!("e@{ts}")))
            .expect("put");
    }
    let out = store.events_since(0, 3).expect("events_since");
    assert_eq!(out.len(), 3);
    let ts_seq: Vec<u64> = out.iter().map(|r| r.ts_us).collect();
    assert_eq!(ts_seq, vec![1, 2, 3], "ascending order, capped at limit");
}

#[test]
fn events_since_zero_limit_returns_empty_without_query() {
    let (_dir, path) = tmp("events_since_zero.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");
    store.put_event(&blank_event(1, "anything")).expect("put");
    let out = store.events_since(0, 0).expect("events_since");
    assert!(out.is_empty(), "limit=0 short-circuits");
}

#[test]
fn events_since_truncates_long_text_to_snippet_cap() {
    use mci_brain::EventRecord;
    let (_dir, path) = tmp("events_since_trunc.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");
    let long = "a".repeat(EventRecord::SNIPPET_MAX_CHARS * 3);
    store.put_event(&blank_event(100, &long)).expect("put");
    let out = store.events_since(0, 10).expect("events_since");
    assert_eq!(out.len(), 1);
    assert!(out[0].text_snippet.len() <= EventRecord::SNIPPET_MAX_CHARS);
}

#[test]
fn stats_on_empty_store_reports_zero_and_none() {
    let (_dir, path) = tmp("stats_empty.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");
    let s = store.stats().expect("stats");
    assert_eq!(s.event_count, 0);
    assert_eq!(s.oldest_ts_us, None);
    assert_eq!(s.newest_ts_us, None);
}

#[test]
fn stats_reports_count_min_max_after_inserts() {
    let (_dir, path) = tmp("stats_after.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");
    for ts in [7_u64, 42, 100, 1] {
        store
            .put_event(&blank_event(ts, &format!("e@{ts}")))
            .expect("put");
    }
    let s = store.stats().expect("stats");
    assert_eq!(s.event_count, 4);
    assert_eq!(s.oldest_ts_us, Some(1));
    assert_eq!(s.newest_ts_us, Some(100));
}
