//! Integration tests for the Phase 3 brain scaffold.
//!
//! Exercises the four traits + stub impls against the public API. Real
//! impls (`SQLCipher` / FTS5 / sqlite-vec store, arctic-embed-s embedder,
//! anchor-then-window query router) land in the Phase 3 PR sequence per
//! `docs/decisions/0010-event-episode-retrieval-unit-cc-fusion.md` and
//! `docs/decisions/0011-embedding-model-snowflake-arctic-embed-s.md`.

use std::sync::Arc;

use mci_brain::{
    stubs::{FixedDimEmbedder, InMemoryBrainStore, NoopChunker, StubRetriever},
    BrainStore, Chunk, ChunkId, Chunker, ChunkerError, EmbedError, Embedder, EventId,
    RetrievalQuery, RetrieveError, Retriever, StoreError, TimeRange,
};

const MICROS_PER_HOUR: u64 = 3_600_000_000;

fn chunk_at(text: &str, ev: u64, ts_us: u64, embedding: Option<Vec<f32>>) -> Chunk {
    Chunk {
        id: ChunkId(0),
        text: text.into(),
        source_event_id: EventId(ev),
        created_at_us: ts_us,
        embedding,
    }
}

// ---------------------------------------------------------------------------
// Chunker
// ---------------------------------------------------------------------------

#[test]
fn noop_chunker_empty_text_returns_empty_vec() {
    let c = NoopChunker;
    let out = c.chunk("").expect("chunk");
    assert!(out.is_empty(), "empty input → empty Vec, got {out:?}");
}

#[test]
fn noop_chunker_single_paragraph_is_one_chunk() {
    let c = NoopChunker;
    let out = c.chunk("a single paragraph with no blank lines").expect("chunk");
    assert_eq!(out.len(), 1);
    assert_eq!(out[0], "a single paragraph with no blank lines");
}

#[test]
fn noop_chunker_double_newline_splits() {
    let c = NoopChunker;
    let out = c.chunk("first para\n\nsecond para\n\nthird").expect("chunk");
    assert_eq!(out.len(), 3);
    assert_eq!(out[0], "first para");
    assert_eq!(out[1], "second para");
    assert_eq!(out[2], "third");
}

// ---------------------------------------------------------------------------
// Embedder
// ---------------------------------------------------------------------------

#[test]
fn fixed_dim_embedder_default_dimension_is_384() {
    // ADR-0009 pins the production dimension at 384. The default stub
    // matches so accidental dimension-mismatch regressions surface here.
    let e = FixedDimEmbedder::default();
    assert_eq!(e.dimension(), 384);
    let v = e.embed_one("anything").expect("embed");
    assert_eq!(v.len(), 384);
}

#[test]
fn fixed_dim_embedder_is_deterministic_same_text_same_vector() {
    let e = FixedDimEmbedder::default();
    let a = e.embed_one("hello world").expect("embed a");
    let b = e.embed_one("hello world").expect("embed b");
    assert_eq!(a, b, "deterministic embedder must round-trip identically");
}

#[test]
fn fixed_dim_embedder_different_text_different_vector() {
    let e = FixedDimEmbedder::default();
    let a = e.embed_one("hello world").expect("embed a");
    let b = e.embed_one("goodbye world").expect("embed b");
    assert_ne!(a, b);
}

#[test]
fn fixed_dim_embedder_vectors_are_unit_norm() {
    // ADR-0009: stored vectors are L2-normalized so cosine == dot product.
    let e = FixedDimEmbedder::default();
    let v = e.embed_one("the quick brown fox jumps over the lazy dog").expect("embed");
    let mag: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    assert!(
        (mag - 1.0).abs() < 1e-6,
        "expected L2 norm ≈ 1.0, got {mag}"
    );
}

#[test]
fn fixed_dim_embedder_zero_dim_rejected() {
    let e = FixedDimEmbedder { dim: 0, seed: 1 };
    let err = e.embed_one("hello").unwrap_err();
    assert!(matches!(err, EmbedError::InvalidInput(_)));
}

// ---------------------------------------------------------------------------
// BrainStore
// ---------------------------------------------------------------------------

#[test]
fn store_put_then_get_round_trip() {
    let s = InMemoryBrainStore::new();
    let id = s
        .put_chunk(&chunk_at("hello", 1, 1_000_000, None))
        .expect("put");
    let got = s.get_chunk(id).expect("get").expect("some");
    assert_eq!(got.id, id);
    assert_eq!(got.text, "hello");
    assert_eq!(got.source_event_id, EventId(1));
    assert_eq!(got.created_at_us, 1_000_000);
    assert!(got.embedding.is_none());
}

#[test]
fn store_get_unknown_id_is_ok_none() {
    let s = InMemoryBrainStore::new();
    let got = s.get_chunk(ChunkId(9_999)).expect("get");
    assert!(got.is_none());
}

