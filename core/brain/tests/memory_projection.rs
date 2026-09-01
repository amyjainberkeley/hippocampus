use std::path::PathBuf;

use mci_brain::episode_segmenter::EpisodeWriter;
use mci_brain::{
    project_event, retract_event, BrainStore, ClaimStatus, ClaimTransition, Entity, EntityIdentity,
    EntityMention, Event, EventId, EvidenceRef, ExpansionBudget, MemoryClaim, MemoryDelta,
    MemoryRetraction, SqlCipherBrainStore, StoreError,
};
use mci_core::crypto::{DbKey, InMemoryKeyWrap, KeyWrap};
use mci_core::store::open as raw_open;
use rusqlite::params;
use tempfile::TempDir;

fn test_key() -> DbKey {
    let key = DbKey::generate().expect("csprng");
    let wrap = InMemoryKeyWrap;
    let wrapped = wrap.wrap(&key).expect("wrap");
    wrap.unwrap_key(&wrapped).expect("unwrap")
}

fn store() -> (TempDir, PathBuf, DbKey, SqlCipherBrainStore) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");
    (dir, path, key, store)
}

fn event(text: &str, ts_us: u64) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some("com.linear".into()),
        window_title: Some("HIPP-201".into()),
        url: Some("linear://HIPP-201/comment".into()),
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

fn evidence(event_id: EventId, locator: &str, scope: &str, ts_us: u64) -> EvidenceRef {
    EvidenceRef::new(
        event_id,
        "structured_app",
        locator,
        scope,
        ts_us,
        "sha256:fixture",
    )
}

fn claim(
    evidence: Vec<EvidenceRef>,
    object: &str,
    status: ClaimStatus,
    supersedes: Option<&MemoryClaim>,
    scope: &str,
    attribution: Option<&str>,
    asserted_at_us: u64,
) -> MemoryClaim {
    MemoryClaim::new(
        "HIPP-201",
        "owner",
        object,
        scope,
        attribution.map(str::to_owned),
        0.95,
        asserted_at_us,
        asserted_at_us,
        None,
        "projector-v1",
        status,
        supersedes.map(|c| c.id.clone()),
        evidence,
    )
}

fn delta(event_id: EventId, asserted_at_us: u64, claims: Vec<MemoryClaim>) -> MemoryDelta {
    MemoryDelta::new(event_id, asserted_at_us, "projector-v1", claims, Vec::new())
}

#[test]
fn active_claim_requires_extant_source_identity_and_preserves_event_text() {
    let (_dir, _path, _key, store) = store();
    let source = store
        .put_event(&event("Priya owns HIPP-201", 10))
        .expect("event");
    let before = store.get_event(source).unwrap().unwrap().text;

    let unsupported = claim(
        Vec::new(),
        "Priya",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        None,
        20,
    );
    let err = project_event(&store, &delta(source, 20, vec![unsupported]))
        .expect_err("unsupported claim must not become active");
    assert!(matches!(err, StoreError::InvalidInput(_)));
    assert_eq!(store.get_event(source).unwrap().unwrap().text, before);
    assert!(store
        .memory_claims_as_of(20, 20, 10)
        .expect("claims")
        .is_empty());
}

#[test]
fn active_claim_evidence_must_include_the_delta_source_event() {
    let (_dir, _path, _key, store) = store();
    let detached_anchor = store.put_event(&event("projection anchor", 10)).unwrap();
    let actual_source = store.put_event(&event("source statement", 11)).unwrap();
    let detached = claim(
        vec![evidence(actual_source, "linear://actual", "team/eng", 11)],
        "Priya",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        Some("Priya"),
        20,
    );

    let error = project_event(&store, &delta(detached_anchor, 20, vec![detached]))
        .expect_err("an active claim cannot use a detached delta anchor");
    assert!(matches!(error, StoreError::InvalidInput(_)));
    assert!(store.memory_claims_as_of(20, 20, 10).unwrap().is_empty());
}

#[test]
fn unsupported_model_statement_remains_proposed_and_outside_current_facts() {
    let (_dir, _path, _key, store) = store();
    let source = store.put_event(&event("model draft", 10)).unwrap();
    let draft = claim(
        Vec::new(),
        "Priya",
        ClaimStatus::Proposed,
        None,
        "project/HIPP-201",
        Some("model"),
        20,
    );

    project_event(&store, &delta(source, 20, vec![draft.clone()])).expect("project");
    assert!(store.memory_claims_as_of(20, 20, 10).unwrap().is_empty());
    let history = store.memory_claim_history(&draft.id).unwrap();
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].status, ClaimStatus::Proposed);
}

