//! Rust-side `WordPiece` tokenizer **with byte-offset mapping** for the
//! V2-P5+ Tier-2 supervised NER model (`dslim/distilbert-NER`,
//! `bert-base-cased` `WordPiece`, `CoNLL-2003` label scheme).
//!
//! # Why a second tokenizer surface
//!
//! The embedder already has a `WordPiece` tokenizer
//! (`adapters/macos/mci-embed-coreml/src/tokenizer.rs`,
//! `snowflake-arctic-embed-s`, bert-base-**uncased**). That one returns
//! only `input_ids` + `attention_mask` — it discards the per-token
//! character offsets the `tokenizers` crate computes, because the
//! embedder never needs to map a token back to a span of the source
//! text.
//!
//! The NER decoder DOES need that mapping: a token-classifier emits a
//! per-token BIO label, and turning a run of labelled tokens into a
//! typed entity mention requires the **byte span** of the original text
//! those tokens cover (the V2-P3 `entity_mentions` schema + the
//! [`crate::extraction::tier2::Tier2RawMatch`] contract are byte-span
//! based). So this is a separate tokenizer surface that adds the offset
//! mapping; it deliberately does not touch the embedder's tokenizer.
//!
//! The NER model uses a **different vocab** (cased vs uncased), so this
//! tokenizer bundles its own `tokenizer.json` — it is not a refactor of
//! the embedder path, it is a sibling.
//!
//! # Offsets are bytes (the Rust crate ≠ the Python binding)
//!
//! Important gotcha: the `tokenizers` **Rust crate** returns **byte**
//! offsets in its `Encoding` (verified empirically against this model:
//! for `"José works"` the `works` token reports offset `(6, 11)` — byte
//! 11 is past the 10-char / 11-byte string, i.e. a byte index). The
//! `HuggingFace` **Python binding** (`tokenizers`/`transformers` fast
//! path), by contrast, presents the same token as **char** offsets
//! (`(6, 10)`) for Python `str` compatibility. The golden fixtures are
//! generated through the Python path and store HF char offsets converted
//! to **bytes** (`offsets_byte`), so the Rust crate's native byte
//! offsets match them directly — no conversion needed here.
//!
//! Byte offsets are exactly what our downstream entity-span
//! representation wants (`Tier2RawMatch::span_start`/`span_end` are byte
//! offsets, verified by `Tier2Extractor::verify_span` via
//! `text[start..end]`). The golden fixture
//! `José works at Café Réunion in Montréal.` pins this across the
//! multibyte boundary; if a future `tokenizers` bump changed the crate
//! to char offsets, `tokenizer_matches_hf_on_every_fixture` would fail
//! loudly rather than silently corrupt spans.
//!
//! # OS-purity
//!
//! Pure Rust + the `tokenizers` crate (already on the workspace
//! lockfile via the macOS adapters; see `core/brain/Cargo.toml`). No
//! `cfg(target_os = ...)`, no `objc2`, no `windows-rs`, no Core ML. The
//! actual NER model inference lives behind a future Core ML backend; the
//! tokenizer + decoder in this module are portable and unit-testable in
//! isolation. A later Windows ONNX NER backend reuses them unchanged.

use std::path::Path;
use std::sync::Arc;

use tokenizers::Tokenizer;

/// `tokenizer.json` for `dslim/distilbert-NER` (`bert-base-cased`
/// `WordPiece`), embedded at compile time. Committed at
/// `resources/tokenizer.json`; provenance + regeneration are documented
/// in `fixtures/gen_golden.py`.
const BUNDLED_NER_TOKENIZER: &[u8] = include_bytes!("resources/tokenizer.json");

/// Errors produced by [`NerWordPieceTokenizer`].
#[derive(Debug, thiserror::Error)]
pub enum NerTokenizerError {
    /// `tokenizer.json` failed to load or parse.
    #[error("ner tokenizer load failed: {0}")]
    Load(String),
    /// `encode()` failed (e.g. the `tokenizers` crate rejected the
    /// padding/truncation params, or an offset fell outside the input).
    #[error("ner tokenizer encode failed: {0}")]
    Encode(String),
}

/// Result of tokenizing one text string for the NER model.
///
/// All four vectors are parallel and the same length: `seq_len` for the
/// natural-length [`NerWordPieceTokenizer::encode`], or `max_length` for
/// the padded [`NerWordPieceTokenizer::encode_padded`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NerEncoded {
    /// Token ids cast to `i32` to drop straight into an
    /// `MLMultiArrayDataType::Int32` backing buffer (same dtype dance as
    /// the embedder path). Includes `[CLS]` at index 0 and `[SEP]` after
    /// the last content token.
    pub input_ids: Vec<i32>,
    /// Attention mask parallel to `input_ids`. `1` = attend (incl.
    /// `[CLS]`/`[SEP]`), `0` = padding.
    pub attention_mask: Vec<i32>,
    /// Special-tokens mask parallel to `input_ids`. `1` for `[CLS]`,
    /// `[SEP]`, `[PAD]` (and any other special token); `0` for content
    /// tokens. The BIO decoder skips tokens where this is `1`.
    pub special_tokens_mask: Vec<i32>,
    /// **Byte** offsets into the original `text`, one `(start, end)` per
    /// token. Special / padding tokens map to `(0, 0)` (they carry no
    /// source span). For a content token, `text[start..end]` is the
    /// substring the token covers.
    pub offsets: Vec<(usize, usize)>,
}

