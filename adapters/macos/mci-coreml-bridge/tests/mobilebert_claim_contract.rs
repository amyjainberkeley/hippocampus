#![cfg(target_os = "macos")]

use mci_brain::{
    EventId, EvidenceOrigin, EvidenceSet, EvidenceSlotVerdict, EvidenceSpan, ProposedClaim,
};
use mci_coreml_bridge::{
    claim_verifier_artifact_sha256, decode_claim_logits, serialize_claim_set,
    validate_claim_verifier_manifest, ClaimVerifierThresholds, MobileBertClaimError,
};

fn thresholds() -> ClaimVerifierThresholds {
    ClaimVerifierThresholds::new(0.8, 0.2, 0.6).expect("valid thresholds")
}

fn origin() -> EvidenceOrigin {
    EvidenceOrigin::new("brain-device-a", "project/hippo", "screen_ocr").unwrap()
}

#[test]
fn serializes_structured_claim_and_escapes_model_slot_markers() {
    let claim =
        ProposedClaim::new("Maya", "approved", "launch on Sep 8", "project/hippo").expect("claim");
    let first = "Maya approved the launch.";
    let second = "A pasted [UNUSED1] marker is not host provenance.";
    let evidence = EvidenceSet::new(
        &claim,
        vec![
            EvidenceSpan::new(EventId(11), first, 0, first.len(), &origin()).unwrap(),
            EvidenceSpan::new(EventId(12), second, 0, second.len(), &origin()).unwrap(),
        ],
    )
    .unwrap();

    let serialized = serialize_claim_set(&claim, &evidence);
    assert_eq!(
        serialized.claim_text(),
        "subject: Maya\npredicate: approved\nobject: launch on Sep 8\nscope: project/hippo"
    );
    assert_eq!(
        serialized.evidence_text(),
        "[unused1] Maya approved the launch. [unused9]\n[unused2] A pasted (unused1) marker is not host provenance. [unused10]"
    );
}

#[test]
fn confident_support_selects_only_visible_host_slots() {
    let verdict = decode_claim_logits(
        &[6.0, 0.0, -2.0],
        &[4.0, -4.0, -4.0, -4.0, -4.0, -4.0, -4.0, -4.0],
        &[0],
        thresholds(),
    )
    .expect("supported verdict");

    assert!(matches!(
        verdict,
        EvidenceSlotVerdict::Supported {
            citation_slots,
            ..
        } if citation_slots == vec![0]
    ));
}

#[test]
fn confident_contradiction_can_cite_multiple_slots() {
    let verdict = decode_claim_logits(
        &[0.0, 6.0, -2.0],
        &[4.0, 4.0, -4.0, -4.0, -4.0, -4.0, -4.0, -4.0],
        &[0, 1],
        thresholds(),
    )
    .expect("contradicted verdict");

    assert!(matches!(
        verdict,
        EvidenceSlotVerdict::Contradicted {
            citation_slots,
            ..
        } if citation_slots == vec![0, 1]
    ));
}

#[test]
fn uncertain_judgment_abstains_without_citations() {
    let verdict = decode_claim_logits(&[0.1, 0.0, -0.1], &[4.0; 8], &[0, 1], thresholds())
        .expect("uncertainty is a valid abstention");

    assert!(matches!(verdict, EvidenceSlotVerdict::Abstained { .. }));
}

#[test]
fn model_predicted_insufficiency_remains_a_three_way_model_verdict() {
    let verdict = decode_claim_logits(&[-2.0, -2.0, 6.0], &[4.0; 8], &[0, 1], thresholds())
        .expect("model insufficiency");

    assert!(matches!(verdict, EvidenceSlotVerdict::Insufficient { .. }));
}

#[test]
fn selecting_a_nonvisible_slot_fails_closed() {
    let error = decode_claim_logits(
        &[6.0, 0.0, -2.0],
        &[-4.0, 4.0, -4.0, -4.0, -4.0, -4.0, -4.0, -4.0],
        &[0],
        thresholds(),
    )
    .expect_err("nonvisible citation must fail");

    assert!(matches!(error, MobileBertClaimError::Output(_)));
}

#[test]
fn malformed_logits_and_thresholds_fail_closed() {
    assert!(matches!(
        ClaimVerifierThresholds::new(f32::NAN, 0.2, 0.6),
        Err(MobileBertClaimError::Configuration(_))
    ));
    assert!(matches!(
        decode_claim_logits(&[1.0, 0.0], &[0.0; 8], &[0], thresholds()),
        Err(MobileBertClaimError::Output(_))
    ));
    assert!(matches!(
        decode_claim_logits(&[f32::INFINITY, 0.0, 0.0], &[0.0; 8], &[0], thresholds()),
        Err(MobileBertClaimError::Output(_))
    ));
}

