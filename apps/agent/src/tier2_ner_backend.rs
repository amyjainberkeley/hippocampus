//! V2-P5+ — `dslim/bert-base-NER`-backed [`NerBackend`] for the **sync**
//! Tier-2 NER tier (the ratified hot-path entity extractor).
//!
//! Wraps the generic Core ML wrapper ([`mci_coreml_bridge::CoreMLModel`])
//! and runs the **exact P2′ production inference path** the #297 bake-off
//! scored — so the F1 measured there is the F1 that ships:
//!
//! ```text
//! text ─▶ NerWordPieceTokenizer.encode (P2′, byte offsets)
//!      ─▶ MLMultiArray[input_ids, attention_mask]
//!      ─▶ CoreMLModel.predict  (cpu_only)            ─▶ logits[1, seq, 9]
//!      ─▶ decode_bio (P2′ BIO span-merge, bert id2label) ─▶ DecodedSpan{kind, byte span}
//!      ─▶ Tier2RawMatch{kind, canonical_name, mention_text, span, confidence}
//! ```
//!
//! `NerWordPieceTokenizer` + `decode_bio` are the committed P2′ pieces
//! (`core/brain/src/extraction/tier2_ner/`, PR #296) — reused verbatim.
//! The bundled WordPiece tokenizer is byte-identical to bert-base-NER's
//! own tokenizer (same bert-base-cased vocab + normalizer + pre/post-
//! processor), so `load_bundled()` needs no model-side tokenizer file.
//!
//! # Compute units — CPU ONLY (never `all`)
//!
//! bert-base's flexible `logits[1, ?, 9]` output disables the data-
//! dependent GPU path (152 ms) and the ANE is RED for the per-token head
//! ([[reference-coreml-computeunits-all-trap]], measured PR #297). CPU is
//! 23 ms / ~220 MB resident — well inside the G2 SLO. This backend pins
//! [`ComputeUnits::CpuOnly`] and MUST NOT inherit the
//! [`CoreMLModel::load`] default (`ComputeUnits::All`, the latency trap).
//!
//! # Cascade / REDACT discipline
//!
//! Same posture as [`crate::tier2_qwen_backend`]: this backend operates on
//! `events.text`, already cascade-twice-cleared. It does NOT re-litigate
//! cascade — the [`mci_brain::Tier2Extractor`] above it applies the
//! cascade-marker SKIP + token-REDACT downstream SKIP filters before any
//! mention is persisted.
//!
//! # OS purity
//!
//! macOS-only (Core ML). The unsafe Core ML FFI stays below the
//! `mci-coreml-bridge` adapter seam; this module — like the rest of
//! `apps/agent` — is `#![forbid(unsafe_code)]` and only calls the bridge's
//! safe wrappers. The portable `apps/agent::brain_ingest` holds this
//! backend as an `Arc<dyn NerBackend>` trait object, so `core/` and the
//! ingest path stay OS-free.

use std::path::Path;
use std::sync::Arc;

use mci_brain::extraction::tier2_ner::{decode_bio, NerWordPieceTokenizer};
use mci_brain::{NerBackend, NerError, Tier2RawMatch};
use mci_coreml_bridge::model::{multi_array_i32, multi_array_len, read_f32_slice};
use mci_coreml_bridge::{ComputeUnits, CoreMLModel};

/// `dslim/bert-base-NER` `CoNLL` BIO `id2label` (cased). The order matches
/// the model's `config.json` / `models/bert_base_NER_labels.json` —
/// `B-MISC` at index 1, which is **distinct** from the distilbert order
/// (`B-PER` at 1). [`decode_bio`] maps `B-/I-PER → person_name`,
/// `ORG → organization`, `LOC → location` and DROPS `MISC` / `O`. Pinned
/// by [`tests::id2label_matches_committed_labels_file`] against the
/// converter's sidecar when present.
const BERT_BASE_NER_ID2LABEL: [&str; 9] = [
    "O", "B-MISC", "I-MISC", "B-PER", "I-PER", "B-ORG", "I-ORG", "B-LOC", "I-LOC",
];

/// Core ML `RangeDim` cap for the bert-base-NER token-classifier input.
/// Events whose natural token length exceeds this are right-truncated via
/// `encode_padded`; screen-text events are far shorter in practice
/// (`n_truncated = 0` across the #297 corpus), so this is a guard, not a
/// common path.
const MAX_SEQ_LEN: usize = 256;

/// A [`NerBackend`] that runs `dslim/bert-base-NER` (INT8) on CPU via Core ML.
pub struct NerTier2Backend {
    model: CoreMLModel,
    tokenizer: Arc<NerWordPieceTokenizer>,
    max_len: usize,
}

