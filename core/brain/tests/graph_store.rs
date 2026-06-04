//! V2-P3 — round-trip integration tests for the graph-foundation
//! writers and readers (`put_entity` / `put_entity_mention` /
//! `put_episode_edge` / `find_entity_by_alias` / `events_with_entity`)
//! against the production `SqlCipherBrainStore`.
//!
//! Each test opens an ephemeral encrypted DB under a
//! `tempfile::tempdir()` with an `InMemoryKeyWrap`-derived `DbKey`
//! (test-only key wrap, gated by mci-core's `insecure-test-keywrap`
//! feature — the shipped agent binary cannot construct it). Mirrors
//! the discipline already used in `tests/sqlcipher_brain_store.rs`.

use std::path::{Path, PathBuf};

use mci_brain::episode_segmenter::{EpisodeId, EpisodeWriter};
use mci_brain::graph::{
    Entity, EntityId, EntityMention, EntityMentionId, EpisodeEdge, EpisodeEdgeId,
};
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

fn test_key() -> DbKey {
    let k = DbKey::generate().expect("csprng");
    let wrap = InMemoryKeyWrap;
    let wrapped = wrap.wrap(&k).expect("wrap");
    wrap.unwrap_key(&wrapped).expect("unwrap")
}

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
        tab_id: None,
        embedding: None,
    }
}

fn make_entity(kind: &str, name: &str, ts_us: u64) -> Entity {
    Entity {
        id: Entity::derive_id(kind, name),
        kind: kind.to_string(),
        canonical_name: name.to_string(),
        summary: None,
        summary_embedding: None,
        content_hash: Entity::derive_content_hash(kind, name),
        created_ts_us: ts_us,
        updated_ts_us: ts_us,
    }
}

fn make_mention(entity: &Entity, event_id: EventId, extractor: &str, text: Option<&str>) -> EntityMention {
    EntityMention {
        id: EntityMention::derive_id(&entity.id, event_id, extractor, text),
        entity_id: entity.id.clone(),
        event_id,
        mention_text: text.map(str::to_string),
        confidence: 1.0,
        extractor_kind: extractor.to_string(),
        ts_us: 1,
    }
}

// ---------------------------------------------------------------------------
// 1. Migration 0004 creates the expected tables + indexes
// ---------------------------------------------------------------------------

#[test]
fn migration_0004_creates_graph_tables_and_indexes() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    {
        let _store = SqlCipherBrainStore::new(&path, &key).expect("open");
    }

    let db = raw_open(&path, &key);
    for table in ["entities", "entity_mentions", "episode_edges"] {
        let count: i64 = db
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master
                 WHERE type='table' AND name=?1",
                params![table],
                |r| r.get(0),
            )
            .expect("query sqlite_master");
        assert_eq!(count, 1, "{table} table missing");
    }
    for index in [
        "entities_kind_name",
        "entities_canonical_name",
        "entities_content_hash",
        "entities_updated_ts",
        "entity_mentions_entity",
        "entity_mentions_event",
        "entity_mentions_ts",
        "entity_mentions_extractor",
        "episode_edges_src",
        "episode_edges_dst",
        "episode_edges_kind",
        "episode_edges_ts",
    ] {
        let count: i64 = db
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master
                 WHERE type='index' AND name=?1",
                params![index],
                |r| r.get(0),
            )
            .expect("query sqlite_master index");
        assert_eq!(count, 1, "{index} index missing");
    }
    // brain_schema_version stamped to "5" (0005 entity_identities runs
    // after 0004); vec-mirror deferred.
    let version: String = db
        .conn()
        .query_row(
            "SELECT value FROM meta WHERE key='brain_schema_version'",
            [],
            |r| r.get(0),
        )
        .expect("schema version");
    assert_eq!(version, "5");
    let vec_mirror: String = db
        .conn()
        .query_row(
            "SELECT value FROM meta WHERE key='vec_entity_summaries_mirror'",
            [],
            |r| r.get(0),
        )
        .expect("vec mirror stamp");
    assert_eq!(vec_mirror, "deferred");
}

#[test]
fn migration_0004_is_idempotent_on_reopen() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    for _ in 0..3 {
        let _store = SqlCipherBrainStore::new(&path, &key).expect("re-open");
    }
    // Schema still healthy + still stamped to 5.
    let db = raw_open(&path, &key);
    let version: String = db
        .conn()
        .query_row(
            "SELECT value FROM meta WHERE key='brain_schema_version'",
            [],
            |r| r.get(0),
        )
        .expect("schema version");
    assert_eq!(version, "5");
}

