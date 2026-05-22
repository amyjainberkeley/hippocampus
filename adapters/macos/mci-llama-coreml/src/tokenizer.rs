//! Byte-level BPE tokenizer compatible with Qwen3's tokenizer.
//!
//! Loads `vocab.json` + `merges.txt` from disk (shipped alongside the
//! downloaded model at `~/Library/Application Support/MCI/Models/`).
//!
//! # Special tokens
//!
//! Qwen3 ChatML:
//! - `<|im_start|>` (ID 151644)
//! - `<|im_end|>` (ID 151645)
//! - `<|endoftext|>` (ID 151643)

use std::collections::HashMap;
use std::path::Path;

use mci_brief::llama_backend::GenerateError;

pub const IM_START_ID: i32 = 151_644;
pub const IM_END_ID: i32 = 151_645;
pub const ENDOFTEXT_ID: i32 = 151_643;

pub struct BpeTokenizer {
    encoder: HashMap<Vec<u8>, i32>,
    decoder: HashMap<i32, Vec<u8>>,
    merges: Vec<(Vec<u8>, Vec<u8>)>,
    special_tokens: Vec<(String, i32)>,
    special_ids: HashMap<i32, String>,
}

impl std::fmt::Debug for BpeTokenizer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BpeTokenizer")
            .field("vocab_size", &self.encoder.len())
            .field("merges", &self.merges.len())
            .finish()
    }
}

impl BpeTokenizer {
    /// Load tokenizer from a directory containing `vocab.json` and `merges.txt`.
    pub fn load(dir: &Path) -> Result<Self, GenerateError> {
        let vocab_path = dir.join("vocab.json");
        let merges_path = dir.join("merges.txt");

        let vocab_bytes = std::fs::read(&vocab_path).map_err(|e| {
            GenerateError::Backend(format!("failed to read {}: {e}", vocab_path.display()))
        })?;
        let merges_text = std::fs::read_to_string(&merges_path).map_err(|e| {
            GenerateError::Backend(format!("failed to read {}: {e}", merges_path.display()))
        })?;

        let raw_vocab: HashMap<String, i32> =
            serde_json::from_slice(&vocab_bytes).map_err(|e| {
                GenerateError::Backend(format!("failed to parse vocab.json: {e}"))
            })?;

        let mut encoder: HashMap<Vec<u8>, i32> = HashMap::with_capacity(raw_vocab.len());
        let mut decoder: HashMap<i32, Vec<u8>> = HashMap::with_capacity(raw_vocab.len());
        let mut special_tokens: Vec<(String, i32)> = Vec::new();
        let mut special_ids: HashMap<i32, String> = HashMap::new();

        for (token_str, id) in &raw_vocab {
            if token_str.starts_with("<|") && token_str.ends_with("|>") {
                special_tokens.push((token_str.clone(), *id));
                special_ids.insert(*id, token_str.clone());
            } else {
                let bytes = token_str.as_bytes().to_vec();
                encoder.insert(bytes.clone(), *id);
                decoder.insert(*id, bytes);
            }
        }

        // Sort special tokens longest-first for greedy matching.
        special_tokens.sort_by(|a, b| b.0.len().cmp(&a.0.len()));

        let merges = parse_merges(&merges_text)?;

        Ok(Self {
            encoder,
            decoder,
            merges,
            special_tokens,
            special_ids,
        })
    }

    /// Encode a string into token IDs.
    ///
    /// Special tokens in the input are recognized and encoded as single
    /// tokens. Regular text between them is BPE-encoded.
    pub fn encode(&self, text: &str) -> Vec<i32> {
        let mut result = Vec::new();
        let mut remaining = text;

        while !remaining.is_empty() {
            if let Some((len, id)) = self.match_special_token(remaining) {
                result.push(id);
                remaining = &remaining[len..];
            } else {
                let next_special = self.next_special_position(remaining);
                let chunk = &remaining[..next_special];
                remaining = &remaining[next_special..];
                result.extend(self.bpe_encode_chunk(chunk));
            }
        }

        result
    }

    /// Decode token IDs back to a string.
    pub fn decode(&self, ids: &[i32]) -> String {
        let mut bytes = Vec::new();
        for &id in ids {
            if let Some(special) = self.special_ids.get(&id) {
                bytes.extend_from_slice(special.as_bytes());
            } else if let Some(token_bytes) = self.decoder.get(&id) {
                bytes.extend_from_slice(token_bytes);
            }
        }
        String::from_utf8_lossy(&bytes).into_owned()
    }

    /// Check if a token ID signals end of generation.
    pub fn is_eos(&self, id: i32) -> bool {
        id == IM_END_ID || id == ENDOFTEXT_ID
    }

    fn match_special_token(&self, text: &str) -> Option<(usize, i32)> {
        for (token, id) in &self.special_tokens {
            if text.starts_with(token.as_str()) {
                return Some((token.len(), *id));
            }
        }
        None
    }

    fn next_special_position(&self, text: &str) -> usize {
        let mut earliest = text.len();
        for (token, _) in &self.special_tokens {
            if let Some(pos) = text.find(token.as_str()) {
                if pos > 0 && pos < earliest {
                    earliest = pos;
                }
            }
        }
        earliest
    }

