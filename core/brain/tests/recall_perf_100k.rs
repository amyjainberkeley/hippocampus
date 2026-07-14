//! Recall-latency perf harness at 100K events — closes CRS G-perf.
//!
//! Seeds a fresh `SqlCipherBrainStore` with 100 000 synthetic events
//! (realistic app / content-length / entity distribution per the CRS
//! telemetry-gap memo), runs a canonical query workload, and reports
//! P50 / P95 / P99 latency for both cold-cache and steady-state warm-cache
//! paths. Emits results as JSONL to stdout AND to a machine-readable
//! `docs/eval/recall-perf-baseline.json` (path resolved via
//! `CARGO_MANIFEST_DIR`) so future runs regression-check against the
//! committed baseline.
//!
//! # Scope
//!
//! Measurement, not assertion. The test is `#[ignore]` by default because
//! seeding 100K events + running 100 queries takes minutes and would burn
//! CI budget; run it explicitly with:
//!
//! ```text
//! cargo test --profile=perf -p mci-brain -- --ignored recall_perf_100k::run
//! ```
//!
//! (The `perf` profile is defined at the workspace root; it inherits
//! `release` codegen but keeps `debug-assertions = true` on `mci-core`
//! so the CSO tripwire in `mci_core::crypto::key_wrap` — which refuses
//! to compile the `insecure-test-keywrap` dev-dep feature in a real
//! release build — is satisfied. Same pattern as the `[profile.bench]`
//! override for `benches/hybrid_recall.rs`.)
//!
//! # What is measured
//!
//! - **Cold-start**: fresh process each measurement — one query at a time
//!   against a store that has just been reopened (page cache warm from
//!   seeding, but retriever state cold). Approximates the "user just opened
//!   Recall" latency at 100K events.
//! - **Steady-state**: 5 rapid-fire successive queries measured after a
//!   warmup pass — the ANE / page-cache / FTS5-index-in-memory regime a
//!   power user actually experiences during extended dictation.
//!
//! # What is NOT measured
//!
//! - Real Core ML / ANE latency (the harness uses the `stubs`
//!   `FixedDimEmbedder` — deterministic, O(dim) per embed, no ML runtime).
//!   Isolating store-side latency is the point; the embedder budget is a
//!   separate concern tracked by `docs/eval/brief-quality.md`.
//! - IO / disk-cache first-hit latency after a reboot — measurement runs
//!   under `tempfile::tempdir()` so the DB file is on the same filesystem
//!   as the harness process but its pages are warm from seeding.
//!
//! Per ADR-0016 §6 + the CRS G-perf memo, the initial baseline recorded
//! by this harness establishes ground truth; subsequent runs compare
//! against `docs/eval/recall-perf-baseline.json`.

#![cfg(feature = "stubs")]
// Perf-harness code is measurement-only: sample counts / durations / bucket
// indices routinely round-trip through f64 for quantile math, and the
// budgets/reporting block reads better with items-after-statements. The
// underlying values are all well under 2^52, so precision-loss lints do
// not describe a real risk here.
#![allow(
    clippy::cast_possible_truncation,
    clippy::cast_precision_loss,
    clippy::cast_sign_loss,
    clippy::items_after_statements,
    clippy::too_many_lines,
    clippy::uninlined_format_args,
    clippy::doc_markdown
)]

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use mci_brain::{
    stubs::FixedDimEmbedder, BrainStore, Embedder, Event, EventId, HybridRetriever,
    RetrievalQuery, Retriever, SqlCipherBrainStore,
};
use mci_core::crypto::{DbKey, InMemoryKeyWrap, KeyWrap};

// ---------------------------------------------------------------------------
// Corpus configuration — see module doc.
// ---------------------------------------------------------------------------

const CORPUS_SIZE: usize = 100_000;
const QUERY_COUNT: usize = 100;
/// Number of full-query-set sweeps to measure after warmup. Chosen to
/// keep the harness under ~10 min at 100K events on a reference M-series
/// laptop while still yielding a stable P99 (3×100=300 warm samples,
/// enough to place P99 at rank 297).
const STEADY_STATE_REPEATS: usize = 3;
const MICROS_PER_MIN: u64 = 60_000_000;
const RETRIEVE_LIMIT: usize = 10;

