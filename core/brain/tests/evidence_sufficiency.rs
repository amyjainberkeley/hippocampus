use mci_brain::{
    evidence_features_for_candidates, explicit_evidence_signal, EvidenceCandidate,
    EvidenceFeatures, ExplicitEvidenceSignal, EVIDENCE_SUFFICIENCY_POLICY,
    EXPLICIT_EVIDENCE_VETO_QUALIFICATION,
};
use sha2::{Digest, Sha256};

fn assert_close(actual: f32, expected: f32) {
    assert!((actual - expected).abs() < 1e-6, "{actual} != {expected}");
}

#[test]
fn feature_extraction_is_generic_and_preserves_raw_model_geometry() {
    let candidates = [
        EvidenceCandidate {
            stable_id: 10,
            text: "The cedar chest is beside the window.",
            raw_semantic_cosine: 0.72,
        },
        EvidenceCandidate {
            stable_id: 20,
            text: "The window faces the courtyard.",
            raw_semantic_cosine: 0.70,
        },
    ];
    let features = evidence_features_for_candidates("Where is the cedar chest?", &candidates)
        .expect("non-empty finite candidates");

    assert_close(features.raw_semantic_cosine, 0.72);
    assert!((features.semantic_margin - 0.02).abs() < 1e-6);
    assert_close(features.query_coverage, 1.0);
    assert_close(features.lexical_semantic_agreement, 1.0);
}

#[test]
fn tied_semantic_candidates_have_zero_raw_margin() {
    let candidates = [
        EvidenceCandidate {
            stable_id: 10,
            text: "A plain ceramic bowl.",
            raw_semantic_cosine: 0.5,
        },
        EvidenceCandidate {
            stable_id: 20,
            text: "A shallow wooden bowl.",
            raw_semantic_cosine: 0.5,
        },
    ];
    let features =
        evidence_features_for_candidates("Which bowl?", &candidates).expect("finite candidates");
    assert_close(features.semantic_margin, 0.0);
}

#[test]
fn tied_candidates_produce_identical_features_when_input_order_is_reversed() {
    let first = EvidenceCandidate {
        stable_id: 10,
        text: "The green cabinet stores the spare brushes.",
        raw_semantic_cosine: 0.75,
    };
    let second = EvidenceCandidate {
        stable_id: 20,
        text: "The spare brushes were put away after painting.",
        raw_semantic_cosine: 0.75,
    };
    let forward =
        evidence_features_for_candidates("Where are the spare brushes stored?", &[first, second])
            .unwrap();
    let reverse =
        evidence_features_for_candidates("Where are the spare brushes stored?", &[second, first])
            .unwrap();
    assert_eq!(forward, reverse);
    assert_close(forward.semantic_margin, 0.0);
    assert!((forward.document_coverage - 0.4).abs() < 1e-6);
}

#[test]
fn coverage_features_describe_best_lexical_evidence_not_an_unrelated_semantic_top() {
    let candidates = [
        EvidenceCandidate {
            stable_id: 10,
            text: "A broad planning note about the studio.",
            raw_semantic_cosine: 0.90,
        },
        EvidenceCandidate {
            stable_id: 20,
            text: "The spare brushes are stored in the green cabinet.",
            raw_semantic_cosine: 0.80,
        },
    ];
    let features =
        evidence_features_for_candidates("Where are the spare brushes stored?", &candidates)
            .unwrap();
    assert_close(features.raw_semantic_cosine, 0.90);
    assert_close(features.query_coverage, 1.0);
    assert!((features.document_coverage - 0.6).abs() < 1e-6);
    assert_close(features.lexical_semantic_agreement, 0.0);
    assert_close(features.novel_specificity, 1.0);
}

#[test]
fn novel_specificity_distinguishes_concrete_evidence_from_a_placeholder() {
    let concrete = [EvidenceCandidate {
        stable_id: 10,
        text: "The north entrance leads directly to the sculpture garden.",
        raw_semantic_cosine: 0.80,
    }];
    let placeholder = [EvidenceCandidate {
        stable_id: 20,
        text: "One entrance leads directly to the sculpture garden.",
        raw_semantic_cosine: 0.82,
    }];
    let query = "Which entrance leads directly to the sculpture garden?";
    let concrete_features = evidence_features_for_candidates(query, &concrete).unwrap();
    let placeholder_features = evidence_features_for_candidates(query, &placeholder).unwrap();
    assert!(concrete_features.novel_specificity > placeholder_features.novel_specificity);
    assert!((concrete_features.novel_specificity - 5.0 / 9.0).abs() < 1e-6);
    assert!((placeholder_features.novel_specificity - 3.0 / 9.0).abs() < 1e-6);
}

