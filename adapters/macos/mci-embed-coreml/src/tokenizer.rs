//! Rust-side WordPiece tokenizer for `snowflake-arctic-embed-s`.
//!
//! # Why this lives in Rust, not in the Core ML graph
//!
//! The Wave-17 erratum to ADR-0011 (CEO + CRS ratified 2026-05-22) records
//! the architectural pivot here: **Core ML cannot express WordPiece
//! tokenization as tensor ops.** The MIL (Model Intermediate Language) spec
//! has no string ops — `coremltools` will not convert a graph whose input
//! is a `String` and whose first hidden layer is a tokenizer.
//!
//! The industry-standard pattern (Apple `ml-stable-diffusion`, WhisperKit,
//! HuggingFace's own Core ML exporters) is **external tokenization +
//! token-IDs input**: tokenize on the host in whatever native runtime
//! makes sense (Rust here), pass `input_ids` + `attention_mask` Int32
//! tensors to the Core ML graph, and let the graph handle every layer
//! from the embedding table onward.
//!
//! # Bundling
//!
//! `tokenizer.json` (~700 KB) is the HuggingFace WordPiece spec for
//! `Snowflake/snowflake-arctic-embed-s`. It is committed at
//! `adapters/macos/mci-embed-coreml/resources/tokenizer.json` and embedded
//! into the binary at compile time via [`include_bytes!`]. Zero runtime
//! filesystem dependency — the tokenizer ships inside `mci-agent` /
//! `Hippocampus.app` regardless of model bundling state.
//!
//! Per the CEO ratification (2026-05-22): tokenizer is bundled in the
//! binary, NOT first-launch downloaded. Reason: enterprise air-gap +
//! MDM-deploy customers cannot rely on first-launch network access for
//! the embedder pipeline to work.

use std::path::Path;
use std::sync::Arc;

use tokenizers::{
    PaddingDirection, PaddingParams, PaddingStrategy, Tokenizer, TruncationDirection,
    TruncationParams, TruncationStrategy,
};

/// Errors produced by [`WordPieceTokenizer`]. Mapped at the call site to
/// [`mci_brain::EmbedError::Backend`] so the embedder error surface stays
/// flat.
#[derive(Debug, thiserror::Error)]
pub enum TokenizerError {
    /// `tokenizer.json` failed to load or parse.
    #[error("tokenizer load failed: {0}")]
    Load(String),
    /// `encode()` rejected the input. Empty input is NOT a load error —
    /// it returns `[CLS] [SEP] [PAD]…` with attention mask `[1, 1, 0, …]`.
    #[error("tokenizer encode failed: {0}")]
    Encode(String),
}

/// Result of tokenizing a single text string for the embedder.
///
/// Both vectors are exactly `max_length` long: tokenization pads with
/// `[PAD]` (id 0) and truncates to fit. Attention mask is `1` for real
/// tokens (including `[CLS]` and `[SEP]`) and `0` for padding.
pub struct Encoded {
    /// Token ids cast to `i32` so they drop straight into an
    /// `MLMultiArrayDataType::Int32` backing buffer — same dtype dance
    /// as `mci-llama-coreml::forward_pass`.
    pub input_ids: Vec<i32>,
    /// Attention mask, parallel to `input_ids`. `1` = attend, `0` = pad.
    pub attention_mask: Vec<i32>,
}

/// `tokenizer.json` for `Snowflake/snowflake-arctic-embed-s`, embedded
/// at compile time. Verified upstream commit: HuggingFace
/// `Snowflake/snowflake-arctic-embed-s` main, fetched 2026-05-22.
const BUNDLED_TOKENIZER: &[u8] = include_bytes!("../resources/tokenizer.json");

/// WordPiece tokenizer for `snowflake-arctic-embed-s`.
///
/// One instance is loaded at backend-open time and held inside
/// [`crate::CoreMLBackend`] via `Arc`. Tokenization is stateless per
/// `encode()` call — the per-call `clone()` of the inner `Tokenizer` is
/// the canonical pattern from the `tokenizers` docs for setting padding
/// + truncation on each call without mutating shared state.
pub struct WordPieceTokenizer {
    inner: Tokenizer,
}

impl std::fmt::Debug for WordPieceTokenizer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WordPieceTokenizer").finish_non_exhaustive()
    }
}

impl WordPieceTokenizer {
    /// Load the tokenizer from the binary-embedded `tokenizer.json`.
    ///
    /// Production callers use this — zero filesystem dependency.
    ///
    /// # Errors
    ///
    /// [`TokenizerError::Load`] if the bundled bytes fail to parse as a
    /// valid HuggingFace tokenizer spec. This is a compile-time-checked
    /// resource, so a `Load` error here means a corrupted build artifact.
    pub fn load_bundled() -> Result<Arc<Self>, TokenizerError> {
        let tk = Tokenizer::from_bytes(BUNDLED_TOKENIZER)
            .map_err(|e| TokenizerError::Load(format!("bundled tokenizer.json: {e}")))?;
        Ok(Arc::new(Self { inner: tk }))
    }

