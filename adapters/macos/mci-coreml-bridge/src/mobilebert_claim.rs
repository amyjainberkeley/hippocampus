//! Fixed-shape `MobileBERT` adapter for host-bound claim verification.
//!
//! This module defines the runtime contract for a future task-trained model.
//! It does not make the current app release-qualified: no verifier artifact or
//! thresholds have passed the blind signed-runtime gate yet.

use std::collections::HashSet;
use std::fmt::Write as _;
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

use mci_brain::{
    ClaimEvidenceVerifier, EvidenceSet, EvidenceSlotVerdict, EvidenceVerifierError, ProposedClaim,
    MAX_VERIFIER_EVIDENCE_SLOTS,
};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use tokenizers::{
    PaddingDirection, PaddingParams, PaddingStrategy, Tokenizer, TruncationDirection,
    TruncationParams, TruncationStrategy,
};

use crate::model::{
    self, ComputeUnits, CoreMLError, CoreMLModel, MultiArrayElementType, MultiArraySchema,
};

/// Frozen token length for the selected `MobileBERT` architecture.
pub const CLAIM_VERIFIER_SEQUENCE_LENGTH: usize = 384;

const JUDGMENT_CLASS_COUNT: usize = 3;
const SLOT_START_MARKERS: [&str; MAX_VERIFIER_EVIDENCE_SLOTS] = [
    "[unused1]",
    "[unused2]",
    "[unused3]",
    "[unused4]",
    "[unused5]",
    "[unused6]",
    "[unused7]",
    "[unused8]",
];
const SLOT_END_MARKERS: [&str; MAX_VERIFIER_EVIDENCE_SLOTS] = [
    "[unused9]",
    "[unused10]",
    "[unused11]",
    "[unused12]",
    "[unused13]",
    "[unused14]",
    "[unused15]",
    "[unused16]",
];

