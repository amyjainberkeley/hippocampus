//! Integration tests for the P3.4 [`EventChunker`] production [`Chunker`]
//! impl.
//!
//! Pins the ADR-0016 §1.2 + ADR-0010 §4 contract: paragraph-then-sentence
//! greedy boundary splitter, sized to a configurable per-chunk word-count
//! ceiling (default 1500 ≈ arctic-embed-s effective context per ADR-0011).
//! The caller-prepends-header invariant lives in the trait + impl
//! doc-comments; these tests exercise the chunking math only.
//!
//! [`Chunker`]: mci_brain::Chunker
//! [`EventChunker`]: mci_brain::EventChunker

use std::fmt::Write as _;

use mci_brain::{Chunker, EventChunker};

/// Helper: produce N space-separated "wN" word tokens. Lets a test pick a
/// precise word count (e.g. `n_words(2000)` → 2000-word string the
/// default chunker MUST split).
fn n_words(n: usize) -> String {
    let mut s = String::with_capacity(n * 4);
    for i in 0..n {
        if i > 0 {
            s.push(' ');
        }
        write!(s, "w{i}").expect("infallible string write");
    }
    s
}

fn word_count(s: &str) -> usize {
    s.split_whitespace().count()
}

// ---------------------------------------------------------------------------
// 1. Empty / whitespace-only inputs
// ---------------------------------------------------------------------------

#[test]
fn empty_input_returns_empty_vec() {
    let c = EventChunker::default();
    let out = c.chunk("").expect("chunk");
    assert!(out.is_empty(), "empty input → empty vec, got {out:?}");
}

#[test]
fn whitespace_only_input_returns_empty_vec() {
    let c = EventChunker::default();
    for input in ["   ", "\t", "\n", "\n\n\n\n", " \t\n  \r\n  "] {
        let out = c.chunk(input).expect("chunk");
        assert!(
            out.is_empty(),
            "whitespace-only input {input:?} → empty vec, got {out:?}"
        );
    }
}

// ---------------------------------------------------------------------------
// 2. Short input (≤ window) — single-chunk, exact round-trip
// ---------------------------------------------------------------------------

#[test]
fn single_paragraph_under_window_returns_one_chunk_equal_to_input() {
    let c = EventChunker::default();
    let input = "a short event with thirteen words, all in one paragraph here.";
    let out = c.chunk(input).expect("chunk");
    assert_eq!(out.len(), 1);
    assert_eq!(
        out[0], input,
        "short single-paragraph input → exact round-trip"
    );
}

#[test]
fn multi_paragraph_under_window_returns_one_chunk_equal_to_input() {
    let c = EventChunker::default();
    let input = "para one with some words.\n\npara two with other words.\n\npara three closes.";
    let out = c.chunk(input).expect("chunk");
    assert_eq!(
        out.len(),
        1,
        "total ≤ window → one chunk regardless of paragraph count, got {out:?}"
    );
    assert_eq!(
        out[0], input,
        "under-window multi-paragraph input → exact round-trip"
    );
}

// ---------------------------------------------------------------------------
// 3. Long input — multi-chunk, each ≤ window
// ---------------------------------------------------------------------------

#[test]
fn single_paragraph_over_window_splits_into_multi_chunk_each_within_budget() {
    let c = EventChunker::new(50);
    // One paragraph of 30 sentences, 10 words each = 300 words; ≥ 2 chunks
    // at a 50-word ceiling. Sentences have an explicit terminator so the
    // splitter has a boundary to break on.
    let mut paragraph = String::new();
    for sentence_idx in 0..30 {
        let mut sentence = String::new();
        for w in 0..10 {
            if w > 0 {
                sentence.push(' ');
            }
            write!(sentence, "s{sentence_idx}w{w}").expect("infallible string write");
        }
        sentence.push('.');
        if sentence_idx > 0 {
            paragraph.push(' ');
        }
        paragraph.push_str(&sentence);
    }
    let out = c.chunk(&paragraph).expect("chunk");
    assert!(
        out.len() > 1,
        "300-word paragraph at window=50 must split, got {} chunk(s)",
        out.len()
    );
    for (i, ck) in out.iter().enumerate() {
        let wc = word_count(ck);
        assert!(
            wc <= 50,
            "chunk #{i} has {wc} words, exceeds window=50; chunk={ck:?}"
        );
    }
}

