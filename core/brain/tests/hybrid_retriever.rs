//! Integration tests for [`mci_brain::HybridRetriever`] — Phase 3 P3.7.
//!
//! Exercises the public API + the `stubs` feature (`FixedDimEmbedder` +
//! `InMemoryBrainStore`) so the production retriever's behaviour is pinned
//! against deterministic backends. Real `SqlCipherBrainStore` + Core ML
//! `ArcticEmbedSEmbedder` plug into the same trait surface; this file
//! tests the OS-free fusion / router / pre-filter logic that sits above
//! them.
//!
//! Mirrors the discipline in `core/brain/tests/scaffold.rs`.

use std::sync::Arc;

use mci_brain::{
    hybrid_retriever::{
        minmax, minmax_normalize, recency_decay, ANCHOR_WINDOW_US, DEFAULT_HALF_LIFE_HOURS,
        DEFAULT_K_LEX, RecencyConfig,
    },
    stubs::{FixedDimEmbedder, InMemoryBrainStore},
    BrainStore, Embedder, Event, EventId, FusionWeights, HybridRetriever, RetrievalQuery,
    RetrievalShape, RetrieveError, Retriever, TimeRange,
};

const MICROS_PER_HOUR: u64 = 3_600_000_000;
const MICROS_PER_DAY: u64 = 24 * MICROS_PER_HOUR;

fn event_at(text: &str, ts_us: u64, app: Option<&str>, embedding: Option<Vec<f32>>) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: app.map(str::to_string),
        window_title: None,
        url: None,
        text: text.into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        embedding,
    }
}

/// Build a store with `n` events, each carrying its own
/// `FixedDimEmbedder`-derived embedding so `vec_search` is meaningful.
fn store_with(events: Vec<Event>) -> Arc<InMemoryBrainStore> {
    let store = Arc::new(InMemoryBrainStore::new());
    for e in events {
        store.put_event(&e).expect("put");
    }
    store
}

/// Tiny smoke embedder so deterministic tests don't depend on the
/// `FixedDimEmbedder`'s exact rotation behaviour for query similarity —
/// produces an L2-normalized vector that matches each event's text via
/// `FixedDimEmbedder` (the events are already embedded with the same
/// embedder, so query ≡ event-text gives a perfect self-match).
fn embedder() -> Arc<FixedDimEmbedder> {
    Arc::new(FixedDimEmbedder::default())
}

// ---------------------------------------------------------------------------
// 1. Min-max normalization preserves order + caps [0, 1]
// ---------------------------------------------------------------------------

#[test]
fn minmax_normalization_preserves_order_and_caps_unit_interval() {
    let raw = [0.2_f32, 0.5, 0.8, 0.1, 0.9];
    let (mn, mx) = minmax(raw.iter().copied());
    let normed: Vec<f32> = raw.iter().map(|v| minmax_normalize(*v, mn, mx)).collect();

    // All values in [0, 1].
    for n in &normed {
        assert!(*n >= 0.0 && *n <= 1.0, "value out of unit interval: {n}");
    }

    // Order preserved: argmax of raw == argmax of normed, argmin too.
    let argmax_raw = raw
        .iter()
        .enumerate()
        .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
        .unwrap()
        .0;
    let argmax_normed = normed
        .iter()
        .enumerate()
        .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
        .unwrap()
        .0;
    assert_eq!(argmax_raw, argmax_normed);

    // Min collapses to 0.0; max collapses to 1.0.
    assert!((normed.iter().copied().fold(f32::INFINITY, f32::min)).abs() < 1e-6);
    assert!((normed.iter().copied().fold(f32::NEG_INFINITY, f32::max) - 1.0).abs() < 1e-6);
}

// ---------------------------------------------------------------------------
// 2. Pure-semantic returns embedding-ranked hits
// ---------------------------------------------------------------------------

