// Gate the entire crate body on macOS — the objc2 deps are gated to the
// same target in `Cargo.toml`, so on Linux this crate compiles to an
// empty library. Same pattern as `mci-embed-coreml`.
#![cfg(target_os = "macos")]

//! macOS Core ML backend for Qwen3-1.7B INT4 brief generation.
//!
//! Implements [`mci_brief::llama_backend::LlamaBackend`] using Apple's
//! Core ML framework via `objc2-core-ml`. The wrapper
//! ([`mci_brief::llama_author::LlamaBriefAuthor`]) handles prompt
//! rendering, citation parsing, and the hallucination tripwire above
//! this crate. This crate: load the model, tokenize, run autoregressive
//! decode, detokenize, return raw text.
//!
//! # Model (ADR-0028)
//!
//! Qwen3-1.7B INT4-palettized via `coremltools` 8.x. ~950 MB on disk,
//! ~400-500 MB in memory during inference. Downloaded on demand to
//! `~/Library/Application Support/MCI/Models/Qwen3-1.7B-INT4.mlmodelc`.
//!
//! # Tokenizer
//!
//! Qwen3 uses byte-level BPE. `vocab.json` + `merges.txt` ship alongside
//! the model. The [`tokenizer`] module implements encode/decode.
//!
//! # Generation
//!
//! Autoregressive token-by-token decode with temperature sampling.
//! The model is exported as a single model with the full context window;
//! KV cache optimization is handled at the Core ML graph level by the
//! conversion script (stateful model via `coremltools` 8.x).
//!
//! # Expected `.mlmodelc` schema (convert_brief_model.py, path a)
//!
//! - **Input:** `"input_ids"`, `MultiArray` `Int32` `[1, SEQ_LEN]`
//! - **Input:** `"attention_mask"`, `MultiArray` `Int32` `[1, SEQ_LEN]`
//! - **Output:** `"logits"`, `MultiArray` `Float16` `[1, SEQ_LEN, VOCAB_SIZE]`
//!
//! SEQ_LEN is fixed at conversion time (default 2048). The model is
//! stateless — no KV cache. The Rust code pads shorter sequences and
//! constructs an attention_mask (1 = real token, 0 = padding).

pub mod tokenizer;

use std::path::Path;

use mci_brief::llama_backend::{GenerateError, LlamaBackend};
use tokenizer::BpeTokenizer;

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::AllocAnyThread;
use objc2_core_ml::{
    MLDictionaryFeatureProvider, MLFeatureProvider, MLFeatureType, MLFeatureValue, MLModel,
    MLModelConfiguration, MLMultiArray, MLMultiArrayDataType,
};
use objc2_foundation::{NSArray, NSDictionary, NSNumber, NSString, NSURL};

const MAX_OUTPUT_TOKENS: usize = 512;
const DEFAULT_SEQ_LEN: usize = 2048;
const DEFAULT_TEMPERATURE: f32 = 0.7;
const DEFAULT_TOP_P: f32 = 0.9;

/// Core ML backend for Qwen3-1.7B INT4.
pub struct Qwen3CoreMLBackend {
    model: Retained<MLModel>,
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

// MLModel is documented thread-safe for predictionFromFeatures:
// (Apple — Core ML Performance & Architecture WWDC 2019). Same assertion
// as mci-embed-coreml.
unsafe impl Send for Qwen3CoreMLBackend {}
unsafe impl Sync for Qwen3CoreMLBackend {}

impl Qwen3CoreMLBackend {
    /// Load the `.mlmodelc` at `model_path` and the tokenizer from
    /// `tokenizer_dir` (containing `vocab.json` + `merges.txt`).
    pub fn open(model_path: &Path, tokenizer_dir: &Path) -> Result<Self, GenerateError> {
        let path_str = model_path
            .to_str()
            .ok_or_else(|| GenerateError::Backend("model path is not valid UTF-8".into()))?;
        if path_str.is_empty() {
            return Err(GenerateError::Backend("model path is empty".into()));
        }
        if !model_path.exists() {
            return Err(GenerateError::Backend(format!(
                "model not found at: {path_str}"
            )));
        }

        let tok = BpeTokenizer::load(tokenizer_dir)?;

        let url = NSURL::fileURLWithPath(&NSString::from_str(path_str));
        let config = unsafe { MLModelConfiguration::new() };
        let model = unsafe {
            MLModel::modelWithContentsOfURL_configuration_error(&url, &config).map_err(|err| {
                let desc = err.localizedDescription();
                let code = err.code();
                GenerateError::Backend(format!("MLModel load failed: code={code} {desc}"))
            })?
        };

        let me = Self {
            model,
            tokenizer: tok,
            seq_len: DEFAULT_SEQ_LEN,
        };
        me.verify_schema()?;
        Ok(me)
    }

