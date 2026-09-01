use std::sync::Arc;

use mci_brain::stubs::InMemoryBrainStore;
use mci_brain::{
    lexical_retrieval_outcome, BrainStore, EmbedError, Embedder, Event, EventId,
    EvidenceSufficiencyPolicy, HybridRetriever, RetrievalDegradation, RetrievalOutcome,
    RetrievalQuery, Retriever, SourceQuality, EVIDENCE_SUFFICIENCY_POLICY,
};

struct PerfectEmbedder;

impl Embedder for PerfectEmbedder {
    fn dimension(&self) -> usize {
        384
    }

    fn embed_one(&self, _text: &str) -> Result<Vec<f32>, EmbedError> {
        let mut value = vec![0.0; 384];
        value[0] = 1.0;
        Ok(value)
    }
}

struct FailingEmbedder;

impl Embedder for FailingEmbedder {
    fn dimension(&self) -> usize {
        384
    }

    fn embed_one(&self, _text: &str) -> Result<Vec<f32>, EmbedError> {
        Err(EmbedError::Backend("model unavailable".into()))
    }
}

fn event(text: &str, url: Option<&str>) -> Event {
    let mut embedding = vec![0.0; 384];
    embedding[0] = 1.0;
    Event {
        id: EventId(0),
        ts_us: 10,
        app_bundle_id: Some("com.linear".into()),
        window_title: Some("HIPP-201".into()),
        url: url.map(str::to_owned),
        text: text.into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: Some(embedding),
    }
}

fn query(text: &str) -> RetrievalQuery {
    RetrievalQuery {
        text: text.into(),
        limit: 5,
        time_filter: None,
        app_filter: None,
    }
}

fn permissive_test_policy() -> EvidenceSufficiencyPolicy {
    EvidenceSufficiencyPolicy {
        validation_qualified: true,
        threshold: 0.0,
        ..EVIDENCE_SUFFICIENCY_POLICY
    }
}

#[test]
fn matched_outcome_carries_extant_event_evidence_and_source_quality() {
    let store = Arc::new(InMemoryBrainStore::new());
    let event_id = store
        .put_event(&event(
            "The amber marker labels crate A7.",
            Some("linear://inventory/crate-a7"),
        ))
        .unwrap();
    let retriever = HybridRetriever::new(store.clone(), Arc::new(PerfectEmbedder), 20)
        .with_evidence_policy(permissive_test_policy());

    let outcome = retriever
        .retrieve_outcome(&query("Which marker labels crate A7?"))
        .unwrap();
    let RetrievalOutcome::Matched { matches } = outcome else {
        panic!("expected matched outcome");
    };
    assert_eq!(matches[0].hit.event_id, event_id);
    assert_eq!(matches[0].evidence.event_id, event_id);
    assert!(store
        .get_event(matches[0].evidence.event_id)
        .unwrap()
        .is_some());
    assert_eq!(
        matches[0].evidence.source_quality,
        SourceQuality::StructuredApp
    );
    assert!(matches[0].hit.score_source > 0.0);
}

#[test]
fn unqualified_production_critic_returns_named_degradation_with_ranked_fallback() {
    let store = Arc::new(InMemoryBrainStore::new());
    let event_id = store
        .put_event(&event(
            "The cedar chest is beside the window.",
            Some("file:///notes/room.txt"),
        ))
        .unwrap();
    let retriever = HybridRetriever::new(store, Arc::new(PerfectEmbedder), 20);

    let outcome = retriever
        .retrieve_outcome(&query("Where is the cedar chest?"))
        .unwrap();
    let RetrievalOutcome::Degraded {
        degradation,
        fallback_matches,
    } = outcome
    else {
        panic!("expected unqualified evidence-sufficiency degradation");
    };
    assert_eq!(
        degradation,
        RetrievalDegradation::EvidenceSufficiencyUnqualified
    );
    assert_eq!(fallback_matches[0].hit.event_id, event_id);
}

