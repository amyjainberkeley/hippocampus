//! V2-P6 — round-trip integration tests for the episode-edge
//! **Consolidator** store surface (`consolidation_candidates` /
//! `put_episode_edges` / `consolidation_watermark` /
//! `episode_edges_for_identity` / `events_in_episode`) against the
//! production `SqlCipherBrainStore`.
//!
//! Mirrors `tests/graph_store.rs`: ephemeral encrypted DB under a
//! `tempfile::tempdir()` with an `InMemoryKeyWrap`-derived `DbKey`.

use std::path::{Path, PathBuf};

use mci_brain::episode_segmenter::{EpisodeId, EpisodeWriter};
use mci_brain::graph::{Entity, EntityIdentity, EntityMention, EpisodeEdge};
use mci_brain::{BrainStore, Event, EventId, IdentityId, SqlCipherBrainStore};
use mci_core::crypto::{DbKey, InMemoryKeyWrap, KeyWrap};
use mci_core::store::{open as mci_core_open, Db};
use rusqlite::params;
use tempfile::TempDir;

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

/// An event in a known episode + app at a given time (`cascade_reason = 0`).
fn event_in(episode: EpisodeId, app: &str, ts_us: u64, text: &str) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some(app.to_string()),
        window_title: None,
        url: None,
        text: text.into(),
        summary: None,
        entities: None,
        episode_id: Some(episode.0),
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: None,
    }
}

fn make_entity(kind: &str, name: &str) -> Entity {
    Entity {
        id: Entity::derive_id(kind, name),
        kind: kind.to_string(),
        canonical_name: name.to_string(),
        summary: None,
        summary_embedding: None,
        content_hash: Entity::derive_content_hash(kind, name),
        created_ts_us: 1,
        updated_ts_us: 1,
    }
}

fn mention(entity: &Entity, event_id: EventId, extractor: &str) -> EntityMention {
    EntityMention {
        id: EntityMention::derive_id(&entity.id, event_id, extractor, None),
        entity_id: entity.id.clone(),
        event_id,
        mention_text: None,
        confidence: 1.0,
        extractor_kind: extractor.to_string(),
        ts_us: 1,
    }
}

/// Mint one `entity_identities` membership row directly (bypassing the
/// resolver — these tests exercise the store, not clustering).
fn membership(identity: &IdentityId, entity: &Entity, kind: &str, name: &str) -> EntityIdentity {
    EntityIdentity {
        id: EntityIdentity::derive_id(identity, &entity.id),
        entity_id: entity.id.clone(),
        identity_id: identity.clone(),
        identity_kind: kind.to_string(),
        identity_canonical_name: name.to_string(),
        rule: "anchor".to_string(),
        confidence: 1.0,
        ts_us: 1,
    }
}

// ---------------------------------------------------------------------------
// consolidation_candidates — only segmented, post-cascade member mentions
// ---------------------------------------------------------------------------

#[test]
fn consolidation_candidates_excludes_unsegmented_and_suppressed_events() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let ep = store
        .create_episode(1_000, 2_000, Some("com.apple.MobileSMS"))
        .expect("ep");
    let name = make_entity("person_name", "Alice Smith");
    store.put_entity(&name).expect("put_entity");
    let identity = EntityIdentity::derive_identity_id("person", "alice smith");
    store
        .put_entity_identity(&membership(&identity, &name, "person", "Alice Smith"))
        .expect("membership");

    // (a) GOOD: segmented (episode set), cascade_reason = 0.
    let good = store
        .put_event(&event_in(ep, "com.apple.MobileSMS", 1_500, "Hi Alice"))
        .expect("good event");
    store
        .put_entity_mention(&mention(&name, good, "ner"))
        .expect("good mention");

    // (b) UNSEGMENTED: episode_id NULL → excluded.
    let mut unseg = event_in(ep, "com.apple.MobileSMS", 1_600, "Alice again");
    unseg.episode_id = None;
    let unseg = store.put_event(&unseg).expect("unseg event");
    store
        .put_entity_mention(&mention(&name, unseg, "ner"))
        .expect("unseg mention");

    // (c) SUPPRESSED: cascade_reason != 0 → excluded. `put_event` blocks
    // reason != 0, so insert it through a raw connection (defence-in-depth
    // for the WHERE cascade_reason = 0 filter).
    {
        let db = raw_open(&path, &key);
        db.conn()
            .execute(
                "INSERT INTO events (ts_us, app_bundle_id, text, episode_id, cascade_reason)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    1_700_i64,
                    "com.apple.MobileSMS",
                    "redacted Alice",
                    i64::try_from(ep.0).unwrap(),
                    9_i64
                ],
            )
            .expect("raw suppressed insert");
        let bad_id = EventId(u64::try_from(db.conn().last_insert_rowid()).unwrap());
        store
            .put_entity_mention(&mention(&name, bad_id, "ner"))
            .expect("bad mention");
    }

    let sites = store.consolidation_candidates().expect("candidates");
    let for_identity: Vec<_> = sites.iter().filter(|s| s.identity_id == identity).collect();
    assert_eq!(
        for_identity.len(),
        1,
        "only the segmented, post-cascade mention is a candidate"
    );
    assert_eq!(for_identity[0].entity_id, name.id);
    assert_eq!(for_identity[0].episode_id, ep);
    assert_eq!(for_identity[0].ts_us, 1_500);
}