#[test]
fn pure_semantic_path_ranks_by_embedding_cosine() {
    let e = embedder();

    // 5 fixture events. Embedding-only test → set w_lex=0, w_rec=0,
    // w_src=0, w_sem=1 so the combined score *is* sem̂.
    let texts = ["alpha", "beta", "gamma", "delta", "epsilon"];
    let events: Vec<Event> = texts
        .iter()
        .enumerate()
        .map(|(i, t)| {
            let emb = e.embed_one(t).unwrap();
            // Spread ts_us so recency decay doesn't accidentally
            // dominate even though its weight is zero in this test.
            event_at(t, (i as u64) * MICROS_PER_HOUR, None, Some(emb))
        })
        .collect();
    let store = store_with(events);

    let r = HybridRetriever::new(store, e, 0).with_weights(FusionWeights {
        w_sem: 1.0,
        w_lex: 0.0,
        w_rec: 0.0,
        w_src: 0.0,
    });

    let q = RetrievalQuery {
        text: "gamma".into(),
        limit: 5,
        time_filter: None,
        app_filter: None,
    };
    let hits = r.retrieve(&q).expect("retrieve");
    assert!(!hits.is_empty());

    // Top hit is the self-match. semantic score for self-match is 1.0
    // (max cosine), so post-min-max normalization it pins to 1.0 even
    // across a 5-event pool.
    // Top semantic for the self-match pins to 1.0 after min-max
    // normalization across the 5-event pool.
    let top = &hits[0];
    assert!(
        (top.score_semantic - 1.0).abs() < 1e-5,
        "expected normalized semantic == 1.0, got {}",
        top.score_semantic
    );
}

// ---------------------------------------------------------------------------
// 3. Pure-lexical returns BM25-ranked hits
// ---------------------------------------------------------------------------

#[test]
fn pure_lexical_path_ranks_by_fts_match_density() {
    let e = embedder();

    // Two events: one short with `"rust"` once, one long with `"rust"`
    // once. Per the InMemoryBrainStore's pseudo-BM25 the shorter
    // matches denser → higher lex score → top hit. Set w_lex=1 so the
    // combined ranking is the lexical ranking alone.
    let short = event_at("rust", 0, None, Some(e.embed_one("rust").unwrap()));
    let long = event_at(
        "rust appears once in this much longer paragraph of unrelated text padding",
        0,
        None,
        Some(e.embed_one("padding").unwrap()),
    );
    let store = store_with(vec![short, long]);

    let r = HybridRetriever::new(store.clone(), e, 0).with_weights(FusionWeights {
        w_sem: 0.0,
        w_lex: 1.0,
        w_rec: 0.0,
        w_src: 0.0,
    });

    let q = RetrievalQuery {
        text: "rust".into(),
        limit: 2,
        time_filter: None,
        app_filter: None,
    };
    let hits = r.retrieve(&q).expect("retrieve");
    assert_eq!(hits.len(), 2);

    // Top hit should be the short event (denser match).
    let top_text = store.get_event(hits[0].event_id).unwrap().unwrap().text;
    assert_eq!(top_text, "rust");
}

// ---------------------------------------------------------------------------
// 4. Hybrid fusion outperforms either alone on a canned eval
// ---------------------------------------------------------------------------

