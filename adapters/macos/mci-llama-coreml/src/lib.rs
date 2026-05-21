// Gate the entire crate body on macOS — the objc2 deps are gated to the
// same target in `Cargo.toml`, so on Linux this crate compiles to an
// empty library. Same pattern as `mci-embed-coreml`.
#![cfg(target_os = "macos")]

//! macOS Core ML backend for Llama-3.2-1B int4 brief generation.
//!
//! Implements [`mci_brief::llama_backend::LlamaBackend`] using Apple's
//! Core ML framework via `objc2-core-ml`. The wrapper
//! ([`mci_brief::llama_author::LlamaBriefAuthor`]) handles prompt
//! rendering, citation parsing, and the hallucination tripwire above
//! this crate. This crate's job: load the `.mlpackage`, run greedy
//! token-by-token decode, return the raw text output.
//!
//! # Why this crate is NOT `#![forbid(unsafe_code)]`
//!
//! Core ML is an Objective-C framework. `objc2-core-ml` exposes selectors
//! as `unsafe fn`. The unsafe surface is audited per call site and kept
//! minimal. `mci-brief` upstream keeps `#![forbid(unsafe_code)]`.
//!
//! # Model bundling
//!
//! The `llama-3.2-1b-int4.mlpackage` (~700 MB) is **not** checked into
//! the repo. The Phase-5 signed-app build pipeline converts it via
//! `coremltools`. See `BUNDLING.md` for the conversion contract.
//!
//! # Tokenizer
//!
//! Llama-3.2-1B requires external tokenization (unlike the arctic-embed-s
//! model which bakes the tokenizer into the Core ML graph). The tokenizer
//! integration is DEFERRED to a follow-on PR — this PR establishes the
//! trait seam + Core ML model loading + schema verification. The
//! `StubLlamaBackend` provides shaped output for the `LlamaBriefAuthor`
//! to exercise the full prompt→parse→cite pipeline in tests.
//!
//! # Expected `.mlpackage` schema (when tokenizer lands)
//!
//! - **Input feature:** `"input_ids"`, `MultiArray` `Int32` `[1, seq_len]`
//! - **Output feature:** `"logits"`, `MultiArray` `Float32` `[1, seq_len, vocab_size]`
//!
//! Greedy decode: argmax over logits at each step, stop on EOS (token 2)
//! or `###CITATIONS:` marker or 256 output tokens.

use std::path::Path;

use mci_brief::llama_backend::{GenerateError, LlamaBackend};

use objc2::rc::Retained;
use objc2_core_ml::{MLFeatureType, MLModel, MLModelConfiguration};
use objc2_foundation::{NSString, NSURL};

const MAX_OUTPUT_TOKENS: usize = 256;

/// Core ML backend for Llama-3.2-1B int4.
///
/// Loads the `.mlpackage` and verifies the schema. Actual token-by-token
/// decode is DEFERRED until the tokenizer integration PR — calling
/// [`LlamaBackend::generate`] on this backend returns
/// [`GenerateError::Backend`] with a "tokenizer not yet wired" message.
pub struct LlamaCoreMLBackend {
    model: Retained<MLModel>,
}

impl std::fmt::Debug for LlamaCoreMLBackend {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LlamaCoreMLBackend").finish_non_exhaustive()
    }
}

// MLModel is documented thread-safe for predictionFromFeatures:
// (Apple — Core ML Performance & Architecture WWDC 2019). Same assertion
// as mci-embed-coreml.
unsafe impl Send for LlamaCoreMLBackend {}
unsafe impl Sync for LlamaCoreMLBackend {}

