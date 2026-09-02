use std::sync::Arc;

use mci_brain::stubs::InMemoryBrainStore;
use mci_brain::{
    lexical_retrieval_outcome, BrainStore, EmbedError, Embedder, Event, EventId,
    EvidenceSufficiencyPolicy, HybridRetriever, RetrievalDegradation, RetrievalOutcome,
    RetrievalQuery, Retriever, SourceQuality, EVIDENCE_SUFFICIENCY_POLICY,
};

struct CapabilityStore {
    inner: InMemoryBrainStore,
    lexical_available: bool,
    vectors_available: bool,
}

impl CapabilityStore {
    fn new(lexical_available: bool, vectors_available: bool) -> Self {
        Self {
            inner: InMemoryBrainStore::new(),
            lexical_available,
            vectors_available,
        }
    }
}

impl BrainStore for CapabilityStore {
    fn put_event(&self, event: &Event) -> Result<EventId, mci_brain::StoreError> {
        self.inner.put_event(event)
    }

    fn get_event(&self, id: EventId) -> Result<Option<Event>, mci_brain::StoreError> {
        self.inner.get_event(id)
    }

    fn fts5_search(
        &self,
        query: &str,
        limit: usize,
    ) -> Result<Vec<(EventId, f32)>, mci_brain::StoreError> {
        if self.lexical_available {
            self.inner.fts5_search(query, limit)
        } else {
            Err(mci_brain::StoreError::Backend("lexical offline".into()))
        }
    }

    fn vec_search(
        &self,
        query_embedding: &[f32],
        limit: usize,
    ) -> Result<Vec<(EventId, f32)>, mci_brain::StoreError> {
        if self.vectors_available {
            self.inner.vec_search(query_embedding, limit)
        } else {
            Err(mci_brain::StoreError::Backend("vectors offline".into()))
        }
    }
}

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
fn explicit_person_question_abstains_when_ranked_context_contains_no_person_answer() {
    let store = Arc::new(InMemoryBrainStore::new());
    store
        .put_event(&event(
            "PR 431 introduced complete false for partial benchmark runs.",
            Some("github://hippocampus/pull/431"),
        ))
        .unwrap();
    store
        .put_event(&event(
            "The model path thread documents the bundled embedder.",
            Some("slack://bench/model-path"),
        ))
        .unwrap();
    let retriever = HybridRetriever::new(store, Arc::new(PerfectEmbedder), 20);

    let outcome = retriever
        .retrieve_outcome(&query("Who approved PR 431 after the rollback discussion?"))
        .unwrap();

    assert!(matches!(
        outcome,
        RetrievalOutcome::NothingMatched {
            reason: mci_brain::NothingMatchedReason::EvidenceFloor
        }
    ));
}

#[test]
fn legacy_retrieve_rejects_unqualified_ranked_context() {
    let store = Arc::new(InMemoryBrainStore::new());
    store
        .put_event(&event(
            "The cedar chest is beside the window.",
            Some("file:///notes/room.txt"),
        ))
        .unwrap();
    let retriever = HybridRetriever::new(store, Arc::new(PerfectEmbedder), 20);

    let error = retriever
        .retrieve(&query("Where is the cedar chest?"))
        .expect_err("legacy API must not erase typed degradation");

    assert!(error.to_string().contains("EvidenceSufficiencyUnqualified"));
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
fn explicit_question_against_empty_store_reports_no_candidates() {
    let retriever = HybridRetriever::new(
        Arc::new(InMemoryBrainStore::new()),
        Arc::new(PerfectEmbedder),
        20,
    );

    assert!(matches!(
        retriever
            .retrieve_outcome(&query("Who approved the balcony inspection?"))
            .unwrap(),
        RetrievalOutcome::NothingMatched {
            reason: mci_brain::NothingMatchedReason::NoCandidates
        }
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

fn anchor_store(lexical_available: bool, vectors_available: bool) -> Arc<CapabilityStore> {
    let store = Arc::new(CapabilityStore::new(lexical_available, vectors_available));
    store
        .put_event(&event(
            "right before deployment the rollback switch was enabled",
            Some("terminal://deploy"),
        ))
        .unwrap();
    store
}

#[test]
fn anchor_embedder_failure_is_named_and_keeps_safe_lexical_context() {
    let retriever = HybridRetriever::new(anchor_store(true, true), Arc::new(FailingEmbedder), 20);
    let outcome = retriever
        .retrieve_outcome(&query("right before deployment"))
        .unwrap();
    let RetrievalOutcome::Degraded {
        degradation,
        fallback_matches,
    } = outcome
    else {
        panic!("anchor embedder failure must be typed");
    };
    assert_eq!(degradation, RetrievalDegradation::EmbeddingsUnavailable);
    assert_eq!(fallback_matches.len(), 1);
}

#[test]
fn anchor_vector_failure_is_named_and_keeps_safe_lexical_context() {
    let retriever = HybridRetriever::new(anchor_store(true, false), Arc::new(PerfectEmbedder), 20);
    let outcome = retriever
        .retrieve_outcome(&query("right before deployment"))
        .unwrap();
    let RetrievalOutcome::Degraded {
        degradation,
        fallback_matches,
    } = outcome
    else {
        panic!("anchor vector failure must be typed");
    };
    assert_eq!(degradation, RetrievalDegradation::EmbeddingsUnavailable);
    assert_eq!(fallback_matches.len(), 1);
}

#[test]
fn anchor_lexical_failure_is_named_and_keeps_safe_semantic_context() {
    let retriever = HybridRetriever::new(anchor_store(false, true), Arc::new(PerfectEmbedder), 20);
    let outcome = retriever
        .retrieve_outcome(&query("right before deployment"))
        .unwrap();
    let RetrievalOutcome::Degraded {
        degradation,
        fallback_matches,
    } = outcome
    else {
        panic!("anchor lexical failure must be typed");
    };
    assert_eq!(degradation, RetrievalDegradation::LexicalUnavailable);
    assert_eq!(fallback_matches.len(), 1);
}

#[test]
fn anchor_combined_failure_is_explicit_and_has_no_fabricated_context() {
    for embedder_fails in [false, true] {
        let outcome = if embedder_fails {
            HybridRetriever::new(anchor_store(false, true), Arc::new(FailingEmbedder), 20)
                .retrieve_outcome(&query("right before deployment"))
        } else {
            HybridRetriever::new(anchor_store(false, false), Arc::new(PerfectEmbedder), 20)
                .retrieve_outcome(&query("right before deployment"))
        }
        .unwrap();
        let RetrievalOutcome::Degraded {
            degradation,
            fallback_matches,
        } = outcome
        else {
            panic!("combined anchor failure must be typed");
        };
        assert_eq!(
            degradation,
            RetrievalDegradation::LexicalAndEmbeddingsUnavailable
        );
        assert!(fallback_matches.is_empty());
    }
}