#[test]
fn explicit_transition_cannot_promote_a_proposed_claim_to_active() {
    let (_dir, _path, _key, store) = store();
    let source = store.put_event(&event("model draft", 10)).unwrap();
    let transition_source = store.put_event(&event("promotion attempt", 30)).unwrap();
    let draft = claim(
        Vec::new(),
        "Priya",
        ClaimStatus::Proposed,
        None,
        "project/HIPP-201",
        Some("model"),
        20,
    );
    project_event(&store, &delta(source, 20, vec![draft.clone()])).unwrap();

    let promotion = ClaimTransition {
        id: "promotion-attempt".into(),
        claim_id: draft.id.clone(),
        status: ClaimStatus::Active,
        asserted_at_us: 30,
        effective_at_us: 30,
        reason: "unsupported promotion".into(),
        source_event_id: transition_source,
        projector_version: "projector-v1".into(),
    };
    let promotion_delta = MemoryDelta::new(
        transition_source,
        30,
        "projector-v1",
        Vec::new(),
        vec![promotion],
    );
    assert!(matches!(
        project_event(&store, &promotion_delta),
        Err(StoreError::InvalidInput(_))
    ));
    assert!(store.memory_claims_as_of(30, 30, 10).unwrap().is_empty());
}

#[test]
fn concurrent_source_specific_contradictions_coexist_until_explicit_correction() {
    let (_dir, _path, _key, store) = store();
    let alice_event = store.put_event(&event("Alice owns HIPP-201", 10)).unwrap();
    let priya_event = store.put_event(&event("Priya owns HIPP-201", 11)).unwrap();
    let alice = claim(
        vec![evidence(
            alice_event,
            "linear://HIPP-201/alice",
            "team/eng",
            10,
        )],
        "Alice",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        Some("Alice"),
        20,
    );
    let priya = claim(
        vec![evidence(
            priya_event,
            "linear://HIPP-201/priya",
            "team/eng",
            11,
        )],
        "Priya",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        Some("Priya"),
        20,
    );

    project_event(&store, &delta(alice_event, 20, vec![alice])).unwrap();
    project_event(&store, &delta(priya_event, 20, vec![priya])).unwrap();

    let facts = store.memory_claims_as_of(20, 20, 10).unwrap();
    assert_eq!(facts.len(), 2);
    assert_eq!(
        facts.iter().map(|c| c.object.as_str()).collect::<Vec<_>>(),
        vec!["Alice", "Priya"]
    );
}

#[test]
fn source_backed_correction_supersedes_only_the_named_claim_bitemporally() {
    let (_dir, _path, _key, store) = store();
    let old_event = store.put_event(&event("Alice owns HIPP-201", 10)).unwrap();
    let correction_event = store
        .put_event(&event("Priya owns HIPP-201 now", 30))
        .unwrap();
    let old = claim(
        vec![evidence(
            old_event,
            "linear://HIPP-201/alice",
            "team/eng",
            10,
        )],
        "Alice",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        Some("Alice"),
        20,
    );
    project_event(&store, &delta(old_event, 20, vec![old.clone()])).unwrap();

    let correction = claim(
        vec![evidence(
            correction_event,
            "linear://HIPP-201/priya",
            "team/eng",
            30,
        )],
        "Priya",
        ClaimStatus::Active,
        Some(&old),
        "project/HIPP-201",
        Some("Priya"),
        40,
    );
    project_event(
        &store,
        &delta(correction_event, 40, vec![correction.clone()]),
    )
    .unwrap();

    assert_eq!(
        store.memory_claims_as_of(25, 25, 10).unwrap()[0].object,
        "Alice"
    );
    assert_eq!(
        store.memory_claims_as_of(40, 40, 10).unwrap()[0].object,
        "Priya"
    );
    assert_eq!(
        store
            .memory_claim_history(&old.id)
            .unwrap()
            .last()
            .unwrap()
            .status,
        ClaimStatus::Superseded
    );
    assert_eq!(
        store
            .memory_claim_history(&correction.id)
            .unwrap()
            .last()
            .unwrap()
            .status,
        ClaimStatus::Active
    );
}