// ---------------------------------------------------------------------------
// 2. put_entity round-trip
// ---------------------------------------------------------------------------

#[test]
fn put_entity_round_trips() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let e = make_entity("person", "Alice", 1_700_000_000_000_000);
    store.put_entity(&e).expect("put_entity");

    let got = store
        .find_entity_by_alias("person", "Alice")
        .expect("find")
        .expect("present");
    assert_eq!(got.id, e.id);
    assert_eq!(got.kind, "person");
    assert_eq!(got.canonical_name, "Alice");
    assert_eq!(got.content_hash, e.content_hash);
    assert_eq!(got.created_ts_us, e.created_ts_us);
    assert_eq!(got.updated_ts_us, e.updated_ts_us);
    assert!(got.summary.is_none());
    assert!(got.summary_embedding.is_none());
}

#[test]
fn put_entity_with_summary_embedding_round_trips() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let mut e = make_entity("topic", "figma-layout", 2_000_000_000_000_000);
    e.summary = Some("Project layout review thread".to_string());
    let mut emb = vec![0.0_f32; EMBEDDING_DIM];
    emb[0] = 1.0;
    e.summary_embedding = Some(emb.clone());
    store.put_entity(&e).expect("put_entity");

    let got = store
        .find_entity_by_alias("topic", "figma-layout")
        .expect("find")
        .expect("present");
    assert_eq!(got.summary.as_deref(), Some("Project layout review thread"));
    let got_emb = got.summary_embedding.expect("embedding round-trips");
    assert_eq!(got_emb.len(), EMBEDDING_DIM);
    assert!((got_emb[0] - 1.0).abs() < 1e-6);
    assert!(got_emb[1..].iter().all(|x| x.abs() < 1e-6));
}

#[test]
fn put_entity_rejects_mis_dim_summary_embedding() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let mut e = make_entity("person", "Bob", 1);
    e.summary_embedding = Some(vec![0.0_f32; 128]);
    let err = store.put_entity(&e).expect_err("mis-dim rejected");
    match err {
        StoreError::InvalidInput(_) => {}
        other => panic!("expected InvalidInput, got {other:?}"),
    }
}

#[test]
fn put_entity_upsert_preserves_created_ts_us() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let mut e = make_entity("person", "Carol", 1_000);
    store.put_entity(&e).expect("first put");

    // Bump updated_ts_us + add a summary; created_ts_us in the writer
    // changes too (a naive replace would overwrite the stored value).
    e.updated_ts_us = 2_000;
    e.created_ts_us = 9_999; // intentional drift; impl should ignore
    e.summary = Some("now with summary".to_string());
    store.put_entity(&e).expect("re-put");

    let got = store
        .find_entity_by_alias("person", "Carol")
        .expect("find")
        .expect("present");
    assert_eq!(got.summary.as_deref(), Some("now with summary"));
    assert_eq!(got.updated_ts_us, 2_000);
    // created_ts_us stays at the original first-write value.
    assert_eq!(got.created_ts_us, 1_000);
}

#[test]
fn find_entity_by_alias_returns_none_for_unknown_pair() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");
    assert!(store
        .find_entity_by_alias("person", "Nobody")
        .expect("find")
        .is_none());
}

// ---------------------------------------------------------------------------
// 3. put_entity_mention round-trip + idempotence + FK enforcement
// ---------------------------------------------------------------------------

#[test]
fn put_entity_mention_round_trips_through_events_with_entity() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let event_id = store
        .put_event(&blank_event(100, "Hey Alice, the layout looks good"))
        .expect("put_event");

    let alice = make_entity("person", "Alice", 1);
    store.put_entity(&alice).expect("put_entity");

    let mention = make_mention(&alice, event_id, "regex", Some("Alice"));
    store.put_entity_mention(&mention).expect("put_mention");

    let hits = store
        .events_with_entity(&alice.id, 10)
        .expect("events_with_entity");
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].event_id, event_id);
    assert_eq!(hits[0].ts_us, 100);
    assert!(hits[0].text_snippet.contains("Alice"));
}

