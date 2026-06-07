//! Phase-6-close **recall-surface fusion** integration tests against the
//! production `SqlCipherBrainStore` + `HybridRetriever`.
//!
//! Covers the four claims of the construction-graph wiring row:
//!
//! - **PRODUCTION caller + WIRING-PROOF**: a query naming a known entity
//!   boosts the matching event ABOVE a non-matching event that would
//!   otherwise win on recency — exercising the real `plain_retrieve`
//!   fusion path calling `mention_match_for_events` on the real store.
//! - **NEGATIVE CONTROL**: with `w_entity = 0` (and the pre-change weight
//!   set) the recency winner is restored — the entity arm has zero effect,
//!   so ranking is byte-identical to the four-arm fusion. A query naming no
//!   known entity is likewise unaffected by the new arm.
//! - The three new store reads (`mention_match_for_events` /
//!   `entity_names_for_event` / `linked_event_ids_for_event`) are unit-
//!   round-tripped, including the redacted-token exclusion and the
//!   cross-app `episode_edges` walk.
//! - `stats()` reports the four new V2-P6 graph counts.
//!
//! Mirrors the seeding discipline in `tests/episode_edges_store.rs`:
//! ephemeral encrypted DB under a `tempfile::tempdir()`.

use std::sync::Arc;

use mci_brain::episode_segmenter::{EpisodeId, EpisodeWriter};
use mci_brain::extraction::tier1::KIND_REDACTED_TOKEN;
use mci_brain::extraction::tier2::KIND_PERSON_NAME;
use mci_brain::graph::{Entity, EntityIdentity, EntityMention, EpisodeEdge};
use mci_brain::stubs::FixedDimEmbedder;
use mci_brain::{
    BrainStore, Embedder, Event, EventId, FusionWeights, HybridRetriever, IdentityId,
    RetrievalQuery, Retriever, SqlCipherBrainStore,
};
use mci_core::crypto::{DbKey, InMemoryKeyWrap, KeyWrap};
use tempfile::TempDir;

const HOUR_US: u64 = 3_600_000_000;

fn test_key() -> DbKey {
    let k = DbKey::generate().expect("csprng");
    let wrap = InMemoryKeyWrap;
    let wrapped = wrap.wrap(&k).expect("wrap");
    wrap.unwrap_key(&wrapped).expect("unwrap")
}

fn open_store() -> (TempDir, SqlCipherBrainStore) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("brain.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open");
    (dir, store)
}

fn mk_event(
    ts_us: u64,
    text: &str,
    app: &str,
    episode_id: Option<u64>,
    embedding: Option<Vec<f32>>,
) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some(app.to_string()),
        window_title: None,
        url: None,
        text: text.into(),
        summary: None,
        entities: None,
        episode_id,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding,
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

fn membership(identity: &IdentityId, entity: &Entity, name: &str) -> EntityIdentity {
    EntityIdentity {
        id: EntityIdentity::derive_id(identity, &entity.id),
        entity_id: entity.id.clone(),
        identity_id: identity.clone(),
        identity_kind: "person".to_string(),
        identity_canonical_name: name.to_string(),
        rule: "anchor".to_string(),
        confidence: 1.0,
        ts_us: 1,
    }
}

/// Canonical-order `shared_identity` edge between two episodes.
fn shared_edge(a: EpisodeId, b: EpisodeId, identity: &IdentityId) -> EpisodeEdge {
    let (lo, hi) = if a.0 <= b.0 { (a, b) } else { (b, a) };
    EpisodeEdge {
        id: EpisodeEdge::derive_shared_identity_id(lo, hi, identity),
        src_episode_id: lo,
        dst_episode_id: hi,
        edge_kind: EpisodeEdge::KIND_SHARED_IDENTITY.to_string(),
        evidence_entity_ids: None,
        ts_us: 1,
    }
}

// ===========================================================================
// WIRING-PROOF + NEGATIVE CONTROL — the entity arm changes ranking, and
// only when w_entity > 0.
// ===========================================================================

/// Build a store with two events that tie on lexical+semantic signal: both
/// carry the same `FixedDimEmbedder` embedding and neither contains the
/// query's entity token in its text. `e_alice` is one hour OLDER but carries
/// an NER mention of the entity `Alice`; `e_plain` is newer and mentions
/// nothing. Returns `(store, embedder, now_us, id_alice, id_plain)`.
fn seed_ranking_store() -> (
    TempDir,
    Arc<SqlCipherBrainStore>,
    Arc<FixedDimEmbedder>,
    u64,
    EventId,
    EventId,
) {
    let (dir, store) = open_store();
    let embedder = Arc::new(FixedDimEmbedder::default());
    // Identical embedding for both events ⇒ identical semantic score ⇒ the
    // recency + entity arms are the only differentiators.
    let emb = embedder.embed_one("pricing discussion notes").unwrap();

    let alice = make_entity(KIND_PERSON_NAME, "Alice");
    store.put_entity(&alice).expect("put_entity");

    let now = 1_000 * HOUR_US;
    // Older, mentions Alice (via NER — the literal text does NOT contain
    // "Alice", mirroring a resolved-mention scenario).
    let id_alice = store
        .put_event(&mk_event(
            now - HOUR_US,
            "pricing discussion notes",
            "com.apple.Safari",
            None,
            Some(emb.clone()),
        ))
        .expect("put e_alice");
    store
        .put_entity_mention(&mention(&alice, id_alice, "ner"))
        .expect("mention");

    // Newer, no mention — wins on recency absent the entity arm.
    let id_plain = store
        .put_event(&mk_event(
            now,
            "pricing discussion notes",
            "com.apple.Safari",
            None,
            Some(emb),
        ))
        .expect("put e_plain");

    (dir, Arc::new(store), embedder, now, id_alice, id_plain)
}