/// Realistic app-bundle distribution (fractions sum to 100).
/// Source: CRS 2026-07 telemetry-gap memo §3 (extended-dictation cohort).
const APP_DISTRIBUTION: &[(&str, u32)] = &[
    ("com.apple.Safari", 30),
    ("com.apple.MobileSMS", 20),
    ("com.microsoft.VSCode", 15),
    ("com.tinyspeck.slackmacgap", 10),
    ("com.apple.mail", 10),
    ("com.google.Chrome", 8),
    ("com.apple.finder", 4),
    ("com.apple.Notes", 3),
];

/// Realistic content-length buckets: (weight, min_words, max_words).
/// short=40%, medium=40%, long=20%.
const LENGTH_BUCKETS: &[(u32, usize, usize)] = &[
    (40, 4, 15),
    (40, 20, 80),
    (20, 120, 400),
];

/// Vocabulary the synthetic content is drawn from. Small on purpose —
/// FTS5 lexical hits should be dense enough to exercise the BM25 ranking
/// path, but sparse enough that the entity-injection pass produces
/// distinguishable rare vs. common entities.
const WORDS: &[&str] = &[
    "rust", "python", "memory", "capture", "brain", "search", "event",
    "window", "browser", "code", "debug", "test", "deploy", "build",
    "config", "parse", "token", "index", "query", "score", "latency",
    "throughput", "profile", "trace", "log", "audit", "review", "commit",
    "branch", "merge", "rebase", "diff", "author", "reviewer", "sprint",
    "roadmap", "milestone", "release", "changelog", "issue", "ticket",
];

/// Rare-entity pool (mixed persons / orgs / topics). 60% of events get one
/// entity injected per the CRS memo's realistic-distribution row.
///
/// Historically kept FTS5-safe by construction (no `:` / `"` / `-`); the
/// `fts_sanitizer` pass (cycle 8.55 URL-panic fix) now handles those
/// metacharacters transparently, so URL / colon-token entities could be
/// mixed into this pool without breaking the harness. The pool is left
/// alphabetic for baseline stability — swap in URL entities in a follow-
/// on perf cycle if the workload-mix analysis calls for it.
const RARE_ENTITIES: &[&str] = &[
    "Alfredsson", "Braithwaite", "Corzelius", "Duszynski", "Elverum",
    "OperationChimera", "ProjectNarwhal", "gigaquark",
    "Framboise", "Ynglingsson",
];

/// Common-entity pool. Injected roughly 10x more often than rare entities.
const COMMON_ENTITIES: &[&str] = &[
    "Amy", "Dave", "Anthropic", "Rust", "Claude", "MCI",
    "GitHub", "Slack", "VSCode",
];

// ---------------------------------------------------------------------------
// PRNG — xorshift64, deterministic seed so runs are reproducible.
// ---------------------------------------------------------------------------

fn xorshift64(state: &mut u64) -> u64 {
    let mut x = *state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *state = x;
    x
}

fn rand_in(state: &mut u64, lo: usize, hi: usize) -> usize {
    lo + (xorshift64(state) as usize) % (hi - lo + 1)
}

fn pick_weighted<'a, T>(state: &mut u64, choices: &'a [(T, u32)]) -> &'a T {
    let total: u32 = choices.iter().map(|(_, w)| *w).sum();
    let mut roll = (xorshift64(state) % u64::from(total)) as u32;
    for (item, w) in choices {
        if roll < *w {
            return item;
        }
        roll -= *w;
    }
    &choices[0].0
}

/// Pick a `(min_words, max_words)` bucket via the same weighted-roll shape,
/// but without allocating a temporary `Vec` (called once per seeded event).
fn pick_length_bucket(state: &mut u64) -> (usize, usize) {
    let total: u32 = LENGTH_BUCKETS.iter().map(|(w, _, _)| *w).sum();
    let mut roll = (xorshift64(state) % u64::from(total)) as u32;
    for (w, lo, hi) in LENGTH_BUCKETS {
        if roll < *w {
            return (*lo, *hi);
        }
        roll -= *w;
    }
    (LENGTH_BUCKETS[0].1, LENGTH_BUCKETS[0].2)
}

// ---------------------------------------------------------------------------
// Synthetic-event generator.
// ---------------------------------------------------------------------------