#[test]
fn hybrid_fusion_beats_lexical_only_when_lexical_misses_the_intent() {
    // Two events that both contain the lexical query term `"rust"`:
    // - `dense_lex`: short text where the term dominates; its embedding
    //   intentionally points elsewhere ("unrelated noise") so it is a
    //   lexical-only match.
    // - `semantic_answer`: long text where the term is just buried
    //   filler, but its embedding self-matches the query — so it is
    //   the semantic answer.
    //
    // Pure-lexical (`w_lex = 1`) ranks `dense_lex` on top (denser
    // pseudo-BM25). Default-weight hybrid ranks `semantic_answer` on
    // top because `w_sem = 0.5` dominates `w_lex = 0.3`.
    let e = embedder();
    let dense_lex = event_at(
        "rust",
        MICROS_PER_HOUR,
        None,
        Some(e.embed_one("unrelated noise").unwrap()),
    );
    let semantic_answer = event_at(
        "rust appears once in this much longer message of unrelated padding context",
        MICROS_PER_HOUR,
        None,
        Some(e.embed_one("rust").unwrap()),
    );
    let store = store_with(vec![dense_lex, semantic_answer]);

    let q = RetrievalQuery {
        text: "rust".into(),
        limit: 2,
        time_filter: None,
        app_filter: None,
    };

    // Pure-lexical ranks the dense match on top.
    let lex_only = HybridRetriever::new(store.clone(), e.clone(), MICROS_PER_HOUR).with_weights(
        FusionWeights {
            w_sem: 0.0,
            w_lex: 1.0,
            w_rec: 0.0,
            w_src: 0.0,
        },
    );
    let lex_top = &lex_only.retrieve(&q).unwrap()[0];
    let lex_top_text = store.get_event(lex_top.event_id).unwrap().unwrap().text;
    assert_eq!(lex_top_text, "rust");

    // Hybrid with defaults puts the semantic answer on top.
    let hybrid = HybridRetriever::new(store.clone(), e, MICROS_PER_HOUR);
    let hyb_top = &hybrid.retrieve(&q).unwrap()[0];
    let hyb_top_text = store.get_event(hyb_top.event_id).unwrap().unwrap().text;
    assert_eq!(
        hyb_top_text,
        "rust appears once in this much longer message of unrelated padding context"
    );
}

// ---------------------------------------------------------------------------
// 5. Router classifies "right before X" → AnchorThenWindow
// ---------------------------------------------------------------------------

#[test]
fn router_classifies_anchor_then_window_for_right_before_phrase() {
    let r = HybridRetriever::new(
        Arc::new(InMemoryBrainStore::new()),
        embedder(),
        10 * MICROS_PER_DAY,
    );
    let q = RetrievalQuery {
        text: "what was I looking at right before the 1Password vault opened".into(),
        limit: 5,
        time_filter: None,
        app_filter: None,
    };
    assert_eq!(r.route(&q), RetrievalShape::AnchorThenWindow);

    let q2 = RetrievalQuery {
        text: "the diff JUST AFTER the test failure".into(),
        limit: 5,
        time_filter: None,
        app_filter: None,
    };
    assert_eq!(r.route(&q2), RetrievalShape::AnchorThenWindow);
}

// ---------------------------------------------------------------------------
// 6. Router classifies "show me last Tuesday afternoon" → TimeRangeExtraction
// ---------------------------------------------------------------------------

#[test]
fn router_classifies_time_range_extraction_for_last_weekday_phrase() {
    let now_us = 30 * MICROS_PER_DAY;
    let r = HybridRetriever::new(Arc::new(InMemoryBrainStore::new()), embedder(), now_us);
    let q = RetrievalQuery {
        text: "show me last Tuesday afternoon".into(),
        limit: 5,
        time_filter: None,
        app_filter: None,
    };
    match r.route(&q) {
        RetrievalShape::TimeRangeExtraction(tr) => {
            // The coarse "last <weekday>" extractor returns the 7..14
            // day window. Assert the bounds are inside that band and
            // the range is non-empty.
            assert!(tr.from_us < tr.to_us);
            assert!(tr.to_us <= now_us);
            assert!(tr.from_us >= now_us.saturating_sub(14 * MICROS_PER_DAY));
            assert!(tr.to_us >= now_us.saturating_sub(14 * MICROS_PER_DAY));
        }
        other => panic!("expected TimeRangeExtraction, got {other:?}"),
    }

    let q2 = RetrievalQuery {
        text: "yesterday".into(),
        limit: 5,
        time_filter: None,
        app_filter: None,
    };
    assert!(matches!(
        r.route(&q2),
        RetrievalShape::TimeRangeExtraction(_)
    ));
}

#[test]
fn router_falls_back_to_plain_for_non_temporal_queries() {
    let r = HybridRetriever::new(Arc::new(InMemoryBrainStore::new()), embedder(), 0);
    let q = RetrievalQuery {
        text: "rust workspace cargo build".into(),
        limit: 5,
        time_filter: None,
        app_filter: None,
    };
    assert_eq!(r.route(&q), RetrievalShape::Plain);
}

// ---------------------------------------------------------------------------
// 7. App pre-filter excludes wrong-bundle hits
// ---------------------------------------------------------------------------