fn run_query(
    store: Arc<SqlCipherBrainStore>,
    embedder: Arc<FixedDimEmbedder>,
    now: u64,
    text: &str,
    weights: Option<FusionWeights>,
) -> Vec<EventId> {
    let mut r = HybridRetriever::new(store, embedder, now);
    if let Some(w) = weights {
        r = r.with_weights(w);
    }
    let q = RetrievalQuery {
        text: text.into(),
        limit: 10,
        time_filter: None,
        app_filter: None,
    };
    r.retrieve(&q)
        .expect("retrieve")
        .into_iter()
        .map(|h| h.event_id)
        .collect()
}

#[test]
fn entity_naming_query_boosts_matching_event_above_recency_winner() {
    let (_dir, store, embedder, now, id_alice, id_plain) = seed_ranking_store();

    // Default (rebalanced) weights: the query names "Alice", so the entity
    // arm lifts the older Alice-mentioning event above the newer plain one.
    let order = run_query(store, embedder, now, "Alice pricing discussion", None);
    assert_eq!(
        order.first().copied(),
        Some(id_alice),
        "entity-naming query must rank the Alice-mentioning event first; got {order:?}"
    );
    assert_eq!(order.get(1).copied(), Some(id_plain));
}

#[test]
fn w_entity_zero_restores_recency_winner_byte_identical_to_pre_change() {
    let (_dir, store, embedder, now, id_alice, id_plain) = seed_ranking_store();

    // The PRE-CHANGE weight set with w_entity pinned to 0 — the fusion
    // reduces exactly to the four-arm formula, so the newer event wins on
    // recency regardless of the entity match.
    let pre_change = FusionWeights {
        w_sem: 0.5,
        w_lex: 0.3,
        w_rec: 0.15,
        w_entity: 0.0,
        w_src: 0.05,
    };
    let order = run_query(
        store,
        embedder,
        now,
        "Alice pricing discussion",
        Some(pre_change),
    );
    assert_eq!(
        order.first().copied(),
        Some(id_plain),
        "with w_entity=0 the entity match must have zero effect — recency winner first; got {order:?}"
    );
    assert_eq!(order.get(1).copied(), Some(id_alice));
}

#[test]
fn entity_free_query_is_unaffected_by_the_entity_arm() {
    let (_dir, store, embedder, now, id_alice, id_plain) = seed_ranking_store();

    // Same store + DEFAULT weights, but the query names no known entity —
    // the entity arm is 0 for every candidate, so the newer event wins.
    let order = run_query(store, embedder, now, "pricing discussion", None);
    assert_eq!(
        order.first().copied(),
        Some(id_plain),
        "entity-free query must rank by recency (new arm inert); got {order:?}"
    );
    assert_eq!(order.get(1).copied(), Some(id_alice));
}

// ===========================================================================
// Store read units
// ===========================================================================

#[test]
fn mention_match_for_events_counts_query_entity_mentions_per_event() {
    let (_dir, store) = open_store();
    let alice = make_entity(KIND_PERSON_NAME, "Alice");
    let bob = make_entity(KIND_PERSON_NAME, "Bob");
    store.put_entity(&alice).unwrap();
    store.put_entity(&bob).unwrap();

    let e1 = store
        .put_event(&mk_event(10, "one", "com.apple.Safari", None, None))
        .unwrap();
    let e2 = store
        .put_event(&mk_event(20, "two", "com.apple.Safari", None, None))
        .unwrap();
    let e3 = store
        .put_event(&mk_event(30, "three", "com.apple.Safari", None, None))
        .unwrap();

    // e1 mentions Alice twice (two extractor passes = two rows), e2 once,
    // e3 only mentions Bob (not in the query set).
    store.put_entity_mention(&mention(&alice, e1, "regex")).unwrap();
    store.put_entity_mention(&mention(&alice, e1, "ner")).unwrap();
    store.put_entity_mention(&mention(&alice, e2, "ner")).unwrap();
    store.put_entity_mention(&mention(&bob, e3, "ner")).unwrap();

    let counts = store
        .mention_match_for_events(std::slice::from_ref(&alice.id), &[e1, e2, e3])
        .expect("mention_match");
    assert_eq!(counts.get(&e1).copied(), Some(2));
    assert_eq!(counts.get(&e2).copied(), Some(1));
    assert_eq!(counts.get(&e3), None, "Bob-only event must not match Alice");

    // Empty inputs short-circuit to an empty map.
    assert!(store
        .mention_match_for_events(&[], &[e1])
        .unwrap()
        .is_empty());
    assert!(store
        .mention_match_for_events(&[alice.id], &[])
        .unwrap()
        .is_empty());
}

