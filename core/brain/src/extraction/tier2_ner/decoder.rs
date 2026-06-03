//! BIO span-merge decoder for the V2-P5+ Tier-2 supervised NER model.
//!
//! Turns a token-classifier's per-token logits (`[seq_len,
//! num_labels]`) into typed **byte** spans over the original text, using
//! the byte-offset mapping from [`super::tokenizer`]. This is a faithful
//! port of `HuggingFace`'s `aggregation_strategy="simple"` path
//! (`transformers/pipelines/token_classification.py`:
//! `gather_pre_entities` → `aggregate` (SIMPLE) → `group_entities` →
//! `group_sub_entities`). The golden tests assert byte-for-byte span
//! parity with the real pipeline on every fixture.
//!
//! # The "simple" algorithm, exactly
//!
//! 1. **Softmax + argmax per token.** For each non-special token,
//!    softmax the logit row over the label dimension; the token's label
//!    is the argmax, its score is that label's probability.
//! 2. **BIO grouping.** Walk the per-token labels left to right. A token
//!    continues the current group iff its tag (the part after `B-`/`I-`)
//!    equals the previous token's tag **and** its prefix is not `B`
//!    (a fresh `B-` always starts a new group, even of the same tag —
//!    so two adjacent people are two entities). Anything else closes the
//!    current group and starts a new one. `O` and any non-`B`/`I` label
//!    are treated as prefix `I`, tag = the label itself, so runs of `O`
//!    group together and are dropped.
//! 3. **Span + score.** A group's byte span is
//!    `(first_token.start, last_token.end)`; its confidence is the mean
//!    of its member tokens' scores.
//! 4. **Filter + map.** Drop `O` groups. Map the `CoNLL` tag to our
//!    entity-kind constant: `PER → person_name`, `ORG → organization`,
//!    `LOC → location`; `MISC` (and anything else) is dropped — it is
//!    not in the V2-P5 schema.
//!
//! # Why faithful, not "improved"
//!
//! The decoder reproduces HF behavior including its quirks (e.g. a
//! subword-inconsistent `B-LOC B-LOC` run yields multiple one-subword
//! spans, see the `MEETING WITH SATYA NADELLA AT MICROSOFT HQ` fixture).
//! Reproducing the model+pipeline exactly is what lets the offline
//! conversion bake-off (P1′) compare Rust-decoded output against a
//! Python reference with zero decoder-side variance. Span-quality
//! improvements (subword cleanup, confidence reweighting) are a separate,
//! later, explicitly-ratified change — not silent drift here.
//!
//! # OS-purity / footprint
//!
//! Pure Rust, zero third-party deps, no allocation beyond the output
//! `Vec` + one scratch softmax buffer per token. No Core ML, no
//! `unsafe`. Decoding a ~30-token sequence is sub-microsecond; it runs
//! in the same async idle-batch worker as the rest of Tier 2, never on
//! the brain ingest hot path.

use crate::extraction::tier2::{KIND_LOCATION, KIND_ORGANIZATION, KIND_PERSON_NAME};

/// `id2label` for `dslim/distilbert-NER`, in model-config order.
///
/// **Pinned** by the `id2label_matches_bundled_config` golden test
/// against `resources/config.json` — do NOT edit by hand. Note the
/// ordering puts `PER` before `ORG`/`LOC` (distinct from
/// `dslim/bert-base-NER`, which leads with `MISC`); reading it from the
/// real config rather than assuming a canonical order is load-bearing.
pub const DISTILBERT_NER_ID2LABEL: [&str; 9] = [
    "O", "B-PER", "I-PER", "B-ORG", "I-ORG", "B-LOC", "I-LOC", "B-MISC", "I-MISC",
];