fn synth_event(state: &mut u64, i: usize, embedder: &FixedDimEmbedder) -> Event {
    let app = *pick_weighted(state, APP_DISTRIBUTION);
    let (min_w, max_w) = pick_length_bucket(state);
    let n_words = rand_in(state, min_w, max_w);

    let mut text = String::with_capacity(n_words * 8);
    for w_idx in 0..n_words {
        if w_idx > 0 {
            text.push(' ');
        }
        text.push_str(WORDS[rand_in(state, 0, WORDS.len() - 1)]);
    }

    // Inject an entity 60% of the time (10:1 common:rare per the memo).
    if xorshift64(state) % 100 < 60 {
        let entity = if xorshift64(state) % 11 == 0 {
            RARE_ENTITIES[rand_in(state, 0, RARE_ENTITIES.len() - 1)]
        } else {
            COMMON_ENTITIES[rand_in(state, 0, COMMON_ENTITIES.len() - 1)]
        };
        text.push(' ');
        text.push_str(entity);
    }

    let emb = embedder.embed_one(&text).expect("embed");
    Event {
        id: EventId(0),
        // 1 minute between events → 100K events ≈ 69 days of history.
        ts_us: (i as u64) * MICROS_PER_MIN,
        app_bundle_id: Some(app.to_string()),
        window_title: None,
        url: None,
        text,
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: Some(emb),
    }
}

// ---------------------------------------------------------------------------
// Query workload — 100 canonical queries mixing short/long, common/rare.
// ---------------------------------------------------------------------------

fn build_queries() -> Vec<String> {
    let mut out: Vec<String> = Vec::with_capacity(QUERY_COUNT);
    // 40 single-word common-vocab queries (FTS5-dense, fusion stresses both halves).
    for i in 0..40 {
        out.push(WORDS[i % WORDS.len()].to_string());
    }
    // 20 two-word phrase queries.
    for i in 0..20 {
        out.push(format!(
            "{} {}",
            WORDS[(i * 3) % WORDS.len()],
            WORDS[(i * 7) % WORDS.len()],
        ));
    }
    // 20 common-entity queries.
    for i in 0..20 {
        out.push(COMMON_ENTITIES[i % COMMON_ENTITIES.len()].to_string());
    }
    // 20 rare-entity queries — the "needle in a haystack" case that gates
    // the extended-dictation UX (a user searching for a specific person /
    // URL they saw once weeks ago).
    for i in 0..20 {
        out.push(RARE_ENTITIES[i % RARE_ENTITIES.len()].to_string());
    }
    assert_eq!(out.len(), QUERY_COUNT);
    out
}

// ---------------------------------------------------------------------------
// Latency histogram — 10ms buckets up to 1s, then one overflow bucket.
// ---------------------------------------------------------------------------

const BUCKET_MS: u64 = 10;
const N_BUCKETS: usize = 101; // 0..1000ms in 10ms steps, plus overflow

struct Histogram {
    buckets: [u64; N_BUCKETS],
    samples: Vec<u64>, // raw micros for exact quantile
}

impl Histogram {
    fn new() -> Self {
        Self {
            buckets: [0; N_BUCKETS],
            samples: Vec::with_capacity(1024),
        }
    }

    fn record_us(&mut self, us: u64) {
        self.samples.push(us);
        let ms = us / 1000;
        let idx = ((ms / BUCKET_MS) as usize).min(N_BUCKETS - 1);
        self.buckets[idx] += 1;
    }

    fn quantile_us(&self, q: f64) -> u64 {
        if self.samples.is_empty() {
            return 0;
        }
        let mut s = self.samples.clone();
        s.sort_unstable();
        let idx = ((s.len() as f64 - 1.0) * q).round() as usize;
        s[idx.min(s.len() - 1)]
    }

    fn mean_us(&self) -> u64 {
        if self.samples.is_empty() {
            return 0;
        }
        let sum: u128 = self.samples.iter().map(|&x| u128::from(x)).sum();
        (sum / self.samples.len() as u128) as u64
    }
}

// ---------------------------------------------------------------------------
// Test-only key (mirrors the pattern in `sqlcipher_brain_store.rs`).
// ---------------------------------------------------------------------------

fn test_key() -> DbKey {
    let k = DbKey::generate().expect("csprng");
    let wrap = InMemoryKeyWrap;
    let wrapped = wrap.wrap(&k).expect("wrap");
    wrap.unwrap_key(&wrapped).expect("unwrap")
}

// ---------------------------------------------------------------------------
// Driver.
// ---------------------------------------------------------------------------