#[test]
fn backdated_correction_respects_transaction_and_valid_time_independently() {
    let (_dir, _path, _key, store) = store();
    let old_event = store.put_event(&event("old assertion", 10)).unwrap();
    let correction_event = store.put_event(&event("later correction", 100)).unwrap();
    let old = MemoryClaim::new(
        "fixture-subject",
        "fixture-property",
        "old-value",
        "fixture/scope",
        Some("source-a".into()),
        0.95,
        20,
        20,
        None,
        "projector-v1",
        ClaimStatus::Active,
        None,
        vec![evidence(old_event, "file:///old", "fixture", 10)],
    );
    project_event(&store, &delta(old_event, 20, vec![old.clone()])).unwrap();

    let correction = MemoryClaim::new(
        "fixture-subject",
        "fixture-property",
        "corrected-value",
        "fixture/scope",
        Some("source-b".into()),
        0.95,
        100,
        30,
        None,
        "projector-v1",
        ClaimStatus::Active,
        Some(old.id.clone()),
        vec![evidence(
            correction_event,
            "file:///correction",
            "fixture",
            100,
        )],
    );
    project_event(
        &store,
        &delta(correction_event, 100, vec![correction.clone()]),
    )
    .unwrap();

    assert_eq!(
        store.memory_claims_as_of(40, 50, 10).unwrap()[0].object,
        "old-value"
    );
    assert_eq!(
        store.memory_claims_as_of(40, 110, 10).unwrap()[0].object,
        "corrected-value"
    );
    assert_eq!(
        store.memory_claims_as_of(25, 110, 10).unwrap()[0].object,
        "old-value"
    );

    let old_history = store.memory_claim_history(&old.id).unwrap();
    assert_eq!(old_history[1].asserted_at_us, 100);
    assert_eq!(old_history[1].effective_at_us, 30);
    let correction_history = store.memory_claim_history(&correction.id).unwrap();
    assert_eq!(correction_history[0].asserted_at_us, 100);
    assert_eq!(correction_history[0].effective_at_us, 30);
}

#[test]
fn correction_cannot_remove_attribution_or_broaden_scope() {
    let (_dir, _path, _key, store) = store();
    let old_event = store.put_event(&event("Alice owns HIPP-201", 10)).unwrap();
    let correction_event = store
        .put_event(&event("Priya owns everything", 30))
        .unwrap();
    let old = claim(
        vec![evidence(
            old_event,
            "linear://HIPP-201/alice",
            "team/eng",
            10,
        )],
        "Alice",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        Some("Alice"),
        20,
    );
    project_event(&store, &delta(old_event, 20, vec![old.clone()])).unwrap();

    let no_attribution = claim(
        vec![evidence(
            correction_event,
            "linear://HIPP-201/priya",
            "team/eng",
            30,
        )],
        "Priya",
        ClaimStatus::Active,
        Some(&old),
        "project/HIPP-201",
        None,
        40,
    );
    assert!(matches!(
        project_event(&store, &delta(correction_event, 40, vec![no_attribution])),
        Err(StoreError::InvalidInput(_))
    ));

    let broad = claim(
        vec![evidence(
            correction_event,
            "linear://HIPP-201/priya",
            "team/eng",
            30,
        )],
        "Priya",
        ClaimStatus::Active,
        Some(&old),
        "project",
        Some("Priya"),
        40,
    );
    assert!(matches!(
        project_event(&store, &delta(correction_event, 40, vec![broad])),
        Err(StoreError::InvalidInput(_))
    ));
    assert_eq!(
        store.memory_claims_as_of(40, 40, 10).unwrap()[0].object,
        "Alice"
    );
}

#[test]
fn replay_is_idempotent_across_projector_versions() {
    let (_dir, _path, _key, store) = store();
    let source = store.put_event(&event("Priya owns HIPP-201", 10)).unwrap();
    let active = claim(
        vec![evidence(source, "linear://HIPP-201/priya", "team/eng", 10)],
        "Priya",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        Some("Priya"),
        20,
    );
    let first = delta(source, 20, vec![active.clone()]);
    project_event(&store, &first).unwrap();
    project_event(&store, &first).unwrap();

    let mut replay = first;
    replay.projector_version = "projector-v2".into();
    project_event(&store, &replay).unwrap();
    assert_eq!(store.memory_claim_history(&active.id).unwrap().len(), 1);
    assert_eq!(store.memory_claims_as_of(20, 20, 10).unwrap().len(), 1);
}