#[test]
fn app_pre_filter_excludes_wrong_bundle_hits() {
    let e = embedder();
    let safari = event_at(
        "page about rust",
        0,
        Some("com.apple.Safari"),
        Some(e.embed_one("page about rust").unwrap()),
    );
    let terminal = event_at(
        "page about rust",
        MICROS_PER_HOUR,
        Some("com.apple.Terminal"),
        Some(e.embed_one("page about rust").unwrap()),
    );
    let store = store_with(vec![safari, terminal]);
    let r = HybridRetriever::new(store.clone(), e, MICROS_PER_HOUR);

    let q = RetrievalQuery {
        text: "page about rust".into(),
        limit: 5,
        time_filter: None,
        app_filter: Some("com.apple.Safari".into()),
    };
    let hits = r.retrieve(&q).expect("retrieve");
    assert_eq!(hits.len(), 1);
    let kept = store.get_event(hits[0].event_id).unwrap().unwrap();
    assert_eq!(kept.app_bundle_id.as_deref(), Some("com.apple.Safari"));
}

// ---------------------------------------------------------------------------
// 8. Time pre-filter excludes out-of-range hits
// ---------------------------------------------------------------------------

#[test]
fn time_pre_filter_excludes_out_of_range_hits() {
    let e = embedder();
    let in_range = event_at(
        "rust",
        50 * MICROS_PER_HOUR,
        None,
        Some(e.embed_one("rust").unwrap()),
    );
    let out_of_range = event_at(
        "rust",
        200 * MICROS_PER_HOUR,
        None,
        Some(e.embed_one("rust").unwrap()),
    );
    let store = store_with(vec![in_range, out_of_range]);
    let r = HybridRetriever::new(store.clone(), e, 300 * MICROS_PER_HOUR);

    let q = RetrievalQuery {
        text: "rust".into(),
        limit: 5,
        time_filter: Some(TimeRange {
            from_us: 0,
            to_us: 100 * MICROS_PER_HOUR,
        }),
        app_filter: None,
    };
    let hits = r.retrieve(&q).expect("retrieve");
    assert_eq!(hits.len(), 1);
    let kept = store.get_event(hits[0].event_id).unwrap().unwrap();
    assert_eq!(kept.ts_us, 50 * MICROS_PER_HOUR);
}

// ---------------------------------------------------------------------------
// 9. Recency decay tips ties
// ---------------------------------------------------------------------------

#[test]
fn recency_decay_tips_ties_in_combined_score() {
    let e = embedder();
    // Two events: same text, same embedding ⇒ same lex̂ and sem̂.
    // Recency decay is the only differentiator.
    let old = event_at("rust", 0, None, Some(e.embed_one("rust").unwrap()));
    let recent = event_at(
        "rust",
        100 * MICROS_PER_HOUR,
        None,
        Some(e.embed_one("rust").unwrap()),
    );
    let store = store_with(vec![old, recent]);
    let r = HybridRetriever::new(store.clone(), e, 100 * MICROS_PER_HOUR);

    let q = RetrievalQuery {
        text: "rust".into(),
        limit: 2,
        time_filter: None,
        app_filter: None,
    };
    let hits = r.retrieve(&q).expect("retrieve");
    assert_eq!(hits.len(), 2);

    let top_ts = store.get_event(hits[0].event_id).unwrap().unwrap().ts_us;
    let bot_ts = store.get_event(hits[1].event_id).unwrap().unwrap().ts_us;
    assert_eq!(top_ts, 100 * MICROS_PER_HOUR);
    assert_eq!(bot_ts, 0);

    // Top recency is exactly 1.0 (Δt = 0); bottom is 0.99^100h ≈ 0.366.
    assert!((hits[0].score_recency - 1.0).abs() < 1e-6);
    assert!(hits[1].score_recency < hits[0].score_recency);
}

// ---------------------------------------------------------------------------
// 10. Anchor-then-window expands ±5 min and excludes outside
// ---------------------------------------------------------------------------

