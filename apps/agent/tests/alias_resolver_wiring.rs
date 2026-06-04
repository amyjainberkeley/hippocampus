//! V2-P6 — construction-graph WIRING PROOF for the `AliasResolver`.
//!
//! These tests drive the *production* worker entry point
//! [`alias_resolver_worker::run_alias_resolver_worker`] — the same
//! function `bin/mci_agent.rs` spawns — against a real
//! `SqlCipherBrainStore`, proving the full path
//!
//!   `entity_mentions`  →  resolver  →  `entity_identities` rows
//!
//! actually runs end-to-end (the
//! [[project-v2p1-unit-tests-passed-but-never-wired]] lesson: a worker
//! that compiles but is never called is dead code). A second test is the
//! false-merge guard: two distinct people driven through the same worker
//! must never collapse into one identity.
//!
//! # CSO sign-off notes
//!
//! (a) The worker reads only post-cascade alias entities and writes only
//!     `entity_identities` (migration 0005). No capture-scope change, no
//!     new IPC, no network surface.
//! (b) Hermetic — every brain lives in a `tempfile::TempDir`.

use std::sync::Arc;
use std::time::Duration;

use mci_agent::alias_resolver_worker;
use mci_brain::graph::{Entity, EntityMention};
use mci_brain::{BrainStore, Event, EventId, IdentityId, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

fn open_temp_store() -> (tempfile::TempDir, Arc<SqlCipherBrainStore>) {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("test_alias.sqlite");
    let key = DbKey::from_bytes([0xAB; 32]);
    let store = Arc::new(SqlCipherBrainStore::new(&db_path, &key).unwrap());
    (dir, store)
}

fn blank_event(ts_us: u64) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: None,
        window_title: None,
        url: None,
        text: "t".into(),
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

/// Spawn the production worker, let it run one resolve cycle, then signal
/// shutdown and join. Returns the worker stats.
async fn run_worker_one_cycle(
    store: &Arc<SqlCipherBrainStore>,
) -> alias_resolver_worker::AliasResolverStats {
    let (tx, rx) = tokio::sync::watch::channel(false);
    let store_c = Arc::clone(store);
    let handle = tokio::spawn(async move {
        alias_resolver_worker::run_alias_resolver_worker(store_c, Duration::from_millis(50), rx)
            .await
    });
    // Let the worker complete one resolve + write, then enter idle sleep.
    tokio::time::sleep(Duration::from_millis(250)).await;
    let _ = tx.send(true);
    handle.await.unwrap().unwrap()
}

#[tokio::test]
async fn worker_writes_identity_rows_end_to_end() {
    let (_dir, store) = open_temp_store();

    let e1 = store.put_event(&blank_event(1_000)).unwrap();
    let e2 = store.put_event(&blank_event(2_000)).unwrap();
    let e3 = store.put_event(&blank_event(3_000)).unwrap();

    let name = make_entity("person_name", "Alice Smith");
    let mail = make_entity("email", "alice.smith@corp.com");
    let phone = make_entity("phone", "+1 555 123 4567");
    for ent in [&name, &mail, &phone] {
        store.put_entity(ent).unwrap();
    }
    store
        .put_entity_mention(&mention(&name, e1, "ner"))
        .unwrap();
    store
        .put_entity_mention(&mention(&mail, e2, "regex"))
        .unwrap();
    // phone co-occurs with the name in e3 (the sole phone↔name signal).
    store
        .put_entity_mention(&mention(&phone, e3, "regex"))
        .unwrap();
    store
        .put_entity_mention(&mention(&name, e3, "ner"))
        .unwrap();

    let stats = run_worker_one_cycle(&store).await;
    assert!(
        stats.cycles_run >= 1,
        "worker ran at least one resolve cycle"
    );
    assert!(stats.memberships_written >= 3, "wrote ≥3 membership rows");
    assert_eq!(stats.store_errors, 0);

    // Walk the identity from the email alias — proves the persisted rows
    // are queryable end-to-end via the BrainStore read surface.
    let membership = store.identity_of_entity(&mail.id).unwrap();
    assert_eq!(membership.len(), 1, "email resolves to one identity");
    assert_eq!(membership[0].identity_kind, "person");
    let identity_id: IdentityId = membership[0].identity_id.clone();

    let members = store.identity_members(&identity_id).unwrap();
    let ids: std::collections::BTreeSet<&str> =
        members.iter().map(|m| m.entity_id.0.as_str()).collect();
    assert!(ids.contains(name.id.0.as_str()), "name walked");
    assert!(ids.contains(mail.id.0.as_str()), "email walked");
    assert!(ids.contains(phone.id.0.as_str()), "phone walked");
    assert_eq!(members.len(), 3);
}

#[tokio::test]
async fn worker_false_merge_guard_keeps_distinct_people_apart() {
    let (_dir, store) = open_temp_store();

    let e1 = store.put_event(&blank_event(1_000)).unwrap();
    let e2 = store.put_event(&blank_event(2_000)).unwrap();

    let smith = make_entity("person_name", "Alice Smith");
    let smith_mail = make_entity("email", "alice.smith@corp.com");
    let chen = make_entity("person_name", "Alice Chen");
    let chen_mail = make_entity("email", "alice.chen@corp.com");
    let bare = make_entity("person_name", "Alice");
    for ent in [&smith, &smith_mail, &chen, &chen_mail, &bare] {
        store.put_entity(ent).unwrap();
    }
    store
        .put_entity_mention(&mention(&smith, e1, "ner"))
        .unwrap();
    store
        .put_entity_mention(&mention(&smith_mail, e1, "regex"))
        .unwrap();
    store
        .put_entity_mention(&mention(&chen, e2, "ner"))
        .unwrap();
    store
        .put_entity_mention(&mention(&chen_mail, e2, "regex"))
        .unwrap();
    store
        .put_entity_mention(&mention(&bare, e1, "ner"))
        .unwrap();

    run_worker_one_cycle(&store).await;

    let smith_id = store.identity_of_entity(&smith.id).unwrap();
    let chen_id = store.identity_of_entity(&chen.id).unwrap();
    assert_eq!(smith_id.len(), 1);
    assert_eq!(chen_id.len(), 1);
    assert_ne!(
        smith_id[0].identity_id, chen_id[0].identity_id,
        "distinct people must never share an identity"
    );
    let smith_members = store.identity_members(&smith_id[0].identity_id).unwrap();
    assert!(smith_members.iter().all(|m| m.entity_id != chen.id));
    assert!(smith_members.iter().all(|m| m.entity_id != chen_mail.id));
    assert!(
        store.identity_of_entity(&bare.id).unwrap().is_empty(),
        "ambiguous bare first name must not merge into either person"
    );
}
