//! Qwen3-1.7B brief-author shim over the generic [`crate::model`] core.
//!
//! Implements [`mci_brief::llama_backend::LlamaBackend`] using a
//! [`CoreMLModel`]. The wrapper (`mci_brief::llama_author::LlamaBriefAuthor`)
//! handles prompt rendering, citation parsing, and the hallucination
//! tripwire above this crate. This shim: tokenize, run the
//! autoregressive decode through Core ML, detokenize, return raw text.
//!
//! # Model (ADR-0028)
//!
//! Qwen3-1.7B FP16 via `coremltools` 8.x. ~950 MB on disk, ~400-500 MB
//! in memory during inference. Downloaded on demand to
//! `~/Library/Application Support/MCI/Models/`.
//!
//! # Expected `.mlmodelc` schema (`scripts/convert_brief_model.py`)
//!
//! - **Input:** `"input_ids"`, `MultiArray` `Int32` `[1, SEQ_LEN]`
//! - **Input:** `"attention_mask"`, `MultiArray` `Int32` `[1, SEQ_LEN]`
//! - **Output:** `"logits"`, `MultiArray` `Float16` `[1, SEQ_LEN, VOCAB]`
//!
//! SEQ_LEN is fixed at conversion time (default 2048). The model is
//! stateless; the Rust side pads shorter sequences and constructs an
//! attention_mask (1 = real token, 0 = padding).

use std::path::Path;

use mci_brief::llama_backend::{GenerateError, LlamaBackend};
use objc2_core_ml::MLMultiArray;

use crate::model::{self, CoreMLError, CoreMLModel};
use crate::tokenizer::BpeTokenizer;

const MAX_OUTPUT_TOKENS: usize = 512;
const DEFAULT_SEQ_LEN: usize = 2048;
/// Temperature for the brief author. 0.3 = much lower variance than
/// generic-chat 0.7; for structured-output tasks (citation markers,
/// bullet structure) this keeps the model on-task across fixtures.
/// Cycle 8.10 brief-eval: 0.7 caused 7/8 fixtures to silently drop
/// citation markers; 0.3 holds the structure with no quality loss on
/// the prose itself.
const DEFAULT_TEMPERATURE: f32 = 0.3;
const DEFAULT_TOP_P: f32 = 0.9;
/// HuggingFace `generate()` default. Penalizes tokens that have
/// recently appeared by dividing their logit (or multiplying if
/// negative) by this factor. Critical for INT4-palettized 1.7B-class
/// models whose output otherwise collapses into 4-token repetitive
/// loops (e.g. "ICKABLE\n" × 50, cycle 8.10 brief-eval).
const DEFAULT_REPETITION_PENALTY: f32 = 1.15;
/// How many recent tokens the repetition penalty applies to. Matches
/// llama.cpp's `--repeat-last-n` default. Bounded by `MAX_OUTPUT_TOKENS`
/// since a longer window has no effect on short generations.
const REPETITION_WINDOW: usize = 64;

/// Map a generic [`CoreMLError`] into the brief-author error surface,
/// preserving the human-readable message.
fn map_coreml(err: CoreMLError) -> GenerateError {
    GenerateError::Backend(err.to_string())
}

/// Core ML backend for Qwen3-1.7B brief generation.
pub struct Qwen3CoreMLBackend {
    model: CoreMLModel,
    tokenizer: BpeTokenizer,
    seq_len: usize,
}

impl std::fmt::Debug for Qwen3CoreMLBackend {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Qwen3CoreMLBackend")
            .field("tokenizer", &self.tokenizer)
            .finish_non_exhaustive()
    }
}

impl Qwen3CoreMLBackend {
    /// Load the `.mlmodelc` at `model_path` and the tokenizer from
    /// `tokenizer_dir` (containing `tokenizer.json`).
    pub fn open(model_path: &Path, tokenizer_dir: &Path) -> Result<Self, GenerateError> {
        // The generic core validates the path (empty / not-found) and
        // loads the model first, matching the original ordering so the
        // "model not found" message still wins over a tokenizer error.
        let model = CoreMLModel::load(model_path).map_err(map_coreml)?;
        let tokenizer = BpeTokenizer::load(tokenizer_dir)?;

        let me = Self {
            model,
            tokenizer,
            seq_len: DEFAULT_SEQ_LEN,
        };
        me.verify_schema()?;
        Ok(me)
    }