/// `WordPiece` tokenizer (with offset mapping) for `dslim/distilbert-NER`.
///
/// One instance is loaded at backend-open time and held behind an
/// `Arc`. Tokenization is stateless per `encode()` call — the per-call
/// `clone()` of the inner `Tokenizer` is the canonical pattern from the
/// `tokenizers` docs for setting padding/truncation without mutating
/// shared state (matches the embedder tokenizer).
pub struct NerWordPieceTokenizer {
    inner: Tokenizer,
}

impl std::fmt::Debug for NerWordPieceTokenizer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NerWordPieceTokenizer")
            .finish_non_exhaustive()
    }
}

impl NerWordPieceTokenizer {
    /// Load from the binary-embedded `tokenizer.json` (zero filesystem
    /// dependency). Production callers use this.
    ///
    /// # Errors
    /// [`NerTokenizerError::Load`] if the bundled bytes fail to parse as
    /// a valid `HuggingFace` tokenizer spec — which, for a compile-time
    /// resource, means a corrupted build artifact.
    pub fn load_bundled() -> Result<Arc<Self>, NerTokenizerError> {
        let tk = Tokenizer::from_bytes(BUNDLED_NER_TOKENIZER)
            .map_err(|e| NerTokenizerError::Load(format!("bundled ner tokenizer.json: {e}")))?;
        Ok(Arc::new(Self { inner: tk }))
    }

    /// Load from a `tokenizer.json` file on disk. Developer override for
    /// model-swap evals; production paths use [`Self::load_bundled`].
    ///
    /// # Errors
    /// [`NerTokenizerError::Load`] if the file is unreadable or does not
    /// parse as a valid `HuggingFace` tokenizer spec.
    pub fn load_from_file(path: &Path) -> Result<Arc<Self>, NerTokenizerError> {
        let bytes = std::fs::read(path)
            .map_err(|e| NerTokenizerError::Load(format!("read {}: {e}", path.display())))?;
        let tk = Tokenizer::from_bytes(&bytes)
            .map_err(|e| NerTokenizerError::Load(format!("{}: {e}", path.display())))?;
        Ok(Arc::new(Self { inner: tk }))
    }

    /// Encode `text` to its **natural-length** token sequence (no
    /// padding, no truncation), adding `[CLS]`/`[SEP]`.
    ///
    /// This is the form the BIO decoder consumes and the form the golden
    /// fixtures pin against the `HuggingFace` fast tokenizer. The returned
    /// vectors have length `seq_len` (content tokens + 2 specials).
    ///
    /// # Errors
    /// [`NerTokenizerError::Encode`] if the `tokenizers` crate fails the
    /// encode, or if a returned char offset falls outside `text` (a
    /// tokenizer-spec corruption — never happens for the bundled spec).
    pub fn encode(&self, text: &str) -> Result<NerEncoded, NerTokenizerError> {
        let enc = self
            .inner
            .encode(text, true)
            .map_err(|e| NerTokenizerError::Encode(format!("encode: {e}")))?;
        Self::materialize(text, &enc)
    }

    /// Encode `text` padded/truncated to exactly `max_length` tokens.
    ///
    /// Pads on the right with `[PAD]` (id 0) and truncates from the
    /// right. Useful when the Core ML NER graph has a fixed input shape;
    /// padding tokens carry `attention_mask = 0`, `special_tokens_mask =
    /// 1`, offset `(0, 0)`, so the decoder skips them.
    ///
    /// # Errors
    /// [`NerTokenizerError::Encode`] as for [`Self::encode`], plus any
    /// failure applying the padding/truncation params.
    pub fn encode_padded(
        &self,
        text: &str,
        max_length: usize,
    ) -> Result<NerEncoded, NerTokenizerError> {
        use tokenizers::{
            PaddingDirection, PaddingParams, PaddingStrategy, TruncationDirection,
            TruncationParams, TruncationStrategy,
        };
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
        .map_err(|e| NerTokenizerError::Encode(format!("with_truncation: {e}")))?;
        let enc = tk
            .encode(text, true)
            .map_err(|e| NerTokenizerError::Encode(format!("encode: {e}")))?;
        Self::materialize(text, &enc)
    }