#[test]
fn entity_names_for_event_returns_allowlist_only_excludes_redacted() {
    let (_dir, store) = open_store();
    let alice = make_entity(KIND_PERSON_NAME, "Alice");
    let secret = make_entity(KIND_REDACTED_TOKEN, "jwt");
    store.put_entity(&alice).unwrap();
    store.put_entity(&secret).unwrap();

    let e = store
        .put_event(&mk_event(10, "msg", "com.apple.Safari", None, None))
        .unwrap();
    store.put_entity_mention(&mention(&alice, e, "ner")).unwrap();
    store.put_entity_mention(&mention(&secret, e, "regex")).unwrap();

    let names = store.entity_names_for_event(e, 16).expect("names");
    assert_eq!(
        names,
        vec!["Alice".to_string()],
        "redacted-token subkind label must never surface; got {names:?}"
    );
    assert!(store.entity_names_for_event(e, 0).unwrap().is_empty());
}

#[test]
fn linked_event_ids_walks_shared_identity_edges_cross_app() {
    let (_dir, store) = open_store();
    // ep1 = Safari, ep2 = Messages.
    let ep1 = store
        .create_episode(0, 100, Some("com.apple.Safari"))
        .unwrap();
    let ep2 = store
        .create_episode(0, 100, Some("com.apple.MobileSMS"))
        .unwrap();

    // e1 + e3 in ep1; e2 in ep2.
    let e1 = store
        .put_event(&mk_event(10, "pricing", "com.apple.Safari", Some(ep1.0), None))
        .unwrap();
    let e3 = store
        .put_event(&mk_event(15, "more safari", "com.apple.Safari", Some(ep1.0), None))
        .unwrap();
    let e2 = store
        .put_event(&mk_event(20, "hi alice", "com.apple.MobileSMS", Some(ep2.0), None))
        .unwrap();

    // Unsegmented event — no episode, so no links.
    let e_lone = store
        .put_event(&mk_event(30, "lonely", "com.apple.Safari", None, None))
        .unwrap();

    let identity = EntityIdentity::derive_identity_id("person", "alice");
    store
        .put_episode_edges(&[shared_edge(ep1, ep2, &identity)])
        .expect("edge");

    // From e1 (ep1): linked events are ep2's events = {e2}; e3 (same
    // episode) and e1 (self) are excluded.
    let from_e1 = store.linked_event_ids_for_event(e1, 16).expect("linked e1");
    assert_eq!(from_e1, vec![e2], "ep1 hit must link only to ep2 events");
    assert!(!from_e1.contains(&e1));
    assert!(!from_e1.contains(&e3));

    // Symmetric: from e2 (ep2): linked events are ep1's events = {e1, e3}.
    let mut from_e2 = store.linked_event_ids_for_event(e2, 16).expect("linked e2");
    from_e2.sort();
    let mut want = vec![e1, e3];
    want.sort();
    assert_eq!(from_e2, want, "ep2 hit must link to both ep1 events");

    // Unsegmented hit has no episode ⇒ no links.
    assert!(store
        .linked_event_ids_for_event(e_lone, 16)
        .unwrap()
        .is_empty());
}

#[test]
fn stats_reports_the_four_graph_counts() {
    let (_dir, store) = open_store();
    assert_eq!(store.stats().unwrap().entity_count, 0, "empty store");

    let alice = make_entity(KIND_PERSON_NAME, "Alice");
    let bob = make_entity(KIND_PERSON_NAME, "Bob");
    store.put_entity(&alice).unwrap();
    store.put_entity(&bob).unwrap();

    let ep1 = store.create_episode(0, 100, Some("com.apple.Safari")).unwrap();
    let ep2 = store
        .create_episode(0, 100, Some("com.apple.MobileSMS"))
        .unwrap();
    let e1 = store
        .put_event(&mk_event(10, "x", "com.apple.Safari", Some(ep1.0), None))
        .unwrap();
    let e2 = store
        .put_event(&mk_event(20, "y", "com.apple.MobileSMS", Some(ep2.0), None))
        .unwrap();

    store.put_entity_mention(&mention(&alice, e1, "ner")).unwrap();
    store.put_entity_mention(&mention(&alice, e2, "ner")).unwrap();
    store.put_entity_mention(&mention(&bob, e1, "ner")).unwrap();

    let identity = EntityIdentity::derive_identity_id("person", "alice");
    store
        .put_entity_identity(&membership(&identity, &alice, "Alice"))
        .unwrap();
    store
        .put_episode_edges(&[shared_edge(ep1, ep2, &identity)])
        .unwrap();

    let s = store.stats().unwrap();
    assert_eq!(s.event_count, 2);
    assert_eq!(s.entity_count, 2);
    assert_eq!(s.entity_mention_count, 3);
    assert_eq!(s.entity_identity_count, 1);
    assert_eq!(s.episode_edge_count, 1);
}