    fn verify_schema(&self) -> Result<(), GenerateError> {
        if !self.model.has_input("input_ids") {
            return Err(GenerateError::Backend(
                "model missing required input feature \"input_ids\"".into(),
            ));
        }
        if !self.model.has_input("attention_mask") {
            return Err(GenerateError::Backend(
                "model missing required input feature \"attention_mask\"".into(),
            ));
        }
        match self.model.output_is_multi_array("logits") {
            None => Err(GenerateError::Backend(
                "model missing required output feature \"logits\"".into(),
            )),
            Some(false) => Err(GenerateError::Backend(
                "output \"logits\" has unexpected feature type, expected MultiArray".into(),
            )),
            Some(true) => Ok(()),
        }
    }

    /// Run a single forward pass on the given token IDs.
    ///
    /// Pads `input_ids` to `self.seq_len` and supplies an attention_mask.
    /// Returns logits for the last real token position.
    ///
    /// # Why `attention_mask = [1; seq_len]` (all-ones), not partial
    ///
    /// `scripts/convert_brief_model.py` traces the Qwen3 graph with
    /// `attn_implementation="eager"` and `attention_mask = ones((1,
    /// seq_len))`. The transformers mask helper branches on
    /// `if (padding_length := kv_length + kv_offset
    ///     - attention_mask.shape[-1]) > 0:` — at trace time
    /// `padding_length == 0`, so `torch.jit.trace` records the False
    /// branch only and the padding-handling code is absent from the
    /// .mlmodelc graph. (`TracerWarning: Converting a tensor to a Python
    /// boolean might cause the trace to be incorrect` in the conversion
    /// log was the smoking gun.)
    ///
    /// At inference, the only mask that respects the traced contract is
    /// the same one the trace saw: all-ones. The causal mask is still
    /// applied inside the graph and is independent of `attention_mask`,
    /// so when we read logits at position `real_len - 1` we see only
    /// positions `0..real_len` — all real prompt tokens. Predictions at
    /// padded positions are garbage (the model "attends" to pad tokens
    /// there) but we never read those.
    ///
    /// Passing a partial `[1,...,1,0,...,0]` instead causes the model to
    /// predict `<|endoftext|>` as its very first generated token on
    /// every prompt — the broken trace's silent failure mode. Surfaced
    /// by ADR-0028 brief-eval (0/8 fixtures, cycle 8.10).
    fn forward_pass(&self, input_ids: &[i32]) -> Result<Vec<f32>, GenerateError> {
        let real_len = input_ids.len().min(self.seq_len);

        // Pad input_ids to fixed seq_len. The traced graph still attends
        // to these positions at queries ≥ real_len, but we only read
        // logits at `real_len - 1`, which is a real prompt token.
        let mut padded_ids = vec![0_i32; self.seq_len];
        padded_ids[..real_len].copy_from_slice(&input_ids[..real_len]);

        // attention_mask = all-ones, matching the trace's input shape.
        // See the doc comment above for why a partial mask breaks the
        // traced graph.
        let mask = vec![1_i32; self.seq_len];

        let input_arr =
            model::multi_array_i32(&[1, self.seq_len], &padded_ids).map_err(map_coreml)?;
        let mask_arr = model::multi_array_i32(&[1, self.seq_len], &mask).map_err(map_coreml)?;

        let prediction = self
            .model
            .predict(&[("input_ids", &input_arr), ("attention_mask", &mask_arr)])
            .map_err(map_coreml)?;
        let logits_arr = prediction.multi_array("logits").map_err(map_coreml)?;

        extract_last_position_logits(&logits_arr, real_len)
    }
}

impl LlamaBackend for Qwen3CoreMLBackend {
    fn generate(&self, prompt: &str) -> Result<String, GenerateError> {
        if prompt.is_empty() {
            return Err(GenerateError::InvalidPrompt("empty prompt".into()));
        }

        let debug = std::env::var("MCI_QWEN3_DEBUG").as_deref() == Ok("1");

        let mut input_ids = self.tokenizer.encode(prompt);
        let prompt_len = input_ids.len();
        let mut output_ids = Vec::with_capacity(MAX_OUTPUT_TOKENS);

        if debug {
            eprintln!(
                "[qwen3-debug] prompt_len={} prompt_tail_ids={:?}",
                prompt_len,
                &input_ids[input_ids.len().saturating_sub(8)..]
            );
        }

        for step in 0..MAX_OUTPUT_TOKENS {
            let mut logits = self.forward_pass(&input_ids)?;
            apply_repetition_penalty(
                &mut logits,
                &output_ids,
                REPETITION_WINDOW,
                DEFAULT_REPETITION_PENALTY,
            );
            let next_token = sample_token(&logits, DEFAULT_TEMPERATURE, DEFAULT_TOP_P);

            if debug && step < 16 {
                let decoded_one = self.tokenizer.decode(&[next_token]);
                eprintln!(
                    "[qwen3-debug] step={step} next_token={next_token} decoded={decoded_one:?}"
                );
            }

            if self.tokenizer.is_eos(next_token) {
                if debug {
                    eprintln!("[qwen3-debug] hit EOS at step {step} token={next_token}");
                }
                break;
            }

            output_ids.push(next_token);
            input_ids.push(next_token);

            // Stop after the citations line is complete
            let decoded = self.tokenizer.decode(&output_ids);
            if decoded.contains("###CITATIONS:") {
                let after = decoded.split("###CITATIONS:").nth(1).unwrap_or("");
                if after.contains('\n') || output_ids.len() > 64 {
                    break;
                }
            }
        }

        let full_output = self.tokenizer.decode(&input_ids[prompt_len..]);
        if debug {
            eprintln!(
                "[qwen3-debug] output_ids={} full_output_len={} full_output_head={:?}",
                output_ids.len(),
                full_output.len(),
                &full_output[..full_output.len().min(200)]
            );
        }
        Ok(full_output)
    }