#[test]
fn multi_paragraph_over_window_splits_on_paragraph_boundary_first() {
    let c = EventChunker::new(30);
    // Two paragraphs of 25 words each: each fits the 30-word window
    // individually, but together they overflow. Greedy packer SHOULD
    // emit chunk #1 = paragraph 1 (25 words), chunk #2 = paragraph 2
    // (25 words) — the boundary lands exactly on `\n\n` because the
    // second paragraph's first sentence would push the total over.
    let p1 = n_words(25) + ".";
    let p2 = n_words(25) + ".";
    let input = format!("{p1}\n\n{p2}");
    let out = c.chunk(&input).expect("chunk");
    assert_eq!(
        out.len(),
        2,
        "two ~equal paragraphs straddling the window → split on \\n\\n, got {} chunks: {out:?}",
        out.len()
    );
    assert!(
        out[0].contains("w0 ") && !out[0].contains("w25"),
        "chunk 0 should hold paragraph 1 only; got {:?}",
        out[0]
    );
    // Each chunk individually within budget.
    for (i, ck) in out.iter().enumerate() {
        assert!(
            word_count(ck) <= 30,
            "chunk #{i} has {} words, exceeds window=30",
            word_count(ck)
        );
    }
}

#[test]
fn sentence_split_within_long_paragraph() {
    // Two sentences of 40 words each, ONE paragraph, window=50. Greedy
    // packer accumulates sentence 1 (40 words), but sentence 2 would
    // push to 80 > 50, so chunk #1 = sentence 1, chunk #2 = sentence 2.
    let c = EventChunker::new(50);
    let s1 = n_words(40) + ".";
    let s2 = format!(
        " {}.",
        (40..80)
            .map(|i| format!("w{i}"))
            .collect::<Vec<_>>()
            .join(" ")
    );
    let input = format!("{s1}{s2}");
    let out = c.chunk(&input).expect("chunk");
    assert_eq!(
        out.len(),
        2,
        "two 40-word sentences at window=50 must split → 2 chunks, got {}: {out:?}",
        out.len()
    );
    for (i, ck) in out.iter().enumerate() {
        assert!(
            word_count(ck) <= 50,
            "chunk #{i} has {} words, exceeds window=50",
            word_count(ck)
        );
    }
}

// ---------------------------------------------------------------------------
// 4. Configurable window
// ---------------------------------------------------------------------------

#[test]
fn default_window_vs_override_produces_different_chunk_counts() {
    // 300 sentences × 1 word each (with terminator) = 300 "sentences"
    // and 300 words. Default window=1500 ⇒ 1 chunk. Override window=100
    // ⇒ ≥ 3 chunks.
    let mut input = String::new();
    for i in 0..300 {
        if i > 0 {
            input.push(' ');
        }
        write!(input, "w{i}.").expect("infallible string write");
    }
    let big = EventChunker::default();
    let small = EventChunker::new(100);
    let out_big = big.chunk(&input).expect("chunk");
    let out_small = small.chunk(&input).expect("chunk");
    assert_eq!(
        out_big.len(),
        1,
        "300 words ≤ default 1500 → 1 chunk, got {}",
        out_big.len()
    );
    assert!(
        out_small.len() >= 3,
        "300 words at window=100 → ≥ 3 chunks, got {}",
        out_small.len()
    );
}