    /// Convert a `tokenizers::Encoding` into our [`NerEncoded`]. The
    /// crate's offsets are already **byte** offsets into `text` (see the
    /// module doc), so they are copied through verbatim. Special /
    /// padding tokens carry `(0, 0)`.
    ///
    /// As a defensive guard, every content-token offset is range-checked
    /// against `text.len()` and must land on char boundaries; a
    /// violation (which would indicate a `tokenizers` semantics change)
    /// surfaces as an [`NerTokenizerError::Encode`] rather than a later
    /// slicing panic in the decoder.
    fn materialize(
        text: &str,
        enc: &tokenizers::Encoding,
    ) -> Result<NerEncoded, NerTokenizerError> {
        #[allow(clippy::cast_possible_wrap)]
        let input_ids: Vec<i32> = enc.get_ids().iter().map(|&x| x as i32).collect();
        #[allow(clippy::cast_possible_wrap)]
        let attention_mask: Vec<i32> = enc.get_attention_mask().iter().map(|&x| x as i32).collect();
        #[allow(clippy::cast_possible_wrap)]
        let special_tokens_mask: Vec<i32> = enc
            .get_special_tokens_mask()
            .iter()
            .map(|&x| x as i32)
            .collect();

        let mut offsets: Vec<(usize, usize)> = Vec::with_capacity(enc.get_offsets().len());
        for &(s, e) in enc.get_offsets() {
            // (0,0) specials pass through. For a content span, both ends
            // must be in-range char boundaries of `text`.
            if !(s == 0 && e == 0)
                && (e > text.len()
                    || s > e
                    || !text.is_char_boundary(s)
                    || !text.is_char_boundary(e))
            {
                return Err(NerTokenizerError::Encode(format!(
                    "token offset ({s},{e}) is not a valid byte span of a {}-byte input",
                    text.len()
                )));
            }
            offsets.push((s, e));
        }

        Ok(NerEncoded {
            input_ids,
            attention_mask,
            special_tokens_mask,
            offsets,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_tokenizer_loads_and_adds_specials() {
        let tk = NerWordPieceTokenizer::load_bundled().expect("bundled NER tokenizer loads");
        let enc = tk.encode("Bob met Alice").expect("encode");
        // `bert-base-cased` family: [CLS]=101 at 0, [SEP]=102 last content.
        assert_eq!(enc.input_ids[0], 101, "[CLS] at position 0");
        assert_eq!(*enc.input_ids.last().unwrap(), 102, "[SEP] last");
        // Specials flagged, content not.
        assert_eq!(enc.special_tokens_mask[0], 1);
        assert_eq!(*enc.special_tokens_mask.last().unwrap(), 1);
        assert_eq!(enc.special_tokens_mask[1], 0);
        // All four parallel vectors same length.
        let n = enc.input_ids.len();
        assert_eq!(enc.attention_mask.len(), n);
        assert_eq!(enc.special_tokens_mask.len(), n);
        assert_eq!(enc.offsets.len(), n);
        // Special tokens carry the (0,0) span.
        assert_eq!(enc.offsets[0], (0, 0));
        assert_eq!(*enc.offsets.last().unwrap(), (0, 0));
    }

    #[test]
    fn ascii_offsets_index_the_source_substring() {
        let tk = NerWordPieceTokenizer::load_bundled().unwrap();
        let text = "Bob met Alice";
        let enc = tk.encode(text).unwrap();
        // Every non-special offset must slice a real substring of `text`.
        for (i, &(s, e)) in enc.offsets.iter().enumerate() {
            if enc.special_tokens_mask[i] == 1 {
                continue;
            }
            assert!(
                text.get(s..e).is_some(),
                "offset ({s},{e}) not a valid slice"
            );
            assert!(e > s, "content token has empty span");
        }
        // First content token covers "Bob".
        assert_eq!(&text[enc.offsets[1].0..enc.offsets[1].1], "Bob");
    }

    #[test]
    fn multibyte_offsets_are_byte_not_char() {
        let tk = NerWordPieceTokenizer::load_bundled().unwrap();
        // "José": J o s é -> 4 chars, 5 bytes (é = 2 bytes). The token
        // covering it must report BYTE offset (0,5), and slicing must
        // round-trip the original substring.
        let text = "José works";
        let enc = tk.encode(text).unwrap();
        let (s, e) = enc.offsets[1]; // first content token
        assert_eq!((s, e), (0, 5), "expected byte offset (0,5) for 'José'");
        assert_eq!(&text[s..e], "José");
    }

    #[test]
    fn encode_padded_pads_to_fixed_length() {
        let tk = NerWordPieceTokenizer::load_bundled().unwrap();
        let enc = tk.encode_padded("Bob", 32).unwrap();
        assert_eq!(enc.input_ids.len(), 32);
        assert_eq!(enc.attention_mask.len(), 32);
        assert_eq!(enc.special_tokens_mask.len(), 32);
        assert_eq!(enc.offsets.len(), 32);
        // Last slot is padding: id 0, attention 0, special 1, offset (0,0).
        assert_eq!(enc.input_ids[31], 0);
        assert_eq!(enc.attention_mask[31], 0);
        assert_eq!(enc.special_tokens_mask[31], 1);
        assert_eq!(enc.offsets[31], (0, 0));
    }
}