    fn max_output_tokens(&self) -> usize {
        MAX_OUTPUT_TOKENS
    }
}

/// Extract logits from the last sequence position of an `MLMultiArray`.
/// Expected shapes: `[1, seq_len, vocab_size]` or `[seq_len, vocab_size]`.
#[allow(deprecated)] // shape()/objectAtIndex(): Apple-deprecated; no stable objc2 replacement.
#[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
fn extract_last_position_logits(
    arr: &MLMultiArray,
    seq_len: usize,
) -> Result<Vec<f32>, GenerateError> {
    let shape = unsafe { arr.shape() };
    let ndim = shape.count();
    if ndim < 2 {
        return Err(GenerateError::Backend(format!(
            "logits array has {ndim} dimensions, expected ≥2"
        )));
    }

    let vocab_size = shape.objectAtIndex(ndim - 1).intValue() as usize;
    let last_pos = seq_len.saturating_sub(1);
    // [1, seq_len, vocab_size] and [seq_len, vocab_size] both place the
    // last real token's logits at the same row-major offset.
    let offset = last_pos * vocab_size;

    model::read_f32_slice(arr, offset, vocab_size).map_err(map_coreml)
}

/// Temperature-based sampling with top-p (nucleus) filtering.
fn sample_token(logits: &[f32], temperature: f32, top_p: f32) -> i32 {
    if logits.is_empty() {
        return 0;
    }

    if temperature <= 0.0 {
        return argmax(logits);
    }

    // Apply temperature
    let scaled: Vec<f32> = logits.iter().map(|&l| l / temperature).collect();

    // Softmax
    let max_logit = scaled.iter().copied().fold(f32::NEG_INFINITY, f32::max);
    let exps: Vec<f32> = scaled.iter().map(|&l| (l - max_logit).exp()).collect();
    let sum: f32 = exps.iter().sum();
    let probs: Vec<f32> = exps.iter().map(|&e| e / sum).collect();

    // Top-p filtering: sort descending, accumulate until top_p
    let mut indexed: Vec<(usize, f32)> = probs.iter().copied().enumerate().collect();
    indexed.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    let mut cumulative = 0.0_f32;
    let mut candidates = Vec::new();
    for (idx, prob) in &indexed {
        cumulative += prob;
        candidates.push((*idx, *prob));
        if cumulative >= top_p {
            break;
        }
    }

    // Renormalize and sample
    let cand_sum: f32 = candidates.iter().map(|(_, p)| p).sum();
    let r = simple_random_f32();
    let mut acc = 0.0_f32;
    for (idx, prob) in &candidates {
        acc += prob / cand_sum;
        if r < acc {
            #[allow(clippy::cast_possible_truncation, clippy::cast_possible_wrap)]
            return *idx as i32;
        }
    }

    #[allow(clippy::cast_possible_truncation, clippy::cast_possible_wrap)]
    {
        candidates.last().map_or(0, |(idx, _)| *idx as i32)
    }
}

/// HuggingFace-style repetition penalty: for each token id that
/// appears in the last `window` entries of `recent_tokens`, divide its
/// logit by `penalty` (positive logits get smaller, negative get more
/// negative). `penalty = 1.0` is a no-op; the HF default is 1.0–1.3.
/// Critical for INT4-quantized models that otherwise collapse into
/// short repetitive loops.
fn apply_repetition_penalty(
    logits: &mut [f32],
    recent_tokens: &[i32],
    window: usize,
    penalty: f32,
) {
    if penalty <= 1.0 || logits.is_empty() || recent_tokens.is_empty() {
        return;
    }
    let start = recent_tokens.len().saturating_sub(window);
    for &tok in &recent_tokens[start..] {
        if let Ok(idx) = usize::try_from(tok) {
            if idx < logits.len() {
                let v = logits[idx];
                logits[idx] = if v > 0.0 { v / penalty } else { v * penalty };
            }
        }
    }
}

