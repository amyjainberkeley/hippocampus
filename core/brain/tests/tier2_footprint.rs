//! V2-P5 — footprint benchmark for the [`Tier2Extractor`] filter
//! chain.
//!
//! Measures the cost of the parts of V2-P5 that run regardless of
//! NER backend:
//!
//! 1. Tier 1 regex bank re-derivation (for the token-REDACT skip
//!    set).
//! 2. Cascade-marker regex scan.
//! 3. Hallucination guard (span verification).
//! 4. Confidence floor check.
//! 5. Overlap filter.
//!
//! The Qwen inference cost (~100-500 ms per call per ADR-0028 §6)
//! is **NOT** measured here — it lives behind the
//! [`NerBackend`](mci_brain::NerBackend) trait. The production
//! worker (`apps/agent/src/tier2_worker.rs`) decouples the Qwen
//! call into single-flight async batches; this benchmark just
//! covers the extractor's deterministic side, which IS on the
//! per-event critical path even when the backend is fast.
//!
//! # SLO context
//!
//! The G2 raised footprint SLO (ratified 2026-05-31, on main per
//! Track 1 PR #274 + `docs/research/orchestrator-ratification-
//! state-2026-05-31.md` §2) reads:
//!
//! - Steady-state ≤ ~10–15% of one CPU core, ≤ ~2 GB RAM at default
//!   settings.
//! - Per-event bursts ≤25% CPU / ≤3 GB RAM brief sub-second.
//!
//! The filter chain measured here runs at microsecond timescale on
//! a 4 KB OCR-typical event, so it stays comfortably inside the
//! per-event budget regardless of backend cost.

use std::sync::Arc;
use std::time::Instant;

use mci_brain::extraction::tier2::{KIND_PERSON_NAME, KIND_TOPIC};
use mci_brain::{MockNerBackend, Tier2Extractor, Tier2RawMatch};

/// Build a representative 4 KB OCR text: structural V2-P4 hits
/// (URLs, emails, phones), a cascade marker, a JWT, plus
/// person/org/topic-shaped phrases V2-P5 NER would target.
fn synthetic_4k_event() -> String {
    let chunk = "Alice from the Brain team flagged a footprint regression on the Hippocampus build. \
                 Email her at alice@anthropic.com or visit https://example.com/x. \
                 Auth: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c \
                 Code: [REDACTED:SMS_OTP] please confirm. \
                 Bob met Carol in San Francisco about V2-P5. \
                 Phone: (415) 555-1234, file: /Users/ao/project/notes.md. ";
    // ~360 chars per chunk; 12 chunks ≈ 4.3 KB.
    chunk.repeat(12)
}

#[test]
fn filter_chain_completes_under_per_event_burst_budget() {
    let text = synthetic_4k_event();

    // Mock backend returns 6 candidates per call — realistic for a
    // dense event. (Real Qwen typically returns 3-10.)
    let raws = vec![
        Tier2RawMatch {
            kind: KIND_PERSON_NAME.into(),
            canonical_name: "Alice".into(),
            mention_text: "Alice".into(),
            span_start: 0,
            span_end: 5,
            confidence: 0.9,
        },
        Tier2RawMatch {
            kind: KIND_TOPIC.into(),
            canonical_name: "footprint regression".into(),
            mention_text: "footprint regression".into(),
            span_start: text.find("footprint regression").unwrap(),
            span_end: text.find("footprint regression").unwrap() + "footprint regression".len(),
            confidence: 0.8,
        },
    ];

    let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raws)));

    // Warm up: first call pays the LazyLock<Regex> compilation.
    let _ = ex.extract(&text).expect("warmup");

    // 1000 iterations to get a stable average.
    let n = 1000;
    let start = Instant::now();
    for _ in 0..n {
        let _ = ex.extract(&text).expect("iter");
    }
    let elapsed = start.elapsed();
    let per_call_us = elapsed.as_micros() / n as u128;

    // Print for the PR body. cargo test --nocapture surfaces it.
    eprintln!(
        "[tier2-footprint] {} iters over {}-byte event in {:?} → ~{} µs/call",
        n,
        text.len(),
        elapsed,
        per_call_us
    );

    // Hard ceiling: 5 ms per call on the filter chain. The G2 burst
    // budget is sub-second; 5 ms is a 200× margin even on a slow
    // dev machine. If this trips, something has regressed in the
    // cascade-marker / Tier 1 redux path (the only places this
    // function spends meaningful time).
    assert!(
        per_call_us < 5_000,
        "filter chain regressed: {per_call_us} µs > 5 ms ceiling"
    );
}

#[test]
fn filter_chain_sustained_load_holds_steady_state_budget() {
    let text = synthetic_4k_event();
    let ex = Tier2Extractor::new(Arc::new(MockNerBackend::empty()));

    // Simulate 60 events at 1 Hz (mock backend; the real loop is
    // gated by the idle-batch sleep, but the filter chain runs at
    // capacity). Sum of all filter-chain cost must be small
    // compared to 60 s wall-clock — the G2 steady-state budget
    // (~10-15% of one core).
    let _ = ex.extract(&text).expect("warmup");

    let events_per_second = 1;
    let seconds = 60;
    let total_events = events_per_second * seconds;
    let start = Instant::now();
    for _ in 0..total_events {
        let _ = ex.extract(&text).expect("iter");
    }
    let elapsed = start.elapsed();
    eprintln!(
        "[tier2-footprint] {total_events} events filter-chain in {elapsed:?} (steady-state)"
    );

    // The whole 60-event filter chain must complete in <300 ms on
    // any reasonable hardware. The 60 s wall-clock budget at 15%
    // CPU is ~9 000 ms of CPU work, so 300 ms is a 30× margin.
    assert!(
        elapsed.as_millis() < 300,
        "60-event filter-chain budget exceeded: {} ms",
        elapsed.as_millis()
    );
}

#[test]
fn filter_chain_burst_load_holds_per_event_budget() {
    let text = synthetic_4k_event();
    let ex = Tier2Extractor::new(Arc::new(MockNerBackend::empty()));
    let _ = ex.extract(&text).expect("warmup");

    // Simulate a 10-event burst (one batch's worth at the worker's
    // default batch_size=8 + headroom).
    let burst = 10;
    let start = Instant::now();
    for _ in 0..burst {
        let _ = ex.extract(&text).expect("iter");
    }
    let elapsed = start.elapsed();
    eprintln!("[tier2-footprint] 10-event burst filter-chain in {elapsed:?}");

    // Burst budget: the whole 10-event sweep must complete in
    // <100 ms. G2 per-event burst is sub-second; this gives the
    // backend (Qwen, ~250 ms/call typical) the bulk of the budget.
    assert!(
        elapsed.as_millis() < 100,
        "10-event burst filter-chain budget exceeded: {} ms",
        elapsed.as_millis()
    );
}