    fn verify_schema(&self) -> Result<(), GenerateError> {
        let desc = unsafe { self.model.modelDescription() };
        let inputs = unsafe { desc.inputDescriptionsByName() };
        let outputs = unsafe { desc.outputDescriptionsByName() };

        let in_key = NSString::from_str("input_ids");
        let mask_key = NSString::from_str("attention_mask");
        let out_key = NSString::from_str("logits");

        inputs.objectForKey(&in_key).ok_or_else(|| {
            GenerateError::Backend("model missing required input feature \"input_ids\"".into())
        })?;

        inputs.objectForKey(&mask_key).ok_or_else(|| {
            GenerateError::Backend(
                "model missing required input feature \"attention_mask\"".into(),
            )
        })?;

        let out_desc = outputs.objectForKey(&out_key).ok_or_else(|| {
            GenerateError::Backend("model missing required output feature \"logits\"".into())
        })?;

        let out_type = unsafe { out_desc.r#type() };
        if out_type != MLFeatureType::MultiArray {
            return Err(GenerateError::Backend(format!(
                "output \"logits\" has feature type {:?}, expected MultiArray",
                out_type.0
            )));
        }
        Ok(())
    }

    /// Run a single forward pass on the given token IDs.
    ///
    /// Pads `input_ids` to `self.seq_len` and constructs an attention_mask
    /// (1 for real tokens, 0 for padding). Returns logits for the last
    /// real token position.
    #[allow(deprecated)]
    fn forward_pass(&self, input_ids: &[i32]) -> Result<Vec<f32>, GenerateError> {
        let real_len = input_ids.len().min(self.seq_len);

        // Pad input_ids to fixed seq_len
        let mut padded_ids = vec![0_i32; self.seq_len];
        padded_ids[..real_len].copy_from_slice(&input_ids[..real_len]);

        // Build attention_mask: 1 for real tokens, 0 for padding
        let mut mask = vec![0_i32; self.seq_len];
        for m in mask.iter_mut().take(real_len) {
            *m = 1;
        }

        let dim0 = NSNumber::new_i64(1);
        let dim1 = NSNumber::new_i64(self.seq_len as i64);
        let shape = NSArray::from_slice(&[&*dim0, &*dim1]);

        // Build input_ids MLMultiArray [1, seq_len]
        let input_arr = unsafe {
            MLMultiArray::initWithShape_dataType_error(
                MLMultiArray::alloc(),
                &shape,
                MLMultiArrayDataType::Int32,
            )
            .map_err(|e| {
                GenerateError::Backend(format!(
                    "MLMultiArray alloc (input_ids): {}",
                    e.localizedDescription()
                ))
            })?
        };
        unsafe {
            let dst = input_arr.dataPointer().as_ptr().cast::<i32>();
            std::ptr::copy_nonoverlapping(padded_ids.as_ptr(), dst, self.seq_len);
        }

        // Build attention_mask MLMultiArray [1, seq_len]
        let mask_arr = unsafe {
            MLMultiArray::initWithShape_dataType_error(
                MLMultiArray::alloc(),
                &shape,
                MLMultiArrayDataType::Int32,
            )
            .map_err(|e| {
                GenerateError::Backend(format!(
                    "MLMultiArray alloc (attention_mask): {}",
                    e.localizedDescription()
                ))
            })?
        };
        unsafe {
            let dst = mask_arr.dataPointer().as_ptr().cast::<i32>();
            std::ptr::copy_nonoverlapping(mask.as_ptr(), dst, self.seq_len);
        }

        // Build feature provider with both inputs
        let id_key = NSString::from_str("input_ids");
        let mask_key = NSString::from_str("attention_mask");
        let id_val: Retained<MLFeatureValue> =
            unsafe { MLFeatureValue::featureValueWithMultiArray(&input_arr) };
        let mask_val: Retained<MLFeatureValue> =
            unsafe { MLFeatureValue::featureValueWithMultiArray(&mask_arr) };
        let id_obj: &AnyObject = &id_val;
        let mask_obj: &AnyObject = &mask_val;
        let dict: Retained<NSDictionary<NSString, AnyObject>> = NSDictionary::from_slices(
            &[&*id_key, &*mask_key],
            &[id_obj, mask_obj],
        );

        let provider = unsafe {
            MLDictionaryFeatureProvider::initWithDictionary_error(
                MLDictionaryFeatureProvider::alloc(),
                &dict,
            )
            .map_err(|err| {
                GenerateError::Backend(format!(
                    "feature-provider init failed: {}",
                    err.localizedDescription()
                ))
            })?
        };

        // Run prediction
        let output = unsafe {
            self.model
                .predictionFromFeatures_error(objc2::runtime::ProtocolObject::from_ref(&*provider))
                .map_err(|err| {
                    GenerateError::Backend(format!(
                        "prediction failed: {}",
                        err.localizedDescription()
                    ))
                })?
        };

        // Extract logits at last real token position
        let out_name = NSString::from_str("logits");
        let out_value = unsafe { output.featureValueForName(&out_name) }.ok_or_else(|| {
            GenerateError::Backend("prediction missing output feature \"logits\"".into())
        })?;

        let logits_arr: Retained<MLMultiArray> = unsafe { out_value.multiArrayValue() }
            .ok_or_else(|| GenerateError::Backend("logits output is not an MLMultiArray".into()))?;

        extract_last_position_logits(&logits_arr, real_len)
    }
}

impl LlamaBackend for Qwen3CoreMLBackend {
    fn generate(&self, prompt: &str) -> Result<String, GenerateError> {
        if prompt.is_empty() {
            return Err(GenerateError::InvalidPrompt("empty prompt".into()));
        }

        let mut input_ids = self.tokenizer.encode(prompt);
        let prompt_len = input_ids.len();
        let mut output_ids = Vec::with_capacity(MAX_OUTPUT_TOKENS);

        for _ in 0..MAX_OUTPUT_TOKENS {
            let logits = self.forward_pass(&input_ids)?;
            let next_token = sample_token(&logits, DEFAULT_TEMPERATURE, DEFAULT_TOP_P);

            if self.tokenizer.is_eos(next_token) {
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
        Ok(full_output)
    }

    fn max_output_tokens(&self) -> usize {
        MAX_OUTPUT_TOKENS
    }
}

/// Extract logits from the last sequence position of an MLMultiArray.
/// Expected shapes: [1, seq_len, vocab_size] or [seq_len, vocab_size].
#[allow(deprecated)]
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

    let offset = if ndim == 3 {
        // [1, seq_len, vocab_size]
        last_pos * vocab_size
    } else {
        // [seq_len, vocab_size]
        last_pos * vocab_size
    };

    let mut logits = vec![0.0_f32; vocab_size];

    let dtype = unsafe { arr.dataType() };
    if dtype == MLMultiArrayDataType::Float32 {
        unsafe {
            let src = arr.dataPointer().as_ptr().cast::<f32>();
            std::ptr::copy_nonoverlapping(src.add(offset), logits.as_mut_ptr(), vocab_size);
        }
    } else if dtype == MLMultiArrayDataType::Float16 {
        unsafe {
            let src = arr.dataPointer().as_ptr().cast::<u16>();
            for i in 0..vocab_size {
                logits[i] = f16_to_f32(*src.add(offset + i));
            }
        }
    } else {
        return Err(GenerateError::Backend(format!(
            "logits dtype is {:?}, expected Float32 or Float16",
            dtype.0
        )));
    }

    Ok(logits)
}

/// IEEE 754 half-precision → single-precision conversion.
fn f16_to_f32(bits: u16) -> f32 {
    let sign = ((bits >> 15) & 1) as u32;
    let exp = ((bits >> 10) & 0x1F) as u32;
    let mantissa = (bits & 0x3FF) as u32;

    if exp == 0 {
        if mantissa == 0 {
            return f32::from_bits(sign << 31);
        }
        // Subnormal
        let mut m = mantissa;
        let mut e: i32 = -14;
        while m & 0x400 == 0 {
            m <<= 1;
            e -= 1;
        }
        m &= 0x3FF;
        #[allow(clippy::cast_sign_loss)]
        let f32_exp = (e + 127) as u32;
        return f32::from_bits((sign << 31) | (f32_exp << 23) | (m << 13));
    }
    if exp == 31 {
        return f32::from_bits((sign << 31) | (255_u32 << 23) | (mantissa << 13));
    }

    let f32_exp = exp + 112; // (exp - 15 + 127)
    f32::from_bits((sign << 31) | (f32_exp << 23) | (mantissa << 13))
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
    (s & 0xFFFF_FFFF) as f32 / 4_294_967_296.0
}

/// Try loading the Qwen3 Core ML backend from model + tokenizer paths.
///
/// Expected layout:
/// ```text
/// ~/Library/Application Support/MCI/Models/
///   Qwen3-1.7B-INT4.mlmodelc/   ← compiled Core ML model
///   vocab.json                   ← BPE vocabulary
///   merges.txt                   ← BPE merge rules
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
    fn f16_to_f32_converts_common_values() {
        assert_eq!(f16_to_f32(0x0000), 0.0);
        assert!((f16_to_f32(0x3C00) - 1.0).abs() < 1e-6);
        assert!((f16_to_f32(0xBC00) - (-1.0)).abs() < 1e-6);
        assert!((f16_to_f32(0x3800) - 0.5).abs() < 1e-6);
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
