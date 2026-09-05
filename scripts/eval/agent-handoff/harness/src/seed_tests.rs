use super::*;
use mci_brain::{EmbedError, EventSource};

struct TestEmbedder;

impl Embedder for TestEmbedder {
    fn dimension(&self) -> usize {
        384
    }

    fn embed_one(&self, _text: &str) -> Result<Vec<f32>, EmbedError> {
        let mut embedding = vec![0.0; self.dimension()];
        embedding[0] = 1.0;
        Ok(embedding)
    }
}

fn fixture(acquisitions: &[(&str, &str, &str)]) -> Value {
    json!({
        "dataset_id": "acquisition-provenance-fixture",
        "task_count": 1,
        "instances": [{
            "question_id": "neutral-fixture",
            "question": "alpha release marker",
            "haystack_dates": acquisitions.iter().map(|_| "2026/09/02 (Wed) 12:00").collect::<Vec<_>>(),
            "haystack_session_ids": acquisitions.iter().map(|(id, _, _)| id).collect::<Vec<_>>(),
            "haystack_urls": acquisitions.iter().map(|(_, url, _)| url).collect::<Vec<_>>(),
            "haystack_app_ids": acquisitions.iter().map(|(_, _, app)| app).collect::<Vec<_>>(),
            "haystack_window_titles": acquisitions.iter().map(|_| "Alpha release notes").collect::<Vec<_>>(),
            "haystack_sessions": acquisitions.iter().map(|_| json!([
                {"content": "alpha release marker is ready"}
            ])).collect::<Vec<_>>(),
            "handoff_expectation": {"max_tokens": 1024, "max_evidence": 8}
        }]
    })
}

fn assert_seeded_sources(acquisitions: &[(&str, &str, &str)], expected: EventSource) {
    let instance: Instance =
        serde_json::from_value(fixture(acquisitions)["instances"][0].clone()).unwrap();
    // Exercise both insertion arms without loading native embedding models.
    let embedders = EvalEmbedders {
        document: Arc::new(TestEmbedder),
        query: Arc::new(TestEmbedder),
    };
    for arm in [Arm::Lexical, Arm::Hybrid] {
        let scratch = tempfile::tempdir().unwrap();
        let store = SqlCipherBrainStore::new(
            &scratch.path().join("brain.sqlite"),
            &DbKey::from_bytes([0x6b; 32]),
        )
        .unwrap();
        let mut owners = BTreeMap::new();
        for session_index in 0..instance.haystack_sessions.len() {
            seed_session(
                &instance,
                session_index,
                arm,
                Some(&embedders),
                &store,
                &mut owners,
            )
            .unwrap();
        }
        assert_eq!(owners.len(), acquisitions.len());
        for (event_id, meta) in owners {
            let event_id = EventId(event_id);
            assert_eq!(
                store.event_source(event_id).unwrap(),
                expected,
                "{} arm, session {}",
                arm.label(),
                meta.session_id
            );
            assert_eq!(
                store
                    .get_event(event_id)
                    .unwrap()
                    .unwrap()
                    .embedding
                    .is_some(),
                matches!(arm, Arm::Hybrid)
            );
        }
    }
}

#[test]
fn seeding_preserves_explicit_screen_origin_in_both_arms() {
    assert_seeded_sources(
        &[
            (
                "screen://capture/1",
                "screen://capture",
                "com.apple.Terminal",
            ),
            (
                "screen://capture/2",
                "https://example.test/page",
                "com.example.unfamiliar",
            ),
            (
                "opaque-session-3",
                "screen://capture/3",
                "com.example.transcript",
            ),
        ],
        EventSource::ScreenOcr,
    );
}

#[test]
fn seeding_keeps_unasserted_acquisition_unknown_in_both_arms() {
    assert_seeded_sources(
        &[
            ("terminal://session", "", "com.apple.Terminal"),
            (
                "file:///transcript",
                "file:///transcript",
                "com.microsoft.VSCode",
            ),
            (
                "browser://page",
                "https://example.test/page",
                "com.apple.Safari",
            ),
            (
                "slack://message",
                "slack://message",
                "com.tinyspeck.slackmacgap",
            ),
            ("linear://issue", "linear://issue", "com.linear"),
            ("github://pull/1", "github://pull/1", "com.microsoft.VSCode"),
            ("mail://message", "mail://message", "com.apple.mail"),
            ("opaque-session", "", ""),
            (
                "imported-screen://capture",
                "https://example.test/screen://capture",
                "com.apple.Terminal",
            ),
        ],
        EventSource::Unknown,
    );
}

#[test]
fn context_deduplicates_only_explicit_screen_captures_independent_of_answer_metadata() {
    let acquisitions = [
        (
            "screen://capture/1",
            "https://example.test/page",
            "com.example.unfamiliar",
        ),
        (
            "opaque-session-2",
            "screen://capture/2",
            "com.apple.Terminal",
        ),
        ("terminal://session/3", "", "com.apple.Terminal"),
        (
            "file:///transcript/4",
            "file:///transcript/4",
            "com.apple.Terminal",
        ),
    ];
    let mut corpus = fixture(&acquisitions);
    let untagged = evaluate_raw(&corpus.to_string(), &[Arm::Lexical]).unwrap();
    let row = &untagged["cases"][0];
    let ranked = row["ranked_session_ids"].as_array().unwrap();
    assert_eq!(ranked.len(), acquisitions.len());
    for (session_id, _, _) in acquisitions {
        assert!(ranked.contains(&json!(session_id)));
    }
    let citations = row["packet"]["citations"].as_array().unwrap();
    assert_eq!(
        citations.len(),
        3,
        "two screen captures collapse; unknown events remain"
    );
    assert_eq!(
        citations
            .iter()
            .filter(|citation| {
                citation["session_id"] == "screen://capture/1"
                    || citation["session_id"] == "opaque-session-2"
            })
            .count(),
        1
    );
    for session_id in ["terminal://session/3", "file:///transcript/4"] {
        assert!(citations
            .iter()
            .any(|citation| citation["session_id"] == session_id));
    }
    assert!(row["packet"]["text"]
        .as_str()
        .unwrap()
        .contains("alpha release marker is ready"));

    let instance = &mut corpus["instances"][0];
    instance["question_id"] = json!("duplicate-ocr-label-only");
    instance["question_type"] = json!("duplicate_ocr");
    instance["capability"] = json!("duplicate_ocr");
    instance["tags"] = json!(["duplicate_ocr", "screen_ocr"]);
    instance["answer"] = json!("irrelevant answer annotation");
    instance["answer_session_ids"] = json!(["terminal://session/3"]);
    instance["handoff_expectation"]["duplicate_session_ids"] =
        json!(["terminal://session/3", "file:///transcript/4"]);
    instance["handoff_expectation"]["max_duplicate_citations"] = json!(0);
    let tagged = evaluate_raw(&corpus.to_string(), &[Arm::Lexical]).unwrap();
    assert_eq!(
        tagged["cases"][0]["ranked_session_ids"],
        row["ranked_session_ids"]
    );
    assert_eq!(tagged["cases"][0]["packet"], row["packet"]);
}