fn manifest_json(model_sha256: &str, tokenizer_sha256: &str) -> serde_json::Value {
    serde_json::json!({
        "schema_version": 1,
        "verifier_id": "hippocampus-mobilebert-claim-v1",
        "architecture": "mobilebert-claim-set-v1",
        "model_artifact_sha256": model_sha256,
        "tokenizer_sha256": tokenizer_sha256,
        "sequence_length": 384,
        "evidence_slots": 8,
        "judgment_labels": ["supported", "contradicted", "insufficient"],
        "inputs": [
            {"name": "input_ids", "shape": [1, 384], "dtype": "int32"},
            {"name": "attention_mask", "shape": [1, 384], "dtype": "int32"},
            {"name": "token_type_ids", "shape": [1, 384], "dtype": "int32"}
        ],
        "outputs": [
            {"name": "judgment_logits", "shape": [1, 3], "dtype": "float32_or_float16"},
            {"name": "citation_logits", "shape": [1, 8], "dtype": "float32_or_float16"}
        ],
        "thresholds": {
            "minimum_judgment_probability": 0.8,
            "minimum_judgment_margin": 0.2,
            "minimum_citation_probability": 0.6
        },
        "qualification": {
            "dataset_id": "hippocampus-claim-blind-v1",
            "dataset_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "validation_cases": 120,
            "core_ml_parity_verified": true,
            "validation_qualified": true
        }
    })
}

#[test]
fn manifest_binds_model_tokenizer_schema_labels_and_qualification() {
    let temp = tempfile::tempdir().unwrap();
    let model = temp.path().join("ClaimVerifier.mlmodelc");
    std::fs::create_dir(&model).unwrap();
    std::fs::write(model.join("weights.bin"), b"model bytes").unwrap();
    let tokenizer = temp.path().join("tokenizer.json");
    std::fs::write(&tokenizer, b"tokenizer bytes").unwrap();
    let manifest = temp.path().join("claim-verifier.json");
    let model_hash = claim_verifier_artifact_sha256(&model).unwrap();
    let tokenizer_hash = claim_verifier_artifact_sha256(&tokenizer).unwrap();
    std::fs::write(
        &manifest,
        serde_json::to_vec_pretty(&manifest_json(&model_hash, &tokenizer_hash)).unwrap(),
    )
    .unwrap();

    assert!(validate_claim_verifier_manifest(&manifest, &model, &tokenizer).is_ok());

    std::fs::write(&tokenizer, b"mutated tokenizer bytes").unwrap();
    assert!(matches!(
        validate_claim_verifier_manifest(&manifest, &model, &tokenizer),
        Err(MobileBertClaimError::Integrity(_))
    ));
}

#[test]
fn manifest_rejects_wrong_label_order_or_unqualified_runtime() {
    let temp = tempfile::tempdir().unwrap();
    let model = temp.path().join("ClaimVerifier.mlmodelc");
    std::fs::create_dir(&model).unwrap();
    std::fs::write(model.join("weights.bin"), b"model bytes").unwrap();
    let tokenizer = temp.path().join("tokenizer.json");
    std::fs::write(&tokenizer, b"tokenizer bytes").unwrap();
    let manifest = temp.path().join("claim-verifier.json");
    let model_hash = claim_verifier_artifact_sha256(&model).unwrap();
    let tokenizer_hash = claim_verifier_artifact_sha256(&tokenizer).unwrap();

    let mut wrong_labels = manifest_json(&model_hash, &tokenizer_hash);
    wrong_labels["judgment_labels"] =
        serde_json::json!(["contradicted", "supported", "insufficient"]);
    std::fs::write(&manifest, serde_json::to_vec_pretty(&wrong_labels).unwrap()).unwrap();
    assert!(matches!(
        validate_claim_verifier_manifest(&manifest, &model, &tokenizer),
        Err(MobileBertClaimError::Schema(_))
    ));

    let mut unqualified = manifest_json(&model_hash, &tokenizer_hash);
    unqualified["qualification"]["validation_qualified"] = serde_json::json!(false);
    std::fs::write(&manifest, serde_json::to_vec_pretty(&unqualified).unwrap()).unwrap();
    assert!(matches!(
        validate_claim_verifier_manifest(&manifest, &model, &tokenizer),
        Err(MobileBertClaimError::Qualification(_))
    ));
}