#[test]
fn frozen_policy_has_independent_calibration_provenance() {
    let policy = EVIDENCE_SUFFICIENCY_POLICY;
    assert_eq!(
        policy.calibration_dataset_id,
        "hippocampus-evidence-sufficiency-calibration-v1"
    );
    assert_close(policy.target_positive_coverage, 0.90);
    assert_eq!(policy.feature_schema_version, 2);
    assert!(!policy.calibration_sha256.is_empty());
}

#[test]
fn evidence_policy_accepts_only_finite_complete_feature_vectors() {
    let policy = EVIDENCE_SUFFICIENCY_POLICY;
    let complete = EvidenceFeatures {
        raw_semantic_cosine: 0.8,
        semantic_margin: 0.2,
        query_coverage: 0.75,
        document_coverage: 0.5,
        lexical_semantic_agreement: 1.0,
        novel_specificity: 0.5,
    };
    assert!(policy.score(complete).is_some());

    for invalid in [
        EvidenceFeatures {
            raw_semantic_cosine: f32::NAN,
            ..complete
        },
        EvidenceFeatures {
            semantic_margin: f32::INFINITY,
            ..complete
        },
        EvidenceFeatures {
            query_coverage: -0.1,
            ..complete
        },
        EvidenceFeatures {
            document_coverage: 1.1,
            ..complete
        },
        EvidenceFeatures {
            lexical_semantic_agreement: 0.5,
            ..complete
        },
        EvidenceFeatures {
            novel_specificity: 1.1,
            ..complete
        },
    ] {
        assert_eq!(policy.score(invalid), None);
        assert!(!policy.is_sufficient(invalid));
    }
}

#[test]
fn policy_decision_is_a_fixed_cross_query_score_boundary() {
    let policy = EVIDENCE_SUFFICIENCY_POLICY;
    let features = EvidenceFeatures {
        raw_semantic_cosine: 0.5,
        semantic_margin: 0.1,
        query_coverage: 0.5,
        document_coverage: 0.5,
        lexical_semantic_agreement: 1.0,
        novel_specificity: 0.5,
    };
    let score = policy.score(features).expect("valid features");
    assert_eq!(
        policy.is_sufficient(features),
        policy.validation_qualified && score >= policy.threshold
    );
}

#[test]
fn failed_held_out_validation_cannot_promote_matches() {
    let policy = EVIDENCE_SUFFICIENCY_POLICY;
    assert!(!policy.validation_qualified);
    let features = EvidenceFeatures {
        raw_semantic_cosine: 1.0,
        semantic_margin: 1.0,
        query_coverage: 1.0,
        document_coverage: 1.0,
        lexical_semantic_agreement: 1.0,
        novel_specificity: 1.0,
    };
    assert!(policy.score(features).is_some());
    assert!(!policy.is_sufficient(features));
}

#[test]
fn committed_calibration_artifact_matches_frozen_policy() {
    let artifact: serde_json::Value = serde_json::from_str(include_str!(
        "../../../eval/relevance-calibration/v1-policy.json"
    ))
    .expect("committed policy artifact parses");
    let policy = EVIDENCE_SUFFICIENCY_POLICY;
    assert_eq!(
        artifact["dataset_id"].as_str(),
        Some(policy.calibration_dataset_id)
    );
    assert_eq!(
        artifact["fixture_sha256"].as_str(),
        Some(policy.calibration_sha256)
    );
    let artifact_threshold = artifact["threshold"].as_f64().expect("numeric threshold");
    assert!((artifact_threshold - f64::from(policy.threshold)).abs() < 1e-8);
    assert_eq!(artifact["validation"]["positive_coverage"], 5.0 / 6.0);
    assert_eq!(
        artifact["validation"]["negative_false_positive_rate"],
        2.0 / 6.0
    );
}

#[test]
fn explicit_answer_shapes_require_values_in_retrieved_evidence() {
    for (query, supported, unsupported) in [
        (
            "How many cases are in the release corpus?",
            "The release corpus contains 24 cases.",
            "The release corpus is documented in the README.",
        ),
        (
            "How long did the focused test run take?",
            "The focused test run completed in 42 seconds.",
            "The focused test run completed successfully.",
        ),
        (
            "What due date was set for the migration?",
            "The migration is due on September 18.",
            "The migration has an assigned owner.",
        ),
    ] {
        let supported_candidates = [EvidenceCandidate {
            stable_id: 1,
            text: supported,
            raw_semantic_cosine: 0.8,
        }];
        let unsupported_candidates = [EvidenceCandidate {
            stable_id: 2,
            text: unsupported,
            raw_semantic_cosine: 0.8,
        }];
        assert_eq!(
            explicit_evidence_signal(query, &supported_candidates),
            ExplicitEvidenceSignal::ValueTypeObserved,
            "supported query: {query}"
        );
        assert_eq!(
            explicit_evidence_signal(query, &unsupported_candidates),
            ExplicitEvidenceSignal::ValueTypeAbsent,
            "unsupported query: {query}"
        );
    }
}