fn argmax(logits: &[f32]) -> i32 {
    let mut best_idx = 0;
    let mut best_val = f32::NEG_INFINITY;
    for (i, &v) in logits.iter().enumerate() {
        if v > best_val {
            best_val = v;
            best_idx = i;
        }
    }
    #[allow(clippy::cast_possible_truncation, clippy::cast_possible_wrap)]
    {
        best_idx as i32
    }
}

/// Simple deterministic-seed PRNG for token sampling.
/// NOT cryptographic — fine for text generation diversity.
fn simple_random_f32() -> f32 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static STATE: AtomicU64 = AtomicU64::new(0x5DEE_CE66_D_u64);
    let mut s = STATE.load(Ordering::Relaxed);
    s ^= s << 13;
    s ^= s >> 7;
    s ^= s << 17;
    STATE.store(s, Ordering::Relaxed);
    #[allow(clippy::cast_precision_loss)]
    {
        (s & 0xFFFF_FFFF) as f32 / 4_294_967_296.0
    }
}

/// Try loading the Qwen3 Core ML backend from model + tokenizer paths.
///
/// Expected layout:
/// ```text
/// ~/Library/Application Support/MCI/Models/<model-id>/<basename>/
///   Qwen3-1.7B-FP16.mlmodelc/   ← compiled Core ML model
///   tokenizer.json              ← HF tokenizer state
/// ```
pub fn try_load_qwen3_backend(
    model_path: &Path,
    tokenizer_dir: &Path,
) -> Result<Qwen3CoreMLBackend, GenerateError> {
    Qwen3CoreMLBackend::open(model_path, tokenizer_dir)
}

/// Load the best available backend: Qwen3 Core ML if the model exists,
/// otherwise the stub.
pub fn load_backend_or_stub(
    model_path: &Path,
    tokenizer_dir: &Path,
) -> (std::sync::Arc<dyn LlamaBackend>, bool) {
    match try_load_qwen3_backend(model_path, tokenizer_dir) {
        Ok(backend) => (std::sync::Arc::new(backend), true),
        Err(_) => (
            std::sync::Arc::new(mci_brief::llama_backend::StubLlamaBackend::default()),
            false,
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_rejects_empty_path() {
        let err =
            Qwen3CoreMLBackend::open(Path::new(""), Path::new("/tmp")).expect_err("empty path");
        assert!(matches!(err, GenerateError::Backend(_)), "{err:?}");
    }

    #[test]
    fn open_returns_error_for_missing_file() {
        let err = Qwen3CoreMLBackend::open(
            Path::new("/tmp/mci-test-nonexistent-qwen3.mlmodelc"),
            Path::new("/tmp"),
        )
        .expect_err("missing path");
        match err {
            GenerateError::Backend(msg) => assert!(
                msg.contains("not found"),
                "expected 'not found' in message, got {msg:?}"
            ),
            GenerateError::InvalidPrompt(msg) => {
                panic!("expected Backend error, got InvalidPrompt({msg:?})")
            }
        }
    }

    #[test]
    fn max_output_tokens_is_512() {
        assert_eq!(MAX_OUTPUT_TOKENS, 512);
    }

    #[test]
    fn argmax_finds_max() {
        assert_eq!(argmax(&[1.0, 3.0, 2.0]), 1);
        assert_eq!(argmax(&[5.0, 1.0, 1.0]), 0);
        assert_eq!(argmax(&[1.0, 1.0, 5.0]), 2);
    }

    #[test]
    fn sample_greedy_equals_argmax() {
        let logits = vec![1.0, 5.0, 2.0, 3.0];
        assert_eq!(sample_token(&logits, 0.0, 1.0), 1);
    }

    #[test]
    fn sample_token_returns_valid_index() {
        let logits = vec![1.0; 100];
        let token = sample_token(&logits, 1.0, 0.9);
        assert!(token >= 0 && token < 100);
    }

    #[test]
    fn load_backend_or_stub_returns_stub_for_missing() {
        let (backend, is_real) = load_backend_or_stub(
            Path::new("/nonexistent/model.mlmodelc"),
            Path::new("/nonexistent/tokenizer"),
        );
        assert!(!is_real);
        let output = backend.generate("test").unwrap();
        assert!(!output.is_empty());
    }
}
