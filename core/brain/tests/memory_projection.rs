use std::path::{Path, PathBuf};

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

fn expect_open_error(path: &Path, key: &DbKey, message: &str) -> StoreError {
    let Err(error) = SqlCipherBrainStore::new(path, key) else {
        panic!("{message}");
    };
    error
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

fn evidence(
    store: &SqlCipherBrainStore,
    event_id: EventId,
    _locator: &str,
    _scope: &str,
    _ts_us: u64,
) -> EvidenceRef {
    canonical_evidence(store, event_id)
}

fn canonical_evidence(store: &SqlCipherBrainStore, event_id: EventId) -> EvidenceRef {
    let event = store.get_event(event_id).unwrap().unwrap();
    EvidenceRef::from_event(event_id, &event, "structured_app")
}

fn insert_orphan_evidence(path: &std::path::Path, key: &DbKey, value: &EvidenceRef) {
    let db = raw_open(path, key).unwrap();
    db.conn()
        .execute(
            "INSERT INTO memory_evidence
             (id, event_id, source_kind, source_locator, source_scope,
              observed_at_us, content_hash)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                value.id.0,
                i64::try_from(value.event_id.0).unwrap(),
                value.source_kind,
                value.source_locator,
                value.source_scope,
                i64::try_from(value.observed_at_us).unwrap(),
                value.content_hash,
            ],
        )
        .unwrap();
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
    let source_event_id = evidence
        .first()
        .expect("evidence-backed claim helper requires a source")
        .event_id;
    claim_for_source(
        source_event_id,
        evidence,
        object,
        status,
        supersedes,
        scope,
        attribution,
        asserted_at_us,
    )
}