/// Perf harness entry point. `#[ignore]` so CI does not run it unattended.
#[test]
#[ignore = "perf harness — run explicitly with --ignored"]
fn run() {
    eprintln!("recall_perf_100k: seeding {} events...", CORPUS_SIZE);

    let embedder = Arc::new(FixedDimEmbedder::default());
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("perf-brain.sqlite");
    let key = test_key();

    // Seed phase — one transaction per put_event; the production ingest
    // path is the same shape (per-event commit, no batching). Timed so
    // baseline seed throughput is committed alongside query latency.
    let store = Arc::new(SqlCipherBrainStore::new(&path, &key).expect("open seed"));
    let mut prng_state: u64 = 0xDECA_FBAD_C0FF_EE00;
    let t_seed = Instant::now();
    for i in 0..CORPUS_SIZE {
        let ev = synth_event(&mut prng_state, i, &embedder);
        store.put_event(&ev).expect("put_event during seed");
        if (i + 1) % 10_000 == 0 {
            eprintln!(
                "  seeded {}/{} in {:.1}s",
                i + 1,
                CORPUS_SIZE,
                t_seed.elapsed().as_secs_f64()
            );
        }
    }
    let seed_secs = t_seed.elapsed().as_secs_f64();
    let seed_throughput = CORPUS_SIZE as f64 / seed_secs;
    eprintln!(
        "recall_perf_100k: seed done in {:.1}s ({:.0} ev/s)",
        seed_secs, seed_throughput,
    );

    let queries = build_queries();
    let now_us = (CORPUS_SIZE as u64) * MICROS_PER_MIN;

    // ---- Cold-cache path — one retriever construction per query so the
    // route/lex-pool/sem-pool state is not amortized across queries. ----
    eprintln!("recall_perf_100k: running {QUERY_COUNT} cold-cache queries...");
    let cold_start = Instant::now();
    let mut cold = Histogram::new();
    for (i, q) in queries.iter().enumerate() {
        let retriever =
            HybridRetriever::new(store.clone(), embedder.clone(), now_us);
        let rq = RetrievalQuery {
            text: q.clone(),
            limit: RETRIEVE_LIMIT,
            time_filter: None,
            app_filter: None,
        };
        let t = Instant::now();
        let hits = retriever.retrieve(&rq).expect("retrieve cold");
        cold.record_us(t.elapsed().as_micros() as u64);
        let _ = hits;
        if (i + 1) % 20 == 0 {
            eprintln!(
                "  cold {}/{} in {:.1}s",
                i + 1,
                QUERY_COUNT,
                cold_start.elapsed().as_secs_f64()
            );
        }
    }
    eprintln!(
        "recall_perf_100k: cold done in {:.1}s",
        cold_start.elapsed().as_secs_f64()
    );

    // ---- Steady-state — reuse one retriever, warmup pass then
    // STEADY_STATE_REPEATS rapid-fire passes over the query set. ----
    eprintln!("recall_perf_100k: running warmup sweep...");
    let warmup_start = Instant::now();
    let retriever = HybridRetriever::new(store.clone(), embedder.clone(), now_us);
    // Warmup: one full sweep to prime the page cache + FTS5 read buffers.
    for q in &queries {
        let _ = retriever.retrieve(&RetrievalQuery {
            text: q.clone(),
            limit: RETRIEVE_LIMIT,
            time_filter: None,
            app_filter: None,
        });
    }
    eprintln!(
        "recall_perf_100k: warmup done in {:.1}s",
        warmup_start.elapsed().as_secs_f64()
    );
    eprintln!(
        "recall_perf_100k: running {STEADY_STATE_REPEATS} steady-state sweeps..."
    );
    let warm_start = Instant::now();
    let mut warm = Histogram::new();
    for rep in 0..STEADY_STATE_REPEATS {
        for q in &queries {
            let rq = RetrievalQuery {
                text: q.clone(),
                limit: RETRIEVE_LIMIT,
                time_filter: None,
                app_filter: None,
            };
            let t = Instant::now();
            let _ = retriever.retrieve(&rq).expect("retrieve warm");
            warm.record_us(t.elapsed().as_micros() as u64);
        }
        eprintln!(
            "  warm sweep {}/{} in {:.1}s",
            rep + 1,
            STEADY_STATE_REPEATS,
            warm_start.elapsed().as_secs_f64()
        );
    }

    // ---- Report — human-readable to stderr, machine-readable JSON to
    // `docs/eval/recall-perf-baseline.json` (only when
    // MCI_PERF_UPDATE_BASELINE=1 is set, so a normal run does not
    // clobber the committed baseline). ----
    let report = serde_json::json!({
        "corpus_size": CORPUS_SIZE,
        "query_count": QUERY_COUNT,
        "steady_state_repeats": STEADY_STATE_REPEATS,
        "retrieve_limit": RETRIEVE_LIMIT,
        "seed_seconds": seed_secs,
        "seed_events_per_sec": seed_throughput,
        "cold": {
            "p50_ms": cold.quantile_us(0.50) as f64 / 1000.0,
            "p95_ms": cold.quantile_us(0.95) as f64 / 1000.0,
            "p99_ms": cold.quantile_us(0.99) as f64 / 1000.0,
            "mean_ms": cold.mean_us() as f64 / 1000.0,
        },
        "warm": {
            "p50_ms": warm.quantile_us(0.50) as f64 / 1000.0,
            "p95_ms": warm.quantile_us(0.95) as f64 / 1000.0,
            "p99_ms": warm.quantile_us(0.99) as f64 / 1000.0,
            "mean_ms": warm.mean_us() as f64 / 1000.0,
        },
    });
    let pretty = serde_json::to_string_pretty(&report).expect("json");
    eprintln!("recall_perf_100k: results\n{pretty}");

    if std::env::var("MCI_PERF_UPDATE_BASELINE").ok().as_deref() == Some("1") {
        let mut out_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        // manifest_dir = core/brain → repo root = ../..
        out_path.pop();
        out_path.pop();
        out_path.push("docs/eval/recall-perf-baseline.json");
        std::fs::write(&out_path, &pretty).expect("write baseline");
        eprintln!(
            "recall_perf_100k: baseline written to {}",
            out_path.display()
        );
    }

    // Advisory budgets — do NOT fail the test (this is measurement, not
    // assertion, per the module doc). A regression detector lives in the
    // baseline-diff CI step, not here.
    const COLD_P50_BUDGET_MS: f64 = 200.0;
    const WARM_P50_BUDGET_MS: f64 = 50.0;
    const WARM_P99_BUDGET_MS: f64 = 500.0;
    let cold_p50 = cold.quantile_us(0.50) as f64 / 1000.0;
    let warm_p50 = warm.quantile_us(0.50) as f64 / 1000.0;
    let warm_p99 = warm.quantile_us(0.99) as f64 / 1000.0;
    if cold_p50 > COLD_P50_BUDGET_MS {
        eprintln!(
            "recall_perf_100k: WARN cold P50 {:.1}ms > {:.1}ms budget",
            cold_p50, COLD_P50_BUDGET_MS,
        );
    }
    if warm_p50 > WARM_P50_BUDGET_MS {
        eprintln!(
            "recall_perf_100k: WARN warm P50 {:.1}ms > {:.1}ms budget",
            warm_p50, WARM_P50_BUDGET_MS,
        );
    }
    if warm_p99 > WARM_P99_BUDGET_MS {
        eprintln!(
            "recall_perf_100k: WARN warm P99 {:.1}ms > {:.1}ms budget",
            warm_p99, WARM_P99_BUDGET_MS,
        );
    }

    // Retain _dir until the very end so the tempdir survives all reads.
    drop(store);
    drop(dir);
}