// ---------------------------------------------------------------------------
// put_episode_edges — batch insert, inserted-count, idempotence
// ---------------------------------------------------------------------------

#[test]
fn put_episode_edges_batch_inserts_then_idempotent() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let ep1 = store
        .create_episode(0, 1, Some("com.apple.MobileSMS"))
        .expect("ep1");
    let ep2 = store
        .create_episode(0, 1, Some("com.apple.Safari"))
        .expect("ep2");
    let identity = EntityIdentity::derive_identity_id("person", "alice smith");
    let edge = EpisodeEdge {
        id: EpisodeEdge::derive_shared_identity_id(ep1, ep2, &identity),
        src_episode_id: ep1,
        dst_episode_id: ep2,
        edge_kind: EpisodeEdge::KIND_SHARED_IDENTITY.to_string(),
        evidence_entity_ids: Some("[\"01ABC\"]".to_string()),
        ts_us: 42,
    };

    let inserted = store
        .put_episode_edges(std::slice::from_ref(&edge))
        .expect("first batch");
    assert_eq!(inserted, 1, "one new edge inserted");

    // Re-deriving the same edge is a row-level no-op (INSERT OR IGNORE).
    let again = store
        .put_episode_edges(std::slice::from_ref(&edge))
        .expect("second batch");
    assert_eq!(again, 0, "idempotent re-derive inserts nothing");

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

fn shared_edge(src: EpisodeId, dst: EpisodeId, identity: &IdentityId) -> EpisodeEdge {
    EpisodeEdge {
        id: EpisodeEdge::derive_shared_identity_id(src, dst, identity),
        src_episode_id: src,
        dst_episode_id: dst,
        edge_kind: EpisodeEdge::KIND_SHARED_IDENTITY.to_string(),
        evidence_entity_ids: None,
        ts_us: 1,
    }
}

#[test]
fn reconcile_episode_edges_prunes_stale_idempotent_and_kind_scoped() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let ep1 = store
        .create_episode(0, 1, Some("com.apple.MobileSMS"))
        .expect("ep1");
    let ep2 = store
        .create_episode(0, 1, Some("com.apple.Safari"))
        .expect("ep2");
    let ep3 = store
        .create_episode(0, 1, Some("com.apple.Notes"))
        .expect("ep3");
    let identity = EntityIdentity::derive_identity_id("person", "alice smith");
    let edge12 = shared_edge(ep1, ep2, &identity);
    let edge13 = shared_edge(ep1, ep3, &identity);

    // An UNRELATED edge of a different kind — reconcile must never touch it.
    let other = EpisodeEdge {
        id: EpisodeEdge::derive_id("co_active", ep2, ep3),
        src_episode_id: ep2,
        dst_episode_id: ep3,
        edge_kind: "co_active".to_string(),
        evidence_entity_ids: None,
        ts_us: 1,
    };
    store.put_episode_edge(&other).expect("co_active edge");

    // Reconcile to {edge12, edge13}.
    let s = store
        .reconcile_episode_edges(
            EpisodeEdge::KIND_SHARED_IDENTITY,
            &[edge12.clone(), edge13.clone()],
        )
        .expect("reconcile");
    assert_eq!((s.inserted, s.deleted), (2, 0));

    // Identical re-run → true no-op.
    let s2 = store
        .reconcile_episode_edges(
            EpisodeEdge::KIND_SHARED_IDENTITY,
            &[edge12.clone(), edge13.clone()],
        )
        .expect("reconcile2");
    assert_eq!((s2.inserted, s2.deleted), (0, 0));

    // Derived set shrinks to {edge12} → edge13 pruned.
    let s3 = store
        .reconcile_episode_edges(
            EpisodeEdge::KIND_SHARED_IDENTITY,
            std::slice::from_ref(&edge12),
        )
        .expect("reconcile3");
    assert_eq!((s3.inserted, s3.deleted), (0, 1), "stale edge13 pruned");
    let remaining = store.episode_edges_for_identity(&identity).expect("walk");
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].id, edge12.id);

    // Empty set → prune the rest.
    let s4 = store
        .reconcile_episode_edges(EpisodeEdge::KIND_SHARED_IDENTITY, &[])
        .expect("reconcile4");
    assert_eq!(s4.deleted, 1);
    assert!(store
        .episode_edges_for_identity(&identity)
        .expect("walk2")
        .is_empty());

    // The co_active edge of another kind survived every reconcile.
    let db = raw_open(&path, &key);
    let kept: i64 = db
        .conn()
        .query_row(
            "SELECT COUNT(*) FROM episode_edges WHERE id = ?1",
            params![&other.id.0],
            |r| r.get(0),
        )
        .expect("count");
    assert_eq!(
        kept, 1,
        "reconcile is scoped to edge_kind and never touched co_active"
    );
}