#[test]
fn put_entity_mention_is_idempotent_on_duplicate() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let event_id = store
        .put_event(&blank_event(1, "Hi Bob"))
        .expect("put_event");
    let bob = make_entity("person", "Bob", 1);
    store.put_entity(&bob).expect("put_entity");

    let m = make_mention(&bob, event_id, "regex", Some("Bob"));
    store.put_entity_mention(&m).expect("first");
    store.put_entity_mention(&m).expect("second (idempotent)");
    store.put_entity_mention(&m).expect("third (idempotent)");

    // Only one row in entity_mentions for the (entity, event, extractor,
    // text) tuple.
    let db = raw_open(&path, &key);
    let count: i64 = db
        .conn()
        .query_row(
            "SELECT COUNT(*) FROM entity_mentions
             WHERE entity_id = ?1 AND event_id = ?2",
            params![&bob.id.0, i64::try_from(event_id.0).unwrap()],
            |r| r.get(0),
        )
        .expect("count");
    assert_eq!(count, 1);
}

#[test]
fn events_with_entity_distinct_across_multiple_extractors() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let event_id = store
        .put_event(&blank_event(1, "Bob and Bob talking"))
        .expect("put_event");
    let bob = make_entity("person", "Bob", 1);
    store.put_entity(&bob).expect("put_entity");

    // Two extractor passes write two distinct mention rows for the same
    // (entity, event) pair — the events_with_entity reader must DISTINCT
    // the parent event.
    store
        .put_entity_mention(&make_mention(&bob, event_id, "regex", Some("Bob")))
        .expect("regex pass");
    store
        .put_entity_mention(&make_mention(&bob, event_id, "qwen", Some("Bob")))
        .expect("qwen pass");

    let hits = store
        .events_with_entity(&bob.id, 10)
        .expect("events_with_entity");
    assert_eq!(hits.len(), 1, "event surfaces once despite two mentions");
}

#[test]
fn put_entity_mention_fails_on_missing_entity_fk() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let event_id = store
        .put_event(&blank_event(1, "orphaned mention"))
        .expect("put_event");
    let ghost = EntityId("00000000000000000000000000".to_string());
    let m = EntityMention {
        id: EntityMentionId("ZZZZZZZZZZZZZZZZZZZZZZZZZZ".to_string()),
        entity_id: ghost,
        event_id,
        mention_text: Some("ghost".to_string()),
        confidence: 1.0,
        extractor_kind: "regex".to_string(),
        ts_us: 1,
    };
    let err = store.put_entity_mention(&m).expect_err("FK should fail");
    match err {
        StoreError::Backend(msg) => assert!(
            msg.to_lowercase().contains("constraint") || msg.contains("FOREIGN"),
            "expected FK error, got {msg}"
        ),
        other => panic!("expected Backend FK error, got {other:?}"),
    }
}

#[test]
fn put_entity_mention_fails_on_missing_event_fk() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let alice = make_entity("person", "Alice", 1);
    store.put_entity(&alice).expect("put_entity");
    let ghost_event = EventId(99_999);
    let m = make_mention(&alice, ghost_event, "regex", Some("Alice"));
    let err = store.put_entity_mention(&m).expect_err("FK should fail");
    match err {
        StoreError::Backend(msg) => assert!(
            msg.to_lowercase().contains("constraint") || msg.contains("FOREIGN"),
            "expected FK error, got {msg}"
        ),
        other => panic!("expected Backend FK error, got {other:?}"),
    }
}

#[test]
fn events_with_entity_orders_by_ts_desc_and_caps_limit() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let alice = make_entity("person", "Alice", 1);
    store.put_entity(&alice).expect("put_entity");

    let mut ids = Vec::new();
    for ts in [100_u64, 50, 300, 200] {
        let ev = store.put_event(&blank_event(ts, "Alice")).expect("put_event");
        store
            .put_entity_mention(&make_mention(&alice, ev, "regex", Some("Alice")))
            .expect("put_mention");
        ids.push((ts, ev));
    }
    let hits = store
        .events_with_entity(&alice.id, 3)
        .expect("events_with_entity");
    assert_eq!(hits.len(), 3);
    let order: Vec<u64> = hits.iter().map(|h| h.ts_us).collect();
    assert_eq!(order, vec![300, 200, 100]);
}

#[test]
fn events_with_entity_limit_zero_is_empty_no_sql() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");
    let ghost = EntityId("00000000000000000000000000".to_string());
    let hits = store.events_with_entity(&ghost, 0).expect("zero limit");
    assert!(hits.is_empty());
}

// ---------------------------------------------------------------------------
// 4. put_episode_edge round-trip + idempotence + FK enforcement
// ---------------------------------------------------------------------------