#[test]
fn anchor_then_window_keeps_events_within_five_minutes_of_anchor() {
    let e = embedder();
    let anchor_ts = 1_000 * MICROS_PER_HOUR;
    let anchor = event_at(
        "1password vault opened",
        anchor_ts,
        None,
        Some(e.embed_one("1password vault opened").unwrap()),
    );
    let inside = event_at(
        "looking at a contract page",
        anchor_ts - 2 * 60 * 1_000_000,
        None,
        Some(e.embed_one("contract page").unwrap()),
    );
    let outside = event_at(
        "completely earlier session",
        anchor_ts - 60 * 60 * 1_000_000,
        None,
        Some(e.embed_one("earlier session").unwrap()),
    );
    let store = store_with(vec![anchor, inside, outside]);
    let r = HybridRetriever::new(store.clone(), e, anchor_ts);

    let q = RetrievalQuery {
        text: "what was I looking at right before 1password vault opened".into(),
        limit: 5,
        time_filter: None,
        app_filter: None,
    };
    // Sanity: router selected anchor-then-window.
    assert_eq!(r.route(&q), RetrievalShape::AnchorThenWindow);

    let hits = r.retrieve(&q).expect("retrieve");
    let kept_ts: std::collections::HashSet<u64> = hits
        .iter()
        .map(|h| store.get_event(h.event_id).unwrap().unwrap().ts_us)
        .collect();

    // Anchor itself and the inside event are within ±5 min; the
    // outside one (1h earlier) is excluded.
    assert!(kept_ts.contains(&anchor_ts));
    assert!(kept_ts.contains(&(anchor_ts - 2 * 60 * 1_000_000)));
    assert!(!kept_ts.contains(&(anchor_ts - 60 * 60 * 1_000_000)));

    // ANCHOR_WINDOW_US is exactly 5 min in micros — defends the
    // numeric constant against accidental edits.
    assert_eq!(ANCHOR_WINDOW_US, 5 * 60 * 1_000_000);
}

// ---------------------------------------------------------------------------
// 11. Empty query → InvalidInput
// ---------------------------------------------------------------------------

#[test]
fn empty_query_is_invalid_input() {
    let r = HybridRetriever::new(Arc::new(InMemoryBrainStore::new()), embedder(), 0);
    let q = RetrievalQuery {
        text: String::new(),
        limit: 5,
        time_filter: None,
        app_filter: None,
    };
    let err = r.retrieve(&q).unwrap_err();
    assert!(matches!(err, RetrieveError::InvalidInput(_)));
}

// ---------------------------------------------------------------------------
// 12. limit=0 → empty Vec
// ---------------------------------------------------------------------------

#[test]
fn zero_limit_returns_empty_result_set_without_calling_store() {
    let r = HybridRetriever::new(Arc::new(InMemoryBrainStore::new()), embedder(), 0);
    let q = RetrievalQuery {
        text: "anything".into(),
        limit: 0,
        time_filter: None,
        app_filter: None,
    };
    let hits = r.retrieve(&q).expect("retrieve");
    assert!(hits.is_empty());
}

// ---------------------------------------------------------------------------
// 13. Defaults match ADR-0010 §5
// ---------------------------------------------------------------------------

#[test]
fn default_fusion_weights_and_pool_sizes_match_adr_0010() {
    let r = HybridRetriever::new(Arc::new(InMemoryBrainStore::new()), embedder(), 0);
    let w = r.weights();
    assert!((w.w_sem - 0.5).abs() < f32::EPSILON);
    assert!((w.w_lex - 0.3).abs() < f32::EPSILON);
    assert!((w.w_rec - 0.15).abs() < f32::EPSILON);
    assert!((w.w_src - 0.05).abs() < f32::EPSILON);
    assert_eq!(DEFAULT_K_LEX, 200);
}

// ---------------------------------------------------------------------------
// 14. Recency-decay math sanity
// ---------------------------------------------------------------------------