    /// Load the tokenizer from a `tokenizer.json` file on disk.
    ///
    /// Developer override for cases where someone wants to test a custom
    /// tokenizer (e.g. a model swap eval). Production paths use
    /// [`Self::load_bundled`].
    ///
    /// # Errors
    ///
    /// [`TokenizerError::Load`] if the file is unreadable or the bytes do
    /// not parse as a valid HuggingFace tokenizer spec.
    pub fn load_from_file(path: &Path) -> Result<Arc<Self>, TokenizerError> {
        let bytes = std::fs::read(path)
            .map_err(|e| TokenizerError::Load(format!("read {}: {e}", path.display())))?;
        let tk = Tokenizer::from_bytes(&bytes)
            .map_err(|e| TokenizerError::Load(format!("{}: {e}", path.display())))?;
        Ok(Arc::new(Self { inner: tk }))
    }

    /// Encode `text` to fixed-length `input_ids` + `attention_mask`.
    ///
    /// Pads to `max_length` with `[PAD]` (id 0). Truncates from the right
    /// (`LongestFirst` strategy is single-sequence-equivalent here).
    /// Special tokens are added (`[CLS]` at position 0, `[SEP]` after the
    /// last content token).
    ///
    /// Returns vectors of length exactly `max_length`.
    ///
    /// # Errors
    ///
    /// [`TokenizerError::Encode`] if the tokenizers crate fails to apply
    /// the padding/truncation params (e.g. impossible parameter
    /// combinations). Empty input is valid and returns
    /// `[CLS] [SEP] [PAD]…`.
    pub fn encode(&self, text: &str, max_length: usize) -> Result<Encoded, TokenizerError> {
        // Clone the inner tokenizer per call so the per-call padding +
        // truncation parameters don't mutate shared state. Cheap: shared
        // model is behind an Arc inside the tokenizer.
        let mut tk = self.inner.clone();
        tk.with_padding(Some(PaddingParams {
            strategy: PaddingStrategy::Fixed(max_length),
            direction: PaddingDirection::Right,
            pad_to_multiple_of: None,
            pad_id: 0,
            pad_type_id: 0,
            pad_token: "[PAD]".to_string(),
        }));
        tk.with_truncation(Some(TruncationParams {
            max_length,
            strategy: TruncationStrategy::LongestFirst,
            stride: 0,
            direction: TruncationDirection::Right,
        }))
        .map_err(|e| TokenizerError::Encode(format!("with_truncation: {e}")))?;

        let enc = tk
            .encode(text, true)
            .map_err(|e| TokenizerError::Encode(format!("encode: {e}")))?;

        let input_ids: Vec<i32> = enc
            .get_ids()
            .iter()
            .map(|&x| {
                // u32 → i32: WordPiece vocab for BERT-family models is
                // ~30k tokens, far below i32::MAX. The cast is safe.
                #[allow(clippy::cast_possible_wrap)]
                {
                    x as i32
                }
            })
            .collect();
        let attention_mask: Vec<i32> = enc
            .get_attention_mask()
            .iter()
            .map(|&x| {
                #[allow(clippy::cast_possible_wrap)]
                {
                    x as i32
                }
            })
            .collect();

        debug_assert_eq!(input_ids.len(), max_length);
        debug_assert_eq!(attention_mask.len(), max_length);
        Ok(Encoded {
            input_ids,
            attention_mask,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_tokenizer_loads() {
        let tk = WordPieceTokenizer::load_bundled().expect("bundled tokenizer should load");
        let enc = tk.encode("hello world", 128).unwrap();
        assert_eq!(enc.input_ids.len(), 128);
        assert_eq!(enc.attention_mask.len(), 128);
        // bert-base-uncased-family vocab: [CLS] = 101
        assert_eq!(
            enc.input_ids[0], 101,
            "expected [CLS] at position 0, got id {}",
            enc.input_ids[0]
        );
    }

    #[test]
    fn truncation_handles_long_input() {
        let tk = WordPieceTokenizer::load_bundled().unwrap();
        let long = "lorem ipsum ".repeat(500);
        let enc = tk.encode(&long, 128).unwrap();
        assert_eq!(enc.input_ids.len(), 128);
        // After truncation the final real token slot is [SEP] = 102.
        // Attention mask is 1 at the final position (real, not pad).
        assert_eq!(enc.attention_mask[127], 1);
        assert_eq!(
            enc.input_ids[127], 102,
            "expected [SEP] at last position after truncation"
        );
    }

    #[test]
    fn padding_attention_mask() {
        let tk = WordPieceTokenizer::load_bundled().unwrap();
        let enc = tk.encode("hi", 128).unwrap();
        // First token is [CLS], attention = 1
        assert_eq!(enc.attention_mask[0], 1);
        // Last token is padding, attention = 0
        assert_eq!(enc.attention_mask[127], 0);
        // [PAD] id is 0 for bert-base-uncased family
        assert_eq!(enc.input_ids[127], 0);
    }

    #[test]
    fn empty_string_encodes() {
        let tk = WordPieceTokenizer::load_bundled().unwrap();
        let enc = tk.encode("", 128).unwrap();
        assert_eq!(enc.input_ids.len(), 128);
        // Empty input becomes [CLS] [SEP] [PAD]…
        assert_eq!(enc.input_ids[0], 101, "[CLS]");
        assert_eq!(enc.input_ids[1], 102, "[SEP]");
        assert_eq!(enc.attention_mask[0], 1);
        assert_eq!(enc.attention_mask[1], 1);
        assert_eq!(enc.attention_mask[2], 0);
    }
}