/// One decoded entity span over the original text.
///
/// Byte-span based, mirroring [`crate::extraction::tier2::Tier2RawMatch`]
/// so a NER [`crate::extraction::tier2::NerBackend`] can build a
/// `Tier2RawMatch` from one of these by adding a normalized
/// `canonical_name` (title-casing for people, etc. — the backend's job,
/// not the decoder's). `text` is the verbatim source substring
/// (`original[span_start..span_end]`), which is exactly what the
/// extractor's `verify_span` hallucination guard checks.
#[derive(Debug, Clone, PartialEq)]
pub struct DecodedSpan {
    /// One of `person_name` / `organization` / `location` (the
    /// `KIND_*` constants from [`crate::extraction::tier2`]).
    pub kind: String,
    /// Verbatim source substring `text[span_start..span_end]`.
    pub text: String,
    /// Inclusive byte offset of the span start in the original text.
    pub span_start: usize,
    /// Exclusive byte offset of the span end in the original text.
    pub span_end: usize,
    /// Mean of the member tokens' argmax-softmax probabilities, in
    /// `[0.0, 1.0]`.
    pub confidence: f32,
}

/// Decode `dslim/distilbert-NER` logits with the pinned 9-label scheme.
///
/// Convenience wrapper over [`decode_bio`] with
/// [`DISTILBERT_NER_ID2LABEL`] and `num_labels = 9`.
#[must_use]
pub fn decode_distilbert_ner(
    text: &str,
    logits: &[f32],
    seq_len: usize,
    offsets: &[(usize, usize)],
    special_tokens_mask: &[i32],
    attention_mask: &[i32],
) -> Vec<DecodedSpan> {
    decode_bio(
        text,
        logits,
        seq_len,
        DISTILBERT_NER_ID2LABEL.len(),
        offsets,
        special_tokens_mask,
        attention_mask,
        &DISTILBERT_NER_ID2LABEL,
    )
}

/// Per-token classifier state, mid-grouping.
struct TokenLabel<'a> {
    label: &'a str,
    score: f32,
    start: usize,
    end: usize,
}

/// Decode token-classifier logits into typed byte spans.
///
/// `logits` is row-major `[seq_len * num_labels]`. `offsets`,
/// `special_tokens_mask`, and `attention_mask` are each `seq_len` long
/// (byte offsets per [`super::tokenizer`]). `id2label` is `num_labels`
/// long, IOB2-tagged (`B-X` / `I-X` / `O`).
///
/// Returns spans in text order. A length mismatch between the arrays
/// (defensive: should never happen for a well-formed model IO) yields an
/// empty result rather than a panic.
#[must_use]
#[allow(clippy::too_many_arguments)]
pub fn decode_bio(
    text: &str,
    logits: &[f32],
    seq_len: usize,
    num_labels: usize,
    offsets: &[(usize, usize)],
    special_tokens_mask: &[i32],
    attention_mask: &[i32],
    id2label: &[&str],
) -> Vec<DecodedSpan> {
    // Defensive shape checks — a malformed IO drops to empty, never
    // panics in a production worker.
    if num_labels == 0
        || id2label.len() != num_labels
        || logits.len() != seq_len.saturating_mul(num_labels)
        || offsets.len() != seq_len
        || special_tokens_mask.len() != seq_len
        || attention_mask.len() != seq_len
    {
        return Vec::new();
    }

    // 1. Per-token argmax + softmax score, skipping special / padding.
    //
    // HF's `gather_pre_entities` skips only `special_tokens_mask`. For a
    // sequence from this module's `encode`/`encode_padded`, padding is
    // always also flagged special, so the two are equivalent and output
    // parity holds (the golden fixtures pin this). We additionally skip
    // `attention_mask == 0` defensively so the decoder stays correct even
    // if a future backend passes a padded sequence whose pad tokens were
    // not flagged special — covered by the
    // `special_and_pad_tokens_are_skipped` unit test.
    let mut tokens: Vec<TokenLabel> = Vec::with_capacity(seq_len);
    for (idx, row) in logits.chunks_exact(num_labels).enumerate() {
        if special_tokens_mask[idx] != 0 || attention_mask[idx] == 0 {
            continue;
        }
        let (best, score) = softmax_argmax(row);
        tokens.push(TokenLabel {
            label: id2label[best],
            score,
            start: offsets[idx].0,
            end: offsets[idx].1,
        });
    }

    // 2. BIO grouping (HF `group_entities`).
    let mut out: Vec<DecodedSpan> = Vec::new();
    let mut group: Vec<&TokenLabel> = Vec::new();
    for tok in &tokens {
        if group.is_empty() {
            group.push(tok);
            continue;
        }
        let (bi, tag) = get_tag(tok.label);
        let (_, last_tag) = get_tag(group[group.len() - 1].label);
        if tag == last_tag && bi != Bi::B {
            group.push(tok);
        } else {
            flush_group(text, &group, &mut out);
            group.clear();
            group.push(tok);
        }
    }
    flush_group(text, &group, &mut out);

    out
}