#[test]
fn legacy_retrieve_preserves_ranked_search_when_evidence_critic_is_unqualified() {
    let store = Arc::new(InMemoryBrainStore::new());
    let event_id = store
        .put_event(&event(
            "The cedar chest is beside the window.",
            Some("file:///notes/room.txt"),
        ))
        .unwrap();
    let retriever = HybridRetriever::new(store, Arc::new(PerfectEmbedder), 20);

    let hits = retriever
        .retrieve(&query("Where is the cedar chest?"))
        .unwrap();

    assert_eq!(hits[0].event_id, event_id);
}

#[test]
fn qualified_negative_critic_returns_nothing_matched() {
    let store = Arc::new(InMemoryBrainStore::new());
    store
        .put_event(&event(
            "The cedar chest is beside the window.",
            Some("file:///notes/room.txt"),
        ))
        .unwrap();
    let rejecting_policy = EvidenceSufficiencyPolicy {
        validation_qualified: true,
        threshold: 1.0,
        ..EVIDENCE_SUFFICIENCY_POLICY
    };
    let retriever = HybridRetriever::new(store, Arc::new(PerfectEmbedder), 20)
        .with_evidence_policy(rejecting_policy);

    assert!(matches!(
        retriever
            .retrieve_outcome(&query("Where is the cedar chest?"))
            .unwrap(),
        RetrievalOutcome::NothingMatched { .. }
    ));
}

#[test]
fn unavailable_embeddings_return_named_degradation_not_match_or_empty() {
    let store = Arc::new(InMemoryBrainStore::new());
    store
        .put_event(&event(
            "cargo test p mci agent test work memory bench",
            Some("terminal://zsh/work-memory-tests"),
        ))
        .unwrap();
    let retriever = HybridRetriever::new(store, Arc::new(FailingEmbedder), 20);

    let outcome = retriever
        .retrieve_outcome(&query("cargo test p mci agent test work memory bench"))
        .unwrap();
    let RetrievalOutcome::Degraded {
        degradation,
        fallback_matches,
    } = outcome
    else {
        panic!("expected degradation");
    };
    assert_eq!(degradation, RetrievalDegradation::EmbeddingsUnavailable);
    assert_eq!(fallback_matches.len(), 1);
}

#[test]
fn empty_store_returns_nothing_matched() {
    let retriever = HybridRetriever::new(
        Arc::new(InMemoryBrainStore::new()),
        Arc::new(PerfectEmbedder),
        20,
    )
    .with_evidence_policy(permissive_test_policy());
    assert!(matches!(
        retriever
            .retrieve_outcome(&query("where is the decision"))
            .unwrap(),
        RetrievalOutcome::NothingMatched { .. }
    ));
}

#[test]
fn source_quality_is_documented_and_monotone_by_capture_fidelity() {
    assert!(SourceQuality::UserAuthored.score() > SourceQuality::StructuredApp.score());
    assert!(SourceQuality::StructuredApp.score() > SourceQuality::LocalArtifact.score());
    assert!(SourceQuality::LocalArtifact.score() > SourceQuality::BrowserPage.score());
    assert!(SourceQuality::BrowserPage.score() > SourceQuality::Accessibility.score());
    assert!(SourceQuality::Accessibility.score() > SourceQuality::Ocr.score());
}

#[test]
fn lexical_production_path_uses_the_same_typed_outcome_boundary() {
    let store = InMemoryBrainStore::new();
    store
        .put_event(&event(
            "cargo test p mci agent test work memory bench",
            Some("terminal://zsh/work-memory-tests"),
        ))
        .unwrap();
    assert!(matches!(
        lexical_retrieval_outcome(
            &store,
            &query("cargo test p mci agent test work memory bench")
        )
        .unwrap(),
        RetrievalOutcome::Matched { .. }
    ));
    assert!(matches!(
        lexical_retrieval_outcome(&store, &query("violet telescope archive")).unwrap(),
        RetrievalOutcome::NothingMatched { .. }
    ));
}