#[test]
fn capture_context_header_values_cannot_satisfy_an_explicit_date_question() {
    let candidates = [EvidenceCandidate {
        stable_id: 1,
        text: "[app=com.linear | title=HIPP-201 new owner | url=linear://HIPP-201 | ts=2026-09-02T08:15:00.000Z]\nUpdated note says Priya owns HIPP 201.",
        raw_semantic_cosine: 0.8,
    }];

    assert_eq!(
        explicit_evidence_signal("What due date did Priya set for HIPP 201?", &candidates),
        ExplicitEvidenceSignal::ValueTypeAbsent
    );
}

#[test]
fn non_explicit_questions_are_left_to_the_calibrated_critic() {
    let candidates = [EvidenceCandidate {
        stable_id: 1,
        text: "The rollback changed partial benchmark runs to fail closed.",
        raw_semantic_cosine: 0.8,
    }];

    assert_eq!(
        explicit_evidence_signal("Why did partial benchmark runs change?", &candidates),
        ExplicitEvidenceSignal::NotApplicable
    );
}

#[derive(serde::Deserialize)]
struct ExplicitEvidenceFixture {
    dataset_id: String,
    cases: Vec<ExplicitEvidenceCase>,
}

#[derive(serde::Deserialize)]
struct ExplicitEvidenceCase {
    id: String,
    split: String,
    query: String,
    supporting_documents: Vec<String>,
    insufficient_documents: Vec<String>,
}

#[test]
fn explicit_evidence_veto_passes_disjoint_calibration_and_validation_splits() {
    let fixture_bytes = include_bytes!("../../../eval/work-memory/explicit-evidence-veto-v1.json");
    let fixture: ExplicitEvidenceFixture =
        serde_json::from_slice(fixture_bytes).expect("explicit evidence fixture parses");
    let qualification = EXPLICIT_EVIDENCE_VETO_QUALIFICATION;
    assert_eq!(fixture.dataset_id, qualification.fixture_dataset_id);
    assert_eq!(
        format!("{:x}", Sha256::digest(fixture_bytes)),
        qualification.fixture_sha256
    );
    for (split, expected_cases) in [
        ("calibration", qualification.calibration_cases),
        ("validation", qualification.validation_cases),
    ] {
        let cases = fixture
            .cases
            .iter()
            .filter(|case| case.split == split)
            .collect::<Vec<_>>();
        assert_eq!(cases.len(), expected_cases, "{split} split size changed");
        for case in cases {
            let supporting = case
                .supporting_documents
                .iter()
                .enumerate()
                .map(|(index, text)| EvidenceCandidate {
                    stable_id: index as u64,
                    text,
                    raw_semantic_cosine: 0.8,
                })
                .collect::<Vec<_>>();
            let insufficient = case
                .insufficient_documents
                .iter()
                .enumerate()
                .map(|(index, text)| EvidenceCandidate {
                    stable_id: index as u64,
                    text,
                    raw_semantic_cosine: 0.8,
                })
                .collect::<Vec<_>>();
            assert_eq!(
                explicit_evidence_signal(&case.query, &supporting),
                ExplicitEvidenceSignal::ValueTypeObserved,
                "{} positive",
                case.id
            );
            assert_eq!(
                explicit_evidence_signal(&case.query, &insufficient),
                ExplicitEvidenceSignal::ValueTypeAbsent,
                "{} negative",
                case.id
            );
        }
    }
}

#[test]
fn explicit_evidence_veto_reports_held_out_unrelated_value_false_pass_throughs() {
    let fixture: ExplicitEvidenceFixture = serde_json::from_str(include_str!(
        "../../../eval/work-memory/explicit-evidence-veto-v1.json"
    ))
    .expect("explicit evidence fixture parses");
    let cases = fixture
        .cases
        .iter()
        .filter(|case| case.split == "adversarial")
        .collect::<Vec<_>>();
    assert_eq!(cases.len(), 8, "adversarial split size changed");

    let false_pass_throughs = cases
        .iter()
        .filter_map(|case| {
            let candidates = case
                .insufficient_documents
                .iter()
                .enumerate()
                .map(|(index, text)| EvidenceCandidate {
                    stable_id: index as u64,
                    text,
                    raw_semantic_cosine: 0.8,
                })
                .collect::<Vec<_>>();
            (explicit_evidence_signal(&case.query, &candidates)
                != ExplicitEvidenceSignal::ValueTypeAbsent)
                .then_some(case.id.as_str())
        })
        .collect::<Vec<_>>();

    let qualification = EXPLICIT_EVIDENCE_VETO_QUALIFICATION;
    assert_eq!(fixture.dataset_id, qualification.fixture_dataset_id);
    assert_eq!(
        false_pass_throughs.len(),
        qualification.adversarial_false_pass_throughs,
        "held-out false pass-through behavior changed: {false_pass_throughs:?}"
    );
    assert_eq!(cases.len(), qualification.adversarial_cases);
    assert!(!qualification.relation_grounded);
}