/// B/I prefix of an IOB2 label.
#[derive(PartialEq, Eq)]
enum Bi {
    B,
    I,
}

/// Split an IOB2 label into its prefix + tag, matching HF `get_tag`:
/// `B-X → (B, "X")`, `I-X → (I, "X")`, anything else (incl. `O`) →
/// `(I, label)` so `O` runs coalesce and a bare `I-`/odd label is a
/// tolerant continuation/start.
fn get_tag(label: &str) -> (Bi, &str) {
    if let Some(tag) = label.strip_prefix("B-") {
        (Bi::B, tag)
    } else if let Some(tag) = label.strip_prefix("I-") {
        (Bi::I, tag)
    } else {
        (Bi::I, label)
    }
}

/// Map a `CoNLL` tag to our entity-kind constant, or `None` to drop.
fn tag_to_kind(tag: &str) -> Option<&'static str> {
    match tag {
        "PER" => Some(KIND_PERSON_NAME),
        "ORG" => Some(KIND_ORGANIZATION),
        "LOC" => Some(KIND_LOCATION),
        // MISC, O, and any unexpected tag are not in the V2-P5 schema.
        _ => None,
    }
}

/// Close a BIO group: map its tag, compute its byte span + mean score,
/// and push a [`DecodedSpan`] if the tag maps to a kept kind.
fn flush_group(text: &str, group: &[&TokenLabel], out: &mut Vec<DecodedSpan>) {
    let Some(first) = group.first() else {
        return;
    };
    let (_, tag) = get_tag(first.label);
    let Some(kind) = tag_to_kind(tag) else {
        return; // O / MISC / unknown -> dropped
    };
    let last = group[group.len() - 1];
    let (start, end) = (first.start, last.end);
    // Byte offsets come from the tokenizer's char→byte map, so they are
    // valid char boundaries; `get` guards against any degenerate span
    // (e.g. an all-special group) without panicking.
    let Some(span_text) = text.get(start..end) else {
        return;
    };
    if span_text.is_empty() {
        return;
    }
    #[allow(clippy::cast_precision_loss)]
    let confidence = group.iter().map(|t| t.score).sum::<f32>() / group.len() as f32;
    out.push(DecodedSpan {
        kind: kind.to_string(),
        text: span_text.to_string(),
        span_start: start,
        span_end: end,
        confidence,
    });
}

/// Numerically-stable softmax over a logit row, returning the argmax
/// index and its softmax probability. Mirrors HF
/// (`maxes`/`shifted_exp`/`sum`).
fn softmax_argmax(row: &[f32]) -> (usize, f32) {
    let mut max = f32::NEG_INFINITY;
    let mut best = 0usize;
    for (i, &v) in row.iter().enumerate() {
        if v > max {
            max = v;
            best = i;
        }
    }
    let mut sum = 0.0f32;
    for &v in row {
        sum += (v - max).exp();
    }
    // softmax(best) = exp(logit_best - max) / sum = exp(0) / sum = 1/sum.
    let prob = if sum > 0.0 { 1.0 / sum } else { 0.0 };
    (best, prob)
}