impl LlamaCoreMLBackend {
    /// Load the `.mlpackage` at `path` and verify schema.
    ///
    /// # Errors
    ///
    /// - `GenerateError::Backend` — path missing, Core ML load failed,
    ///   or schema mismatch.
    pub fn open(path: &Path) -> Result<Self, GenerateError> {
        let path_str = path
            .to_str()
            .ok_or_else(|| GenerateError::Backend("model path is not valid UTF-8".into()))?;
        if path_str.is_empty() {
            return Err(GenerateError::Backend("model path is empty".into()));
        }
        if !path.exists() {
            return Err(GenerateError::Backend(format!(
                "model not found at: {path_str}"
            )));
        }

        let url = NSURL::fileURLWithPath(&NSString::from_str(path_str));
        let config = unsafe { MLModelConfiguration::new() };
        let model = unsafe {
            MLModel::modelWithContentsOfURL_configuration_error(&url, &config).map_err(|err| {
                let desc = err.localizedDescription();
                let code = err.code();
                GenerateError::Backend(format!("MLModel load failed: code={code} {desc}"))
            })?
        };

        let me = Self { model };
        me.verify_schema()?;
        Ok(me)
    }

    fn verify_schema(&self) -> Result<(), GenerateError> {
        let desc = unsafe { self.model.modelDescription() };
        let inputs = unsafe { desc.inputDescriptionsByName() };
        let outputs = unsafe { desc.outputDescriptionsByName() };

        let in_key = NSString::from_str("input_ids");
        let out_key = NSString::from_str("logits");

        inputs.objectForKey(&in_key).ok_or_else(|| {
            GenerateError::Backend(
                "model missing required input feature \"input_ids\"".into(),
            )
        })?;

        let out_desc = outputs.objectForKey(&out_key).ok_or_else(|| {
            GenerateError::Backend(
                "model missing required output feature \"logits\"".into(),
            )
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
}

impl LlamaBackend for LlamaCoreMLBackend {
    fn generate(&self, _prompt: &str) -> Result<String, GenerateError> {
        // TODO(ADR-0018 follow-on): wire sentencepiece tokenizer + greedy
        // decode loop. This PR establishes the model-loading shape; the
        // tokenizer crate selection + integration is the next PR.
        //
        // When wired, the loop will:
        //   1. Tokenize `prompt` via sentencepiece into input_ids
        //   2. For up to MAX_OUTPUT_TOKENS steps:
        //      a. Run prediction on [1, seq_len] input
        //      b. Argmax over logits[:, -1, :] → next_token
        //      c. Stop on EOS (token 2) or "###CITATIONS:" in decoded text
        //      d. Append next_token to input_ids
        //   3. Detokenize and return
        let _ = MAX_OUTPUT_TOKENS;
        Err(GenerateError::Backend(
            "LlamaCoreMLBackend: tokenizer not yet wired (ADR-0018 follow-on)".into(),
        ))
    }

    fn max_output_tokens(&self) -> usize {
        MAX_OUTPUT_TOKENS
    }
}

/// Try loading the Core ML Llama backend from a list of candidate paths.
///
/// Same fallback-chain pattern as `mci_embed_coreml::try_load_coreml_backend`.
pub fn try_load_llama_backend(
    candidate_paths: &[&Path],
) -> Result<LlamaCoreMLBackend, GenerateError> {
    let mut last_err = GenerateError::Backend("no candidate paths provided".into());
    for path in candidate_paths {
        match LlamaCoreMLBackend::open(path) {
            Ok(backend) => return Ok(backend),
            Err(e) => last_err = e,
        }
    }
    Err(last_err)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_rejects_empty_path() {
        let err = LlamaCoreMLBackend::open(Path::new("")).expect_err("empty path");
        assert!(
            matches!(err, GenerateError::Backend(_)),
            "{err:?}"
        );
    }

    #[test]
    fn open_returns_error_for_missing_file() {
        let err = LlamaCoreMLBackend::open(Path::new(
            "/tmp/mci-test-nonexistent-llama.mlpackage",
        ))
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
    fn max_output_tokens_is_256() {
        assert_eq!(MAX_OUTPUT_TOKENS, 256);
    }
}
