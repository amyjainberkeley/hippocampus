//! Production [`Chunker`] impl — paragraph + sentence boundary splitter
//! sized to the arctic-embed-s effective context (ADR-0010 §4 + ADR-0011 +
//! ADR-0016 §1.2).
//!
//! # What this is
//!
//! The P3.4 production impl of the [`Chunker`] trait scaffolded by P3.1.
//! It does the **chunking math only**: given an `event_text` string and a
//! token budget (`embed_context_window_tokens`), produce a `Vec<String>` of
//! sub-chunks each within the budget, split preferentially on paragraph
//! (`\n\n`) boundaries and secondarily on sentence boundaries
//! (period+space / exclam+space / question+space).
//!
//! # Caller-prepends-header invariant (LOAD-BEARING per ADR-0010 §1.3 +
//! ADR-0016 §1.2)
//!
//! The `Chunker` trait surface takes only `event_text: &str` — no per-event
//! context. Per ADR-0010 §1.3 (the LongMemEval-validated "key expansion"
//! lift, +9.4% recall@5) every chunk that reaches the embedder MUST be
//! prepended with the event's context header
//! `[app=<appBundleId> | title=<windowTitle> | url=<url> | ts=<iso8601>]\n<text>`.
//! Because the trait doesn't carry the context, the **caller** (P3.7
//! `HybridRetriever` / P3.2 `BrainStore` write path / the OCR-event
//! ingestor) is responsible for prepending the header to `event_text`
//! **before** calling [`Chunker::chunk`], and for re-prepending it onto
//! second-and-later sub-chunks at embedder-call time. The chunker itself
//! does NOT inject the header.
//!
//! Embedding any chunk WITHOUT the header is an ADR-0016 §4 invariant
//! regression (recall quality drops materially per the `LongMemEval`
//! ablation; this is one of the structural quality lifts ADR-0010
//! purchased for MCI's brain). Trust-by-convention is the trait shape
//! Phase 3 ships with; a follow-up PR (recommended in the P3.4 PR body,
//! out of P3.4 scope) is expected to lift the header onto a typed
//! `EventContext { app, title, url, ts }` argument on the trait so the
//! discipline becomes type-checked rather than reviewer-enforced.
//!
//! # Token approximation
//!
//! Per ADR-0011 the effective context for arctic-embed-s is ~1500 tokens.
//! BPE-accurate tokenization requires the model's tokenizer (Core ML on
//! macOS / ONNX on Windows), which lives behind the [`Embedder`] trait
//! and is not OS-free. The chunker therefore uses a cheap **word-count
//! approximation** — `str::split_whitespace().count()` — as the proxy
//! for token count. The approximation is conservative for English UI/OCR
//! text on the order of `tokens ≈ 1.3 × words`; the default ceiling
//! (1500 word-tokens) therefore corresponds to ~2000 BPE tokens, which
//! is safely above arctic-embed-s's actual 512-token internal sequence
//! ceiling (the model truncates above 512 internally — the 1500-token
//! "effective context" figure in ADR-0010/0016 refers to the
//! semantically-coherent window before truncation degrades retrieval).
//! Production downstream consumers (P3.3 `ArcticEmbedSEmbedder` wrapper)
//! re-truncate at the BPE-tokenizer level if necessary; the chunker's
//! job here is the upstream semantic-boundary split.
//!
//! The word-count approximation is intentional: it is OS-free, requires
//! no external tokenizer, and is deterministic across machines (no
//! `DefaultHasher`-style instability). Cross-machine reproducibility is
//! a P3.7 retrieval-eval requirement (ADR-0016 §7 binding-before-merge).
//!
//! [`Chunker`]: crate::Chunker
//! [`Embedder`]: crate::Embedder

use crate::{Chunker, ChunkerError};

/// Default token budget. Matches the arctic-embed-s effective-context
/// figure cited in ADR-0010 §4 / ADR-0016 §1.2. The chunker compares this
/// against a whitespace-word count (see the module-level doc for the
/// approximation rationale).
pub const DEFAULT_EMBED_CONTEXT_WINDOW_TOKENS: usize = 1500;

/// Production [`Chunker`] — splits an event's text into one-or-more
/// sub-chunks each within a configurable token budget.
///
/// # Behavior
///
/// - **Empty or whitespace-only input** ⇒ `Ok(vec![])`.
/// - **Short input** (word count ≤ `embed_context_window_tokens`)
///   ⇒ `Ok(vec![event_text.to_string()])` — single chunk, exact
///   round-trip of the input.
/// - **Long input** (word count > `embed_context_window_tokens`)
///   ⇒ split on paragraph boundaries first (`"\n\n"`); within
///   paragraphs split on sentence-end punctuation followed by
///   whitespace (`. `, `! `, `? `); greedily accumulate sentences into
///   the current chunk until the next sentence would push the chunk's
///   word count over `embed_context_window_tokens`, then start a new
///   chunk. Sentences from different paragraphs in the same chunk are
///   re-joined with `"\n\n"`; sentences within one paragraph in the
///   same chunk are joined with a single space.
///
/// # Caller-prepends-header invariant
///
/// See the module-level doc-comment. The chunker does NOT prepend the
/// ADR-0010 §1.3 context header — that is the caller's responsibility
/// **before** invoking [`Chunker::chunk`]. Embedding any chunk without
/// the header is an ADR-0016 §4 invariant regression.
///
/// # Examples
///
/// ```
/// use mci_brain::{Chunker, EventChunker};
/// let chunker = EventChunker::default();
/// let chunks = chunker.chunk("a single short event").unwrap();
/// assert_eq!(chunks, vec!["a single short event".to_string()]);
/// ```
#[derive(Debug, Clone, Copy)]
pub struct EventChunker {
    /// The per-chunk word-count ceiling. See module-level doc for why a
    /// word-count approximation is used in place of a true BPE
    /// tokenizer.
    pub embed_context_window_tokens: usize,
}