// ===========================================================================
// Focused unit tests — synthetic logits, model-independent. These pin the
// BIO grouping contract (I-without-B, B-B adjacency, label switch, MISC/O
// drop, confidence averaging, special/pad skip, shape guards) without the
// model in the loop. The golden_tests in `mod.rs` pin parity with the real
// model + HF pipeline.
// ===========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    // Label indices for DISTILBERT_NER_ID2LABEL.
    const O: usize = 0;
    const B_PER: usize = 1;
    const I_PER: usize = 2;
    const B_ORG: usize = 3;
    const I_ORG: usize = 4;
    const B_LOC: usize = 5;
    const I_LOC: usize = 6;
    const B_MISC: usize = 7;
    const I_MISC: usize = 8;

    const N: usize = 9;

    /// A near-one-hot logit row: chosen label gets 10.0, the rest 0.0, so
    /// argmax is deterministic and its softmax prob ≈ 0.9997.
    fn row(best: usize) -> Vec<f32> {
        let mut r = vec![0.0f32; N];
        r[best] = 10.0;
        r
    }

    /// Parallel model-IO arrays: (flat logits, byte offsets, special
    /// mask, attention mask).
    type ModelIo = (Vec<f32>, Vec<(usize, usize)>, Vec<i32>, Vec<i32>);

    /// Build [`ModelIo`] from a list of `(label, (start,end), is_special)`
    /// tuples.
    fn build(tokens: &[(usize, (usize, usize), bool)]) -> ModelIo {
        let mut flat = Vec::new();
        let mut offs = Vec::new();
        let mut spec = Vec::new();
        let mut attn = Vec::new();
        for &(label, off, is_special) in tokens {
            flat.extend(row(label));
            offs.push(off);
            spec.push(i32::from(is_special));
            attn.push(1);
        }
        (flat, offs, spec, attn)
    }

    fn decode(text: &str, tokens: &[(usize, (usize, usize), bool)]) -> Vec<DecodedSpan> {
        let (flat, offs, spec, attn) = build(tokens);
        decode_distilbert_ner(text, &flat, tokens.len(), &offs, &spec, &attn)
    }

    #[test]
    fn single_person_span_merges_b_then_i() {
        // text: "Alice Smith ok"  -> [CLS] Alice Smith ok [SEP]
        let text = "Alice Smith ok";
        let spans = decode(
            text,
            &[
                (O, (0, 0), true),       // CLS
                (B_PER, (0, 5), false),  // Alice
                (I_PER, (6, 11), false), // Smith
                (O, (12, 14), false),    // ok
                (O, (0, 0), true),       // SEP
            ],
        );
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].kind, KIND_PERSON_NAME);
        assert_eq!((spans[0].span_start, spans[0].span_end), (0, 11));
        assert_eq!(spans[0].text, "Alice Smith");
        assert!(spans[0].confidence > 0.99);
    }

    #[test]
    fn i_without_b_is_tolerant_start() {
        // O then I-PER (no preceding B) still yields a person span.
        let text = "hi Bob";
        let spans = decode(
            text,
            &[
                (O, (0, 2), false),     // hi
                (I_PER, (3, 6), false), // Bob (I- with no B-)
            ],
        );
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].kind, KIND_PERSON_NAME);
        assert_eq!((spans[0].span_start, spans[0].span_end), (3, 6));
    }

    #[test]
    fn adjacent_b_of_same_tag_are_two_entities() {
        // B-PER B-PER -> two separate people (a fresh B always breaks).
        let text = "Bob Sue";
        let spans = decode(
            text,
            &[
                (B_PER, (0, 3), false), // Bob
                (B_PER, (4, 7), false), // Sue
            ],
        );
        assert_eq!(spans.len(), 2);
        assert_eq!(spans[0].text, "Bob");
        assert_eq!(spans[1].text, "Sue");
    }

    #[test]
    fn label_switch_breaks_group() {
        // B-PER then I-ORG -> person + org (tolerant ORG start).
        let text = "Bob ACME";
        let spans = decode(
            text,
            &[
                (B_PER, (0, 3), false), // Bob
                (I_ORG, (4, 8), false), // ACME
            ],
        );
        assert_eq!(spans.len(), 2);
        assert_eq!(spans[0].kind, KIND_PERSON_NAME);
        assert_eq!(spans[1].kind, KIND_ORGANIZATION);
        assert_eq!(spans[1].text, "ACME");
    }

    #[test]
    fn org_and_loc_map_correctly() {
        let text = "ACME Paris";
        let spans = decode(text, &[(B_ORG, (0, 4), false), (B_LOC, (5, 10), false)]);
        assert_eq!(spans.len(), 2);
        assert_eq!(spans[0].kind, KIND_ORGANIZATION);
        assert_eq!(spans[1].kind, KIND_LOCATION);
    }

    #[test]
    fn multi_token_loc_merges() {
        let text = "New York Times"; // pretend B-LOC I-LOC over "New York"
        let spans = decode(
            text,
            &[
                (B_LOC, (0, 3), false), // New
                (I_LOC, (4, 8), false), // York
                (O, (9, 14), false),    // Times
            ],
        );
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].kind, KIND_LOCATION);
        assert_eq!(spans[0].text, "New York");
        assert_eq!((spans[0].span_start, spans[0].span_end), (0, 8));
    }

    #[test]
    fn misc_is_dropped() {
        let text = "German Prize";
        let spans = decode(text, &[(B_MISC, (0, 6), false), (I_MISC, (7, 12), false)]);
        assert!(
            spans.is_empty(),
            "MISC must be dropped (not in V2-P5 schema)"
        );
    }

    #[test]
    fn all_o_yields_nothing() {
        let text = "just some words";
        let spans = decode(
            text,
            &[(O, (0, 4), false), (O, (5, 9), false), (O, (10, 15), false)],
        );
        assert!(spans.is_empty());
    }

    #[test]
    fn confidence_is_mean_of_member_scores() {
        // First token strong (10.0), second weak (1.0) for I-PER. Mean of
        // the two softmax probs; both > the per-token of the weak one.
        let text = "Al Bo";
        let mut flat = row(B_PER); // strong Al
        let mut weak = vec![0.0f32; N];
        weak[I_PER] = 1.0; // weak Bo -> lower prob
        flat.extend(weak);
        let offs = vec![(0, 2), (3, 5)];
        let spec = vec![0, 0];
        let attn = vec![1, 1];
        let spans = decode_distilbert_ner(text, &flat, 2, &offs, &spec, &attn);
        assert_eq!(spans.len(), 1);
        // strong prob ≈ 0.9997, weak prob = e^1/(e^1+8) ≈ 0.2536; mean ≈ 0.6267
        let c = spans[0].confidence;
        assert!(
            (0.55..0.70).contains(&c),
            "confidence {c} not in expected mean band"
        );
    }

    #[test]
    fn special_and_pad_tokens_are_skipped() {
        // CLS(special) PER PER SEP(special) PAD(attn=0). PAD has a bogus
        // PER label but attention 0 -> must not appear.
        let text = "Bob Lee";
        let mut flat = Vec::new();
        for r in [row(O), row(B_PER), row(I_PER), row(O), row(B_PER)] {
            flat.extend(r);
        }
        let offs = vec![(0, 0), (0, 3), (4, 7), (0, 0), (0, 0)];
        let spec = vec![1, 0, 0, 1, 1]; // CLS, content, content, SEP, PAD(special)
        let attn = vec![1, 1, 1, 1, 0]; // PAD has attention 0
        let spans = decode_distilbert_ner(text, &flat, 5, &offs, &spec, &attn);
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].text, "Bob Lee");
        assert_eq!((spans[0].span_start, spans[0].span_end), (0, 7));
    }

    #[test]
    fn shape_mismatch_yields_empty() {
        // logits too short for seq_len*num_labels.
        let out = decode_bio(
            "x",
            &[0.0; 5],
            3,
            N,
            &[(0, 1)],
            &[0],
            &[1],
            &DISTILBERT_NER_ID2LABEL,
        );
        assert!(out.is_empty());
    }

    #[test]
    fn get_tag_handles_o_and_bare_labels() {
        assert!(matches!(get_tag("B-PER"), (Bi::B, "PER")));
        assert!(matches!(get_tag("I-ORG"), (Bi::I, "ORG")));
        assert!(matches!(get_tag("O"), (Bi::I, "O")));
        assert!(matches!(get_tag("WEIRD"), (Bi::I, "WEIRD")));
    }
}
