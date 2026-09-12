use mci_agent_handoff_eval::{evaluate_raw, Arm};

#[test]
fn lexical_fixture_runs_through_recall_and_context_with_exact_provenance() {
    let corpus = r#"
    {
      "dataset_id": "fixture-agent-handoff",
      "task_count": 1,
      "instances": [{
        "question_id": "fixture-exact",
        "question_type": "exact_provenance",
        "capability": "exact_provenance",
        "question": "alpha release marker",
        "question_date": "2026/09/02 (Wed) 18:00",
        "answer_session_ids": ["file:///alpha"],
        "haystack_dates": ["2026/09/02 (Wed) 12:00"],
        "haystack_session_ids": ["file:///alpha"],
        "haystack_app_ids": ["com.example.editor"],
        "haystack_window_titles": ["Alpha release notes"],
        "haystack_urls": ["file:///alpha"],
        "haystack_sessions": [[{"role":"assistant","content":"alpha release marker is ready"}]],
        "tags": ["exact_provenance"],
        "handoff_expectation": {
          "required_facts": ["alpha release marker"],
          "required_session_ids": ["file:///alpha"],
          "forbidden_session_ids": [],
          "contradiction_session_ids": [],
          "duplicate_session_ids": [],
          "max_duplicate_citations": 0,
          "expect_abstention": false,
          "max_tokens": 128,
          "max_evidence": 4
        }
      }]
    }
    "#;

    let report = evaluate_raw(corpus, &[Arm::Lexical]).unwrap();
    assert_eq!(
        report["surface"],
        "LiveBrainReader::recall + LiveBrainReader::context (mci_context backend)"
    );
    let row = &report["cases"][0];
    assert_eq!(row["recall_disposition"], "degraded");
    assert_eq!(row["ranked_session_ids"][0], "file:///alpha");
    assert_eq!(row["packet"]["outcome"], "observations_only");
    assert_eq!(row["packet"]["citations"][0]["session_id"], "file:///alpha");
    assert_eq!(
        row["packet"]["citations"][0]["window_title"],
        "Alpha release notes"
    );
    assert!(row["packet"]["text"]
        .as_str()
        .unwrap()
        .contains("alpha release marker is ready"));
}