impl Default for EventChunker {
    fn default() -> Self {
        Self {
            embed_context_window_tokens: DEFAULT_EMBED_CONTEXT_WINDOW_TOKENS,
        }
    }
}

impl EventChunker {
    /// Construct an [`EventChunker`] with a custom per-chunk word-count
    /// ceiling. Use [`EventChunker::default`] for the production
    /// arctic-embed-s figure (1500).
    #[must_use]
    pub fn new(embed_context_window_tokens: usize) -> Self {
        Self {
            embed_context_window_tokens,
        }
    }
}

impl Chunker for EventChunker {
    fn chunk(&self, event_text: &str) -> Result<Vec<String>, ChunkerError> {
        if event_text.trim().is_empty() {
            return Ok(Vec::new());
        }
        if word_count(event_text) <= self.embed_context_window_tokens {
            return Ok(vec![event_text.to_string()]);
        }

        let paragraphs: Vec<&str> = event_text
            .split("\n\n")
            .map(str::trim)
            .filter(|p| !p.is_empty())
            .collect();

        let mut chunks: Vec<String> = Vec::new();
        let mut current = String::new();
        let mut current_words: usize = 0;

        for paragraph in &paragraphs {
            let sentences = split_sentences(paragraph);
            for (s_idx, sentence) in sentences.iter().enumerate() {
                let sw = word_count(sentence);
                let separator: &str = if current.is_empty() {
                    ""
                } else if s_idx == 0 {
                    "\n\n"
                } else {
                    " "
                };

                let would_overflow = current_words + sw > self.embed_context_window_tokens;
                if would_overflow && !current.is_empty() {
                    chunks.push(std::mem::take(&mut current));
                    current.push_str(sentence);
                    current_words = sw;
                } else {
                    current.push_str(separator);
                    current.push_str(sentence);
                    current_words += sw;
                }
            }
        }
        if !current.is_empty() {
            chunks.push(current);
        }
        Ok(chunks)
    }
}

/// Whitespace-word count — the token-count proxy. See module-level doc
/// for the approximation rationale.
fn word_count(s: &str) -> usize {
    s.split_whitespace().count()
}

/// Split a paragraph into sentences on `. `, `! `, `? ` boundaries.
///
/// Keeps the terminating punctuation attached to the sentence it ends
/// (so re-joining sentences preserves the punctuation). Collapses
/// runs of whitespace between sentences. A paragraph that contains no
/// sentence-end punctuation followed by whitespace is returned as a
/// single one-element vec (the whole paragraph as one "sentence").
fn split_sentences(paragraph: &str) -> Vec<String> {
    let chars: Vec<char> = paragraph.chars().collect();
    let mut sentences: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        current.push(c);
        let is_terminator = c == '.' || c == '!' || c == '?';
        let next_is_ws = i + 1 < chars.len() && chars[i + 1].is_whitespace();
        if is_terminator && next_is_ws {
            let trimmed = current.trim().to_string();
            if !trimmed.is_empty() {
                sentences.push(trimmed);
            }
            current.clear();
            i += 1;
            while i < chars.len() && chars[i].is_whitespace() {
                i += 1;
            }
            continue;
        }
        i += 1;
    }
    let tail = current.trim().to_string();
    if !tail.is_empty() {
        sentences.push(tail);
    }
    sentences
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_window_is_1500() {
        let c = EventChunker::default();
        assert_eq!(c.embed_context_window_tokens, 1500);
        assert_eq!(
            c.embed_context_window_tokens,
            DEFAULT_EMBED_CONTEXT_WINDOW_TOKENS
        );
    }

    #[test]
    fn word_count_counts_whitespace_split_tokens() {
        assert_eq!(word_count(""), 0);
        assert_eq!(word_count("   \n\n  \t "), 0);
        assert_eq!(word_count("one"), 1);
        assert_eq!(word_count("one two three"), 3);
        assert_eq!(word_count("one\n\ntwo\tthree"), 3);
    }

    #[test]
    fn split_sentences_keeps_terminator_attached() {
        let s = split_sentences("Hello world. How are you? I am fine!");
        assert_eq!(s, vec!["Hello world.", "How are you?", "I am fine!"]);
    }

    #[test]
    fn split_sentences_returns_one_element_for_no_terminator() {
        let s = split_sentences("no terminating punct here just words");
        assert_eq!(s, vec!["no terminating punct here just words"]);
    }
}