#[test]
fn event_retraction_appends_audit_state_without_deleting_claim_or_event() {
    let (_dir, _path, _key, store) = store();
    let source = store.put_event(&event("Priya owns HIPP-201", 10)).unwrap();
    let retraction_source = store
        .put_event(&event("Retract prior ownership note", 30))
        .unwrap();
    let active = claim(
        vec![evidence(source, "linear://HIPP-201/priya", "team/eng", 10)],
        "Priya",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        Some("Priya"),
        20,
    );
    project_event(&store, &delta(source, 20, vec![active.clone()])).unwrap();

    retract_event(
        &store,
        &MemoryRetraction::new(
            source,
            retraction_source,
            100,
            30,
            "source retracted",
            "projector-v1",
        ),
    )
    .unwrap();

    assert_eq!(store.memory_claims_as_of(40, 50, 10).unwrap().len(), 1);
    assert!(store.memory_claims_as_of(40, 110, 10).unwrap().is_empty());
    assert_eq!(store.memory_claims_as_of(25, 110, 10).unwrap().len(), 1);
    let history = store.memory_claim_history(&active.id).unwrap();
    assert_eq!(history.len(), 2);
    assert_eq!(history[0].status, ClaimStatus::Active);
    assert_eq!(history[1].status, ClaimStatus::Retracted);
    assert_eq!(history[1].asserted_at_us, 100);
    assert_eq!(history[1].effective_at_us, 30);
    assert!(store.get_event(source).unwrap().is_some());
}

fn create_prior_schema(path: &std::path::Path, key: &DbKey, version: usize) {
    let mut db = raw_open(path, key).expect("raw open");
    let tx = db.conn_mut().transaction().expect("migration tx");
    tx.execute_batch(include_str!("../migrations/0001_phase_3_brain_schema.sql"))
        .expect("0001");
    if version >= 2 {
        tx.execute_batch(include_str!("../migrations/0002_briefs.sql"))
            .expect("0002");
    }
    if version >= 3 {
        tx.execute_batch(include_str!("../migrations/0003_events_tab_id.sql"))
            .expect("0003");
    }
    if version >= 4 {
        tx.execute_batch(include_str!("../migrations/0004_v2_graph_schema.sql"))
            .expect("0004");
    }
    if version >= 5 {
        tx.execute_batch(include_str!("../migrations/0005_entity_identities.sql"))
            .expect("0005");
    }
    tx.commit().expect("commit prior schema");
}

