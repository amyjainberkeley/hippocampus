use mci_brain::{
    evidence_features_for_candidates, EvidenceCandidate, EvidenceFeatures,
    EVIDENCE_SUFFICIENCY_POLICY,
};

#[test]
fn feature_extraction_is_generic_and_preserves_raw_model_geometry() {
    let candidates = [
        EvidenceCandidate {
            text: "The cedar chest is beside the window.",
            raw_semantic_cosine: 0.72,
        },
        EvidenceCandidate {
            text: "The window faces the courtyard.",
            raw_semantic_cosine: 0.70,
        },
    ];
    let features = evidence_features_for_candidates("Where is the cedar chest?", &candidates)
        .expect("non-empty finite candidates");

    assert_eq!(features.raw_semantic_cosine, 0.72);
    assert!((features.semantic_margin - 0.02).abs() < 1e-6);
    assert_eq!(features.query_coverage, 1.0);
    assert_eq!(features.lexical_semantic_agreement, 1.0);
}

#[test]
fn tied_semantic_candidates_have_zero_raw_margin() {
    let candidates = [
        EvidenceCandidate {
            text: "A plain ceramic bowl.",
            raw_semantic_cosine: 0.5,
        },
        EvidenceCandidate {
            text: "A shallow wooden bowl.",
            raw_semantic_cosine: 0.5,
        },
    ];
    let features =
        evidence_features_for_candidates("Which bowl?", &candidates).expect("finite candidates");
    assert_eq!(features.semantic_margin, 0.0);
}

#[test]
fn frozen_policy_has_independent_calibration_provenance() {
    let policy = EVIDENCE_SUFFICIENCY_POLICY;
    assert_eq!(
        policy.calibration_dataset_id,
        "hippocampus-evidence-sufficiency-calibration-v1"
    );
    assert_eq!(policy.target_positive_coverage, 0.90);
    assert_eq!(policy.feature_schema_version, 1);
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
    assert_eq!(artifact["validation"]["positive_coverage"], 2.0 / 3.0);
    assert_eq!(artifact["validation"]["negative_false_positive_rate"], 0.5);
}