/// Errors from the claim-verifier adapter.
#[derive(Debug, thiserror::Error)]
pub enum MobileBertClaimError {
    /// Qualification thresholds were malformed.
    #[error("invalid claim-verifier configuration: {0}")]
    Configuration(String),
    /// The tokenizer could not be loaded or applied.
    #[error("claim-verifier tokenizer error: {0}")]
    Tokenizer(String),
    /// The Core ML model failed to load or predict.
    #[error("claim-verifier Core ML error: {0}")]
    CoreMl(#[from] CoreMLError),
    /// The model or tokenizer does not expose the frozen contract.
    #[error("invalid claim-verifier schema: {0}")]
    Schema(String),
    /// The bundle-sealed manifest was absent or malformed.
    #[error("invalid claim-verifier manifest: {0}")]
    Manifest(String),
    /// A model or tokenizer artifact did not match the manifest.
    #[error("claim-verifier integrity failure: {0}")]
    Integrity(String),
    /// The manifest does not attest a completed qualification gate.
    #[error("unqualified claim verifier: {0}")]
    Qualification(String),
    /// Input could not fit the frozen model contract.
    #[error("invalid claim-verifier input: {0}")]
    Input(String),
    /// Model output was malformed, non-finite, or cited unavailable evidence.
    #[error("invalid claim-verifier output: {0}")]
    Output(String),
}

const CLAIM_VERIFIER_MANIFEST_MAX_BYTES: u64 = 65_536;
const CLAIM_VERIFIER_ARCHITECTURE: &str = "mobilebert-claim-set-v1";
const JUDGMENT_LABELS: [&str; JUDGMENT_CLASS_COUNT] = ["supported", "contradicted", "insufficient"];

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ClaimVerifierManifest {
    schema_version: u32,
    verifier_id: String,
    architecture: String,
    model_artifact_sha256: String,
    tokenizer_sha256: String,
    sequence_length: usize,
    evidence_slots: usize,
    judgment_labels: Vec<String>,
    inputs: Vec<ManifestTensor>,
    outputs: Vec<ManifestTensor>,
    thresholds: ManifestThresholds,
    qualification: ManifestQualification,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct ManifestTensor {
    name: String,
    shape: Vec<usize>,
    dtype: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ManifestThresholds {
    #[serde(rename = "minimum_judgment_probability")]
    judgment_probability: f32,
    #[serde(rename = "minimum_judgment_margin")]
    judgment_margin: f32,
    #[serde(rename = "minimum_citation_probability")]
    citation_probability: f32,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ManifestQualification {
    dataset_id: String,
    dataset_sha256: String,
    validation_cases: usize,
    core_ml_parity_verified: bool,
    validation_qualified: bool,
}

/// Validate a bundle-sealed manifest and both artifact identities without
/// opening Core ML. Release signing must seal all three files in the app.
pub fn validate_claim_verifier_manifest(
    manifest_path: &Path,
    model_path: &Path,
    tokenizer_path: &Path,
) -> Result<ClaimVerifierThresholds, MobileBertClaimError> {
    let metadata = std::fs::symlink_metadata(manifest_path).map_err(|error| {
        MobileBertClaimError::Manifest(format!("{}: {error}", manifest_path.display()))
    })?;
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.len() > CLAIM_VERIFIER_MANIFEST_MAX_BYTES
    {
        return Err(MobileBertClaimError::Manifest(
            "manifest must be a regular file no larger than 64 KiB".to_owned(),
        ));
    }
    let bytes = std::fs::read(manifest_path).map_err(|error| {
        MobileBertClaimError::Manifest(format!("{}: {error}", manifest_path.display()))
    })?;
    let manifest: ClaimVerifierManifest = serde_json::from_slice(&bytes)
        .map_err(|error| MobileBertClaimError::Manifest(error.to_string()))?;
    validate_manifest_schema(&manifest)?;

    let model_sha256 = claim_verifier_artifact_sha256(model_path)?;
    if model_sha256 != manifest.model_artifact_sha256 {
        return Err(MobileBertClaimError::Integrity(format!(
            "model SHA-256 mismatch: expected {}, got {model_sha256}",
            manifest.model_artifact_sha256
        )));
    }
    let tokenizer_sha256 = claim_verifier_artifact_sha256(tokenizer_path)?;
    if tokenizer_sha256 != manifest.tokenizer_sha256 {
        return Err(MobileBertClaimError::Integrity(format!(
            "tokenizer SHA-256 mismatch: expected {}, got {tokenizer_sha256}",
            manifest.tokenizer_sha256
        )));
    }

    ClaimVerifierThresholds::new(
        manifest.thresholds.judgment_probability,
        manifest.thresholds.judgment_margin,
        manifest.thresholds.citation_probability,
    )
}

fn validate_manifest_schema(manifest: &ClaimVerifierManifest) -> Result<(), MobileBertClaimError> {
    if manifest.schema_version != 1
        || manifest.architecture != CLAIM_VERIFIER_ARCHITECTURE
        || manifest.sequence_length != CLAIM_VERIFIER_SEQUENCE_LENGTH
        || manifest.evidence_slots != MAX_VERIFIER_EVIDENCE_SLOTS
        || manifest.judgment_labels != JUDGMENT_LABELS
        || manifest.inputs != expected_input_tensors()
        || manifest.outputs != expected_output_tensors()
    {
        return Err(MobileBertClaimError::Schema(
            "manifest does not match the frozen architecture, labels, or tensor contract"
                .to_owned(),
        ));
    }
    if manifest.verifier_id.trim().is_empty() || manifest.verifier_id.len() > 128 {
        return Err(MobileBertClaimError::Schema(
            "verifier_id must be nonempty and at most 128 bytes".to_owned(),
        ));
    }
    for (name, digest) in [
        ("model_artifact_sha256", &manifest.model_artifact_sha256),
        ("tokenizer_sha256", &manifest.tokenizer_sha256),
        (
            "qualification.dataset_sha256",
            &manifest.qualification.dataset_sha256,
        ),
    ] {
        if !is_sha256(digest) {
            return Err(MobileBertClaimError::Schema(format!(
                "{name} must be 64 lowercase hexadecimal characters"
            )));
        }
    }
    if manifest.qualification.dataset_id.trim().is_empty()
        || manifest.qualification.dataset_id.len() > 256
        || manifest.qualification.validation_cases == 0
        || !manifest.qualification.core_ml_parity_verified
        || !manifest.qualification.validation_qualified
    {
        return Err(MobileBertClaimError::Qualification(
            "blind dataset identity, nonzero cases, Core ML parity, and qualification are required"
                .to_owned(),
        ));
    }
    Ok(())
}

fn expected_input_tensors() -> Vec<ManifestTensor> {
    ["input_ids", "attention_mask", "token_type_ids"]
        .into_iter()
        .map(|name| ManifestTensor {
            name: name.to_owned(),
            shape: vec![1, CLAIM_VERIFIER_SEQUENCE_LENGTH],
            dtype: "int32".to_owned(),
        })
        .collect()
}

fn expected_output_tensors() -> Vec<ManifestTensor> {
    vec![
        ManifestTensor {
            name: "judgment_logits".to_owned(),
            shape: vec![1, JUDGMENT_CLASS_COUNT],
            dtype: "float32_or_float16".to_owned(),
        },
        ManifestTensor {
            name: "citation_logits".to_owned(),
            shape: vec![1, MAX_VERIFIER_EVIDENCE_SLOTS],
            dtype: "float32_or_float16".to_owned(),
        },
    ]
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Hash a regular file by its bytes or a model directory by a deterministic,
/// path-sensitive stream of sorted regular files. Symlinks are rejected.
pub fn claim_verifier_artifact_sha256(path: &Path) -> Result<String, MobileBertClaimError> {
    let metadata = std::fs::symlink_metadata(path)
        .map_err(|error| MobileBertClaimError::Integrity(format!("{}: {error}", path.display())))?;
    if metadata.file_type().is_symlink() {
        return Err(MobileBertClaimError::Integrity(format!(
            "artifact cannot be a symlink: {}",
            path.display()
        )));
    }
    if metadata.is_file() {
        return sha256_file(path);
    }
    if !metadata.is_dir() {
        return Err(MobileBertClaimError::Integrity(format!(
            "artifact is not a regular file or directory: {}",
            path.display()
        )));
    }

    let mut files = Vec::new();
    collect_artifact_files(path, path, &mut files)?;
    if files.is_empty() {
        return Err(MobileBertClaimError::Integrity(format!(
            "artifact directory is empty: {}",
            path.display()
        )));
    }
    files.sort();
    let mut digest = Sha256::new();
    digest.update(b"hippocampus:artifact-directory:v1\0");
    for relative in files {
        let relative_text = relative.to_str().ok_or_else(|| {
            MobileBertClaimError::Integrity("artifact path is not valid UTF-8".to_owned())
        })?;
        let file_path = path.join(&relative);
        let file_metadata = std::fs::metadata(&file_path).map_err(|error| {
            MobileBertClaimError::Integrity(format!("{}: {error}", file_path.display()))
        })?;
        update_length_prefixed(&mut digest, relative_text.as_bytes());
        digest.update(file_metadata.len().to_be_bytes());
        update_digest_from_file(&mut digest, &file_path)?;
    }
    Ok(hex_digest(digest.finalize()))
}

fn collect_artifact_files(
    root: &Path,
    current: &Path,
    files: &mut Vec<std::path::PathBuf>,
) -> Result<(), MobileBertClaimError> {
    let entries = std::fs::read_dir(current).map_err(|error| {
        MobileBertClaimError::Integrity(format!("{}: {error}", current.display()))
    })?;
    for entry in entries {
        let entry = entry.map_err(|error| MobileBertClaimError::Integrity(error.to_string()))?;
        let path = entry.path();
        let metadata = std::fs::symlink_metadata(&path).map_err(|error| {
            MobileBertClaimError::Integrity(format!("{}: {error}", path.display()))
        })?;
        if metadata.file_type().is_symlink() {
            return Err(MobileBertClaimError::Integrity(format!(
                "artifact contains a symlink: {}",
                path.display()
            )));
        }
        if metadata.is_dir() {
            collect_artifact_files(root, &path, files)?;
        } else if metadata.is_file() {
            files.push(
                path.strip_prefix(root)
                    .map_err(|error| MobileBertClaimError::Integrity(error.to_string()))?
                    .to_owned(),
            );
        } else {
            return Err(MobileBertClaimError::Integrity(format!(
                "artifact contains a non-regular entry: {}",
                path.display()
            )));
        }
    }
    Ok(())
}

fn sha256_file(path: &Path) -> Result<String, MobileBertClaimError> {
    let mut digest = Sha256::new();
    update_digest_from_file(&mut digest, path)?;
    Ok(hex_digest(digest.finalize()))
}

fn update_digest_from_file(digest: &mut Sha256, path: &Path) -> Result<(), MobileBertClaimError> {
    let file = File::open(path)
        .map_err(|error| MobileBertClaimError::Integrity(format!("{}: {error}", path.display())))?;
    let mut reader = BufReader::new(file);
    let mut buffer = vec![0_u8; 64 * 1_024].into_boxed_slice();
    loop {
        let count = reader.read(&mut buffer).map_err(|error| {
            MobileBertClaimError::Integrity(format!("{}: {error}", path.display()))
        })?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    Ok(())
}

fn update_length_prefixed(digest: &mut Sha256, bytes: &[u8]) {
    digest.update(u64::try_from(bytes.len()).unwrap_or(u64::MAX).to_be_bytes());
    digest.update(bytes);
}

fn hex_digest(bytes: impl AsRef<[u8]>) -> String {
    let bytes = bytes.as_ref();
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        write!(&mut output, "{byte:02x}").expect("writing to a String cannot fail");
    }
    output
}

/// Thresholds frozen by qualification and supplied alongside a model.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ClaimVerifierThresholds {
    judgment_probability: f32,
    judgment_margin: f32,
    citation_probability: f32,
}

impl ClaimVerifierThresholds {
    /// Validate a complete threshold set. These values must come from a
    /// qualification artifact; the adapter deliberately provides no default.
    pub fn new(
        minimum_judgment_probability: f32,
        minimum_judgment_margin: f32,
        minimum_citation_probability: f32,
    ) -> Result<Self, MobileBertClaimError> {
        if !is_probability(minimum_judgment_probability)
            || !minimum_judgment_margin.is_finite()
            || !(0.0..=1.0).contains(&minimum_judgment_margin)
            || !is_probability(minimum_citation_probability)
        {
            return Err(MobileBertClaimError::Configuration(
                "probability thresholds must be finite in (0, 1], and margin in [0, 1]".to_owned(),
            ));
        }
        Ok(Self {
            judgment_probability: minimum_judgment_probability,
            judgment_margin: minimum_judgment_margin,
            citation_probability: minimum_citation_probability,
        })
    }
}

fn is_probability(value: f32) -> bool {
    value.is_finite() && (0.0..=1.0).contains(&value) && value > 0.0
}

/// Stable textual representation consumed by the task-trained tokenizer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SerializedClaimSet {
    claim_text: String,
    evidence_text: String,
}

impl SerializedClaimSet {
    /// Structured claim sequence.
    #[must_use]
    pub fn claim_text(&self) -> &str {
        &self.claim_text
    }

    /// Ranked evidence sequence with host-owned slot markers.
    #[must_use]
    pub fn evidence_text(&self) -> &str {
        &self.evidence_text
    }
}

/// Serialize one claim and its immutable evidence slots for model input.
///
/// Slot-marker lookalikes in source text are escaped only in this model view;
/// canonical event bytes and the citations bound by `EvidenceSet` are unchanged.
#[must_use]
pub fn serialize_claim_set(
    claim: &ProposedClaim,
    evidence: &EvidenceSet<'_>,
) -> SerializedClaimSet {
    let claim_text = format!(
        "subject: {}\npredicate: {}\nobject: {}\nscope: {}",
        normalize_model_text(claim.subject()),
        normalize_model_text(claim.predicate()),
        normalize_model_text(claim.object()),
        normalize_model_text(claim.scope()),
    );
    let mut evidence_text = String::new();
    for (slot, span) in evidence.iter().enumerate() {
        if slot > 0 {
            evidence_text.push('\n');
        }
        write!(
            &mut evidence_text,
            "{} {} {}",
            SLOT_START_MARKERS[slot],
            normalize_model_text(span.exact_text()),
            SLOT_END_MARKERS[slot],
        )
        .expect("writing to a String cannot fail");
    }
    SerializedClaimSet {
        claim_text,
        evidence_text,
    }
}

fn normalize_model_text(value: &str) -> String {
    let mut normalized = value.split_whitespace().collect::<Vec<_>>().join(" ");
    for marker in SLOT_START_MARKERS.into_iter().chain(SLOT_END_MARKERS) {
        let escaped = marker.replace('[', "(").replace(']', ")");
        normalized = replace_ascii_case_insensitive(&normalized, marker, &escaped);
    }
    normalized
}

fn replace_ascii_case_insensitive(value: &str, needle: &str, replacement: &str) -> String {
    let lowered = value.to_ascii_lowercase();
    let mut output = String::with_capacity(value.len());
    let mut cursor = 0;
    while let Some(relative) = lowered[cursor..].find(needle) {
        let start = cursor + relative;
        output.push_str(&value[cursor..start]);
        output.push_str(replacement);
        cursor = start + needle.len();
    }
    output.push_str(&value[cursor..]);
    output
}

/// Decode fixed-shape model logits into a host-bindable verdict.
///
/// Class order is frozen as `supported`, `contradicted`, `insufficient`.
/// Citation logits use sigmoid probabilities in host slot order. A citation
/// above threshold for a slot absent from the tokenized input is invalid.
pub fn decode_claim_logits(
    judgment_logits: &[f32],
    citation_logits: &[f32],
    visible_slots: &[usize],
    thresholds: ClaimVerifierThresholds,
) -> Result<EvidenceSlotVerdict, MobileBertClaimError> {
    if judgment_logits.len() != JUDGMENT_CLASS_COUNT {
        return Err(MobileBertClaimError::Output(format!(
            "judgment logit count {} != {JUDGMENT_CLASS_COUNT}",
            judgment_logits.len()
        )));
    }
    if citation_logits.len() != MAX_VERIFIER_EVIDENCE_SLOTS {
        return Err(MobileBertClaimError::Output(format!(
            "citation logit count {} != {MAX_VERIFIER_EVIDENCE_SLOTS}",
            citation_logits.len()
        )));
    }
    if judgment_logits
        .iter()
        .chain(citation_logits)
        .any(|v| !v.is_finite())
    {
        return Err(MobileBertClaimError::Output(
            "all logits must be finite".to_owned(),
        ));
    }
    let visible = visible_slots.iter().copied().collect::<HashSet<_>>();
    if visible.is_empty()
        || visible.len() != visible_slots.len()
        || visible
            .iter()
            .any(|slot| *slot >= MAX_VERIFIER_EVIDENCE_SLOTS)
    {
        return Err(MobileBertClaimError::Input(
            "visible slots must be nonempty, unique, and in range".to_owned(),
        ));
    }

    let probabilities = softmax_three(judgment_logits)?;
    let mut classes = [0_usize, 1, 2];
    classes.sort_by(|left, right| probabilities[*right].total_cmp(&probabilities[*left]));
    let top_class = classes[0];
    let top_probability = probabilities[top_class];
    let margin = top_probability - probabilities[classes[1]];

    if top_class == 2 {
        return Ok(EvidenceSlotVerdict::Insufficient {
            confidence: top_probability,
        });
    }
    if top_probability < thresholds.judgment_probability || margin < thresholds.judgment_margin {
        return Ok(EvidenceSlotVerdict::Abstained {
            strongest_class_confidence: top_probability,
        });
    }

    let mut citation_slots = Vec::new();
    for (slot, logit) in citation_logits.iter().copied().enumerate() {
        if sigmoid(logit) < thresholds.citation_probability {
            continue;
        }
        if !visible.contains(&slot) {
            return Err(MobileBertClaimError::Output(format!(
                "model selected nonvisible citation slot {slot}"
            )));
        }
        citation_slots.push(slot);
    }
    if citation_slots.is_empty() {
        return Err(MobileBertClaimError::Output(
            "support or contradiction selected no visible citation slots".to_owned(),
        ));
    }

    match top_class {
        0 => Ok(EvidenceSlotVerdict::Supported {
            confidence: top_probability,
            citation_slots,
        }),
        1 => Ok(EvidenceSlotVerdict::Contradicted {
            confidence: top_probability,
            citation_slots,
        }),
        _ => unreachable!("three-class index already validated"),
    }
}

fn softmax_three(logits: &[f32]) -> Result<[f32; 3], MobileBertClaimError> {
    let max = logits.iter().copied().fold(f32::NEG_INFINITY, f32::max);
    let exps = [
        (logits[0] - max).exp(),
        (logits[1] - max).exp(),
        (logits[2] - max).exp(),
    ];
    let sum = exps.iter().sum::<f32>();
    if !sum.is_finite() || sum <= 0.0 {
        return Err(MobileBertClaimError::Output(
            "judgment softmax was not finite".to_owned(),
        ));
    }
    Ok([exps[0] / sum, exps[1] / sum, exps[2] / sum])
}

fn sigmoid(logit: f32) -> f32 {
    if logit >= 0.0 {
        1.0 / (1.0 + (-logit).exp())
    } else {
        let exp = logit.exp();
        exp / (1.0 + exp)
    }
}

#[derive(Debug)]
struct EncodedClaimSet {
    input_ids: Vec<i32>,
    attention_mask: Vec<i32>,
    token_type_ids: Vec<i32>,
    visible_slots: Vec<usize>,
}

#[derive(Debug, Clone, Copy)]
struct SlotMarkerIds {
    starts: [u32; MAX_VERIFIER_EVIDENCE_SLOTS],
    ends: [u32; MAX_VERIFIER_EVIDENCE_SLOTS],
}

/// Native fixed-shape verifier for a task-trained `MobileBERT` artifact.
#[derive(Debug)]
pub struct MobileBertClaimVerifier {
    model: CoreMLModel,
    tokenizer: Tokenizer,
    thresholds: ClaimVerifierThresholds,
    marker_ids: SlotMarkerIds,
}

impl MobileBertClaimVerifier {
    /// Open a compiled model and its exact tokenizer with qualified thresholds.
    pub fn open(
        model_path: &Path,
        tokenizer_path: &Path,
        manifest_path: &Path,
    ) -> Result<Self, MobileBertClaimError> {
        let thresholds =
            validate_claim_verifier_manifest(manifest_path, model_path, tokenizer_path)?;
        let model = CoreMLModel::load_with_compute_units(model_path, ComputeUnits::CpuOnly)?;
        let tokenizer = Tokenizer::from_file(tokenizer_path).map_err(|error| {
            MobileBertClaimError::Tokenizer(format!("{}: {error}", tokenizer_path.display()))
        })?;
        let marker_ids = marker_ids(&tokenizer)?;
        let backend = Self {
            model,
            tokenizer,
            thresholds,
            marker_ids,
        };
        backend.verify_schema()?;
        Ok(backend)
    }

    fn verify_schema(&self) -> Result<(), MobileBertClaimError> {
        for name in ["input_ids", "attention_mask", "token_type_ids"] {
            let expected = MultiArraySchema {
                shape: vec![1, CLAIM_VERIFIER_SEQUENCE_LENGTH],
                element_type: MultiArrayElementType::Int32,
            };
            if self.model.input_multi_array_schema(name) != Some(expected) {
                return Err(MobileBertClaimError::Schema(format!(
                    "input {name:?} is not fixed Int32 [1, {CLAIM_VERIFIER_SEQUENCE_LENGTH}]"
                )));
            }
        }
        for (name, width) in [
            ("judgment_logits", JUDGMENT_CLASS_COUNT),
            ("citation_logits", MAX_VERIFIER_EVIDENCE_SLOTS),
        ] {
            let Some(schema) = self.model.output_multi_array_schema(name) else {
                return Err(MobileBertClaimError::Schema(format!(
                    "missing MultiArray output {name:?}"
                )));
            };
            if schema.shape != [1, width]
                || !matches!(
                    schema.element_type,
                    MultiArrayElementType::Float16 | MultiArrayElementType::Float32
                )
            {
                return Err(MobileBertClaimError::Schema(format!(
                    "output {name:?} is not floating [1, {width}]"
                )));
            }
        }
        Ok(())
    }

    fn verify_inner(
        &self,
        claim: &ProposedClaim,
        evidence: &EvidenceSet<'_>,
    ) -> Result<EvidenceSlotVerdict, MobileBertClaimError> {
        if !evidence.validates_claim_scope(claim) {
            return Err(MobileBertClaimError::Input(
                "evidence set is not authorized for the proposed-claim scope".to_owned(),
            ));
        }
        let serialized = serialize_claim_set(claim, evidence);
        let encoded = encode_claim_set(&self.tokenizer, &serialized, self.marker_ids)?;
        let input_ids =
            model::multi_array_i32(&[1, CLAIM_VERIFIER_SEQUENCE_LENGTH], &encoded.input_ids)?;
        let attention_mask = model::multi_array_i32(
            &[1, CLAIM_VERIFIER_SEQUENCE_LENGTH],
            &encoded.attention_mask,
        )?;
        let token_type_ids = model::multi_array_i32(
            &[1, CLAIM_VERIFIER_SEQUENCE_LENGTH],
            &encoded.token_type_ids,
        )?;
        let prediction = self.model.predict(&[
            ("input_ids", &input_ids),
            ("attention_mask", &attention_mask),
            ("token_type_ids", &token_type_ids),
        ])?;
        let judgment = prediction.multi_array("judgment_logits")?;
        let citations = prediction.multi_array("citation_logits")?;
        if model::multi_array_len(&judgment) != JUDGMENT_CLASS_COUNT
            || model::multi_array_len(&citations) != MAX_VERIFIER_EVIDENCE_SLOTS
        {
            return Err(MobileBertClaimError::Output(
                "model outputs do not match the frozen [3] and [8] shapes".to_owned(),
            ));
        }
        let judgment_logits = model::read_f32_slice(&judgment, 0, JUDGMENT_CLASS_COUNT)?;
        let citation_logits = model::read_f32_slice(&citations, 0, MAX_VERIFIER_EVIDENCE_SLOTS)?;
        decode_claim_logits(
            &judgment_logits,
            &citation_logits,
            &encoded.visible_slots,
            self.thresholds,
        )
    }
}

impl ClaimEvidenceVerifier for MobileBertClaimVerifier {
    fn verify_claim(
        &self,
        claim: &ProposedClaim,
        evidence: &EvidenceSet<'_>,
    ) -> Result<EvidenceSlotVerdict, EvidenceVerifierError> {
        self.verify_inner(claim, evidence)
            .map_err(|error| match error {
                MobileBertClaimError::Output(_) | MobileBertClaimError::Input(_) => {
                    EvidenceVerifierError::InvalidOutput(error.to_string())
                }
                _ => EvidenceVerifierError::Unavailable(error.to_string()),
            })
    }
}

fn marker_ids(tokenizer: &Tokenizer) -> Result<SlotMarkerIds, MobileBertClaimError> {
    let unknown = tokenizer.token_to_id("[UNK]");
    let mut starts = [0_u32; MAX_VERIFIER_EVIDENCE_SLOTS];
    let mut ends = [0_u32; MAX_VERIFIER_EVIDENCE_SLOTS];
    let mut seen = HashSet::with_capacity(MAX_VERIFIER_EVIDENCE_SLOTS * 2);
    for (slot, marker) in SLOT_START_MARKERS.iter().enumerate() {
        starts[slot] = validated_marker_id(tokenizer, marker, unknown, &mut seen)?;
    }
    for (slot, marker) in SLOT_END_MARKERS.iter().enumerate() {
        ends[slot] = validated_marker_id(tokenizer, marker, unknown, &mut seen)?;
    }
    Ok(SlotMarkerIds { starts, ends })
}

fn validated_marker_id(
    tokenizer: &Tokenizer,
    marker: &str,
    unknown: Option<u32>,
    seen: &mut HashSet<u32>,
) -> Result<u32, MobileBertClaimError> {
    let id = tokenizer.token_to_id(marker).ok_or_else(|| {
        MobileBertClaimError::Schema(format!("tokenizer is missing slot marker {marker}"))
    })?;
    if Some(id) == unknown || !seen.insert(id) {
        return Err(MobileBertClaimError::Schema(format!(
            "slot marker {marker} does not have a unique non-UNK token"
        )));
    }
    let encoded = tokenizer
        .encode(marker, false)
        .map_err(|error| MobileBertClaimError::Tokenizer(error.to_string()))?;
    if encoded.get_ids() != [id] {
        return Err(MobileBertClaimError::Schema(format!(
            "slot marker {marker} does not encode as its single vocabulary token"
        )));
    }
    Ok(id)
}

fn encode_claim_set(
    tokenizer: &Tokenizer,
    serialized: &SerializedClaimSet,
    marker_ids: SlotMarkerIds,
) -> Result<EncodedClaimSet, MobileBertClaimError> {
    let mut tokenizer = tokenizer.clone();
    tokenizer.with_padding(Some(PaddingParams {
        strategy: PaddingStrategy::Fixed(CLAIM_VERIFIER_SEQUENCE_LENGTH),
        direction: PaddingDirection::Right,
        pad_to_multiple_of: None,
        pad_id: 0,
        pad_type_id: 0,
        pad_token: "[PAD]".to_owned(),
    }));
    tokenizer
        .with_truncation(Some(TruncationParams {
            max_length: CLAIM_VERIFIER_SEQUENCE_LENGTH,
            strategy: TruncationStrategy::OnlySecond,
            stride: 0,
            direction: TruncationDirection::Right,
        }))
        .map_err(|error| MobileBertClaimError::Tokenizer(error.to_string()))?;
    let encoding = tokenizer
        .encode((serialized.claim_text(), serialized.evidence_text()), true)
        .map_err(|error| MobileBertClaimError::Tokenizer(error.to_string()))?;

    if encoding.len() != CLAIM_VERIFIER_SEQUENCE_LENGTH {
        return Err(MobileBertClaimError::Input(format!(
            "tokenizer output length {} != {CLAIM_VERIFIER_SEQUENCE_LENGTH}",
            encoding.len()
        )));
    }
    let ids = encoding.get_ids();
    let attention = encoding.get_attention_mask();
    let type_ids = encoding.get_type_ids();
    let offsets = encoding.get_offsets();
    let mut visible_slots = Vec::new();
    for slot in 0..MAX_VERIFIER_EVIDENCE_SLOTS {
        let Some(start) = ids.iter().enumerate().find_map(|(index, id)| {
            (*id == marker_ids.starts[slot] && type_ids[index] == 1 && attention[index] == 1)
                .then_some(index)
        }) else {
            continue;
        };
        let Some(end) = ((start + 1)..ids.len()).find(|index| {
            ids[*index] == marker_ids.ends[slot] && type_ids[*index] == 1 && attention[*index] == 1
        }) else {
            continue;
        };
        let has_content = ((start + 1)..end)
            .any(|index| attention[index] == 1 && offsets[index].0 < offsets[index].1);
        if has_content {
            visible_slots.push(slot);
        }
    }
    if visible_slots.is_empty() {
        return Err(MobileBertClaimError::Input(
            "no complete evidence slot fit the frozen token window".to_owned(),
        ));
    }

    Ok(EncodedClaimSet {
        input_ids: u32_to_i32(ids)?,
        attention_mask: u32_to_i32(attention)?,
        token_type_ids: u32_to_i32(type_ids)?,
        visible_slots,
    })
}

fn u32_to_i32(values: &[u32]) -> Result<Vec<i32>, MobileBertClaimError> {
    values
        .iter()
        .map(|value| {
            i32::try_from(*value).map_err(|_| {
                MobileBertClaimError::Input(format!("token value {value} exceeds Int32"))
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use tokenizers::models::wordlevel::WordLevel;
    use tokenizers::pre_tokenizers::whitespace::{Whitespace, WhitespaceSplit};
    use tokenizers::processors::template::TemplateProcessing;

    use super::*;

    fn fixture_tokenizer() -> Tokenizer {
        let mut vocab = HashMap::from([
            ("[UNK]".to_owned(), 0),
            ("[CLS]".to_owned(), 1),
            ("[SEP]".to_owned(), 2),
            ("[PAD]".to_owned(), 3),
            ("claim".to_owned(), 20),
            ("word".to_owned(), 21),
            ("second".to_owned(), 22),
        ]);
        for (slot, marker) in SLOT_START_MARKERS
            .iter()
            .chain(SLOT_END_MARKERS.iter())
            .enumerate()
        {
            vocab.insert((*marker).to_owned(), u32::try_from(slot + 4).unwrap());
        }
        let model = WordLevel::builder()
            .vocab(vocab)
            .unk_token("[UNK]".to_owned())
            .build()
            .unwrap();
        let mut tokenizer = Tokenizer::new(model);
        tokenizer.with_pre_tokenizer(Some(WhitespaceSplit));
        tokenizer.with_post_processor(Some(
            TemplateProcessing::builder()
                .try_single("[CLS] $A [SEP]")
                .unwrap()
                .try_pair("[CLS]:0 $A:0 [SEP]:0 $B:1 [SEP]:1")
                .unwrap()
                .special_tokens(vec![("[CLS]", 1), ("[SEP]", 2)])
                .build()
                .unwrap(),
        ));
        tokenizer
    }

    #[test]
    fn fixed_window_marks_only_evidence_slots_with_tokenized_content() {
        let tokenizer = fixture_tokenizer();
        let serialized = SerializedClaimSet {
            claim_text: "claim".to_owned(),
            evidence_text: format!(
                "[unused1] word [unused9]\n[unused2] {} [unused10]",
                vec!["word"; CLAIM_VERIFIER_SEQUENCE_LENGTH].join(" ")
            ),
        };

        let encoded = encode_claim_set(
            &tokenizer,
            &serialized,
            marker_ids(&tokenizer).expect("slot markers"),
        )
        .expect("fixed-shape encoding");

        assert_eq!(encoded.input_ids.len(), CLAIM_VERIFIER_SEQUENCE_LENGTH);
        assert_eq!(encoded.attention_mask.len(), CLAIM_VERIFIER_SEQUENCE_LENGTH);
        assert_eq!(encoded.token_type_ids.len(), CLAIM_VERIFIER_SEQUENCE_LENGTH);
        assert_eq!(encoded.visible_slots, vec![0]);
    }

    #[test]
    fn marker_validation_rejects_vocab_entries_split_by_the_pipeline() {
        let mut tokenizer = fixture_tokenizer();
        tokenizer.with_pre_tokenizer(Some(Whitespace));

        assert!(matches!(
            marker_ids(&tokenizer),
            Err(MobileBertClaimError::Schema(message))
                if message.contains("does not encode as its single vocabulary token")
        ));
    }
}
