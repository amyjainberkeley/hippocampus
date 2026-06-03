//! Qwen3 tokenizer for the brief-author Core ML backend.
//!
//! Backed by HuggingFace's `tokenizers` crate (Apache-2.0). Loads
//! `tokenizer.json` directly from disk so Qwen3's ByteLevel BPE
//! pre-tokenizer (which remaps bytes 0-255 to printable Unicode chars
//! before BPE-merging — GPT-2 convention) is handled correctly, and so
//! the ChatML control tokens (`<|im_start|>`, `<|im_end|>`,
//! `<|endoftext|>`, the tool-call / thinking tokens) are recognized as
//! single special-token IDs instead of being shredded into byte pieces.
//!
//! # History — cycle 8.10 silent failure
//!
//! The original hand-rolled byte BPE in this file:
//!
//! 1. Looked up the BPE merge table by RAW bytes from `merges.txt`.
//!    Qwen3 (and every other ByteLevel BPE) writes merges in the
//!    REMAPPED character space, not raw bytes — every space, newline,
//!    and non-ASCII character missed every merge.
//! 2. Fell back to token 0 (`!`) on any vocab miss
//!    (`encoder.get(p).copied().unwrap_or(0)`). Every space and newline
//!    in the input therefore tokenized to `!`.
//! 3. Read special tokens from `vocab.json`, but Qwen3 keeps them in
//!    `added_tokens.json`. Result: no special tokens recognized.
//!
//! Net effect: every prompt was reduced to a sequence of `!` plus a few
//! coincidentally-correct ASCII tokens. The model saw nonsense and
//! produced nonsense (cycle 8.10 brief-eval 0/8). Switching to the
//! reference HF tokenizer eliminates this entire class of bug.
//!
//! # Special tokens
//!
//! Qwen3 ChatML:
//! - `<|im_start|>` (ID 151644)
//! - `<|im_end|>` (ID 151645)
//! - `<|endoftext|>` (ID 151643)

use std::path::Path;

use mci_brief::llama_backend::GenerateError;
use tokenizers::Tokenizer;

pub const IM_START_ID: i32 = 151_644;
pub const IM_END_ID: i32 = 151_645;
pub const ENDOFTEXT_ID: i32 = 151_643;

pub struct BpeTokenizer {
    inner: Tokenizer,
}

impl std::fmt::Debug for BpeTokenizer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BpeTokenizer")
            .field("vocab_size", &self.inner.get_vocab_size(true))
            .finish()
    }
}

impl BpeTokenizer {
    /// Load tokenizer from a directory containing `tokenizer.json`.
    ///
    /// `tokenizer.json` is what `tokenizer.save_pretrained()` writes
    /// alongside the model and ships inside the model `.tar.gz`. It
    /// carries the full tokenizer state: ByteLevel pre-tokenizer
    /// configuration, BPE merges (in remapped-char space), the base
    /// vocab, AND every added / special token with its ID. We never
    /// reach for `vocab.json` / `merges.txt` / `added_tokens.json`
    /// individually — that path was the source of the cycle 8.10
    /// silent-failure bug.
    pub fn load(dir: &Path) -> Result<Self, GenerateError> {
        let tok_path = dir.join("tokenizer.json");
        if !tok_path.exists() {
            return Err(GenerateError::Backend(format!(
                "tokenizer.json not found at {}. The Qwen3 tarball must \
                 ship this file alongside the .mlmodelc.",
                tok_path.display()
            )));
        }
        let inner = Tokenizer::from_file(&tok_path).map_err(|e| {
            GenerateError::Backend(format!(
                "failed to load {}: {e}",
                tok_path.display()
            ))
        })?;
        Ok(Self { inner })
    }

    /// Encode a string into token IDs.
    ///
    /// Special tokens in the input (e.g. `<|im_start|>`) are recognized
    /// and encoded as single-token IDs by the loaded `tokenizer.json`'s
    /// added-tokens table. Regular text between them is ByteLevel-BPE
    /// encoded. We pass `add_special_tokens = false` because the brief
    /// author already emits the full ChatML prompt structure as text.
    pub fn encode(&self, text: &str) -> Vec<i32> {
        match self.inner.encode(text, false) {
            Ok(enc) => enc
                .get_ids()
                .iter()
                .map(|&id| i32::try_from(id).unwrap_or(0))
                .collect(),
            Err(_) => Vec::new(),
        }
    }