#[test]
fn put_episode_edges_empty_is_noop() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");
    assert_eq!(store.put_episode_edges(&[]).expect("empty"), 0);
}

// ---------------------------------------------------------------------------
// episode_edges_for_identity — PRECISE per-identity filter
// ---------------------------------------------------------------------------

#[test]
fn episode_edges_for_identity_isolates_per_identity_over_same_pair() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let ep1 = store
        .create_episode(0, 1, Some("com.apple.MobileSMS"))
        .expect("ep1");
    let ep2 = store
        .create_episode(0, 1, Some("com.apple.Safari"))
        .expect("ep2");

    // Two DIFFERENT identities, each linking the SAME episode pair.
    let alice = EntityIdentity::derive_identity_id("person", "alice smith");
    let bob = EntityIdentity::derive_identity_id("person", "bob jones");
    let alice_edge = EpisodeEdge {
        id: EpisodeEdge::derive_shared_identity_id(ep1, ep2, &alice),
        src_episode_id: ep1,
        dst_episode_id: ep2,
        edge_kind: EpisodeEdge::KIND_SHARED_IDENTITY.to_string(),
        evidence_entity_ids: None,
        ts_us: 1,
    };
    let bob_edge = EpisodeEdge {
        id: EpisodeEdge::derive_shared_identity_id(ep1, ep2, &bob),
        src_episode_id: ep1,
        dst_episode_id: ep2,
        edge_kind: EpisodeEdge::KIND_SHARED_IDENTITY.to_string(),
        evidence_entity_ids: None,
        ts_us: 1,
    };
    assert_ne!(
        alice_edge.id, bob_edge.id,
        "distinct identity → distinct PK"
    );
    let inserted = store
        .put_episode_edges(&[alice_edge.clone(), bob_edge.clone()])
        .expect("put two");
    assert_eq!(inserted, 2);

    let a = store
        .episode_edges_for_identity(&alice)
        .expect("alice edges");
    assert_eq!(a.len(), 1);
    assert_eq!(a[0].id, alice_edge.id);

    let b = store.episode_edges_for_identity(&bob).expect("bob edges");
    assert_eq!(b.len(), 1);
    assert_eq!(b[0].id, bob_edge.id);

    let unknown = EntityIdentity::derive_identity_id("person", "nobody here");
    assert!(store
        .episode_edges_for_identity(&unknown)
        .expect("none")
        .is_empty());
}

// ---------------------------------------------------------------------------
// events_in_episode — leaf of the dot-connect walk
// ---------------------------------------------------------------------------

#[test]
fn events_in_episode_returns_episode_events_newest_first() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let ep = store
        .create_episode(0, 1, Some("com.apple.Safari"))
        .expect("ep");
    let other = store
        .create_episode(0, 1, Some("com.apple.MobileSMS"))
        .expect("other");
    store
        .put_event(&event_in(ep, "com.apple.Safari", 100, "first"))
        .expect("e1");
    store
        .put_event(&event_in(ep, "com.apple.Safari", 300, "third"))
        .expect("e3");
    store
        .put_event(&event_in(ep, "com.apple.Safari", 200, "second"))
        .expect("e2");
    // An event in a DIFFERENT episode must not leak in.
    store
        .put_event(&event_in(other, "com.apple.MobileSMS", 250, "elsewhere"))
        .expect("eo");

    let hits = store.events_in_episode(ep, 10).expect("events_in_episode");
    let ts: Vec<u64> = hits.iter().map(|h| h.ts_us).collect();
    assert_eq!(
        ts,
        vec![300, 200, 100],
        "newest first, scoped to the episode"
    );

    assert!(store.events_in_episode(ep, 0).expect("zero").is_empty());
}

// ---------------------------------------------------------------------------
// consolidation_watermark — change detection
// ---------------------------------------------------------------------------

#[test]
fn consolidation_watermark_changes_when_inputs_change() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let w0 = store.consolidation_watermark().expect("w0");
    assert_eq!(w0, mci_brain::ConsolidationWatermark::default());

    let ep = store
        .create_episode(0, 1, Some("com.apple.Safari"))
        .expect("ep");
    let ev = store
        .put_event(&event_in(ep, "com.apple.Safari", 100, "Alice"))
        .expect("ev");
    let w1 = store.consolidation_watermark().expect("w1");
    assert_ne!(w1, w0, "a segmented event bumps the watermark");

    let name = make_entity("person_name", "Alice Smith");
    store.put_entity(&name).expect("entity");
    store
        .put_entity_mention(&mention(&name, ev, "ner"))
        .expect("mention");
    let identity = EntityIdentity::derive_identity_id("person", "alice smith");
    store
        .put_entity_identity(&membership(&identity, &name, "person", "Alice Smith"))
        .expect("membership");
    let w2 = store.consolidation_watermark().expect("w2");
    assert_ne!(
        w2, w1,
        "a mention + identity membership bumps the watermark"
    );

    // Stable when nothing changes.
    assert_eq!(store.consolidation_watermark().expect("w2 again"), w2);
}