impl NerTier2Backend {
    /// Load the bert-base-NER INT8 model from `model_path` (a compiled
    /// `.mlmodelc`) plus the bundled `WordPiece` tokenizer, pinned to
    /// **CPU-only** compute units.
    ///
    /// # Errors
    /// [`NerError::Backend`] if the bundled tokenizer fails to parse (a
    /// corrupted build artifact) or the Core ML model fails to load
    /// (missing / incompatible `.mlmodelc`).
    pub fn load(model_path: &Path) -> Result<Self, NerError> {
        let tokenizer = NerWordPieceTokenizer::load_bundled()
            .map_err(|e| NerError::Backend(format!("load bundled ner tokenizer: {e}")))?;
        let model = CoreMLModel::load_with_compute_units(model_path, ComputeUnits::CpuOnly)
            .map_err(|e| {
                NerError::Backend(format!("load bert-base-NER {}: {e}", model_path.display()))
            })?;
        Ok(Self {
            model,
            tokenizer,
            max_len: MAX_SEQ_LEN,
        })
    }
}

impl std::fmt::Debug for NerTier2Backend {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NerTier2Backend")
            .field("max_len", &self.max_len)
            .finish_non_exhaustive()
    }
}

impl NerBackend for NerTier2Backend {
    fn extract_entities(&self, text: &str) -> Result<Vec<Tier2RawMatch>, NerError> {
        if text.trim().is_empty() {
            return Err(NerError::InvalidInput("empty text".into()));
        }

        // Natural-length encode; only pad/truncate when the event overflows
        // the model's RangeDim cap (keeps realistic latency on short events).
        let natural = self
            .tokenizer
            .encode(text)
            .map_err(|e| NerError::Backend(format!("encode: {e}")))?;
        let enc = if natural.input_ids.len() > self.max_len {
            self.tokenizer
                .encode_padded(text, self.max_len)
                .map_err(|e| NerError::Backend(format!("encode_padded: {e}")))?
        } else {
            natural
        };
        let seq_len = enc.input_ids.len();
        let num_labels = BERT_BASE_NER_ID2LABEL.len();

        let ids = multi_array_i32(&[1, seq_len], &enc.input_ids)
            .map_err(|e| NerError::Backend(e.to_string()))?;
        let mask = multi_array_i32(&[1, seq_len], &enc.attention_mask)
            .map_err(|e| NerError::Backend(e.to_string()))?;

        let pred = self
            .model
            .predict(&[("input_ids", &*ids), ("attention_mask", &*mask)])
            .map_err(|e| NerError::Backend(format!("predict: {e}")))?;
        let logits_arr = pred
            .multi_array("logits")
            .map_err(|e| NerError::Backend(e.to_string()))?;

        // Output is logits [1, seq, num_labels]; recover the real element
        // count rather than trusting a fixed shape.
        let want = seq_len * num_labels;
        let have = multi_array_len(&logits_arr);
        if have < want {
            return Err(NerError::Parse(format!(
                "logits len {have} < expected {want} (seq={seq_len})"
            )));
        }
        let logits =
            read_f32_slice(&logits_arr, 0, want).map_err(|e| NerError::Backend(e.to_string()))?;

        // decode_bio maps BIO → MCI kind strings and drops O/MISC; the
        // returned DecodedSpan.kind is already person_name/organization/
        // location, and DecodedSpan.text is the verified source substring.
        let spans = decode_bio(
            text,
            &logits,
            seq_len,
            num_labels,
            &enc.offsets,
            &enc.special_tokens_mask,
            &enc.attention_mask,
            &BERT_BASE_NER_ID2LABEL,
        );

        let out = spans
            .into_iter()
            .map(|s| Tier2RawMatch {
                kind: s.kind,
                // canonical_name == surface for now; the V2-P6 AliasResolver
                // normalizes + clusters aliases under one EntityId later.
                canonical_name: s.text.clone(),
                mention_text: s.text,
                span_start: s.span_start,
                span_end: s.span_end,
                confidence: s.confidence,
            })
            .collect();
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::time::Instant;

    /// Candidate locations for the bert-base-NER INT8 `.mlmodelc` (gitignored;
    /// converted by `scripts/convert_ner.py`, bundled in P6). Tests that need
    /// the real model skip gracefully when none is present.
    fn locate_model() -> Option<PathBuf> {
        if let Some(p) = std::env::var_os("MCI_NER_MODEL_PATH") {
            let p = PathBuf::from(p);
            if p.exists() {
                return Some(p);
            }
        }
        let home = std::env::var_os("HOME").map(PathBuf::from)?;
        let candidates = [
            home.join("Documents/GitHub/mci/models/bert_base_NER_INT8.mlmodelc"),
            PathBuf::from("models/bert_base_NER_INT8.mlmodelc"),
        ];
        candidates.into_iter().find(|p| p.exists())
    }

    #[test]
    fn id2label_has_bert_base_order_not_distilbert() {
        // bert-base leads O, B-MISC, …; distilbert leads O, B-PER, … —
        // a silent swap here would corrupt every decoded span's kind.
        assert_eq!(BERT_BASE_NER_ID2LABEL[1], "B-MISC");
        assert_eq!(BERT_BASE_NER_ID2LABEL[3], "B-PER");
        assert_eq!(BERT_BASE_NER_ID2LABEL.len(), 9);
    }

    #[test]
    fn id2label_matches_committed_labels_file_when_present() {
        // Cross-check the hardcoded order against the converter sidecar
        // (gitignored; present on the dev/conversion box). Skips in CI.
        let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
            return;
        };
        let labels = home.join("Documents/GitHub/mci/models/bert_base_NER_labels.json");
        if !labels.exists() {
            return;
        }
        let raw = std::fs::read_to_string(&labels).expect("read labels");
        // Minimal parse: find each "N": "LABEL" pair for N in 0..9.
        for (i, expect) in BERT_BASE_NER_ID2LABEL.iter().enumerate() {
            let needle = format!("\"{i}\": \"{expect}\"");
            assert!(
                raw.contains(&needle),
                "labels.json missing {needle} — hardcoded id2label drifted from the converted model"
            );
        }
    }