#[allow(clippy::too_many_arguments)]
fn claim_for_source(
    source_event_id: EventId,
    evidence: Vec<EvidenceRef>,
    object: &str,
    status: ClaimStatus,
    supersedes: Option<&MemoryClaim>,
    scope: &str,
    attribution: Option<&str>,
    asserted_at_us: u64,
) -> MemoryClaim {
    let scope = if scope == "local" || scope.starts_with("local/") {
        scope.to_owned()
    } else {
        format!("local/app/com.linear/{scope}")
    };
    MemoryClaim::new(
        source_event_id,
        "HIPP-201",
        "owner",
        object,
        &scope,
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

fn proposed_claim(source_event_id: EventId, object: &str, asserted_at_us: u64) -> MemoryClaim {
    claim_for_source(
        source_event_id,
        Vec::new(),
        object,
        ClaimStatus::Proposed,
        None,
        "project/HIPP-201",
        Some("model"),
        asserted_at_us,
    )
}

#[test]
fn active_claim_requires_extant_source_identity_and_preserves_event_text() {
    let (_dir, _path, _key, store) = store();
    let source = store
        .put_event(&event("Priya owns HIPP-201", 10))
        .expect("event");
    let before = store.get_event(source).unwrap().unwrap().text;

    let unsupported = claim_for_source(
        source,
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
fn deleting_a_projected_event_atomically_removes_its_memory_projection() {
    let (_dir, path, key, store) = store();
    let source = store.put_event(&event("projected source", 10)).unwrap();
    let evidence = canonical_evidence(&store, source);
    let scope = evidence.source_scope.clone();
    let projected = claim(
        vec![evidence],
        "Priya",
        ClaimStatus::Active,
        None,
        &scope,
        Some("Priya"),
        20,
    );
    project_event(&store, &delta(source, 20, vec![projected])).unwrap();

    assert_eq!(store.delete_event(source).unwrap(), 1);
    assert!(store.get_event(source).unwrap().is_none());
    drop(store);

    let db = raw_open(&path, &key).unwrap();
    for table in [
        "memory_deltas",
        "memory_evidence",
        "memory_claims",
        "memory_claim_evidence",
        "memory_claim_transitions",
        "memory_event_retractions",
    ] {
        let count: i64 = db
            .conn()
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 0, "{table} retained deleted-event memory");
    }
}

#[test]
fn deleting_a_source_event_removes_its_recursive_correction_descendants() {
    let (_dir, path, key, store) = store();
    let original_source = store.put_event(&event("Alice owns HIPP-201", 10)).unwrap();
    let correction_source = store.put_event(&event("Priya owns HIPP-201", 30)).unwrap();
    let original_evidence = canonical_evidence(&store, original_source);
    let original_scope = original_evidence.source_scope.clone();
    let original = claim(
        vec![original_evidence],
        "Alice",
        ClaimStatus::Active,
        None,
        &original_scope,
        Some("Alice"),
        20,
    );
    project_event(&store, &delta(original_source, 20, vec![original.clone()])).unwrap();
    let correction_evidence = canonical_evidence(&store, correction_source);
    let correction_scope = correction_evidence.source_scope.clone();
    let correction = claim(
        vec![correction_evidence],
        "Priya",
        ClaimStatus::Active,
        Some(&original),
        &correction_scope,
        Some("Priya"),
        40,
    );
    project_event(
        &store,
        &delta(correction_source, 40, vec![correction.clone()]),
    )
    .unwrap();

    assert_eq!(store.delete_event(original_source).unwrap(), 1);
    assert!(store.get_event(correction_source).unwrap().is_some());
    assert!(store.memory_claim_history(&original.id).unwrap().is_empty());
    assert!(store
        .memory_claim_history(&correction.id)
        .unwrap()
        .is_empty());
    drop(store);

    let db = raw_open(&path, &key).unwrap();
    for table in [
        "memory_evidence",
        "memory_claims",
        "memory_claim_evidence",
        "memory_claim_transitions",
    ] {
        let count: i64 = db
            .conn()
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 0, "dependent correction survived in {table}");
    }
}

#[test]
fn deleting_secondary_evidence_preserves_independent_same_source_delta_and_orphan() {
    let (_dir, path, key, store) = store();
    let projection_source = store.put_event(&event("projection source", 10)).unwrap();
    let secondary_evidence = store.put_event(&event("supporting source", 11)).unwrap();
    let orphan_source = store.put_event(&event("unrelated orphan", 12)).unwrap();
    let source_evidence = canonical_evidence(&store, projection_source);
    let support_evidence = canonical_evidence(&store, secondary_evidence);
    let orphan_evidence = canonical_evidence(&store, orphan_source);
    let scope = source_evidence.source_scope.clone();
    let dependent = claim(
        vec![source_evidence.clone(), support_evidence],
        "Priya",
        ClaimStatus::Active,
        None,
        &scope,
        Some("Priya"),
        20,
    );
    let sibling = proposed_claim(projection_source, "sibling", 20);
    let affected_delta = delta(
        projection_source,
        20,
        vec![dependent.clone(), sibling.clone()],
    );
    project_event(&store, &affected_delta).unwrap();
    let independent = claim(
        vec![source_evidence],
        "independent",
        ClaimStatus::Active,
        None,
        &scope,
        Some("Independent Source"),
        30,
    );
    let independent_delta = delta(projection_source, 30, vec![independent.clone()]);
    project_event(&store, &independent_delta).unwrap();
    drop(store);
    insert_orphan_evidence(&path, &key, &orphan_evidence);
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();

    assert_eq!(store.delete_event(secondary_evidence).unwrap(), 1);
    assert!(store.get_event(projection_source).unwrap().is_some());
    assert!(store
        .memory_claim_history(&dependent.id)
        .unwrap()
        .is_empty());
    assert!(store.memory_claim_history(&sibling.id).unwrap().is_empty());
    assert_eq!(
        store.memory_claim_history(&independent.id).unwrap().len(),
        1
    );
    drop(store);

    let db = raw_open(&path, &key).unwrap();
    let mut statement = db
        .conn()
        .prepare("SELECT id FROM memory_deltas ORDER BY id")
        .unwrap();
    let remaining_delta_ids = statement
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(remaining_delta_ids, vec![independent_delta.id]);
    assert_ne!(remaining_delta_ids, vec![affected_delta.id]);
    let orphan_count: i64 = db
        .conn()
        .query_row(
            "SELECT COUNT(*) FROM memory_evidence WHERE id = ?1",
            params![orphan_evidence.id.0],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(orphan_count, 1, "unrelated orphan evidence must survive");
}

#[test]
fn deletion_closure_removes_owned_correction_and_transition_but_not_independent_delta() {
    let (_dir, _path, _key, store) = store();
    let stable_source = store.put_event(&event("stable fact", 5)).unwrap();
    let original_source = store.put_event(&event("Alice owns HIPP-201", 10)).unwrap();
    let withdrawn_evidence = store.put_event(&event("supporting note", 11)).unwrap();
    let correction_source = store.put_event(&event("Priya owns HIPP-201", 30)).unwrap();

    let stable_evidence = canonical_evidence(&store, stable_source);
    let stable_scope = stable_evidence.source_scope.clone();
    let stable = claim(
        vec![stable_evidence],
        "stable",
        ClaimStatus::Active,
        None,
        &stable_scope,
        Some("Stable Source"),
        15,
    );
    project_event(&store, &delta(stable_source, 15, vec![stable.clone()])).unwrap();

    let original_evidence = canonical_evidence(&store, original_source);
    let original_scope = original_evidence.source_scope.clone();
    let original = claim(
        vec![
            original_evidence,
            canonical_evidence(&store, withdrawn_evidence),
        ],
        "Alice",
        ClaimStatus::Active,
        None,
        &original_scope,
        Some("Alice"),
        20,
    );
    project_event(&store, &delta(original_source, 20, vec![original.clone()])).unwrap();

    let correction_evidence = canonical_evidence(&store, correction_source);
    let correction_scope = correction_evidence.source_scope.clone();
    let correction = claim(
        vec![correction_evidence],
        "Priya",
        ClaimStatus::Active,
        Some(&original),
        &correction_scope,
        Some("Priya"),
        40,
    );
    let explicit_transition = ClaimTransition::new(
        stable.id.clone(),
        ClaimStatus::Contradicted,
        40,
        40,
        "mixed correction delta",
        correction_source,
        "projector-v1",
    );
    let correction_delta = MemoryDelta::new(
        correction_source,
        40,
        "projector-v1",
        vec![correction.clone()],
        vec![explicit_transition],
    );
    project_event(&store, &correction_delta).unwrap();

    let independent = proposed_claim(correction_source, "independent", 50);
    let independent_delta = delta(correction_source, 50, vec![independent.clone()]);
    project_event(&store, &independent_delta).unwrap();

    assert_eq!(store.delete_event(withdrawn_evidence).unwrap(), 1);
    assert!(store.memory_claim_history(&original.id).unwrap().is_empty());
    assert!(store
        .memory_claim_history(&correction.id)
        .unwrap()
        .is_empty());
    assert_eq!(
        store.memory_claim_history(&independent.id).unwrap().len(),
        1
    );
    let stable_history = store.memory_claim_history(&stable.id).unwrap();
    assert_eq!(stable_history.len(), 1);
    assert_eq!(stable_history[0].status, ClaimStatus::Active);
}

#[test]
fn range_deletion_of_secondary_evidence_preserves_independent_same_source_delta() {
    let (_dir, _path, _key, store) = store();
    let expired_evidence = store.put_event(&event("expired support", 10)).unwrap();
    let projection_source = store.put_event(&event("current source", 100)).unwrap();
    let source_evidence = canonical_evidence(&store, projection_source);
    let scope = source_evidence.source_scope.clone();
    let affected = claim(
        vec![
            source_evidence.clone(),
            canonical_evidence(&store, expired_evidence),
        ],
        "affected",
        ClaimStatus::Active,
        None,
        &scope,
        Some("Affected Source"),
        110,
    );
    project_event(
        &store,
        &delta(projection_source, 110, vec![affected.clone()]),
    )
    .unwrap();
    let independent = claim(
        vec![source_evidence],
        "independent",
        ClaimStatus::Active,
        None,
        &scope,
        Some("Independent Source"),
        120,
    );
    project_event(
        &store,
        &delta(projection_source, 120, vec![independent.clone()]),
    )
    .unwrap();

    assert_eq!(store.delete_events_in_range(0, 50).unwrap(), 1);
    assert!(store.memory_claim_history(&affected.id).unwrap().is_empty());
    assert_eq!(
        store.memory_claim_history(&independent.id).unwrap().len(),
        1
    );
}

#[test]
fn range_deletion_removes_only_memory_projected_from_events_in_range() {
    let (_dir, path, key, store) = store();
    let old_source = store.put_event(&event("old source", 10)).unwrap();
    let kept_source = store.put_event(&event("kept source", 100)).unwrap();
    let old_claim = proposed_claim(old_source, "old", 20);
    let kept_claim = proposed_claim(kept_source, "kept", 110);
    project_event(&store, &delta(old_source, 20, vec![old_claim])).unwrap();
    project_event(&store, &delta(kept_source, 110, vec![kept_claim.clone()])).unwrap();

    assert_eq!(store.delete_events_in_range(0, 50).unwrap(), 1);
    assert!(store.get_event(old_source).unwrap().is_none());
    assert!(store.get_event(kept_source).unwrap().is_some());
    assert_eq!(store.memory_claim_history(&kept_claim.id).unwrap().len(), 1);
    drop(store);

    let db = raw_open(&path, &key).unwrap();
    for table in ["memory_deltas", "memory_claims"] {
        let count: i64 = db
            .conn()
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(
            count, 1,
            "{table} did not preserve only the kept projection"
        );
    }
}

#[test]
fn wipe_all_clears_projected_memory_and_retraction_ledger() {
    let (_dir, path, key, store) = store();
    let source = store.put_event(&event("source", 10)).unwrap();
    let orphan_source = store.put_event(&event("orphan evidence", 20)).unwrap();
    let retraction_source = store.put_event(&event("withdraw source", 30)).unwrap();
    let projected = proposed_claim(source, "Priya", 20);
    project_event(&store, &delta(source, 20, vec![projected])).unwrap();
    let independent = proposed_claim(source, "independent", 25);
    project_event(&store, &delta(source, 25, vec![independent])).unwrap();
    retract_event(
        &store,
        &MemoryRetraction::new(
            source,
            retraction_source,
            40,
            40,
            "privacy withdrawal",
            "projector-v1",
        ),
    )
    .unwrap();
    let orphan_evidence = canonical_evidence(&store, orphan_source);
    drop(store);
    insert_orphan_evidence(&path, &key, &orphan_evidence);
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();

    assert_eq!(store.wipe_all().unwrap(), 3);
    drop(store);

    let db = raw_open(&path, &key).unwrap();
    for table in [
        "memory_deltas",
        "memory_evidence",
        "memory_claims",
        "memory_claim_evidence",
        "memory_claim_transitions",
        "memory_event_retractions",
    ] {
        let count: i64 = db
            .conn()
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 0, "wipe retained rows in {table}");
    }
}

#[test]
fn active_claim_evidence_must_include_the_delta_source_event() {
    let (_dir, _path, _key, store) = store();
    let detached_anchor = store.put_event(&event("projection anchor", 10)).unwrap();
    let actual_source = store.put_event(&event("source statement", 11)).unwrap();
    let detached = claim(
        vec![evidence(
            &store,
            actual_source,
            "linear://actual",
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

    let error = project_event(&store, &delta(detached_anchor, 20, vec![detached]))
        .expect_err("an active claim cannot use a detached delta anchor");
    assert!(matches!(error, StoreError::InvalidInput(_)));
    assert!(store.memory_claims_as_of(20, 20, 10).unwrap().is_empty());
}

#[test]
fn active_claim_rejects_evidence_metadata_not_owned_by_the_canonical_event() {
    let (_dir, path, key, store) = store();
    let source = store.put_event(&event("Priya owns HIPP-201", 10)).unwrap();
    let canonical = canonical_evidence(&store, source);
    let forged = [
        EvidenceRef::new(
            source,
            &canonical.source_kind,
            "linear://forged",
            &canonical.source_scope,
            canonical.observed_at_us,
            &canonical.content_hash,
        ),
        EvidenceRef::new(
            source,
            &canonical.source_kind,
            &canonical.source_locator,
            &canonical.source_scope,
            canonical.observed_at_us + 1,
            &canonical.content_hash,
        ),
        EvidenceRef::new(
            source,
            &canonical.source_kind,
            &canonical.source_locator,
            &canonical.source_scope,
            canonical.observed_at_us,
            "sha256:forged",
        ),
        EvidenceRef::new(
            source,
            &canonical.source_kind,
            &canonical.source_locator,
            "local",
            canonical.observed_at_us,
            &canonical.content_hash,
        ),
    ];

    for (index, evidence) in forged.into_iter().enumerate() {
        let claim = claim(
            vec![evidence],
            "Priya",
            ClaimStatus::Active,
            None,
            &canonical.source_scope,
            Some("Priya"),
            20 + index as u64,
        );
        let error = project_event(&store, &delta(source, 20 + index as u64, vec![claim]))
            .expect_err("forged canonical-event metadata must fail closed");
        assert!(matches!(error, StoreError::InvalidInput(_)));
    }
    drop(store);

    let db = raw_open(&path, &key).unwrap();
    for table in ["memory_deltas", "memory_evidence", "memory_claims"] {
        let count: i64 = db
            .conn()
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 0, "failed projection leaked into {table}");
    }
}

#[test]
fn active_claim_scope_must_be_same_as_or_narrower_than_its_evidence() {
    let (_dir, _path, _key, store) = store();
    let source = store.put_event(&event("Priya owns HIPP-201", 10)).unwrap();
    let evidence = canonical_evidence(&store, source);
    let overbroad = claim(
        vec![evidence],
        "Priya",
        ClaimStatus::Active,
        None,
        "local",
        Some("Priya"),
        20,
    );

    let error = project_event(&store, &delta(source, 20, vec![overbroad]))
        .expect_err("source-local evidence cannot authorize a broader claim");
    assert!(matches!(error, StoreError::InvalidInput(_)));
}

#[test]
fn active_claim_requires_preserved_attribution_on_initial_projection() {
    let (_dir, _path, _key, store) = store();
    let source = store.put_event(&event("Priya owns HIPP-201", 10)).unwrap();
    let evidence = canonical_evidence(&store, source);
    let scope = evidence.source_scope.clone();
    let unattributed = claim(
        vec![evidence],
        "Priya",
        ClaimStatus::Active,
        None,
        &scope,
        None,
        20,
    );

    let error = project_event(&store, &delta(source, 20, vec![unattributed]))
        .expect_err("active memory must retain a nonempty attribution");
    assert!(matches!(error, StoreError::InvalidInput(_)));
}

#[test]
fn unsupported_model_statement_remains_proposed_and_outside_current_facts() {
    let (_dir, _path, _key, store) = store();
    let source = store.put_event(&event("model draft", 10)).unwrap();
    let draft = claim_for_source(
        source,
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
    let draft = claim_for_source(
        source,
        Vec::new(),
        "Priya",
        ClaimStatus::Proposed,
        None,
        "project/HIPP-201",
        Some("model"),
        20,
    );
    project_event(&store, &delta(source, 20, vec![draft.clone()])).unwrap();

    let promotion = ClaimTransition::new(
        draft.id.clone(),
        ClaimStatus::Active,
        30,
        30,
        "unsupported promotion",
        transition_source,
        "projector-v1",
    );
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
fn forged_transition_identity_is_rejected_without_persistence() {
    let (_dir, path, key, store) = store();
    let source = store.put_event(&event("model draft", 10)).unwrap();
    let transition_source = store.put_event(&event("contradiction", 30)).unwrap();
    let draft = proposed_claim(source, "Priya", 20);
    project_event(&store, &delta(source, 20, vec![draft.clone()])).unwrap();
    let mut transition = ClaimTransition::new(
        draft.id,
        ClaimStatus::Contradicted,
        40,
        40,
        "source conflict",
        transition_source,
        "projector-v1",
    );
    transition.id = "forged-transition-id".into();

    let error = project_event(
        &store,
        &MemoryDelta::new(
            transition_source,
            40,
            "projector-v1",
            Vec::new(),
            vec![transition],
        ),
    )
    .expect_err("mutated transition identity must fail closed");
    assert!(matches!(error, StoreError::InvalidInput(_)));
    drop(store);

    let db = raw_open(&path, &key).unwrap();
    let count: i64 = db
        .conn()
        .query_row("SELECT COUNT(*) FROM memory_claim_transitions", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(count, 0);
}

#[test]
fn same_transition_id_with_mutated_payload_is_rejected_and_original_survives() {
    let (_dir, path, key, store) = store();
    let source = store.put_event(&event("model draft", 10)).unwrap();
    let transition_source = store.put_event(&event("contradiction", 30)).unwrap();
    let draft = proposed_claim(source, "Priya", 20);
    project_event(&store, &delta(source, 20, vec![draft.clone()])).unwrap();
    let original = ClaimTransition::new(
        draft.id,
        ClaimStatus::Contradicted,
        40,
        40,
        "source conflict",
        transition_source,
        "projector-v1",
    );
    project_event(
        &store,
        &MemoryDelta::new(
            transition_source,
            40,
            "projector-v1",
            Vec::new(),
            vec![original.clone()],
        ),
    )
    .unwrap();
    let mut conflicting = original;
    conflicting.reason = "mutated reason".into();
    let error = project_event(
        &store,
        &MemoryDelta::new(
            transition_source,
            40,
            "projector-v1",
            Vec::new(),
            vec![conflicting],
        ),
    )
    .expect_err("same transition id with a different payload must fail closed");
    assert!(matches!(error, StoreError::InvalidInput(_)));
    drop(store);

    let db = raw_open(&path, &key).unwrap();
    let (count, reason): (i64, String) = db
        .conn()
        .query_row(
            "SELECT COUNT(*), reason FROM memory_claim_transitions",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(count, 1);
    assert_eq!(reason, "source conflict");
}

#[test]
fn explicit_transition_source_event_must_be_owned_by_its_delta() {
    let (_dir, path, key, store) = store();
    let source = store.put_event(&event("model draft", 10)).unwrap();
    let delta_source = store.put_event(&event("delta owner", 30)).unwrap();
    let unrelated_source = store.put_event(&event("unrelated event", 31)).unwrap();
    let draft = proposed_claim(source, "Priya", 20);
    project_event(&store, &delta(source, 20, vec![draft.clone()])).unwrap();
    let transition = ClaimTransition::new(
        draft.id,
        ClaimStatus::Contradicted,
        40,
        40,
        "source conflict",
        unrelated_source,
        "projector-v1",
    );

    let error = project_event(
        &store,
        &MemoryDelta::new(
            delta_source,
            40,
            "projector-v1",
            Vec::new(),
            vec![transition],
        ),
    )
    .expect_err("transition provenance must match the delta owner");
    assert!(matches!(error, StoreError::InvalidInput(_)));
    drop(store);

    let db = raw_open(&path, &key).unwrap();
    let count: i64 = db
        .conn()
        .query_row("SELECT COUNT(*) FROM memory_claim_transitions", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(count, 0);
}

#[test]
fn concurrent_source_specific_contradictions_coexist_until_explicit_correction() {
    let (_dir, _path, _key, store) = store();
    let alice_event = store.put_event(&event("Alice owns HIPP-201", 10)).unwrap();
    let priya_event = store.put_event(&event("Priya owns HIPP-201", 11)).unwrap();
    let alice = claim(
        vec![evidence(
            &store,
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
            &store,
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
            &store,
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
            &store,
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
        old_event,
        "fixture-subject",
        "fixture-property",
        "old-value",
        "local/app/com.linear/fixture/scope",
        Some("source-a".into()),
        0.95,
        20,
        20,
        None,
        "projector-v1",
        ClaimStatus::Active,
        None,
        vec![evidence(&store, old_event, "file:///old", "fixture", 10)],
    );
    project_event(&store, &delta(old_event, 20, vec![old.clone()])).unwrap();

    let correction = MemoryClaim::new(
        correction_event,
        "fixture-subject",
        "fixture-property",
        "corrected-value",
        "local/app/com.linear/fixture/scope",
        Some("source-b".into()),
        0.95,
        100,
        30,
        None,
        "projector-v1",
        ClaimStatus::Active,
        Some(old.id.clone()),
        vec![evidence(
            &store,
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
            &store,
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
            &store,
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
            &store,
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
fn scoped_learning_correction_replay_survives_restart_and_later_retraction() {
    let (_dir, path, key, store) = store();
    let source = store.put_event(&event("original owner", 10)).unwrap();
    let correction_source = store.put_event(&event("confirmed correction", 20)).unwrap();
    let original = claim(
        vec![canonical_evidence(&store, source)],
        "Alice",
        ClaimStatus::Active,
        None,
        "project/A",
        Some("owner"),
        10,
    );
    project_event(&store, &delta(source, 10, vec![original.clone()])).unwrap();
    let corrected = claim(
        vec![canonical_evidence(&store, correction_source)],
        "Priya",
        ClaimStatus::Active,
        Some(&original),
        "project/A",
        Some("owner"),
        20,
    );
    let mut correction_delta = delta(correction_source, 20, vec![corrected.clone()]);
    project_event(&store, &correction_delta).unwrap();
    drop(store);
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();
    correction_delta.projector_version = "projector-v2".into();
    correction_delta.claims[0].projector_version = "projector-v2".into();
    project_event(&store, &correction_delta).expect("an accepted correction must replay");
    assert_eq!(
        store.memory_claims_as_of(20, 20, 10).unwrap(),
        vec![corrected.clone()]
    );
    assert_eq!(store.memory_claim_history(&original.id).unwrap().len(), 2);

    let withdrawal = store.put_event(&event("withdraw correction", 30)).unwrap();
    retract_event(
        &store,
        &MemoryRetraction::new(
            correction_source,
            withdrawal,
            30,
            30,
            "withdrawn",
            "projector-v2",
        ),
    )
    .unwrap();
    project_event(&store, &correction_delta).expect("replay must not resurrect withdrawn learning");
    assert!(store.memory_claims_as_of(30, 30, 10).unwrap().is_empty());
    assert_eq!(
        store.memory_claims_as_of(20, 20, 10).unwrap(),
        vec![corrected]
    );
}

#[test]
fn scoped_learning_project_correction_cannot_retire_a_broader_rule() {
    let (_dir, _path, _key, store) = store();
    let source = store.put_event(&event("shared owner", 10)).unwrap();
    let original = claim(
        vec![canonical_evidence(&store, source)],
        "Alice",
        ClaimStatus::Active,
        None,
        "project",
        Some("owner"),
        10,
    );
    project_event(&store, &delta(source, 10, vec![original.clone()])).unwrap();
    let correction_source = store.put_event(&event("project A owner", 20)).unwrap();
    let correction = claim(
        vec![canonical_evidence(&store, correction_source)],
        "Priya",
        ClaimStatus::Active,
        Some(&original),
        "project/A",
        Some("owner"),
        20,
    );
    assert!(
        matches!(
            project_event(
                &store,
                &delta(correction_source, 20, vec![correction.clone()])
            ),
            Err(StoreError::InvalidInput(_))
        ),
        "a project A correction must not retire the shared rule for project B"
    );
    assert_eq!(
        store.memory_claims_as_of(20, 20, 10).unwrap(),
        vec![original.clone()]
    );
    assert_eq!(store.memory_claim_history(&original.id).unwrap().len(), 1);
    assert!(store
        .memory_claim_history(&correction.id)
        .unwrap()
        .is_empty());
}

#[test]
fn scoped_learning_correction_cannot_cross_sibling_projects() {
    let (_dir, _path, _key, store) = store();
    let source = store.put_event(&event("project A owner", 10)).unwrap();
    let original = claim(
        vec![canonical_evidence(&store, source)],
        "Alice",
        ClaimStatus::Active,
        None,
        "project/A",
        Some("owner"),
        10,
    );
    project_event(&store, &delta(source, 10, vec![original.clone()])).unwrap();
    let correction_source = store.put_event(&event("project B owner", 20)).unwrap();
    let correction = claim(
        vec![canonical_evidence(&store, correction_source)],
        "Priya",
        ClaimStatus::Active,
        Some(&original),
        "project/B",
        Some("owner"),
        20,
    );
    assert!(matches!(
        project_event(&store, &delta(correction_source, 20, vec![correction])),
        Err(StoreError::InvalidInput(_))
    ));
    assert_eq!(
        store.memory_claims_as_of(20, 20, 10).unwrap(),
        vec![original]
    );
}

#[test]
fn scoped_learning_expired_correction_does_not_restore_superseded_state() {
    let (_dir, _path, _key, store) = store();
    let source = store.put_event(&event("old procedure", 10)).unwrap();
    let original = claim(
        vec![canonical_evidence(&store, source)],
        "Alice",
        ClaimStatus::Active,
        None,
        "project/A",
        Some("owner"),
        10,
    );
    project_event(&store, &delta(source, 10, vec![original.clone()])).unwrap();
    let correction_source = store.put_event(&event("temporary procedure", 20)).unwrap();
    let corrected = MemoryClaim::new(
        correction_source,
        &original.subject,
        &original.predicate,
        "Priya",
        &original.scope,
        Some("owner".into()),
        0.95,
        20,
        20,
        Some(29),
        "projector-v1",
        ClaimStatus::Active,
        Some(original.id.clone()),
        vec![canonical_evidence(&store, correction_source)],
    );
    project_event(
        &store,
        &delta(correction_source, 20, vec![corrected.clone()]),
    )
    .unwrap();
    assert_eq!(
        store.memory_claims_as_of(29, 30, 10).unwrap(),
        vec![corrected.clone()]
    );
    assert!(store.memory_claims_as_of(30, 30, 10).unwrap().is_empty());
    assert_eq!(
        store.memory_claims_as_of(19, 30, 10).unwrap(),
        vec![original]
    );
    let late_source = store.put_event(&event("late correction", 30)).unwrap();
    let late = claim(
        vec![canonical_evidence(&store, late_source)],
        "Morgan",
        ClaimStatus::Active,
        Some(&corrected),
        "project/A",
        Some("owner"),
        30,
    );
    assert!(matches!(
        project_event(&store, &delta(late_source, 30, vec![late])),
        Err(StoreError::InvalidInput(_))
    ));
}

#[test]
fn replay_is_idempotent_across_projector_versions() {
    let (_dir, _path, _key, store) = store();
    let source = store.put_event(&event("Priya owns HIPP-201", 10)).unwrap();
    let active = claim(
        vec![evidence(
            &store,
            source,
            "linear://HIPP-201/priya",
            "team/eng",
            10,
        )],
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
        vec![evidence(
            &store,
            source,
            "linear://HIPP-201/priya",
            "team/eng",
            10,
        )],
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
        assert_eq!(schema, "10", "upgrade from schema {version}");
        for table in [
            "memory_deltas",
            "memory_evidence",
            "memory_claims",
            "memory_claim_evidence",
            "memory_claim_transitions",
            "memory_event_retractions",
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

fn create_populated_historical_memory_schema(path: &Path, key: &DbKey, version: u8) {
    create_prior_schema(path, key, 5);
    let mut db = raw_open(path, key).unwrap();
    let tx = db.conn_mut().transaction().unwrap();
    let historical_schema = match version {
        6 => include_str!("fixtures/memory_schema_v6_462060a.sql"),
        7 => include_str!("fixtures/memory_schema_v7_dd960ad.sql"),
        _ => panic!("unsupported historical memory schema {version}"),
    };
    tx.execute_batch(historical_schema).unwrap();
    if version == 7 {
        tx.execute(
            "INSERT OR REPLACE INTO meta (key, value)
             VALUES ('brain_schema_version', '7')",
            [],
        )
        .unwrap();
    }
    tx.execute_batch(
        "INSERT INTO events (id, ts_us, text, cascade_reason)
                 VALUES (1, 10, 'old source', 0), (2, 20, 'correction source', 0);
             INSERT INTO memory_deltas VALUES
                 ('d1', 1, 10, 'projector-v1'),
                 ('d2', 2, 20, 'projector-v1');
             INSERT INTO memory_evidence VALUES
                 ('e1', 1, 'ocr', 'event://1', 'local/event/1', 10, 'hash-1'),
                 ('e2', 2, 'ocr', 'event://2', 'local/event/2', 20, 'hash-2');
             INSERT INTO memory_claims VALUES
                 ('c1', 1, 'subject', 'owner', 'Alice', 'local/event/1', 'Alice',
                  0.9, 10, 10, NULL, 'projector-v1', 'active', NULL),
                 ('c2', 2, 'subject', 'owner', 'Priya', 'local/event/2', 'Priya',
                  0.9, 20, 20, NULL, 'projector-v1', 'active', 'c1');
             INSERT INTO memory_claim_evidence VALUES ('c1', 'e1'), ('c2', 'e2');
             INSERT INTO memory_claim_transitions VALUES
                 ('t1', 'c1', 'superseded', 20, 20, 'corrected', 2, 'projector-v1');",
    )
    .unwrap();
    if version == 7 {
        tx.execute(
            "INSERT INTO memory_event_retractions VALUES
             ('r1', 1, 2, 30, 30, 'withdrawn', 'projector-v1')",
            [],
        )
        .unwrap();
    }
    tx.commit().unwrap();
}

fn assert_populated_historical_memory_migration(version: u8, expected_retractions: i64) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(format!("brain-v{version}.sqlite"));
    let key = test_key();
    create_populated_historical_memory_schema(&path, &key, version);

    let store = SqlCipherBrainStore::new(&path, &key)
        .unwrap_or_else(|error| panic!("upgrade populated historical v{version} store: {error}"));
    drop(store);
    let db = raw_open(&path, &key).unwrap();
    let version: String = db
        .conn()
        .query_row(
            "SELECT value FROM meta WHERE key='brain_schema_version'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(version, "10");
    for (table, expected) in [
        ("memory_deltas", 2_i64),
        ("memory_evidence", 2),
        ("memory_claims", 2),
        ("memory_claim_evidence", 2),
        ("memory_claim_transitions", 1),
        ("memory_event_retractions", expected_retractions),
    ] {
        let count: i64 = db
            .conn()
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, expected, "migration lost rows from {table}");
    }
    let id_not_null: i64 = db
        .conn()
        .query_row(
            "SELECT [notnull] FROM pragma_table_info('memory_claims') WHERE name='id'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(id_not_null, 1);
    let claim_owners = db
        .conn()
        .prepare("SELECT id, delta_id FROM memory_claims ORDER BY id")
        .unwrap()
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(
        claim_owners,
        vec![("c1".into(), "d1".into()), ("c2".into(), "d2".into())]
    );
    let transition_owner: String = db
        .conn()
        .query_row(
            "SELECT delta_id FROM memory_claim_transitions WHERE id='t1'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(transition_owner, "d2");
}

#[test]
fn migration_v8_preserves_populated_historical_v6_without_retraction_ledger() {
    assert_populated_historical_memory_migration(6, 0);
}

#[test]
fn migration_v8_preserves_populated_historical_v7_with_retraction_ledger() {
    assert_populated_historical_memory_migration(7, 1);
}

#[test]
fn failed_historical_v7_restore_rolls_back_schema_and_data() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("brain-v7-orphan.sqlite");
    let key = test_key();
    create_populated_historical_memory_schema(&path, &key, 7);
    {
        let db = raw_open(&path, &key).unwrap();
        db.conn()
            .execute_batch("PRAGMA foreign_keys = OFF;")
            .unwrap();
        db.conn()
            .execute(
                "INSERT INTO memory_event_retractions VALUES
                 ('orphan', 999, 2, 40, 40, 'invalid historical row', 'projector-v1')",
                [],
            )
            .unwrap();
    }

    let error = expect_open_error(&path, &key, "orphaned v7 restore must fail");
    assert!(matches!(error, StoreError::Backend(_)));
    let db = raw_open(&path, &key).unwrap();
    let version: String = db
        .conn()
        .query_row(
            "SELECT value FROM meta WHERE key='brain_schema_version'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(version, "7");
    for (table, expected) in [
        ("memory_deltas", 2_i64),
        ("memory_claims", 2),
        ("memory_claim_transitions", 1),
        ("memory_event_retractions", 2),
    ] {
        let count: i64 = db
            .conn()
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, expected, "rollback changed {table}");
    }
    let delta_column: i64 = db
        .conn()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('memory_claims') WHERE name='delta_id'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        delta_column, 0,
        "failed restore must keep the v7 table shape"
    );
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

    let err = expect_open_error(&path, &key, "migration must fail");
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
        vec![evidence(
            &store,
            large_event,
            "file:///large",
            "team/eng",
            10,
        )],
        "large",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        Some("file"),
        20,
    );
    let small = claim(
        vec![evidence(
            &store,
            small_event,
            "linear://small",
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
        vec![evidence(&store, source, "linear://small", "team/eng", 10)],
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

#[test]
fn forged_evidence_identity_is_rejected_without_persisting_any_memory_rows() {
    let (_dir, path, key, store) = store();
    let source = store.put_event(&event("source statement", 10)).unwrap();
    let mut forged = evidence(&store, source, "linear://original", "team/eng", 10);
    forged.id.0 = "forged-evidence-id".into();
    let forged_claim = claim(
        vec![forged],
        "Priya",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        Some("Priya"),
        20,
    );

    let error = project_event(&store, &delta(source, 20, vec![forged_claim]))
        .expect_err("a caller-mutated evidence id must fail closed");
    assert!(matches!(error, StoreError::InvalidInput(_)));
    drop(store);

    let db = raw_open(&path, &key).unwrap();
    for table in ["memory_deltas", "memory_evidence", "memory_claims"] {
        let count: i64 = db
            .conn()
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 0, "transaction leaked a row into {table}");
    }
}

#[test]
fn same_evidence_id_with_different_payload_is_rejected_and_original_row_survives() {
    let (_dir, path, key, store) = store();
    let source = store.put_event(&event("source statement", 10)).unwrap();
    let original = evidence(&store, source, "linear://original", "team/eng", 10);
    let original_claim = claim(
        vec![original.clone()],
        "Priya",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        Some("Priya"),
        20,
    );
    project_event(&store, &delta(source, 20, vec![original_claim.clone()])).unwrap();

    let mut conflicting_evidence = original;
    conflicting_evidence.source_locator = "linear://forged".into();
    let conflicting_claim = claim(
        vec![conflicting_evidence],
        "Priya",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        Some("Priya"),
        20,
    );
    let error = project_event(&store, &delta(source, 20, vec![conflicting_claim]))
        .expect_err("same evidence id with a new payload must not be ignored");
    assert!(matches!(error, StoreError::InvalidInput(_)));
    drop(store);

    let db = raw_open(&path, &key).unwrap();
    let (locator, links): (String, i64) = db
        .conn()
        .query_row(
            "SELECT e.source_locator, COUNT(ce.evidence_id)
             FROM memory_evidence e
             LEFT JOIN memory_claim_evidence ce ON ce.evidence_id = e.id
             GROUP BY e.id",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(locator, "linear://HIPP-201/comment");
    assert_eq!(links, 1);
    assert_eq!(
        db.conn()
            .query_row("SELECT COUNT(*) FROM memory_claims", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        1
    );
}

#[test]
fn claim_identity_covers_confidence_status_and_evidence_independent_of_input_order() {
    let (_dir, _path, _key, store) = store();
    let first_event = store.put_event(&event("first source", 10)).unwrap();
    let second_event = store.put_event(&event("second source", 11)).unwrap();
    let first = evidence(&store, first_event, "linear://first", "team/eng", 10);
    let second = evidence(&store, second_event, "linear://second", "team/eng", 11);
    let base = MemoryClaim::new(
        first_event,
        "HIPP-201",
        "owner",
        "Priya",
        "project/HIPP-201",
        Some("Priya".into()),
        0.95,
        20,
        20,
        None,
        "projector-v1",
        ClaimStatus::Active,
        None,
        vec![first.clone(), second.clone()],
    );
    let reversed = MemoryClaim::new(
        first_event,
        "HIPP-201",
        "owner",
        "Priya",
        "project/HIPP-201",
        Some("Priya".into()),
        0.95,
        20,
        20,
        None,
        "projector-v2",
        ClaimStatus::Active,
        None,
        vec![second.clone(), first.clone()],
    );
    let changed_confidence = MemoryClaim::new(
        first_event,
        "HIPP-201",
        "owner",
        "Priya",
        "project/HIPP-201",
        Some("Priya".into()),
        0.75,
        20,
        20,
        None,
        "projector-v1",
        ClaimStatus::Active,
        None,
        vec![first.clone(), second.clone()],
    );
    let changed_status = MemoryClaim::new(
        first_event,
        "HIPP-201",
        "owner",
        "Priya",
        "project/HIPP-201",
        Some("Priya".into()),
        0.95,
        20,
        20,
        None,
        "projector-v1",
        ClaimStatus::Proposed,
        None,
        vec![first.clone(), second.clone()],
    );
    let changed_evidence = MemoryClaim::new(
        first_event,
        "HIPP-201",
        "owner",
        "Priya",
        "project/HIPP-201",
        Some("Priya".into()),
        0.95,
        20,
        20,
        None,
        "projector-v1",
        ClaimStatus::Active,
        None,
        vec![first],
    );

    assert_eq!(
        base.id, reversed.id,
        "input order and projector version are replay metadata"
    );
    assert_ne!(base.id, changed_confidence.id);
    assert_ne!(base.id, changed_status.id);
    assert_ne!(base.id, changed_evidence.id);
}

#[test]
fn claim_identity_includes_source_event_even_without_evidence() {
    let first = MemoryClaim::new(
        EventId(41),
        "HIPP-201",
        "owner",
        "Priya",
        "project/HIPP-201",
        Some("model".into()),
        0.5,
        20,
        20,
        None,
        "projector-v1",
        ClaimStatus::Proposed,
        None,
        Vec::new(),
    );
    let second = MemoryClaim::new(
        EventId(42),
        "HIPP-201",
        "owner",
        "Priya",
        "project/HIPP-201",
        Some("model".into()),
        0.5,
        20,
        20,
        None,
        "projector-v1",
        ClaimStatus::Proposed,
        None,
        Vec::new(),
    );

    assert_ne!(first.id, second.id);
}

#[test]
fn claim_payload_mutation_after_construction_is_rejected_transactionally() {
    let (_dir, _path, _key, store) = store();
    let source = store.put_event(&event("source statement", 10)).unwrap();
    let mut mutated = claim(
        vec![evidence(&store, source, "linear://source", "team/eng", 10)],
        "Priya",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        Some("Priya"),
        20,
    );
    mutated.object = "Mallory".into();

    assert!(matches!(
        project_event(&store, &delta(source, 20, vec![mutated])),
        Err(StoreError::InvalidInput(_))
    ));
    assert!(store.memory_claims_as_of(20, 20, 10).unwrap().is_empty());
}

#[test]
fn persisted_same_claim_id_with_different_payload_is_rejected_without_overwrite() {
    let (_dir, path, key, store) = store();
    let source = store.put_event(&event("source statement", 10)).unwrap();
    let original = claim(
        vec![evidence(&store, source, "linear://source", "team/eng", 10)],
        "Priya",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        Some("Priya"),
        20,
    );
    let original_delta = delta(source, 20, vec![original.clone()]);
    project_event(&store, &original_delta).unwrap();
    drop(store);

    let db = raw_open(&path, &key).unwrap();
    db.conn()
        .execute(
            "UPDATE memory_claims SET object='Mallory' WHERE id=?1",
            params![original.id.0],
        )
        .unwrap();
    drop(db);

    let reopened = SqlCipherBrainStore::new(&path, &key).unwrap();
    let error = project_event(&reopened, &original_delta)
        .expect_err("a persisted same-id/different-payload claim must fail closed");
    assert!(matches!(error, StoreError::InvalidInput(_)));
    drop(reopened);

    let db = raw_open(&path, &key).unwrap();
    let (object, claim_count): (String, i64) = db
        .conn()
        .query_row(
            "SELECT object, (SELECT COUNT(*) FROM memory_claims) \
               FROM memory_claims WHERE id=?1",
            params![original.id.0],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(
        object, "Mallory",
        "conflicting replay must not overwrite a row"
    );
    assert_eq!(
        claim_count, 1,
        "conflicting replay must not append a duplicate"
    );
}

#[test]
fn reversed_delta_replay_order_converges_to_the_same_persisted_projection() {
    fn run(reverse: bool) -> Vec<(String, String, String, String)> {
        let (_dir, path, key, store) = store();
        let alice_event = store.put_event(&event("Alice owns HIPP-201", 10)).unwrap();
        let priya_event = store.put_event(&event("Priya owns HIPP-201", 11)).unwrap();
        let alice = claim(
            vec![evidence(
                &store,
                alice_event,
                "linear://HIPP-201/alice",
                "team/eng",
                10,
            )],
            "Alice",
            ClaimStatus::Active,
            None,
            "local/app/com.linear/project/HIPP-201",
            Some("Alice"),
            20,
        );
        let priya = claim(
            vec![evidence(
                &store,
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
        let mut deltas = vec![
            delta(alice_event, 20, vec![alice]),
            delta(priya_event, 20, vec![priya]),
        ];
        if reverse {
            deltas.reverse();
        }
        for projection in deltas {
            project_event(&store, &projection).unwrap();
        }
        drop(store);

        let db = raw_open(&path, &key).unwrap();
        let mut statement = db
            .conn()
            .prepare(
                "SELECT c.id, c.object, e.id, e.source_locator \
                   FROM memory_claims c \
                   JOIN memory_claim_evidence ce ON ce.claim_id=c.id \
                   JOIN memory_evidence e ON e.id=ce.evidence_id \
                  ORDER BY c.id, e.id",
            )
            .unwrap();
        statement
            .query_map([], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
            })
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap()
    }

    assert_eq!(run(false), run(true));
}

#[test]
fn retract_before_project_is_durable_across_projector_replay() {
    let (_dir, path, key, store) = store();
    let source = store.put_event(&event("withdrawn source", 10)).unwrap();
    let retraction_event = store.put_event(&event("withdrawal recorded", 30)).unwrap();
    retract_event(
        &store,
        &MemoryRetraction::new(
            source,
            retraction_event,
            40,
            25,
            "source withdrawn",
            "projector-v1",
        ),
    )
    .unwrap();

    let active = claim(
        vec![evidence(
            &store,
            source,
            "linear://withdrawn",
            "team/eng",
            10,
        )],
        "Priya",
        ClaimStatus::Active,
        None,
        "local/app/com.linear/project/HIPP-201",
        Some("Priya"),
        20,
    );
    let first = delta(source, 20, vec![active.clone()]);
    project_event(&store, &first).unwrap();
    assert_eq!(store.memory_claims_as_of(20, 30, 10).unwrap().len(), 1);
    assert!(store.memory_claims_as_of(30, 50, 10).unwrap().is_empty());

    let mut replay = first;
    replay.projector_version = "projector-v2".into();
    replay.claims[0].projector_version = "projector-v2".into();
    project_event(&store, &replay).unwrap();
    assert!(store.memory_claims_as_of(30, 50, 10).unwrap().is_empty());
    let history = store.memory_claim_history(&active.id).unwrap();
    assert_eq!(
        history
            .iter()
            .filter(|row| row.status == ClaimStatus::Retracted)
            .count(),
        1,
        "replay must not duplicate or lose the durable retraction"
    );
    drop(store);

    let db = raw_open(&path, &key).unwrap();
    let ledger_count: i64 = db
        .conn()
        .query_row("SELECT COUNT(*) FROM memory_event_retractions", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(ledger_count, 1);
}

fn project_terminal_claim(
    status: ClaimStatus,
    effective_at_us: u64,
) -> (TempDir, SqlCipherBrainStore, MemoryClaim, EventId) {
    let (dir, _path, _key, store) = store();
    let source = store.put_event(&event("Alice owns HIPP-201", 10)).unwrap();
    let transition_source = store.put_event(&event("terminal state", 30)).unwrap();
    let original = claim(
        vec![evidence(
            &store,
            source,
            "linear://original",
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
    project_event(&store, &delta(source, 20, vec![original.clone()])).unwrap();
    let transition = ClaimTransition::new(
        original.id.clone(),
        status,
        100,
        effective_at_us,
        "terminal fixture",
        transition_source,
        "projector-v1",
    );
    project_event(
        &store,
        &MemoryDelta::new(
            transition_source,
            100,
            "projector-v1",
            Vec::new(),
            vec![transition],
        ),
    )
    .unwrap();
    (dir, store, original, transition_source)
}

#[test]
fn corrections_reject_proposed_and_every_terminal_target_at_their_bitemporal_point() {
    let (_dir, _path, _key, proposed_store) = store();
    let proposed_source = proposed_store.put_event(&event("model draft", 10)).unwrap();
    let correction_source = proposed_store.put_event(&event("correction", 30)).unwrap();
    let proposed = claim_for_source(
        proposed_source,
        Vec::new(),
        "Alice",
        ClaimStatus::Proposed,
        None,
        "project/HIPP-201",
        Some("model"),
        20,
    );
    project_event(
        &proposed_store,
        &delta(proposed_source, 20, vec![proposed.clone()]),
    )
    .unwrap();
    let correction = claim(
        vec![evidence(
            &proposed_store,
            correction_source,
            "linear://correction",
            "team/eng",
            30,
        )],
        "Priya",
        ClaimStatus::Active,
        Some(&proposed),
        "project/HIPP-201",
        Some("Priya"),
        110,
    );
    assert!(matches!(
        project_event(
            &proposed_store,
            &delta(correction_source, 110, vec![correction])
        ),
        Err(StoreError::InvalidInput(_))
    ));

    for status in [
        ClaimStatus::Superseded,
        ClaimStatus::Retracted,
        ClaimStatus::Contradicted,
    ] {
        let (_dir, terminal_store, original, transition_source) =
            project_terminal_claim(status, 30);
        let correction_event = terminal_store.put_event(&event("new owner", 110)).unwrap();
        let correction = MemoryClaim::new(
            correction_event,
            "HIPP-201",
            "owner",
            "Priya",
            "local/app/com.linear/project/HIPP-201",
            Some("Priya".into()),
            0.95,
            110,
            40,
            None,
            "projector-v1",
            ClaimStatus::Active,
            Some(original.id),
            vec![evidence(
                &terminal_store,
                correction_event,
                "linear://new-owner",
                "team/eng",
                110,
            )],
        );
        let error = project_event(
            &terminal_store,
            &delta(correction_event, 110, vec![correction]),
        )
        .expect_err("terminal target must not be superseded again");
        assert!(matches!(error, StoreError::InvalidInput(_)), "{status:?}");
        assert!(terminal_store
            .get_event(transition_source)
            .unwrap()
            .is_some());
    }
}

#[test]
fn backdated_terminal_transition_is_evaluated_at_correction_valid_time() {
    let (_dir, terminal_store, original, _transition_source) =
        project_terminal_claim(ClaimStatus::Contradicted, 30);
    let correction_event = terminal_store
        .put_event(&event("historical correction", 110))
        .unwrap();
    let historical = MemoryClaim::new(
        correction_event,
        "HIPP-201",
        "owner",
        "Priya",
        "local/app/com.linear/project/HIPP-201",
        Some("Priya".into()),
        0.95,
        110,
        25,
        Some(29),
        "projector-v1",
        ClaimStatus::Active,
        Some(original.id),
        vec![evidence(
            &terminal_store,
            correction_event,
            "linear://historical",
            "team/eng",
            110,
        )],
    );
    project_event(
        &terminal_store,
        &delta(correction_event, 110, vec![historical]),
    )
    .expect("target was active before the backdated terminal transition became effective");
}

#[test]
fn one_node_budget_skips_oversized_first_claim_and_admits_later_evidence() {
    let (_dir, _path, _key, store) = store();
    let large_event = store
        .put_event(&event(
            &std::iter::repeat_n("oversized", 100)
                .collect::<Vec<_>>()
                .join(" "),
            10,
        ))
        .unwrap();
    let small_event = store
        .put_event(&event("small admissible evidence", 11))
        .unwrap();
    let small = claim(
        vec![evidence(
            &store,
            small_event,
            "linear://small",
            "team/eng",
            11,
        )],
        "small",
        ClaimStatus::Active,
        None,
        "project/HIPP-201",
        Some("Priya"),
        20,
    );
    let mut attempt = 0;
    let large = loop {
        let candidate = claim(
            vec![evidence(
                &store,
                large_event,
                &format!("linear://large/{attempt}"),
                "team/eng",
                10,
            )],
            &format!("large-{attempt}"),
            ClaimStatus::Active,
            None,
            "project/HIPP-201",
            Some("Priya"),
            20,
        );
        if candidate.id < small.id {
            break candidate;
        }
        attempt += 1;
        assert!(
            attempt < 10_000,
            "could not construct deterministic hash order fixture"
        );
    };
    project_event(&store, &delta(large_event, 20, vec![large.clone()])).unwrap();
    project_event(&store, &delta(small_event, 20, vec![small.clone()])).unwrap();

    let expanded = store
        .expand_memory(
            &[large.id, small.id.clone()],
            ExpansionBudget {
                max_nodes: 1,
                max_edges: 1,
                max_evidence: 1,
                max_tokens: 8,
            },
        )
        .unwrap();
    assert_eq!(expanded.evidence.len(), 1);
    assert_eq!(expanded.evidence[0].evidence.event_id, small_event);
    assert_eq!(expanded.claim_ids, vec![small.id]);
}

#[test]
fn migration_rejects_column_compatible_table_missing_constraints_and_keeps_v5_stamp() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("weak-memory-schema.sqlite");
    let key = test_key();
    create_prior_schema(&path, &key, 5);
    {
        let db = raw_open(&path, &key).unwrap();
        db.conn()
            .execute_batch(
                "CREATE TABLE memory_claims (
                    id TEXT PRIMARY KEY,
                    source_event_id INTEGER NOT NULL,
                    subject TEXT NOT NULL,
                    predicate TEXT NOT NULL,
                    object TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    attribution TEXT,
                    confidence REAL NOT NULL,
                    asserted_at_us INTEGER NOT NULL,
                    valid_from_us INTEGER NOT NULL,
                    valid_to_us INTEGER,
                    projector_version TEXT NOT NULL,
                    initial_status TEXT NOT NULL,
                    supersedes_claim_id TEXT
                );",
            )
            .unwrap();
    }

    let error = expect_open_error(
        &path,
        &key,
        "structurally weak Task 5 table must be rejected",
    );
    assert!(matches!(error, StoreError::Backend(_)));
    let db = raw_open(&path, &key).unwrap();
    let version: String = db
        .conn()
        .query_row(
            "SELECT value FROM meta WHERE key='brain_schema_version'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(version, "5");
    let retraction_table: i64 = db
        .conn()
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE name='memory_event_retractions'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(retraction_table, 0, "failed migration must fully roll back");
}

#[test]
fn migration_rejects_exact_columns_and_foreign_key_when_primary_key_is_missing() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("missing-memory-delta-pk.sqlite");
    let key = test_key();
    create_prior_schema(&path, &key, 5);
    {
        let db = raw_open(&path, &key).unwrap();
        db.conn()
            .execute_batch(
                "CREATE TABLE memory_deltas (
                    id TEXT,
                    source_event_id INTEGER NOT NULL,
                    asserted_at_us INTEGER NOT NULL,
                    projector_version TEXT NOT NULL,
                    FOREIGN KEY (source_event_id) REFERENCES events(id) ON DELETE RESTRICT
                );",
            )
            .unwrap();
    }

    let error = expect_open_error(
        &path,
        &key,
        "a name-compatible table without its primary key must be rejected",
    );
    assert!(matches!(error, StoreError::Backend(_)));
    let db = raw_open(&path, &key).unwrap();
    let version: String = db
        .conn()
        .query_row(
            "SELECT value FROM meta WHERE key='brain_schema_version'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(version, "5");
}

#[test]
fn migration_rejects_claim_evidence_without_composite_primary_key() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("missing-claim-evidence-pk.sqlite");
    let key = test_key();
    create_prior_schema(&path, &key, 5);
    {
        let db = raw_open(&path, &key).unwrap();
        db.conn()
            .execute_batch(
                "CREATE TABLE memory_claim_evidence (
                    claim_id TEXT NOT NULL,
                    evidence_id TEXT NOT NULL,
                    FOREIGN KEY (claim_id) REFERENCES memory_claims(id) ON DELETE RESTRICT,
                    FOREIGN KEY (evidence_id) REFERENCES memory_evidence(id) ON DELETE RESTRICT
                );",
            )
            .unwrap();
    }

    let error = expect_open_error(
        &path,
        &key,
        "claim/evidence identity requires its composite primary key",
    );
    assert!(matches!(error, StoreError::Backend(_)));
}

#[test]
fn migration_rejects_secondary_index_with_wrong_uniqueness() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("unique-secondary-index.sqlite");
    let key = test_key();
    create_prior_schema(&path, &key, 5);
    {
        let db = raw_open(&path, &key).unwrap();
        db.conn()
            .execute_batch(
                "CREATE TABLE memory_evidence (
                    id TEXT NOT NULL PRIMARY KEY,
                    event_id INTEGER NOT NULL,
                    source_kind TEXT NOT NULL,
                    source_locator TEXT NOT NULL,
                    source_scope TEXT NOT NULL,
                    observed_at_us INTEGER NOT NULL,
                    content_hash TEXT NOT NULL,
                    FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE RESTRICT
                );
                CREATE UNIQUE INDEX memory_evidence_event
                    ON memory_evidence(event_id, id);",
            )
            .unwrap();
    }

    let error = expect_open_error(
        &path,
        &key,
        "a load-bearing secondary index must have exact uniqueness",
    );
    assert!(matches!(error, StoreError::Backend(_)));
}

#[test]
fn migration_rejects_case_insensitive_scalar_identity_collation() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("nocase-memory-delta-id.sqlite");
    let key = test_key();
    create_prior_schema(&path, &key, 5);
    {
        let db = raw_open(&path, &key).unwrap();
        db.conn()
            .execute_batch(
                "CREATE TABLE memory_deltas (
                    id TEXT COLLATE NOCASE NOT NULL PRIMARY KEY,
                    source_event_id INTEGER NOT NULL,
                    asserted_at_us INTEGER NOT NULL,
                    projector_version TEXT NOT NULL,
                    FOREIGN KEY (source_event_id) REFERENCES events(id) ON DELETE RESTRICT
                );",
            )
            .unwrap();
    }

    let error = expect_open_error(
        &path,
        &key,
        "case-insensitive memory identities must not be stamped canonical",
    );
    assert!(matches!(error, StoreError::Backend(_)));
}

#[test]
fn migration_rejects_generated_or_hidden_memory_columns() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("generated-memory-column.sqlite");
    let key = test_key();
    create_prior_schema(&path, &key, 5);
    {
        let db = raw_open(&path, &key).unwrap();
        db.conn()
            .execute_batch(
                "CREATE TABLE memory_deltas (
                    id TEXT NOT NULL PRIMARY KEY,
                    source_event_id INTEGER NOT NULL,
                    asserted_at_us INTEGER NOT NULL,
                    projector_version TEXT NOT NULL,
                    shadow_id TEXT GENERATED ALWAYS AS (lower(id)) VIRTUAL,
                    FOREIGN KEY (source_event_id) REFERENCES events(id) ON DELETE RESTRICT
                );",
            )
            .unwrap();
    }

    let error = expect_open_error(
        &path,
        &key,
        "generated memory columns must not be invisible to schema validation",
    );
    assert!(matches!(error, StoreError::Backend(_)));
}

#[test]
fn migration_rejects_secondary_index_collation_and_direction_drift() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("drifted-memory-index.sqlite");
    let key = test_key();
    create_prior_schema(&path, &key, 5);
    {
        let db = raw_open(&path, &key).unwrap();
        db.conn()
            .execute_batch(
                "CREATE TABLE memory_evidence (
                    id TEXT NOT NULL PRIMARY KEY,
                    event_id INTEGER NOT NULL,
                    source_kind TEXT NOT NULL,
                    source_locator TEXT NOT NULL,
                    source_scope TEXT NOT NULL,
                    observed_at_us INTEGER NOT NULL,
                    content_hash TEXT NOT NULL,
                    FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE RESTRICT
                );
                CREATE INDEX memory_evidence_event
                    ON memory_evidence(event_id COLLATE NOCASE DESC, id ASC);",
            )
            .unwrap();
    }

    let error = expect_open_error(
        &path,
        &key,
        "memory index collation and direction must be canonical",
    );
    assert!(matches!(error, StoreError::Backend(_)));
}

#[test]
fn migration_rejects_nonindexed_column_collation_with_comment_spacing() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("drifted-memory-column-collation.sqlite");
    let key = test_key();
    create_prior_schema(&path, &key, 5);
    {
        let db = raw_open(&path, &key).unwrap();
        db.conn()
            .execute_batch(
                "CREATE TABLE memory_evidence (
                    id TEXT NOT NULL PRIMARY KEY,
                    event_id INTEGER NOT NULL,
                    source_kind TEXT COLLATE/**/NOCASE NOT NULL,
                    source_locator TEXT NOT NULL,
                    source_scope TEXT NOT NULL,
                    observed_at_us INTEGER NOT NULL,
                    content_hash TEXT NOT NULL,
                    FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE RESTRICT
                );
                CREATE INDEX memory_evidence_event
                    ON memory_evidence(event_id, id);",
            )
            .unwrap();
    }

    let error = expect_open_error(
        &path,
        &key,
        "all persisted memory column collations must be canonical",
    );
    assert!(matches!(error, StoreError::Backend(_)));
}

#[test]
fn migration_rejects_an_extra_check_constraint_regardless_of_spacing() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("extra-check-constraint.sqlite");
    let key = test_key();
    create_prior_schema(&path, &key, 5);
    {
        let db = raw_open(&path, &key).unwrap();
        db.conn()
            .execute_batch(
                "CREATE TABLE memory_claims (
                    id TEXT NOT NULL PRIMARY KEY,
                    source_event_id INTEGER NOT NULL,
                    subject TEXT NOT NULL,
                    predicate TEXT NOT NULL,
                    object TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    attribution TEXT,
                    confidence REAL NOT NULL
                        CHECK (confidence >= 0.0 AND confidence <= 1.0),
                    asserted_at_us INTEGER NOT NULL,
                    valid_from_us INTEGER NOT NULL,
                    valid_to_us INTEGER,
                    projector_version TEXT NOT NULL,
                    initial_status TEXT NOT NULL
                        CHECK (initial_status IN ('proposed', 'active')),
                    supersedes_claim_id TEXT,
                    FOREIGN KEY (source_event_id) REFERENCES events(id) ON DELETE RESTRICT,
                    FOREIGN KEY (supersedes_claim_id) REFERENCES memory_claims(id) ON DELETE RESTRICT,
                    CHECK(length(subject) > 0)
                );",
            )
            .unwrap();
    }

    let error = expect_open_error(
        &path,
        &key,
        "an extra CHECK must not be accepted as the canonical schema",
    );
    assert!(matches!(error, StoreError::Backend(_)));
}

#[test]
fn migration_rejects_check_constraints_that_exist_only_in_comments() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("comment-spoofed-checks.sqlite");
    let key = test_key();
    create_prior_schema(&path, &key, 5);
    {
        let db = raw_open(&path, &key).unwrap();
        db.conn()
            .execute_batch(
                "CREATE TABLE memory_claims (
                    id TEXT NOT NULL PRIMARY KEY,
                    delta_id TEXT,
                    source_event_id INTEGER NOT NULL,
                    subject TEXT NOT NULL,
                    predicate TEXT NOT NULL,
                    object TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    attribution TEXT,
                    confidence REAL NOT NULL
                        /* CHECK (confidence >= 0.0 AND confidence <= 1.0) */,
                    asserted_at_us INTEGER NOT NULL,
                    valid_from_us INTEGER NOT NULL,
                    valid_to_us INTEGER,
                    projector_version TEXT NOT NULL,
                    initial_status TEXT NOT NULL
                        /* CHECK (initial_status IN ('proposed', 'active')) */,
                    supersedes_claim_id TEXT,
                    FOREIGN KEY (delta_id) REFERENCES memory_deltas(id) ON DELETE RESTRICT,
                    FOREIGN KEY (source_event_id) REFERENCES events(id) ON DELETE RESTRICT,
                    FOREIGN KEY (supersedes_claim_id) REFERENCES memory_claims(id) ON DELETE RESTRICT
                );
                CREATE TABLE memory_claim_transitions (
                    id TEXT NOT NULL PRIMARY KEY,
                    delta_id TEXT,
                    claim_id TEXT NOT NULL,
                    status TEXT NOT NULL
                        /* CHECK (status IN ('superseded', 'retracted', 'contradicted')) */,
                    asserted_at_us INTEGER NOT NULL,
                    effective_at_us INTEGER NOT NULL,
                    reason TEXT NOT NULL,
                    source_event_id INTEGER NOT NULL,
                    projector_version TEXT NOT NULL,
                    FOREIGN KEY (delta_id) REFERENCES memory_deltas(id) ON DELETE RESTRICT,
                    FOREIGN KEY (claim_id) REFERENCES memory_claims(id) ON DELETE RESTRICT,
                    FOREIGN KEY (source_event_id) REFERENCES events(id) ON DELETE RESTRICT
                );",
            )
            .unwrap();
    }

    let error = expect_open_error(
        &path,
        &key,
        "comment-only CHECK expressions must not be stamped canonical",
    );
    assert!(matches!(error, StoreError::Backend(_)));
    let db = raw_open(&path, &key).unwrap();
    let version: String = db
        .conn()
        .query_row(
            "SELECT value FROM meta WHERE key='brain_schema_version'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(version, "5");
    db.conn()
        .execute_batch("PRAGMA foreign_keys = OFF;")
        .unwrap();
    db.conn()
        .execute(
            "INSERT INTO memory_claims
             (id, delta_id, source_event_id, subject, predicate, object, scope,
              attribution, confidence, asserted_at_us, valid_from_us, valid_to_us,
              projector_version, initial_status, supersedes_claim_id)
             VALUES ('invalid-claim', NULL, 999, '', 'predicate', 'object', 'scope',
                     NULL, 2.0, 1, 1, NULL, 'projector-v1', 'invalid', NULL)",
            [],
        )
        .expect("comment-only claim checks accept invalid confidence and status");
    db.conn()
        .execute(
            "INSERT INTO memory_claim_transitions
             (id, delta_id, claim_id, status, asserted_at_us, effective_at_us,
              reason, source_event_id, projector_version)
             VALUES ('invalid-transition', NULL, 'invalid-claim', 'invalid', 2, 2,
                     'comment spoof', 999, 'projector-v1')",
            [],
        )
        .expect("comment-only transition check accepts an invalid status");
}
