//! V2-P6 — construction-graph WIRING PROOF + Phase-6 **dot-connect gate**
//! for the episode-edge Consolidator.
//!
//! `worker_connects_cross_app_events_end_to_end` drives the *production*
//! worker entry points — the same functions `bin/mci_agent.rs` spawns —
//! against a real `SqlCipherBrainStore`, exercising the WHOLE pipeline on a
//! fixture:
//!
//! ```text
//!   events (Messages + Safari)
//!        │  episode_worker        → episodes (one per app)
//!        │  alias_resolver_worker → entity_identities (one Person)
//!        │  consolidator_worker   → episode_edges (shared_identity)
//!        ▼
//!   episode_edges_for_identity → events_in_episode
//!        ⇒ BOTH the Messages event AND the Safari event come back as a
//!          single connected hit  ← the Phase-6 "first cross-app
//!          dot-connect query returns a hit" gate.
//! ```
//!
//! `worker_re_derivation_is_idempotent` proves a second consolidator pass
//! over the unchanged store writes ZERO new edges and leaves the rows
//! byte-identical (content-stable PK + `INSERT OR IGNORE`).
//!
//! # CSO sign-off notes
//!
//! (a) The workers read only post-cascade, segmented events + already-
//!     resolved identities and write only `episode_edges` (migration 0004,
//!     NO new schema). No capture-scope change, no new IPC, no network.
//! (b) Hermetic — every brain lives in a `tempfile::TempDir`.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use mci_agent::{alias_resolver_worker, consolidator_worker, episode_worker};
use mci_brain::episode_segmenter::HeuristicEpisodeSegmenter;
use mci_brain::graph::{Entity, EntityMention};
use mci_brain::{BrainStore, Event, EventId, IdentityId, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

const MESSAGES: &str = "com.apple.MobileSMS";
const SAFARI: &str = "com.apple.Safari";
const S: u64 = 1_000_000; // one second, microseconds

fn open_temp_store() -> (tempfile::TempDir, Arc<SqlCipherBrainStore>, PathBuf, DbKey) {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("test_edges.sqlite");
    let key = DbKey::from_bytes([0xCD; 32]);
    let store = Arc::new(SqlCipherBrainStore::new(&db_path, &key).unwrap());
    (dir, store, db_path, key)
}

/// An unsegmented event (the segmenter assigns the episode) in `app` at
/// time `ts_us`.
fn event(app: &str, ts_us: u64, text: &str) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some(app.to_string()),
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

/// Spawn a worker future for one cycle, then signal shutdown and join.
async fn one_cycle<F, Fut, T>(make: F) -> T
where
    F: FnOnce(tokio::sync::watch::Receiver<bool>) -> Fut,
    Fut: std::future::Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    let (tx, rx) = tokio::sync::watch::channel(false);
    let handle = tokio::spawn(make(rx));
    tokio::time::sleep(Duration::from_millis(250)).await;
    let _ = tx.send(true);
    handle.await.unwrap()
}

/// Run segmenter → alias-resolver, leaving a fully-resolved store ready for
/// the consolidator. Returns the identity the Person resolves to.
async fn build_resolved_store(store: &Arc<SqlCipherBrainStore>) -> IdentityId {
    // Two events: an event in Messages mentioning Alice's NAME, then an
    // event in Safari (30 s later) mentioning Alice's EMAIL — the canonical
    // cross-app scenario.
    let msg = store
        .put_event(&event(MESSAGES, S, "Texting Alice Smith"))
        .unwrap();
    let web = store
        .put_event(&event(SAFARI, 31 * S, "alice.smith@corp.com profile"))
        .unwrap();

    let name = make_entity("person_name", "Alice Smith");
    let mail = make_entity("email", "alice.smith@corp.com");
    store.put_entity(&name).unwrap();
    store.put_entity(&mail).unwrap();
    store
        .put_entity_mention(&mention(&name, msg, "ner"))
        .unwrap();
    store
        .put_entity_mention(&mention(&mail, web, "regex"))
        .unwrap();

    // 1) Segment events into per-app episodes.
    let seg_store = Arc::clone(store);
    one_cycle(move |rx| async move {
        episode_worker::run_episode_worker(
            seg_store,
            Arc::new(HeuristicEpisodeSegmenter::new()),
            64,
            Duration::from_millis(50),
            rx,
        )
        .await
        .unwrap()
    })
    .await;

    // 2) Resolve the name + email into ONE canonical identity.
    let alias_store = Arc::clone(store);
    one_cycle(move |rx| async move {
        alias_resolver_worker::run_alias_resolver_worker(alias_store, Duration::from_millis(50), rx)
            .await
            .unwrap()
    })
    .await;

    // The name + email must have collapsed into one identity.
    let by_name = store.identity_of_entity(&name.id).unwrap();
    let by_mail = store.identity_of_entity(&mail.id).unwrap();
    assert_eq!(by_name.len(), 1, "name resolves to an identity");
    assert_eq!(by_mail.len(), 1, "email resolves to an identity");
    assert_eq!(
        by_name[0].identity_id, by_mail[0].identity_id,
        "name + email are the SAME person"
    );
    by_name[0].identity_id.clone()
}

