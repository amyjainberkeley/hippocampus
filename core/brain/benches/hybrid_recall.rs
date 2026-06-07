//! Criterion benchmark for [`HybridRetriever`] recall latency.
//!
//! Synthetic corpus: 1000 events, 100 queries. Three configurations:
//! lexical-only, semantic-only, full hybrid (default weights). Baseline
//! for future fusion-tuning PRs to compare against.
//!
//! Run: `cargo bench -p mci-brain`
//! Compile-check only (CI): `cargo bench --no-run -p mci-brain`

use std::sync::Arc;

use criterion::{black_box, criterion_group, criterion_main, Criterion};

use mci_brain::{
    stubs::{FixedDimEmbedder, InMemoryBrainStore},
    BrainStore, Embedder, Event, EventId, FusionWeights, HybridRetriever, RetrievalQuery,
    Retriever,
};

const MICROS_PER_HOUR: u64 = 3_600_000_000;
const CORPUS_SIZE: usize = 1000;
const QUERY_COUNT: usize = 100;

const WORDS: &[&str] = &[
    "rust", "python", "memory", "capture", "brain", "search", "event", "window", "browser", "code",
    "debug", "test", "deploy", "build", "config", "parse", "token", "index", "query", "score",
];

struct Corpus {
    store: Arc<InMemoryBrainStore>,
    embedder: Arc<FixedDimEmbedder>,
    queries: Vec<String>,
    now_us: u64,
}

fn build_corpus() -> Corpus {
    let embedder = Arc::new(FixedDimEmbedder::default());
    let store = Arc::new(InMemoryBrainStore::new());

    for i in 0..CORPUS_SIZE {
        let w1 = WORDS[i % WORDS.len()];
        let w2 = WORDS[(i * 7) % WORDS.len()];
        let w3 = WORDS[(i * 13) % WORDS.len()];
        let text = format!("{w1} {w2} {w3} event number {i}");
        let emb = embedder.embed_one(&text).unwrap();
        let event = Event {
            id: EventId(0),
            ts_us: (i as u64) * MICROS_PER_HOUR,
            app_bundle_id: Some("com.bench.app".into()),
            window_title: None,
            url: None,
            text,
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            embedding: Some(emb),
        };
        store.put_event(&event).unwrap();
    }

    let queries: Vec<String> = (0..QUERY_COUNT)
        .map(|i| {
            let w = WORDS[i % WORDS.len()];
            format!("{w} search query {i}")
        })
        .collect();

    Corpus {
        store,
        embedder,
        queries,
        now_us: (CORPUS_SIZE as u64) * MICROS_PER_HOUR,
    }
}

fn bench_hybrid_recall(c: &mut Criterion) {
    let corpus = build_corpus();

    c.bench_function("hybrid_default_1000ev_100q", |b| {
        let r = HybridRetriever::new(corpus.store.clone(), corpus.embedder.clone(), corpus.now_us);
        b.iter(|| {
            for q in &corpus.queries {
                let query = RetrievalQuery {
                    text: q.clone(),
                    limit: 10,
                    time_filter: None,
                    app_filter: None,
                };
                black_box(r.retrieve(&query).unwrap());
            }
        });
    });

    c.bench_function("lexical_only_1000ev_100q", |b| {
        let r = HybridRetriever::new(corpus.store.clone(), corpus.embedder.clone(), corpus.now_us)
            .with_weights(FusionWeights {
                w_sem: 0.0,
                w_lex: 1.0,
                w_rec: 0.0,
                w_entity: 0.0,
                w_src: 0.0,
            });
        b.iter(|| {
            for q in &corpus.queries {
                let query = RetrievalQuery {
                    text: q.clone(),
                    limit: 10,
                    time_filter: None,
                    app_filter: None,
                };
                black_box(r.retrieve(&query).unwrap());
            }
        });
    });

    c.bench_function("semantic_only_1000ev_100q", |b| {
        let r = HybridRetriever::new(corpus.store.clone(), corpus.embedder.clone(), corpus.now_us)
            .with_weights(FusionWeights {
                w_sem: 1.0,
                w_lex: 0.0,
                w_rec: 0.0,
                w_entity: 0.0,
                w_src: 0.0,
            });
        b.iter(|| {
            for q in &corpus.queries {
                let query = RetrievalQuery {
                    text: q.clone(),
                    limit: 10,
                    time_filter: None,
                    app_filter: None,
                };
                black_box(r.retrieve(&query).unwrap());
            }
        });
    });
}

criterion_group!(benches, bench_hybrid_recall);
criterion_main!(benches);