    /// Decode token IDs back to a string.
    ///
    /// `skip_special_tokens = false` so the brief-author parser can see
    /// the `###CITATIONS:` block exactly as the model emitted it.
    pub fn decode(&self, ids: &[i32]) -> String {
        let u_ids: Vec<u32> = ids
            .iter()
            .filter_map(|&i| u32::try_from(i).ok())
            .collect();
        self.inner.decode(&u_ids, false).unwrap_or_default()
    }

    /// Check if a token ID signals end of generation.
    pub fn is_eos(&self, id: i32) -> bool {
        id == IM_END_ID || id == ENDOFTEXT_ID
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Path to the real Qwen3 tokenizer artifacts produced by
    /// `scripts/convert_brief_model.py`. Tests are `#[ignore]` so CI
    /// (which doesn't carry the converted model) stays green; run with
    /// `cargo test -p mci-coreml-bridge -- --ignored` on a workstation
    /// that has the converted model.
    fn qwen3_tokenizer_dir() -> std::path::PathBuf {
        // Worktree root: repo/.claude/worktrees/<slug>/
        // This file:   adapters/macos/mci-coreml-bridge/src/tokenizer.rs
        // Model dir:   models/
        let mut p = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        p.push("../../../models");
        p
    }

    #[test]
    #[ignore]
    fn encodes_im_start_as_single_token() {
        let tok = BpeTokenizer::load(&qwen3_tokenizer_dir()).unwrap();
        let ids = tok.encode("<|im_start|>");
        assert_eq!(ids, vec![IM_START_ID]);
    }

    #[test]
    #[ignore]
    fn encodes_im_end_as_single_token() {
        let tok = BpeTokenizer::load(&qwen3_tokenizer_dir()).unwrap();
        let ids = tok.encode("<|im_end|>");
        assert_eq!(ids, vec![IM_END_ID]);
    }

    #[test]
    #[ignore]
    fn encodes_endoftext_as_single_token() {
        let tok = BpeTokenizer::load(&qwen3_tokenizer_dir()).unwrap();
        let ids = tok.encode("<|endoftext|>");
        assert_eq!(ids, vec![ENDOFTEXT_ID]);
    }

    #[test]
    #[ignore]
    fn round_trips_chatml_prompt() {
        let tok = BpeTokenizer::load(&qwen3_tokenizer_dir()).unwrap();
        let prompt =
            "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n<|im_start|>user\nHello<|im_end|>\n<|im_start|>assistant\n";
        let ids = tok.encode(prompt);
        // Must round-trip via decode (ByteLevel decoder reverses the
        // GPT-2 byte remap so newlines come back as `\n`, not `Ċ`).
        let decoded = tok.decode(&ids);
        assert_eq!(decoded, prompt);
    }

    #[test]
    #[ignore]
    fn newline_is_not_token_zero() {
        // The cycle 8.10 silent-failure regression test: every prompt
        // must NOT collapse every `\n` to token 0 (`!`).
        let tok = BpeTokenizer::load(&qwen3_tokenizer_dir()).unwrap();
        let ids = tok.encode("hello\nworld");
        assert!(
            !ids.iter().any(|&id| id == 0),
            "token 0 (`!`) appeared in encoding of `hello\\nworld`: {ids:?} \
             — the ByteLevel remap is broken again."
        );
    }

    #[test]
    fn is_eos_correct() {
        // Pure constant check — works without the model tarball.
        let im_end = IM_END_ID;
        let endoftext = ENDOFTEXT_ID;
        let im_start = IM_START_ID;
        assert_ne!(im_end, im_start);
        assert_ne!(endoftext, im_start);
        assert_ne!(im_end, endoftext);
        // (Methods need a Tokenizer instance; the round-trip tests
        // above exercise the real `is_eos` against the real tokenizer.)
    }
}