// ---------------------------------------------------------------------------
// Sanity tests — small-corpus smoke to guard against harness bit-rot.
// These run under `cargo test` (no `#[ignore]`), so a broken harness is
// caught in the normal test loop without paying the 100K seed cost.
// ---------------------------------------------------------------------------

#[test]
fn histogram_quantiles_are_monotonic() {
    let mut h = Histogram::new();
    for us in [1_000, 5_000, 10_000, 50_000, 100_000, 500_000] {
        h.record_us(us);
    }
    assert!(h.quantile_us(0.50) <= h.quantile_us(0.95));
    assert!(h.quantile_us(0.95) <= h.quantile_us(0.99));
}

#[test]
fn synth_event_generator_produces_valid_events() {
    let embedder = FixedDimEmbedder::default();
    let mut state: u64 = 0x1234_5678_9abc_def0;
    for i in 0..50 {
        let ev = synth_event(&mut state, i, &embedder);
        assert_eq!(ev.cascade_reason, 0);
        assert!(ev.embedding.as_ref().unwrap().len() == 384);
        assert!(!ev.text.is_empty());
        assert!(ev.app_bundle_id.is_some());
    }
}

#[test]
fn query_workload_shape_is_100_and_covers_all_families() {
    let qs = build_queries();
    assert_eq!(qs.len(), QUERY_COUNT);
    // First 40 are single-word.
    assert!(qs[..40].iter().all(|q| !q.contains(' ')));
    // Next 20 are two-word phrases.
    assert!(qs[40..60].iter().all(|q| q.contains(' ')));
}
