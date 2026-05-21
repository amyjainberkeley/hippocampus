//! Integration tests for the brief authoring pipeline scaffold.
//!
//! Tests pinned by ADR-0018 §4:
//! - lifecycle happy path (5-state traversal)
//! - lifecycle rejects skipping states
//! - lifecycle blocks approval without human_approver_id
//! - tripwire blocks bogus citation
//! - tripwire blocks orphan claim (body with no citations)
//! - stub author produces brief with all citations present

use std::sync::Arc;

use mci_brain::stubs::InMemoryBrainStore;
use mci_brain::{BrainStore, Event, EventId, EventRecord};

use mci_brief::author::{BriefAuthor, StubBriefAuthor};
use mci_brief::lifecycle::{advance, LifecycleAction, LifecycleError};
use mci_brief::model::{Brief, BriefId, BriefState};
use mci_brief::tripwire::{validate_citations, ViolationKind};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_event(text: &str, ts_us: u64) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some("com.test.app".into()),
        window_title: Some("Test Window".into()),
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

fn make_brief(title: &str, body: &str, citations: Vec<EventId>, state: BriefState) -> Brief {
    Brief {
        id: BriefId(1),
        title: title.into(),
        body: body.into(),
        citations,
        state,
        created_ts_us: 1_000_000,
        updated_ts_us: 1_000_000,
        human_approver_id: None,
    }
}