#[test]
fn put_episode_edge_round_trips() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let src = store
        .create_episode(100, 200, Some("com.apple.MobileSMS"))
        .expect("src");
    let dst = store
        .create_episode(150, 250, Some("com.figma.Desktop"))
        .expect("dst");

    let edge = EpisodeEdge {
        id: EpisodeEdge::derive_id("co_active", src, dst),
        src_episode_id: src,
        dst_episode_id: dst,
        edge_kind: "co_active".to_string(),
        evidence_entity_ids: Some("[\"01ABCDEF\"]".to_string()),
        ts_us: 200,
    };
    store.put_episode_edge(&edge).expect("put_episode_edge");

    let db = raw_open(&path, &key);
    let (got_kind, got_evidence, got_ts): (String, Option<String>, i64) = db
        .conn()
        .query_row(
            "SELECT edge_kind, evidence_entity_ids, ts_us
             FROM episode_edges WHERE id = ?1",
            params![&edge.id.0],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .expect("read back");
    assert_eq!(got_kind, "co_active");
    assert_eq!(got_evidence.as_deref(), Some("[\"01ABCDEF\"]"));
    assert_eq!(got_ts, 200);
}

#[test]
fn put_episode_edge_is_idempotent_on_duplicate() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let a = store.create_episode(0, 1, None).expect("a");
    let b = store.create_episode(0, 1, None).expect("b");
    let edge = EpisodeEdge {
        id: EpisodeEdge::derive_id("referenced", a, b),
        src_episode_id: a,
        dst_episode_id: b,
        edge_kind: "referenced".to_string(),
        evidence_entity_ids: None,
        ts_us: 1,
    };
    store.put_episode_edge(&edge).expect("first");
    store.put_episode_edge(&edge).expect("second (idempotent)");

    let db = raw_open(&path, &key);
    let count: i64 = db
        .conn()
        .query_row(
            "SELECT COUNT(*) FROM episode_edges WHERE id = ?1",
            params![&edge.id.0],
            |r| r.get(0),
        )
        .expect("count");
    assert_eq!(count, 1);
}

#[test]
fn put_episode_edge_fails_on_missing_src_or_dst_fk() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let real = store.create_episode(0, 1, None).expect("real");
    let ghost = EpisodeId(99_999);
    let edge = EpisodeEdge {
        id: EpisodeEdgeId("ZZZZZZZZZZZZZZZZZZZZZZZZZZ".to_string()),
        src_episode_id: real,
        dst_episode_id: ghost,
        edge_kind: "co_active".to_string(),
        evidence_entity_ids: None,
        ts_us: 1,
    };
    let err = store.put_episode_edge(&edge).expect_err("FK should fail");
    assert!(matches!(err, StoreError::Backend(_)));
}

// ---------------------------------------------------------------------------
// 5. Cascade on delete — entity removal tears down its mentions
// ---------------------------------------------------------------------------

#[test]
fn deleting_entity_cascades_to_entity_mentions() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let event_id = store
        .put_event(&blank_event(1, "Alice and Bob"))
        .expect("put_event");
    let alice = make_entity("person", "Alice", 1);
    store.put_entity(&alice).expect("put_entity");
    store
        .put_entity_mention(&make_mention(&alice, event_id, "regex", Some("Alice")))
        .expect("put_mention");

    // Manual delete via raw SQL (the BrainStore trait has no
    // `delete_entity` method yet; the retention purger lands later in
    // V2-P3+ to exercise cascade for real).
    let db = raw_open(&path, &key);
    db.conn()
        .execute("DELETE FROM entities WHERE id = ?1", params![&alice.id.0])
        .expect("delete entity");

    let mention_count: i64 = db
        .conn()
        .query_row(
            "SELECT COUNT(*) FROM entity_mentions WHERE entity_id = ?1",
            params![&alice.id.0],
            |r| r.get(0),
        )
        .expect("mention count");
    assert_eq!(mention_count, 0, "FK cascade should have removed mentions");
}

#[test]
fn deleting_event_cascades_to_entity_mentions() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let event_id = store
        .put_event(&blank_event(1, "Alice arriving"))
        .expect("put_event");
    let alice = make_entity("person", "Alice", 1);
    store.put_entity(&alice).expect("put_entity");
    store
        .put_entity_mention(&make_mention(&alice, event_id, "regex", Some("Alice")))
        .expect("put_mention");

    let db = raw_open(&path, &key);
    db.conn()
        .execute(
            "DELETE FROM events WHERE id = ?1",
            params![i64::try_from(event_id.0).unwrap()],
        )
        .expect("delete event");

    let mention_count: i64 = db
        .conn()
        .query_row(
            "SELECT COUNT(*) FROM entity_mentions WHERE event_id = ?1",
            params![i64::try_from(event_id.0).unwrap()],
            |r| r.get(0),
        )
        .expect("mention count");
    assert_eq!(mention_count, 0);
}