    /// BPE-encode a chunk of regular text (no special tokens).
    fn bpe_encode_chunk(&self, text: &str) -> Vec<i32> {
        if text.is_empty() {
            return Vec::new();
        }

        let bytes = text.as_bytes();
        let mut pieces: Vec<Vec<u8>> = bytes.iter().map(|&b| vec![b]).collect();

        for (left, right) in &self.merges {
            let mut i = 0;
            while i + 1 < pieces.len() {
                if pieces[i] == *left && pieces[i + 1] == *right {
                    let mut merged = pieces[i].clone();
                    merged.extend_from_slice(&pieces[i + 1]);
                    pieces[i] = merged;
                    pieces.remove(i + 1);
                } else {
                    i += 1;
                }
            }
        }

        pieces
            .iter()
            .map(|p| self.encoder.get(p).copied().unwrap_or(0))
            .collect()
    }
}

fn parse_merges(content: &str) -> Result<Vec<(Vec<u8>, Vec<u8>)>, GenerateError> {
    let mut merges = Vec::new();
    for line in content.lines() {
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        let mut parts = line.splitn(2, ' ');
        let left = match parts.next() {
            Some(s) if !s.is_empty() => s,
            _ => continue,
        };
        let right = match parts.next() {
            Some(s) if !s.is_empty() => s,
            _ => continue,
        };
        merges.push((left.as_bytes().to_vec(), right.as_bytes().to_vec()));
    }
    Ok(merges)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn create_test_tokenizer_dir() -> tempfile::TempDir {
        let dir = tempfile::TempDir::new().unwrap();

        let vocab: HashMap<&str, i32> = [
            ("h", 104),
            ("e", 101),
            ("l", 108),
            ("o", 111),
            ("he", 200),
            ("ll", 201),
            ("lo", 202),
            ("hel", 300),
            ("hello", 400),
            ("<|im_start|>", 151_644),
            ("<|im_end|>", 151_645),
            ("<|endoftext|>", 151_643),
        ]
        .into_iter()
        .collect();

        let vocab_json = serde_json::to_string(&vocab).unwrap();
        let mut f = std::fs::File::create(dir.path().join("vocab.json")).unwrap();
        f.write_all(vocab_json.as_bytes()).unwrap();

        // Merge order matters: each rule is applied across all pieces
        // before the next rule. "hello" = [h][e][l][l][o] →
        //   h e   → [he][l][l][o]
        //   l o   → [he][l][lo]
        //   he l  → [hel][lo]
        //   hel lo → [hello]
        std::fs::write(
            dir.path().join("merges.txt"),
            "h e\nl o\nhe l\nhel lo\n",
        )
        .unwrap();

        dir
    }

    #[test]
    fn load_from_files() {
        let dir = create_test_tokenizer_dir();
        let tok = BpeTokenizer::load(dir.path()).unwrap();
        assert!(!tok.encoder.is_empty());
        assert!(!tok.merges.is_empty());
    }

    #[test]
    fn encode_special_tokens() {
        let dir = create_test_tokenizer_dir();
        let tok = BpeTokenizer::load(dir.path()).unwrap();
        assert_eq!(tok.encode("<|im_start|>"), vec![IM_START_ID]);
        assert_eq!(tok.encode("<|im_end|>"), vec![IM_END_ID]);
    }

    #[test]
    fn decode_special_tokens() {
        let dir = create_test_tokenizer_dir();
        let tok = BpeTokenizer::load(dir.path()).unwrap();
        assert_eq!(
            tok.decode(&[IM_START_ID, IM_END_ID]),
            "<|im_start|><|im_end|>"
        );
    }

    #[test]
    fn encode_bpe_merges() {
        let dir = create_test_tokenizer_dir();
        let tok = BpeTokenizer::load(dir.path()).unwrap();
        let ids = tok.encode("hello");
        assert_eq!(ids, vec![400]);
    }

    #[test]
    fn encode_mixed_special_and_text() {
        let dir = create_test_tokenizer_dir();
        let tok = BpeTokenizer::load(dir.path()).unwrap();
        let ids = tok.encode("<|im_start|>hello<|im_end|>");
        assert_eq!(ids[0], IM_START_ID);
        assert_eq!(ids[1], 400); // "hello" merged
        assert_eq!(ids[2], IM_END_ID);
    }

    #[test]
    fn is_eos_correct() {
        let dir = create_test_tokenizer_dir();
        let tok = BpeTokenizer::load(dir.path()).unwrap();
        assert!(tok.is_eos(IM_END_ID));
        assert!(tok.is_eos(ENDOFTEXT_ID));
        assert!(!tok.is_eos(IM_START_ID));
        assert!(!tok.is_eos(0));
    }

    #[test]
    fn load_fails_missing_vocab() {
        let dir = tempfile::TempDir::new().unwrap();
        std::fs::write(dir.path().join("merges.txt"), "").unwrap();
        let err = BpeTokenizer::load(dir.path()).unwrap_err();
        assert!(err.to_string().contains("vocab.json"));
    }

    #[test]
    fn load_fails_missing_merges() {
        let dir = tempfile::TempDir::new().unwrap();
        std::fs::write(dir.path().join("vocab.json"), "{}").unwrap();
        let err = BpeTokenizer::load(dir.path()).unwrap_err();
        assert!(err.to_string().contains("merges.txt"));
    }
}