fn seed_store_with_events(store: &InMemoryBrainStore, texts: &[&str]) -> Vec<EventId> {
    texts
        .iter()
        .enumerate()
        .map(|(i, text)| {
            #[allow(clippy::cast_possible_truncation)]
            let event = make_event(text, (i as u64 + 1) * 1_000_000);
            store.put_event(&event).expect("put_event")
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Lifecycle tests
// ---------------------------------------------------------------------------

#[test]
fn lifecycle_happy_path() {
    let mut brief = make_brief(
        "Daily brief",
        "Merged PR #72 for cascade wiring",
        vec![EventId(1)],
        BriefState::Draft,
    );

    // Draft → Reviewing
    advance(&mut brief, LifecycleAction::Submit).unwrap();
    assert_eq!(brief.state, BriefState::Reviewing);

    // Reviewing → Approved (with human_approver_id, empty violations)
    advance(
        &mut brief,
        LifecycleAction::Approve {
            human_approver_id: "user:alice@example.com".into(),
            citation_violations: vec![],
        },
    )
    .unwrap();
    assert_eq!(brief.state, BriefState::Approved);
    assert_eq!(
        brief.human_approver_id.as_deref(),
        Some("user:alice@example.com")
    );

    // Approved → Synced
    advance(&mut brief, LifecycleAction::Sync).unwrap();
    assert_eq!(brief.state, BriefState::Synced);

    // Synced → Archived
    advance(&mut brief, LifecycleAction::Archive).unwrap();
    assert_eq!(brief.state, BriefState::Archived);
}

#[test]
fn lifecycle_rejects_skipping_states() {
    // Draft → Approved directly = error
    let mut brief = make_brief("skip", "body", vec![EventId(1)], BriefState::Draft);
    let err = advance(
        &mut brief,
        LifecycleAction::Approve {
            human_approver_id: "user:bob".into(),
            citation_violations: vec![],
        },
    );
    assert!(err.is_err());
    assert!(matches!(
        err.unwrap_err(),
        LifecycleError::InvalidTransition { .. }
    ));
    assert_eq!(brief.state, BriefState::Draft);

    // Draft → Sync directly = error
    let err = advance(&mut brief, LifecycleAction::Sync);
    assert!(matches!(
        err.unwrap_err(),
        LifecycleError::InvalidTransition { .. }
    ));

    // Draft → Archive directly = error
    let err = advance(&mut brief, LifecycleAction::Archive);
    assert!(matches!(
        err.unwrap_err(),
        LifecycleError::InvalidTransition { .. }
    ));

    // Reviewing → Sync directly = error
    let mut brief = make_brief("skip", "body", vec![EventId(1)], BriefState::Reviewing);
    let err = advance(&mut brief, LifecycleAction::Sync);
    assert!(matches!(
        err.unwrap_err(),
        LifecycleError::InvalidTransition { .. }
    ));

    // Approved → Archive directly = error (must go through Synced)
    let mut brief = make_brief("skip", "body", vec![EventId(1)], BriefState::Approved);
    let err = advance(&mut brief, LifecycleAction::Archive);
    assert!(matches!(
        err.unwrap_err(),
        LifecycleError::InvalidTransition { .. }
    ));

    // Archived → anything = error (terminal)
    let mut brief = make_brief("skip", "body", vec![EventId(1)], BriefState::Archived);
    assert!(advance(&mut brief, LifecycleAction::Submit).is_err());
    assert!(advance(
        &mut brief,
        LifecycleAction::Approve {
            human_approver_id: "user:x".into(),
            citation_violations: vec![],
        },
    )
    .is_err());
    assert!(advance(&mut brief, LifecycleAction::Sync).is_err());
    assert!(advance(&mut brief, LifecycleAction::Archive).is_err());
}

#[test]
fn lifecycle_blocks_approval_without_human_approver() {
    let mut brief = make_brief(
        "no approver",
        "body",
        vec![EventId(1)],
        BriefState::Reviewing,
    );
    let err = advance(
        &mut brief,
        LifecycleAction::Approve {
            human_approver_id: String::new(),
            citation_violations: vec![],
        },
    );
    assert!(matches!(err.unwrap_err(), LifecycleError::MissingApprover));
    assert_eq!(brief.state, BriefState::Reviewing);
}

#[test]
fn lifecycle_blocks_approval_with_tripwire_violations() {
    use mci_brief::tripwire::{CitationViolation, ViolationKind};

    let mut brief = make_brief(
        "tripwire",
        "body referencing missing event",
        vec![EventId(999)],
        BriefState::Reviewing,
    );
    let violations = vec![CitationViolation {
        kind: ViolationKind::UnresolvedCitation,
        detail: "event:999 does not exist".into(),
    }];
    let err = advance(
        &mut brief,
        LifecycleAction::Approve {
            human_approver_id: "user:carol".into(),
            citation_violations: violations,
        },
    );
    assert!(matches!(
        err.unwrap_err(),
        LifecycleError::TripwireFailed(_)
    ));
    assert_eq!(brief.state, BriefState::Reviewing);
}

// ---------------------------------------------------------------------------
// Tripwire tests
// ---------------------------------------------------------------------------

#[test]
fn tripwire_blocks_bogus_citation() {
    let store = Arc::new(InMemoryBrainStore::new());
    // Seed one real event
    let ids = seed_store_with_events(&store, &["real event about Rust compilation"]);

    // Brief cites a non-existent event
    let brief = make_brief(
        "bad citation",
        "Rust compilation completed successfully",
        vec![ids[0], EventId(9999)],
        BriefState::Reviewing,
    );
    let violations = validate_citations(&brief, store.as_ref());
    assert!(!violations.is_empty());
    assert!(violations
        .iter()
        .any(|v| v.kind == ViolationKind::UnresolvedCitation));
}

#[test]
fn tripwire_blocks_orphan_claim() {
    let store = Arc::new(InMemoryBrainStore::new());

    // Brief has body text but zero citations
    let brief = make_brief(
        "orphan",
        "This brief claims things with no evidence",
        vec![],
        BriefState::Reviewing,
    );
    let violations = validate_citations(&brief, store.as_ref());
    assert!(!violations.is_empty());
    assert!(violations
        .iter()
        .any(|v| v.kind == ViolationKind::OrphanClaim));
}

#[test]
fn tripwire_passes_valid_citations() {
    let store = Arc::new(InMemoryBrainStore::new());
    let ids = seed_store_with_events(&store, &["Merged cascade wiring PR number 72"]);

    let brief = make_brief(
        "valid",
        "Merged cascade wiring",
        vec![ids[0]],
        BriefState::Reviewing,
    );
    let violations = validate_citations(&brief, store.as_ref());
    assert!(
        violations.is_empty(),
        "expected no violations: {violations:?}"
    );
}

#[test]
fn tripwire_detects_content_mismatch() {
    let store = Arc::new(InMemoryBrainStore::new());
    let ids = seed_store_with_events(&store, &["unrelated text about cooking recipes"]);

    // Brief body has no overlap with the cited event
    let brief = make_brief(
        "mismatch",
        "Deployed Kubernetes cluster upgrade",
        vec![ids[0]],
        BriefState::Reviewing,
    );
    let violations = validate_citations(&brief, store.as_ref());
    assert!(!violations.is_empty());
    assert!(violations
        .iter()
        .any(|v| v.kind == ViolationKind::ContentMismatch));
}

// ---------------------------------------------------------------------------
// Author tests
// ---------------------------------------------------------------------------

#[test]
fn stub_author_produces_brief_with_all_citations_present() {
    let store = Arc::new(InMemoryBrainStore::new());
    let ids = seed_store_with_events(
        &store,
        &[
            "Reviewed PR for Phase 3 brain scaffold",
            "Updated STATE.md with latest handoff notes",
            "Ran cargo test across workspace — 540 passing",
        ],
    );

    let records: Vec<EventRecord> = ids
        .iter()
        .map(|&id| {
            let event = store.get_event(id).unwrap().unwrap();
            EventRecord {
                event_id: id,
                ts_us: event.ts_us,
                app_bundle_id: event.app_bundle_id.clone(),
                window_title: event.window_title.clone(),
                url: event.url.clone(),
                text_snippet: EventRecord::truncate_snippet(&event.text),
            }
        })
        .collect();

    let author = StubBriefAuthor;
    let brief = author.author(&records, "End of day summary").unwrap();

    // Brief is in Draft state
    assert_eq!(brief.state, BriefState::Draft);
    // Title matches topic
    assert_eq!(brief.title, "End of day summary");
    // All input event IDs present in citations
    for id in &ids {
        assert!(
            brief.citations.contains(id),
            "citation {id} missing from brief"
        );
    }
    // Body contains text from each event
    for record in &records {
        assert!(
            brief.body.contains(&record.text_snippet),
            "body missing snippet from {}",
            record.event_id
        );
    }

    // Tripwire passes on the stub's output
    let violations = validate_citations(&brief, store.as_ref());
    assert!(
        violations.is_empty(),
        "stub author produced brief with tripwire violations: {violations:?}"
    );
}

#[test]
fn stub_author_rejects_empty_input() {
    let author = StubBriefAuthor;
    let err = author.author(&[], "empty topic");
    assert!(err.is_err());
}

// ---------------------------------------------------------------------------
// Store tests
// ---------------------------------------------------------------------------

#[test]
fn in_memory_brief_store_round_trip() {
    use mci_brief::store::{BriefStore, InMemoryBriefStore};

    let store = InMemoryBriefStore::new();
    let brief = make_brief("test", "body", vec![EventId(1)], BriefState::Draft);

    let id = store.put_brief(&brief).unwrap();
    let fetched = store.get_brief(id).unwrap().unwrap();
    assert_eq!(fetched.id, id);
    assert_eq!(fetched.title, "test");
    assert_eq!(fetched.state, BriefState::Draft);

    // Update state
    let mut updated = fetched;
    updated.state = BriefState::Reviewing;
    store.update_brief(&updated).unwrap();
    let re_fetched = store.get_brief(id).unwrap().unwrap();
    assert_eq!(re_fetched.state, BriefState::Reviewing);

    // List
    let all = store.list_briefs().unwrap();
    assert_eq!(all.len(), 1);
}

#[test]
fn in_memory_brief_store_update_nonexistent_fails() {
    use mci_brief::store::{BriefStore, InMemoryBriefStore};

    let store = InMemoryBriefStore::new();
    let brief = make_brief("ghost", "body", vec![], BriefState::Draft);
    let err = store.update_brief(&brief);
    assert!(err.is_err());
}