#[test]
fn store_fts5_hits_ordered_by_descending_score() {
    let s = InMemoryBrainStore::new();
    // Higher density of "rust" in shorter text scores higher.
    let dense = s
        .put_chunk(&chunk_at("rust rust rust", 1, 0, None))
        .expect("put dense");
    let sparse = s
        .put_chunk(&chunk_at(
            "this is a long passage with one rust word buried in it",
            2,
            0,
            None,
        ))
        .expect("put sparse");
    let _miss = s
        .put_chunk(&chunk_at("nothing here", 3, 0, None))
        .expect("put miss");
    let hits = s.fts5_search("rust", 10).expect("fts5");
    assert_eq!(hits.len(), 2, "miss row must be excluded; got {hits:?}");
    assert_eq!(hits[0].0, dense, "dense match must rank first");
    assert_eq!(hits[1].0, sparse);
    assert!(
        hits[0].1 >= hits[1].1,
        "fts5 must return scores descending"
    );
}

#[test]
fn store_vec_search_hits_ordered_by_descending_cosine() {
    // Three orthogonal-ish unit vectors; cosine to a query equals the
    // matching component.
    let store = InMemoryBrainStore::new();
    let vec_a = vec![1.0, 0.0, 0.0];
    let vec_b = vec![0.0, 1.0, 0.0];
    let vec_c = vec![0.0, 0.0, 1.0];
    let id_a = store
        .put_chunk(&chunk_at("a", 1, 0, Some(vec_a)))
        .expect("put a");
    let id_b = store
        .put_chunk(&chunk_at("b", 2, 0, Some(vec_b)))
        .expect("put b");
    let _id_c = store
        .put_chunk(&chunk_at("c", 3, 0, Some(vec_c)))
        .expect("put c");

    let query = vec![0.9, 0.4, 0.0];
    let hits = store.vec_search(&query, 3).expect("vec");
    assert_eq!(hits.len(), 3);
    assert_eq!(hits[0].0, id_a, "highest cosine first");
    assert_eq!(hits[1].0, id_b);
    assert!(
        hits[0].1 >= hits[1].1 && hits[1].1 >= hits[2].1,
        "vec scores must be descending: {hits:?}"
    );
}

#[test]
fn store_fts5_empty_query_rejected() {
    let s = InMemoryBrainStore::new();
    let err = s.fts5_search("", 5).unwrap_err();
    assert!(matches!(err, StoreError::InvalidInput(_)));
}

// ---------------------------------------------------------------------------
// Retriever — end-to-end
// ---------------------------------------------------------------------------

fn make_retriever_with_fixtures() -> (Arc<InMemoryBrainStore>, StubRetriever<FixedDimEmbedder>, Vec<ChunkId>) {
    let store = Arc::new(InMemoryBrainStore::new());
    let emb = FixedDimEmbedder::default();
    // 5 chunks across 2 apps + 3 time bands. The retriever's "now" is at
    // 100 hours past the epoch so recency-decay is monotonic and obvious.
    let now_us = 100 * MICROS_PER_HOUR;

    // event 1 — Safari, 0 hours ago, contains "rust"
    let c1 = store
        .put_chunk(&chunk_at(
            "rust async runtime tokio",
            1,
            now_us,
            Some(emb.embed_one("rust async runtime tokio").unwrap()),
        ))
        .unwrap();
    store.set_event_app(EventId(1), "com.apple.Safari");

    // event 2 — Safari, 10 hours ago, "rust" again but less dense
    let c2 = store
        .put_chunk(&chunk_at(
            "we wrote a small rust crate to test the trait shape",
            2,
            now_us - 10 * MICROS_PER_HOUR,
            Some(emb.embed_one("we wrote a small rust crate to test the trait shape").unwrap()),
        ))
        .unwrap();
    store.set_event_app(EventId(2), "com.apple.Safari");

    // event 3 — Terminal, 1 hour ago, "rust"
    let c3 = store
        .put_chunk(&chunk_at(
            "cargo test rust workspace",
            3,
            now_us - MICROS_PER_HOUR,
            Some(emb.embed_one("cargo test rust workspace").unwrap()),
        ))
        .unwrap();
    store.set_event_app(EventId(3), "com.apple.Terminal");

    // event 4 — Terminal, 50 hours ago, no "rust"
    let c4 = store
        .put_chunk(&chunk_at(
            "unrelated python notebook page",
            4,
            now_us - 50 * MICROS_PER_HOUR,
            Some(emb.embed_one("unrelated python notebook page").unwrap()),
        ))
        .unwrap();
    store.set_event_app(EventId(4), "com.apple.Terminal");

    // event 5 — Safari, 200 hours ago (older than now_us itself? no — now is
    // 100h; this would underflow. Bump now to make it possible). Use 5h ago
    // instead so we still have a far-past sample without underflow.
    let c5 = store
        .put_chunk(&chunk_at(
            "introduction to rust ownership rules",
            5,
            now_us - 5 * MICROS_PER_HOUR,
            Some(emb.embed_one("introduction to rust ownership rules").unwrap()),
        ))
        .unwrap();
    store.set_event_app(EventId(5), "com.apple.Safari");

    let r = StubRetriever::new(emb, Arc::clone(&store), now_us);
    (store, r, vec![c1, c2, c3, c4, c5])
}