#[test]
fn override_window_zero_or_tiny_still_emits_at_least_one_chunk_per_sentence() {
    // Pathological window=1: each sentence is "oversized" alone but the
    // chunker must still emit something (no infinite loop, no panics).
    // Each chunk holds exactly one sentence because adding any next
    // sentence would overflow trivially.
    let c = EventChunker::new(1);
    let input = "alpha beta gamma. delta epsilon. zeta.";
    let out = c.chunk(input).expect("chunk");
    assert!(!out.is_empty(), "tiny window must still produce output");
    // The greedy packer holds the first sentence even though it
    // overflows window=1, because emitting an empty chunk is worse.
    assert_eq!(out.len(), 3, "expect one chunk per sentence, got {out:?}");
}

// ---------------------------------------------------------------------------
// 5. Boundary preservation
// ---------------------------------------------------------------------------

#[test]
fn long_input_chunks_preserve_paragraph_separator_when_packed_together() {
    // Two small paragraphs that together exceed the window: they MUST
    // split. But three small paragraphs where the first two fit and
    // the third overflows: chunk 1 = para1 + "\n\n" + para2, chunk 2 =
    // para3.
    let c = EventChunker::new(40);
    let p1 = n_words(15) + ".";
    let p2 = n_words(15) + ".";
    let p3 = n_words(15) + ".";
    let input = format!("{p1}\n\n{p2}\n\n{p3}");
    let out = c.chunk(&input).expect("chunk");
    assert_eq!(
        out.len(),
        2,
        "expect 2 chunks for 15+15+15 at window=40, got {out:?}"
    );
    assert!(
        out[0].contains("\n\n"),
        "first chunk should hold both paras joined with \\n\\n; got {:?}",
        out[0]
    );
    assert!(
        !out[1].contains("\n\n"),
        "second chunk should be single paragraph; got {:?}",
        out[1]
    );
}

// ---------------------------------------------------------------------------
// 6. Caller-prepends-header convention — chunker round-trips it on the
//    single-chunk path. (Documents the invariant; does not enforce it.)
// ---------------------------------------------------------------------------

#[test]
fn short_input_with_context_header_round_trips_exactly() {
    // The CALLER prepends `[app=... | title=... | url=... | ts=...]\n`
    // per ADR-0010 §1.3. On the short-input path the chunker must
    // return that exact string back (single chunk, no mutation).
    let c = EventChunker::default();
    let header = "[app=com.apple.Safari | title=Apple — Newsroom | \
        url=https://www.apple.com/newsroom | ts=2026-05-20T18:00:00Z]\n";
    let body = "Apple today announced a new product.";
    let with_header = format!("{header}{body}");
    let out = c.chunk(&with_header).expect("chunk");
    assert_eq!(out.len(), 1);
    assert_eq!(
        out[0], with_header,
        "short-path round-trip must preserve caller-prepended header verbatim"
    );
}

// ---------------------------------------------------------------------------
// 7. Unicode safety
// ---------------------------------------------------------------------------

#[test]
fn unicode_input_does_not_panic_and_round_trips_short_path() {
    let c = EventChunker::default();
    let input = "日本語テキスト。 emoji 🚀✨ café résumé naïve.\n\nLine 2 — em-dash.";
    let out = c.chunk(input).expect("chunk");
    assert_eq!(out.len(), 1);
    assert_eq!(out[0], input);
}

// ---------------------------------------------------------------------------
// 8. Determinism — same input + same chunker config → same output across
//    invocations. (Required by ADR-0016 §7 retrieval-eval reproducibility.)
// ---------------------------------------------------------------------------

#[test]
fn chunker_is_deterministic_across_invocations() {
    let c = EventChunker::new(50);
    let s1 = n_words(40) + ".";
    let s2 = format!(
        " {}.",
        (40..80)
            .map(|i| format!("w{i}"))
            .collect::<Vec<_>>()
            .join(" ")
    );
    let input = format!("{s1}{s2}");
    let a = c.chunk(&input).expect("chunk");
    let b = c.chunk(&input).expect("chunk");
    let d = c.chunk(&input).expect("chunk");
    assert_eq!(a, b);
    assert_eq!(b, d);
}