/// Run the production consolidator worker for one cycle.
async fn run_consolidator_once(
    store: &Arc<SqlCipherBrainStore>,
) -> consolidator_worker::ConsolidatorStats {
    let cons_store = Arc::clone(store);
    one_cycle(move |rx| async move {
        consolidator_worker::run_consolidator_worker(cons_store, Duration::from_millis(50), rx)
            .await
            .unwrap()
    })
    .await
}

#[tokio::test]
async fn worker_connects_cross_app_events_end_to_end() {
    let (_dir, store, _path, _key) = open_temp_store();
    let identity = build_resolved_store(&store).await;

    // 3) Consolidate → cross-app `shared_identity` edge.
    let stats = run_consolidator_once(&store).await;
    assert!(stats.cycles_run >= 1, "consolidator ran a cycle");
    assert_eq!(stats.store_errors, 0);
    assert!(stats.edges_written >= 1, "wrote ≥1 cross-app edge");

    // 4) THE DOT-CONNECT QUERY: walk identity → edges → linked events.
    let edges = store.episode_edges_for_identity(&identity).unwrap();
    assert_eq!(edges.len(), 1, "exactly one cross-app link for this person");
    let edge = &edges[0];
    assert_eq!(edge.edge_kind, mci_brain::EpisodeEdge::KIND_SHARED_IDENTITY);

    // Evidence cites BOTH the name and the email entity.
    let evidence: Vec<String> =
        serde_json::from_str(edge.evidence_entity_ids.as_deref().unwrap()).unwrap();
    let name_id = Entity::derive_id("person_name", "Alice Smith").0;
    let mail_id = Entity::derive_id("email", "alice.smith@corp.com").0;
    assert!(evidence.contains(&name_id), "name is cited as evidence");
    assert!(evidence.contains(&mail_id), "email is cited as evidence");

    // Walk both endpoints back to their events — the connected hit must
    // contain ONE Messages event AND ONE Safari event (cross-app).
    let mut apps: Vec<String> = Vec::new();
    for ep in [edge.src_episode_id, edge.dst_episode_id] {
        for ev in store.events_in_episode(ep, 10).unwrap() {
            apps.push(ev.app_bundle_id.unwrap_or_default());
        }
    }
    assert!(
        apps.iter().any(|a| a == MESSAGES),
        "the connected hit includes the Messages event ({apps:?})"
    );
    assert!(
        apps.iter().any(|a| a == SAFARI),
        "the connected hit includes the Safari event ({apps:?})"
    );
}

#[tokio::test]
async fn worker_re_derivation_is_idempotent() {
    let (_dir, store, _path, _key) = open_temp_store();
    let identity = build_resolved_store(&store).await;

    // First consolidate cycle — writes the edge.
    let first = run_consolidator_once(&store).await;
    assert!(first.edges_written >= 1);
    let after_first = store.episode_edges_for_identity(&identity).unwrap();
    assert_eq!(after_first.len(), 1);

    // Second cycle on the UNCHANGED store — a fresh worker re-derives the
    // same edge and writes/prunes NOTHING (content-stable PK + reconcile
    // no-op).
    let second = run_consolidator_once(&store).await;
    assert!(second.edges_derived_last >= 1, "it re-derived the edge");
    assert_eq!(second.edges_written, 0, "but inserted nothing new");
    assert_eq!(second.edges_pruned, 0, "and pruned nothing");

    // The rows are byte-identical across the two passes.
    let after_second = store.episode_edges_for_identity(&identity).unwrap();
    assert_eq!(
        after_first, after_second,
        "edges are stable across re-derivation"
    );
}

#[tokio::test]
async fn worker_prunes_stale_edge_when_membership_shrinks() {
    // The self-healing guarantee (review finding: a grow-only consolidator
    // would strand an edge after the AliasResolver drops a membership it
    // rested on). Here the resolver later disavows the email leaf; the
    // identity then co-occurs in only the Messages episode, so its cross-app
    // edge is no longer derivable and the next consolidate MUST prune it.
    let (_dir, store, path, key) = open_temp_store();
    let identity = build_resolved_store(&store).await;

    run_consolidator_once(&store).await;
    assert_eq!(
        store.episode_edges_for_identity(&identity).unwrap().len(),
        1,
        "edge exists after first consolidate"
    );

    // Simulate the alias reconcile dropping the email membership. `mail_id`
    // is a Crockford-base32 ULID (alphanumeric only — safe to inline), so
    // this needs no rusqlite param binding / dev-dep.
    let mail_id = Entity::derive_id("email", "alice.smith@corp.com").0;
    {
        let db = mci_core::store::open(&path, &key).unwrap();
        db.conn()
            .execute(
                &format!("DELETE FROM entity_identities WHERE entity_id = '{mail_id}'"),
                [],
            )
            .unwrap();
    }

    // Re-consolidate → the now-unjustified edge is pruned (self-healing).
    let stats = run_consolidator_once(&store).await;
    assert!(stats.edges_pruned >= 1, "stale edge pruned");
    assert!(
        store
            .episode_edges_for_identity(&identity)
            .unwrap()
            .is_empty(),
        "no stale cross-app link remains after the membership shrank"
    );
}