    #[test]
    fn backend_rejects_empty_input() {
        let Some(model_path) = locate_model() else {
            eprintln!("skip: bert-base-NER model not present");
            return;
        };
        let backend = NerTier2Backend::load(&model_path).expect("load");
        assert!(matches!(
            backend.extract_entities("   "),
            Err(NerError::InvalidInput(_))
        ));
    }

    /// Real-model smoke: the wired tokenize → Core ML → decode path
    /// recovers the obvious Person / Org / Location from a clean sentence.
    /// This is the on-device decoder-parity check for the *bert* id2label
    /// (the committed golden fixtures pin *distilbert*); skips if the model
    /// is absent.
    #[test]
    fn backend_decodes_known_entities_on_device() {
        let Some(model_path) = locate_model() else {
            eprintln!("skip: bert-base-NER model not present (set MCI_NER_MODEL_PATH)");
            return;
        };
        let backend = NerTier2Backend::load(&model_path).expect("load model");
        let text = "Barack Obama visited Microsoft in Seattle last week.";
        let out = backend.extract_entities(text).expect("extract");

        // Every span must verify against the source (the decoder guarantees
        // this; assert it here as the wired-path invariant).
        for m in &out {
            assert_eq!(
                &text[m.span_start..m.span_end],
                m.mention_text,
                "span must slice the source substring"
            );
            assert!((0.0..=1.0).contains(&m.confidence));
        }
        let kinds: Vec<&str> = out.iter().map(|m| m.kind.as_str()).collect();
        assert!(
            kinds.contains(&"person_name"),
            "expected a person_name (Barack Obama); got {out:?}"
        );
        assert!(
            kinds.contains(&"organization"),
            "expected an organization (Microsoft); got {out:?}"
        );
        assert!(
            kinds.contains(&"location"),
            "expected a location (Seattle); got {out:?}"
        );
    }

    /// On-device wired-path latency smoke (footprint confirm). Ignored by
    /// default — run with `--ignored` on a Mac with the model present:
    /// `cargo test -p mci-agent --release tier2_ner_backend -- --ignored --nocapture`.
    /// Prints per-call latency for the WIRED backend (tokenize + CPU Core ML
    /// + decode), which should track the #297 bake-off CPU envelope (~24 ms).
    #[test]
    #[ignore = "needs the bert-base-NER model on disk; run on-device for footprint confirm"]
    fn backend_latency_smoke() {
        let model_path = locate_model().expect("model required for --ignored run");
        let backend = NerTier2Backend::load(&model_path).expect("load");
        let texts = [
            "Alice from the Brain team flagged a regression in Cupertino.",
            "Met Dr. Chen at Stanford to discuss the Anthropic partnership in San Francisco.",
            "The Northwind Aviation team shipped from Building 4 in Seattle on Tuesday.",
        ];
        // Warm up (first-inference / shape-compile cost excluded).
        for _ in 0..3 {
            let _ = backend.extract_entities(texts[0]);
        }
        let mut samples = Vec::new();
        for i in 0..30 {
            let t = texts[i % texts.len()];
            let start = Instant::now();
            let _ = backend.extract_entities(t).expect("extract");
            samples.push(start.elapsed().as_secs_f64() * 1000.0);
        }
        samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let p50 = samples[samples.len() / 2];
        let p95 = samples[samples.len() * 95 / 100];
        eprintln!(
            "wired NerTier2Backend extract latency: p50={p50:.1}ms p95={p95:.1}ms (cpu_only)"
        );
        assert!(
            p50 < 200.0,
            "wired p50 {p50:.1}ms unexpectedly high for cpu_only bert"
        );
    }
}
