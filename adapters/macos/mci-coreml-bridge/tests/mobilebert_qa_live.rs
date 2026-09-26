#![cfg(target_os = "macos")]

use std::path::PathBuf;

use mci_coreml_bridge::mobilebert_qa::MobileBertQaBackend;

fn candidate_paths() -> (PathBuf, PathBuf) {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..");
    (
        root.join("models/MobileBertQASquad2_FP32.mlmodelc"),
        root.join("models/MobileBertQASquad2-tokenizer/tokenizer.json"),
    )
}

#[test]
#[ignore = "requires the unqualified gitignored MobileBERT QA candidate"]
fn native_candidate_matches_the_reference_answer_and_margin() {
    let (model, tokenizer) = candidate_paths();
    let backend = MobileBertQaBackend::open(&model, &tokenizer).expect("open QA candidate");
    let answer = backend
        .answer(
            "Which instrument did Nila practice before supper?",
            "Nila practiced the cello in the dining room before supper. The cello case was resting beside the dining-room chair. Supper was served after the music practice ended.",
        )
        .expect("extract answer");

    assert_eq!(answer.text, "cello");
    assert!(
        (answer.no_answer_margin - 19.568_893).abs() < 0.001,
        "{answer:?}"
    );

    let insufficient = backend
        .answer(
            "Which instrument did Nila practice before supper?",
            "Nila practiced music in the dining room before supper. A closed instrument case was beside the chair. Supper was served after practice ended.",
        )
        .expect("extract insufficient candidate span");
    assert_eq!(insufficient.text, "music");
    assert!(
        (insufficient.no_answer_margin - 16.633_268).abs() < 0.001,
        "{insufficient:?}"
    );
}