#[test]
fn migration_upgrades_and_reopens_every_prior_brain_schema() {
    for version in 1..=5 {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(format!("brain-v{version}.sqlite"));
        let key = test_key();
        create_prior_schema(&path, &key, version);

        for _ in 0..2 {
            let _store = SqlCipherBrainStore::new(&path, &key).expect("upgrade/reopen");
        }
        let db = raw_open(&path, &key).unwrap();
        let schema: String = db
            .conn()
            .query_row(
                "SELECT value FROM meta WHERE key='brain_schema_version'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(schema, "6", "upgrade from schema {version}");
        for table in [
            "memory_deltas",
            "memory_evidence",
            "memory_claims",
            "memory_claim_evidence",
            "memory_claim_transitions",
        ] {
            let count: i64 = db
                .conn()
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
                    params![table],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(count, 1, "{table} missing after upgrade from {version}");
        }
    }
}

#[test]
fn failed_memory_migration_rolls_back_all_0006_changes() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("incompatible.sqlite");
    let key = test_key();
    create_prior_schema(&path, &key, 5);
    {
        let db = raw_open(&path, &key).unwrap();
        db.conn()
            .execute_batch("CREATE TABLE memory_claims (id TEXT PRIMARY KEY);")
            .unwrap();
    }

    let err = match SqlCipherBrainStore::new(&path, &key) {
        Ok(_) => panic!("migration must fail"),
        Err(error) => error,
    };
    assert!(matches!(err, StoreError::Backend(_)));
    let db = raw_open(&path, &key).unwrap();
    let schema: String = db
        .conn()
        .query_row(
            "SELECT value FROM meta WHERE key='brain_schema_version'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(schema, "5");
    let evidence_table: i64 = db
        .conn()
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE name='memory_evidence'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(evidence_table, 0, "partial 0006 DDL must roll back");
}

#[test]
fn bounded_expansion_is_deterministic_and_oversized_evidence_does_not_starve_later_items() {
    let (_dir, _path, _key, store) = store();
    let large_text = std::iter::repeat_n("oversized", 100)
        .collect::<Vec<_>>()
        .join(" ");
    let large_event = store.put_event(&event(&large_text, 10)).unwrap();
    let small_event = store.put_event(&event("Priya owns HIPP-201", 11)).unwrap();
    let large = claim(
        vec![evidence(large_event, "file:///large", "team/eng", 10)],
        "large",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        Some("file"),
        20,
    );
    let small = claim(
        vec![evidence(small_event, "linear://small", "team/eng", 11)],
        "Priya",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        Some("Priya"),
        20,
    );
    project_event(&store, &delta(large_event, 20, vec![large.clone()])).unwrap();
    project_event(&store, &delta(small_event, 20, vec![small.clone()])).unwrap();

    let budget = ExpansionBudget {
        max_nodes: 4,
        max_edges: 4,
        max_evidence: 2,
        max_tokens: 8,
    };
    let forward = store
        .expand_memory(&[large.id.clone(), small.id.clone()], budget)
        .unwrap();
    let reverse = store
        .expand_memory(&[small.id.clone(), large.id.clone()], budget)
        .unwrap();

    assert_eq!(forward, reverse);
    assert_eq!(forward.evidence.len(), 1);
    assert_eq!(forward.evidence[0].evidence.event_id, small_event);
    assert!(forward.tokens_used <= budget.max_tokens);
    assert!(forward.nodes_used <= budget.max_nodes);
    assert!(forward.edges_used <= budget.max_edges);
    assert!(forward.truncated);
}

#[test]
fn expansion_walks_episode_entity_and_identity_within_hard_budgets() {
    let (_dir, _path, _key, store) = store();
    let source = store.put_event(&event("Priya owns HIPP-201", 10)).unwrap();
    let episode = store.create_episode(10, 10, Some("com.linear")).unwrap();
    store.set_event_episode(source, episode).unwrap();
    let entity = Entity {
        id: Entity::derive_id("person_name", "Priya"),
        kind: "person_name".into(),
        canonical_name: "Priya".into(),
        summary: None,
        summary_embedding: None,
        content_hash: Entity::derive_content_hash("person_name", "Priya"),
        created_ts_us: 10,
        updated_ts_us: 10,
    };
    store.put_entity(&entity).unwrap();
    store
        .put_entity_mention(&EntityMention {
            id: EntityMention::derive_id(&entity.id, source, "ner", Some("Priya")),
            entity_id: entity.id.clone(),
            event_id: source,
            mention_text: Some("Priya".into()),
            confidence: 1.0,
            extractor_kind: "ner".into(),
            ts_us: 10,
        })
        .unwrap();
    let identity_id = EntityIdentity::derive_identity_id("person", "priya");
    store
        .put_entity_identity(&EntityIdentity {
            id: EntityIdentity::derive_id(&identity_id, &entity.id),
            entity_id: entity.id.clone(),
            identity_id: identity_id.clone(),
            identity_kind: "person".into(),
            identity_canonical_name: "Priya".into(),
            rule: "anchor".into(),
            confidence: 1.0,
            ts_us: 10,
        })
        .unwrap();
    let active = claim(
        vec![evidence(source, "linear://small", "team/eng", 10)],
        "Priya",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        Some("Priya"),
        20,
    );
    project_event(&store, &delta(source, 20, vec![active.clone()])).unwrap();

    let expansion = store
        .expand_memory(
            &[active.id],
            ExpansionBudget {
                max_nodes: 8,
                max_edges: 8,
                max_evidence: 2,
                max_tokens: 20,
            },
        )
        .unwrap();
    assert_eq!(expansion.episode_ids, vec![episode]);
    assert_eq!(expansion.entity_ids, vec![entity.id]);
    assert_eq!(expansion.identity_ids, vec![identity_id]);
    assert!(!expansion.truncated);
}
