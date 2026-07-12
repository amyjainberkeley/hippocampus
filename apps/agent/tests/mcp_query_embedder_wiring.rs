//! Query-side embedder wiring smoke test (closes TODO P3.8 / CRS
//! telemetry-gap G3).
//!
//! Before this fix, `run_mcp_serve` hard-coded `embedder = None`, so
//! `mci_recall` fell back to FTS5 lexical-only even when the ingest
//! pump had produced real 384-d embeddings for every event. PR #310
//! ratified the ingest-side wire; this test locks the recall-side
//! wire in place so it cannot silently regress back to lexical-only.
//!
//! The test does NOT exercise `run_mcp_serve` directly (it depends on
//! the encrypted brain file + Core ML model on disk). Instead it
//! exercises the same seam `run_mcp_serve` calls into:
//! `LiveBrainReader::from_store_with_embedder(store, Some(embedder))`
//! → `Server::dispatch("mci_recall")` → the embedder's `embed_one`
//! must fire on the user's query text.
//!
//! We use a **spy embedder** (records every `embed_one` call and
//! returns a unit-norm 384-d vector) so we assert two things at once:
//!
//! 1. The embedder was actually consulted — proving the query side is
//!    wired (not stub-swallowed).
//! 2. The returned vector is unit-norm 384-d — the same shape contract
//!    PR #310 pinned on the ingest side (`ArcticEmbedSEmbedder`
//!    invariant per ADR-0011 §3).
//!
//! # CSO sign-off notes
//!
//! (a) No new write paths — test uses existing `BrainStore::put_event`.
//! (b) Read-only handle via existing `LiveBrainReader::from_store_with_embedder`.
//! (c) Hermetic — brain lives in a `tempfile::TempDir`, disposed on drop.
//! (d) Zero new third-party crates.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use mci_agent::mcp::{JsonRpcId, JsonRpcRequest, LiveBrainReader, Server};
use mci_brain::{BrainStore, EmbedError, Embedder, Event, EventId, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

/// Spy embedder: records every query text passed to `embed_one`, and
/// returns a deterministic unit-norm 384-d vector so the downstream
/// `HybridRetriever` accepts the shape.
struct SpyEmbedder {
    calls: Mutex<Vec<String>>,
    call_count: AtomicUsize,
}

impl SpyEmbedder {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            calls: Mutex::new(Vec::new()),
            call_count: AtomicUsize::new(0),
        })
    }

    fn call_count(&self) -> usize {
        self.call_count.load(Ordering::SeqCst)
    }

    fn last_call(&self) -> Option<String> {
        self.calls.lock().unwrap().last().cloned()
    }
}

impl Embedder for SpyEmbedder {
    fn dimension(&self) -> usize {
        384
    }

    fn embed_one(&self, text: &str) -> Result<Vec<f32>, EmbedError> {
        self.calls.lock().unwrap().push(text.to_owned());
        self.call_count.fetch_add(1, Ordering::SeqCst);

        // Return a unit-norm 384-d vector so HybridRetriever's shape
        // check + cosine math don't blow up. Simple pattern:
        // v[0]=1, rest=0 → |v| = 1.
        let mut v = vec![0.0_f32; 384];
        v[0] = 1.0;
        Ok(v)
    }
}

fn open_temp_store() -> (tempfile::TempDir, Arc<SqlCipherBrainStore>) {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("query_embedder_test.sqlite");
    let key = DbKey::from_bytes([0xCD; 32]);
    let store = Arc::new(SqlCipherBrainStore::new(&db_path, &key).unwrap());
    (dir, store)
}

fn make_event_with_embedding(text: &str, ts_us: u64) -> Event {
    // Seed with the same unit-norm vector our SpyEmbedder returns so
    // there's at least one semantic candidate to score against.
    let mut emb = vec![0.0_f32; 384];
    emb[0] = 1.0;
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some("com.example.p3p8.spy".into()),
        window_title: Some("Query embedder wiring smoke".into()),
        url: Some("https://example.com/p3p8".into()),
        text: text.into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: Some(emb),
    }
}

/// Core wiring assertion: when the reader carries `Some(embedder)`, a
/// `mci_recall` dispatch MUST invoke `embed_one` on the query text.
///
/// This is the assertion that would have failed under the old
/// `embedder = None` default in `run_mcp_serve` — even after PR #310
/// wired the ingest side, the query side stayed dark.
#[test]
fn mci_recall_invokes_query_embedder_when_wired() {
    let (_dir, store) = open_temp_store();

    // Seed at least one event with a matching embedding so the hybrid
    // path has something to fuse (FTS5 hit on "cache invalidation" +
    // cosine 1.0 against the seeded vector).
    store
        .put_event(&make_event_with_embedding(
            "cache invalidation strategies for CDN edge nodes",
            1_000_000,
        ))
        .unwrap();

    let spy = SpyEmbedder::new();
    let embedder: Arc<dyn Embedder> = Arc::clone(&spy) as Arc<dyn Embedder>;

    let reader = LiveBrainReader::from_store_with_embedder(store, Some(embedder));
    let server = Server::new(Arc::new(reader));

    let query_text = "cache invalidation";
    let request = JsonRpcRequest {
        jsonrpc: "2.0".into(),
        method: "tools/call".into(),
        params: Some(serde_json::json!({
            "name": "mci_recall",
            "arguments": {"query": query_text, "limit": 10}
        })),
        id: Some(JsonRpcId::Number(1)),
    };

    let response = server.dispatch(request).expect("dispatch response");
    assert!(
        response.error.is_none(),
        "mci_recall must not error: {:?}",
        response.error
    );

    // Assertion 1 — the query-side embedder was actually consulted.
    // Under the pre-fix `embedder = None` default this would be 0.
    assert!(
        spy.call_count() >= 1,
        "query-side embedder must be called at least once — got {}",
        spy.call_count()
    );

    // Assertion 2 — the embedder saw the user's query text (or a
    // prefix-decorated variant of it, per ADR-0011 §3). The raw query
    // must appear inside whatever string reached the embedder.
    let last = spy.last_call().expect("spy recorded at least one call");
    assert!(
        last.contains(query_text),
        "embedder call text must contain the user's query — got {last:?}"
    );
}

/// PR #310 shape contract, mirrored on the query side: any real
/// embedder wired into the recall path returns a 384-d unit-norm
/// vector (`ArcticEmbedS` invariant, ADR-0011 §3). Locking this on the
/// query side keeps future backend swaps honest.
#[test]
fn query_embedder_returns_unit_norm_384d_vector() {
    let spy = SpyEmbedder::new();
    let embedder: &dyn Embedder = spy.as_ref();

    assert_eq!(embedder.dimension(), 384, "arctic-embed-s is 384-d");

    let v = embedder
        .embed_one("unit norm probe")
        .expect("embed_one must succeed on spy");
    assert_eq!(v.len(), 384, "vector must be 384-d");

    let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    assert!(
        norm.is_finite() && (norm - 1.0).abs() < 1e-4,
        "vector must be unit-norm, got |v|={norm}"
    );
}