#[test]
fn recency_decay_exponential_with_default_half_life() {
    let hl = DEFAULT_HALF_LIFE_HOURS;
    let now = 1_000 * MICROS_PER_HOUR;

    // Δt = 0 → 1.0.
    assert!((recency_decay(now, now, hl) - 1.0).abs() < 1e-6);

    // At exactly the half-life (24h) → 0.5.
    let at_hl = now - (hl as u64) * MICROS_PER_HOUR;
    let r_hl = recency_decay(now, at_hl, hl);
    assert!(
        (r_hl - 0.5).abs() < 1e-4,
        "at half-life got {r_hl}, want ~0.5"
    );

    // 100 hours → exp(-ln(2)/24 * 100) ≈ 0.0558.
    let then = now - 100 * MICROS_PER_HOUR;
    let r = recency_decay(now, then, hl);
    let lambda = std::f32::consts::LN_2 / hl;
    let expected = (-lambda * 100.0).exp();
    assert!((r - expected).abs() < 1e-4, "got {r}, expected ~{expected}");

    // Future event (then > now) saturates to 1.0.
    let future = now + MICROS_PER_DAY;
    assert!((recency_decay(now, future, hl) - 1.0).abs() < 1e-6);
}

// ---------------------------------------------------------------------------
// 15. Inverted time_filter is InvalidInput
// ---------------------------------------------------------------------------

#[test]
fn inverted_time_filter_is_invalid_input() {
    let r = HybridRetriever::new(Arc::new(InMemoryBrainStore::new()), embedder(), 0);
    let q = RetrievalQuery {
        text: "anything".into(),
        limit: 5,
        time_filter: Some(TimeRange {
            from_us: 100,
            to_us: 50,
        }),
        app_filter: None,
    };
    let err = r.retrieve(&q).unwrap_err();
    assert!(matches!(err, RetrieveError::InvalidInput(_)));
}

// ---------------------------------------------------------------------------
// 16. Recency config wires through to retrieval scores
// ---------------------------------------------------------------------------

#[test]
fn with_recency_config_affects_score() {
    let e = embedder();
    let now = 200 * MICROS_PER_HOUR;
    let old = event_at("rust", 0, None, Some(e.embed_one("rust").unwrap()));
    let store = store_with(vec![old]);

    let fast_decay = HybridRetriever::new(store.clone(), e.clone(), now)
        .with_recency(RecencyConfig { half_life_hours: 1.0 });
    let slow_decay = HybridRetriever::new(store, e, now)
        .with_recency(RecencyConfig { half_life_hours: 1000.0 });

    let q = RetrievalQuery {
        text: "rust".into(),
        limit: 1,
        time_filter: None,
        app_filter: None,
    };

    let fast_score = fast_decay.retrieve(&q).unwrap()[0].score_recency;
    let slow_score = slow_decay.retrieve(&q).unwrap()[0].score_recency;
    assert!(
        fast_score < slow_score,
        "fast decay ({fast_score}) should be less than slow ({slow_score})"
    );
}

// ===========================================================================
// PROPERTY TESTS — hand-rolled deterministic fuzz (256 iterations)
//
// proptest is not on the workspace lockfile. Rather than trigger the
// ADR-0008 §1 dependency-addition gate for a dev-only crate, we use a
// xorshift64 PRNG to generate random inputs. 256 iterations matches
// proptest's default. If proptest is ever added, these can be trivially
// ported.
// ===========================================================================

fn xorshift64(state: &mut u64) -> u64 {
    let mut x = *state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *state = x;
    x
}

fn rand_f32_unit(state: &mut u64) -> f32 {
    (xorshift64(state) % 10_001) as f32 / 10_000.0
}

// ---------------------------------------------------------------------------
// P1. For any FusionWeights summing to 1.0, all arm scores in [0,1] →
//     fused score in [0,1].
// ---------------------------------------------------------------------------