#[test]
fn retriever_returns_hits_ordered_by_combined_score() {
    let (_store, retriever, _ids) = make_retriever_with_fixtures();
    let q = RetrievalQuery {
        text: "rust".into(),
        limit: 10,
        time_filter: None,
        app_filter: None,
    };
    let hits = retriever.retrieve(&q).expect("retrieve");
    assert!(!hits.is_empty(), "query 'rust' must produce hits");
    // strictly descending by combined score
    for w in hits.windows(2) {
        assert!(
            w[0].score_combined >= w[1].score_combined,
            "hits must be sorted by score_combined descending: {hits:?}"
        );
    }
}

#[test]
fn retriever_normalized_scores_in_unit_range() {
    let (_store, retriever, _ids) = make_retriever_with_fixtures();
    let q = RetrievalQuery {
        text: "rust".into(),
        limit: 10,
        time_filter: None,
        app_filter: None,
    };
    let hits = retriever.retrieve(&q).expect("retrieve");
    for h in &hits {
        assert!(
            (0.0..=1.0).contains(&h.score_lexical),
            "score_lexical out of [0,1]: {h:?}"
        );
        assert!(
            (0.0..=1.0).contains(&h.score_semantic),
            "score_semantic out of [0,1]: {h:?}"
        );
        assert!(
            (0.0..=1.0).contains(&h.score_recency),
            "score_recency out of [0,1]: {h:?}"
        );
    }
}

#[test]
fn retriever_time_filter_excludes_out_of_range_chunks() {
    let (store, retriever, _ids) = make_retriever_with_fixtures();
    let now_us = 100 * MICROS_PER_HOUR;
    // Window the past 2 hours only. Fixtures within: event 1 (0h ago),
    // event 3 (1h ago). Fixtures outside: event 2 (10h), event 4 (50h),
    // event 5 (5h).
    let q = RetrievalQuery {
        text: "rust".into(),
        limit: 10,
        time_filter: Some(TimeRange {
            from_us: now_us - 2 * MICROS_PER_HOUR,
            to_us: now_us,
        }),
        app_filter: None,
    };
    let hits = retriever.retrieve(&q).expect("retrieve");
    let events: Vec<EventId> = hits
        .iter()
        .map(|h| {
            let c = store.get_chunk(h.chunk_id).unwrap().unwrap();
            c.source_event_id
        })
        .collect();
    for ev in &events {
        assert!(
            *ev == EventId(1) || *ev == EventId(3),
            "time_filter must exclude events outside the window, got {ev:?}"
        );
    }
    assert!(
        events.contains(&EventId(1)) || events.contains(&EventId(3)),
        "time_filter must retain at least one in-window event"
    );
}

#[test]
fn retriever_app_filter_excludes_wrong_bundle_chunks() {
    let (store, retriever, _ids) = make_retriever_with_fixtures();
    let q = RetrievalQuery {
        text: "rust".into(),
        limit: 10,
        time_filter: None,
        app_filter: Some("com.apple.Terminal".into()),
    };
    let hits = retriever.retrieve(&q).expect("retrieve");
    for h in &hits {
        let c = store.get_chunk(h.chunk_id).unwrap().unwrap();
        let app = store
            .get_event_app(c.source_event_id)
            .expect("event has app");
        assert_eq!(
            app, "com.apple.Terminal",
            "app_filter must exclude wrong-bundle hits"
        );
    }
}

#[test]
fn retriever_empty_query_rejected() {
    let (_store, retriever, _ids) = make_retriever_with_fixtures();
    let q = RetrievalQuery {
        text: String::new(),
        limit: 5,
        time_filter: None,
        app_filter: None,
    };
    let err = retriever.retrieve(&q).unwrap_err();
    assert!(matches!(err, RetrieveError::InvalidInput(_)));
}

#[test]
fn retriever_zero_limit_returns_empty() {
    let (_store, retriever, _ids) = make_retriever_with_fixtures();
    let q = RetrievalQuery {
        text: "rust".into(),
        limit: 0,
        time_filter: None,
        app_filter: None,
    };
    let hits = retriever.retrieve(&q).expect("retrieve");
    assert!(hits.is_empty());
}

// ---------------------------------------------------------------------------
// Error round-trips — Display surfaces a useful message
// ---------------------------------------------------------------------------

#[test]
fn errors_display_round_trip() {
    let e1: ChunkerError = ChunkerError::InvalidInput("boundary".into());
    let e2: EmbedError = EmbedError::Backend("ane offline".into());
    let e3: StoreError = StoreError::Other("disk full".into());
    let e4: RetrieveError = RetrieveError::InvalidInput("empty".into());
    assert!(e1.to_string().contains("boundary"));
    assert!(e2.to_string().contains("ane offline"));
    assert!(e3.to_string().contains("disk full"));
    assert!(e4.to_string().contains("empty"));
    // Discriminants and namespaced prefixes
    assert!(e1.to_string().starts_with("chunker:"));
    assert!(e2.to_string().starts_with("embed:"));
    assert!(e3.to_string().starts_with("store:"));
    assert!(e4.to_string().starts_with("retrieve:"));
}