#[test]
fn property_fused_score_in_unit_interval_for_unit_weights() {
    let mut rng = 0xDEAD_BEEF_CAFE_BABEu64;
    for _ in 0..256 {
        let a = rand_f32_unit(&mut rng);
        let b = rand_f32_unit(&mut rng) * (1.0 - a);
        let c = rand_f32_unit(&mut rng) * (1.0 - a - b);
        let d = 1.0 - a - b - c;
        let w = FusionWeights {
            w_sem: a,
            w_lex: b,
            w_rec: c,
            w_src: d,
        };

        let sem = rand_f32_unit(&mut rng);
        let lex = rand_f32_unit(&mut rng);
        let rec = rand_f32_unit(&mut rng);
        let src = rand_f32_unit(&mut rng);

        let fused = w.w_sem.mul_add(sem, w.w_lex.mul_add(lex, w.w_rec.mul_add(rec, w.w_src * src)));
        assert!(
            fused >= -1e-6 && fused <= 1.0 + 1e-6,
            "fused {fused} out of [0,1] for w={w:?} scores=({sem},{lex},{rec},{src})"
        );
    }
}

// ---------------------------------------------------------------------------
// P2. Monotonicity: increasing one arm's score (others held) never
//     decreases the fused score (for non-zero weight).
// ---------------------------------------------------------------------------

#[test]
fn property_monotonicity_of_fusion() {
    let mut rng = 0x1234_5678_9ABC_DEF0u64;
    for _ in 0..256 {
        let w = FusionWeights {
            w_sem: 0.1 + rand_f32_unit(&mut rng) * 0.4,
            w_lex: 0.1 + rand_f32_unit(&mut rng) * 0.3,
            w_rec: 0.05 + rand_f32_unit(&mut rng) * 0.2,
            w_src: 0.01 + rand_f32_unit(&mut rng) * 0.1,
        };

        let base_sem = rand_f32_unit(&mut rng) * 0.8;
        let base_lex = rand_f32_unit(&mut rng);
        let base_rec = rand_f32_unit(&mut rng);
        let base_src = rand_f32_unit(&mut rng);

        let bump = 0.01 + rand_f32_unit(&mut rng) * 0.19;
        let bumped_sem = (base_sem + bump).min(1.0);

        let score_lo = w.w_sem.mul_add(
            base_sem,
            w.w_lex
                .mul_add(base_lex, w.w_rec.mul_add(base_rec, w.w_src * base_src)),
        );
        let score_hi = w.w_sem.mul_add(
            bumped_sem,
            w.w_lex
                .mul_add(base_lex, w.w_rec.mul_add(base_rec, w.w_src * base_src)),
        );
        assert!(
            score_hi >= score_lo - 1e-6,
            "monotonicity violated: bumping sem {base_sem}->{bumped_sem} dropped score {score_lo}->{score_hi}"
        );
    }
}

// ---------------------------------------------------------------------------
// P3. Recency: 1-second-old event always scores >= 1-day-old event
//     (same content, same store, default config).
// ---------------------------------------------------------------------------

#[test]
fn property_recent_event_always_outscores_old_event() {
    let mut rng = 0xFEED_FACE_0000_0001u64;

    for _ in 0..256 {
        let now = 100 * MICROS_PER_DAY + xorshift64(&mut rng) % (50 * MICROS_PER_DAY);
        let recent_ts = now - 1_000_000;
        let old_ts = now - MICROS_PER_DAY;

        let hl = 1.0 + rand_f32_unit(&mut rng) * 100.0;
        let r_recent = recency_decay(now, recent_ts, hl);
        let r_old = recency_decay(now, old_ts, hl);
        assert!(
            r_recent >= r_old,
            "recent ({r_recent}) < old ({r_old}) at hl={hl}"
        );
    }
}

// ---------------------------------------------------------------------------
// P4. recency_decay always in [0, 1] for any non-negative inputs.
// ---------------------------------------------------------------------------

#[test]
fn property_recency_decay_bounded_unit_interval() {
    let mut rng = 0xAAAA_BBBB_CCCC_DDDDu64;
    for _ in 0..256 {
        let now = xorshift64(&mut rng);
        let then = xorshift64(&mut rng);
        let hl = 0.001 + rand_f32_unit(&mut rng) * 10_000.0;
        let r = recency_decay(now, then, hl);
        assert!(
            (0.0..=1.0).contains(&r),
            "recency_decay({now}, {then}, {hl}) = {r} out of [0,1]"
        );
    }
}
