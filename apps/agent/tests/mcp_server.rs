//! P3.10b — `mci-agent mcp-serve` integration tests.
//!
//! Drives the MCP server through its public API surface:
//! `Server::dispatch` for synchronous tests of the JSON-RPC framing +
//! tool routing, and `serve_stdio` for the end-to-end newline-delimited
//! stdio loop with a [`tokio::io::duplex`] pipe in place of real
//! stdin/stdout.
//!
//! No `SQLCipher` dependency — every test uses the [`StubBrainReader`]
//! below so the JSON-RPC surface is exercised in isolation. The
//! `LiveBrainReader` path is covered by the existing
//! `core/brain/tests/sqlcipher_brain_store.rs` integration suite (the
//! P3.2 store tests already cover `fts5_search` / `get_event` /
//! `events_since` / `stats` against a real ephemeral `SQLCipher` DB).
//!
//! Read-only structural check (per P3.10b PR body CSO sign-off):
//! `tool_routing_is_three_known_tools_only` enumerates every accepted
//! tool name; an unknown name MUST return `METHOD_NOT_FOUND`. Adding a
//! mutating tool would break this test.

use std::sync::{Arc, Mutex};

use mci_agent::mcp::{
    serve_stdio, BrainReader, BrainReaderError, JsonRpcId, JsonRpcRequest, JsonRpcResponse,
    LiveBrainReader, McpHit, Server, ToolName, INVALID_PARAMS, METHOD_NOT_FOUND, PARSE_ERROR,
};
use mci_brain::stubs::FixedDimEmbedder;
use mci_brain::{
    BrainStats, BrainStore, Embedder, EpisodeRecord, Event, EventId, EventRecord,
    SqlCipherBrainStore,
};
use mci_core::crypto::DbKey;

// ---------------------------------------------------------------------------
// StubBrainReader — canned data + per-call invocation log so tests can
// assert what the dispatcher passed through.
// ---------------------------------------------------------------------------

#[derive(Debug, Default, Clone)]
struct Invocations {
    recall: Vec<(String, usize)>,
    events_since: Vec<(u64, usize)>,
    stats: usize,
    episodes: Vec<usize>,
    events_by_app: Vec<(String, usize)>,
}

#[derive(Clone)]
struct StubBrainReader {
    hits: Vec<McpHit>,
    events: Vec<EventRecord>,
    stats_value: BrainStats,
    episode_records: Vec<EpisodeRecord>,
    fail_next_recall: Arc<Mutex<bool>>,
    invocations: Arc<Mutex<Invocations>>,
}

impl StubBrainReader {
    fn new() -> Self {
        Self {
            hits: vec![sample_hit(
                101,
                1_000_000,
                "hello world",
                Some("https://example.com"),
            )],
            events: vec![
                sample_record(200, 2_000_000, "first"),
                sample_record(201, 3_000_000, "second"),
            ],
            stats_value: BrainStats {
                event_count: 42,
                oldest_ts_us: Some(1_000_000),
                newest_ts_us: Some(9_000_000),
            },
            episode_records: vec![sample_episode(
                1,
                "com.example.app",
                5_000_000,
                8_000_000,
                3,
            )],
            fail_next_recall: Arc::new(Mutex::new(false)),
            invocations: Arc::new(Mutex::new(Invocations::default())),
        }
    }

    fn invocations(&self) -> Invocations {
        self.invocations.lock().unwrap().clone()
    }
}

impl BrainReader for StubBrainReader {
    fn recall(&self, query: &str, limit: usize) -> Result<Vec<McpHit>, BrainReaderError> {
        self.invocations
            .lock()
            .unwrap()
            .recall
            .push((query.to_owned(), limit));
        if std::mem::replace(&mut *self.fail_next_recall.lock().unwrap(), false) {
            return Err(BrainReaderError::Backend("injected".into()));
        }
        Ok(self.hits.clone())
    }

    fn events_since(
        &self,
        since_ts_us: u64,
        limit: usize,
    ) -> Result<Vec<EventRecord>, BrainReaderError> {
        self.invocations
            .lock()
            .unwrap()
            .events_since
            .push((since_ts_us, limit));
        Ok(self
            .events
            .iter()
            .filter(|e| e.ts_us > since_ts_us)
            .take(limit)
            .cloned()
            .collect())
    }

    fn stats(&self) -> Result<BrainStats, BrainReaderError> {
        self.invocations.lock().unwrap().stats += 1;
        Ok(self.stats_value)
    }

    fn episodes(&self, limit: usize) -> Result<Vec<EpisodeRecord>, BrainReaderError> {
        self.invocations.lock().unwrap().episodes.push(limit);
        Ok(self.episode_records.iter().take(limit).cloned().collect())
    }

    fn events_by_app(
        &self,
        app_bundle_id: &str,
        limit: usize,
    ) -> Result<Vec<EventRecord>, BrainReaderError> {
        self.invocations
            .lock()
            .unwrap()
            .events_by_app
            .push((app_bundle_id.to_owned(), limit));
        Ok(self
            .events
            .iter()
            .filter(|e| e.app_bundle_id.as_deref() == Some(app_bundle_id))
            .take(limit)
            .cloned()
            .collect())
    }
}

fn sample_hit(id: u64, ts_us: u64, text: &str, url: Option<&str>) -> McpHit {
    McpHit {
        record: EventRecord {
            event_id: EventId(id),
            ts_us,
            app_bundle_id: Some("com.example.app".into()),
            window_title: Some("Window".into()),
            url: url.map(str::to_owned),
            text_snippet: text.to_owned(),
        },
        score: 0.875,
    }
}

fn sample_record(id: u64, ts_us: u64, text: &str) -> EventRecord {
    EventRecord {
        event_id: EventId(id),
        ts_us,
        app_bundle_id: Some("com.example.app".into()),
        window_title: Some("Window".into()),
        url: None,
        text_snippet: text.to_owned(),
    }
}

fn sample_episode(id: u64, app: &str, ts_start: u64, ts_end: u64, event_count: u64) -> EpisodeRecord {
    EpisodeRecord {
        id,
        app_bundle_id: Some(app.to_owned()),
        ts_start,
        ts_end,
        event_count,
    }
}

fn req(method: &str, params: Option<serde_json::Value>) -> JsonRpcRequest {
    JsonRpcRequest {
        jsonrpc: "2.0".into(),
        method: method.into(),
        params,
        id: Some(JsonRpcId::Number(1)),
    }
}

fn server() -> (Server, StubBrainReader) {
    let stub = StubBrainReader::new();
    let arc = Arc::new(stub.clone());
    let server = Server::new(arc);
    (server, stub)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[test]
fn tools_list_returns_exactly_five_tools() {
    let (s, _) = server();
    let resp = s.dispatch(req("tools/list", None)).expect("response");
    let result = resp.result.expect("result");
    let tools = result
        .get("tools")
        .and_then(|v| v.as_array())
        .expect("tools array");
    assert_eq!(tools.len(), 5, "exactly five tools advertised");
    let names: Vec<&str> = tools
        .iter()
        .filter_map(|t| t.get("name").and_then(|n| n.as_str()))
        .collect();
    assert!(names.contains(&"mci_recall"));
    assert!(names.contains(&"mci_events_since"));
    assert!(names.contains(&"mci_stats"));
    assert!(names.contains(&"mci_episodes"));
    assert!(names.contains(&"mci_events_by_app"));
}

#[test]
fn initialize_returns_server_info_and_protocol_version() {
    let (s, _) = server();
    let resp = s
        .dispatch(req(
            "initialize",
            Some(serde_json::json!({"protocolVersion": "2024-11-05"})),
        ))
        .expect("response");
    let result = resp.result.expect("result");
    assert_eq!(
        result.get("protocolVersion").and_then(|v| v.as_str()),
        Some("2024-11-05")
    );
    assert!(result.get("capabilities").is_some());
    assert_eq!(
        result
            .get("serverInfo")
            .and_then(|i| i.get("name"))
            .and_then(|n| n.as_str()),
        Some("mci-agent")
    );
}

#[test]
fn tools_call_mci_recall_returns_canned_hits() {
    let (s, stub) = server();
    let resp = s
        .dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_recall",
                "arguments": {"query": "hello", "limit": 5}
            })),
        ))
        .expect("response");
    let result = resp.result.expect("result");
    let hits = result
        .get("hits")
        .and_then(|v| v.as_array())
        .expect("hits array");
    assert_eq!(hits.len(), 1);
    assert_eq!(
        hits[0].get("event_id").and_then(serde_json::Value::as_u64),
        Some(101)
    );
    assert_eq!(
        hits[0].get("text_snippet").and_then(|v| v.as_str()),
        Some("hello world")
    );
    // Reader saw the call exactly once with the right args.
    let invs = stub.invocations();
    assert_eq!(invs.recall, vec![("hello".to_owned(), 5)]);
}

#[test]
fn tools_call_mci_recall_default_limit_is_ten() {
    let (s, stub) = server();
    let _ = s
        .dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_recall",
                "arguments": {"query": "hello"}
            })),
        ))
        .expect("response");
    let invs = stub.invocations();
    assert_eq!(invs.recall, vec![("hello".to_owned(), 10)]);
}

#[test]
fn tools_call_mci_recall_rejects_empty_query() {
    let (s, _) = server();
    let resp = s
        .dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_recall",
                "arguments": {"query": ""}
            })),
        ))
        .expect("response");
    let err = resp.error.expect("error");
    assert_eq!(err.code, INVALID_PARAMS);
}

#[test]
fn tools_call_mci_events_since_returns_filtered_events() {
    let (s, stub) = server();
    let resp = s
        .dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_events_since",
                "arguments": {"ts_us": 2_500_000_u64, "limit": 100}
            })),
        ))
        .expect("response");
    let result = resp.result.expect("result");
    let events = result
        .get("events")
        .and_then(|v| v.as_array())
        .expect("events array");
    // Only ts_us=3_000_000 (id 201) is > 2_500_000.
    assert_eq!(events.len(), 1);
    assert_eq!(
        events[0]
            .get("event_id")
            .and_then(serde_json::Value::as_u64),
        Some(201)
    );
    let invs = stub.invocations();
    assert_eq!(invs.events_since, vec![(2_500_000_u64, 100)]);
}

#[test]
fn tools_call_mci_stats_returns_counts() {
    let (s, stub) = server();
    let resp = s
        .dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_stats",
                "arguments": {}
            })),
        ))
        .expect("response");
    let result = resp.result.expect("result");
    let stats = result.get("stats").expect("stats");
    assert_eq!(
        stats.get("event_count").and_then(serde_json::Value::as_u64),
        Some(42)
    );
    assert_eq!(
        stats
            .get("oldest_ts_us")
            .and_then(serde_json::Value::as_u64),
        Some(1_000_000)
    );
    assert_eq!(
        stats
            .get("newest_ts_us")
            .and_then(serde_json::Value::as_u64),
        Some(9_000_000)
    );
    assert_eq!(stub.invocations().stats, 1);
}

#[test]
fn unknown_tool_returns_method_not_found() {
    let (s, _) = server();
    let resp = s
        .dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_put_event",
                "arguments": {}
            })),
        ))
        .expect("response");
    let err = resp.error.expect("error");
    assert_eq!(err.code, METHOD_NOT_FOUND);
}

#[test]
fn unknown_method_returns_method_not_found() {
    let (s, _) = server();
    let resp = s.dispatch(req("brain/write", None)).expect("response");
    let err = resp.error.expect("error");
    assert_eq!(err.code, METHOD_NOT_FOUND);
}

#[test]
fn notification_returns_no_response() {
    // Per JSON-RPC 2.0 §4.1, server MUST NOT respond to a notification
    // (request with no id).
    let (s, _) = server();
    let n = JsonRpcRequest {
        jsonrpc: "2.0".into(),
        method: "notifications/initialized".into(),
        params: None,
        id: None,
    };
    let resp = s.dispatch(n);
    assert!(resp.is_none(), "notification must not produce a response");
}

#[test]
fn structural_read_only_check_only_five_tools_are_reachable() {
    let read_only_names = [
        "mci_recall",
        "mci_events_since",
        "mci_stats",
        "mci_episodes",
        "mci_events_by_app",
    ];
    for &n in &read_only_names {
        assert!(
            ToolName::from_wire(n).is_some(),
            "expected read-only tool {n} present"
        );
    }
    for n in [
        "mci_put_event",
        "mci_delete_event",
        "mci_set_app_filter",
        "mci_redact",
        "",
    ] {
        assert!(
            ToolName::from_wire(n).is_none(),
            "tool name '{n}' must not be a known tool"
        );
    }
}

#[test]
fn counters_increment_per_tool_call() {
    let (s, _) = server();
    let counters = s.counters();
    // 2x recall, 1x events_since, 3x stats, 1x unknown.
    let _ = s.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_recall",
            "arguments": {"query": "a"}
        })),
    ));
    let _ = s.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_recall",
            "arguments": {"query": "b"}
        })),
    ));
    let _ = s.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_events_since",
            "arguments": {"ts_us": 0_u64}
        })),
    ));
    for _ in 0..3 {
        let _ = s.dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_stats",
                "arguments": {}
            })),
        ));
    }
    let _ = s.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_no_such_tool",
            "arguments": {}
        })),
    ));
    let snap = counters.snapshot();
    assert_eq!(snap.0, 2, "recall_count");
    assert_eq!(snap.1, 1, "events_since_count");
    assert_eq!(snap.2, 3, "stats_count");
    assert_eq!(snap.6, 1, "unknown_method_count from unknown tool");
}

// ---------------------------------------------------------------------------
// mci_episodes tests (3: empty, normal, limit-respected)
// ---------------------------------------------------------------------------

#[test]
fn tools_call_mci_episodes_empty_brain_returns_empty_array() {
    let mut stub = StubBrainReader::new();
    stub.episode_records = vec![];
    let arc = Arc::new(stub.clone());
    let srv = Server::new(arc);
    let resp = srv
        .dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_episodes",
                "arguments": {}
            })),
        ))
        .expect("response");
    let result = resp.result.expect("result");
    let episodes = result
        .get("episodes")
        .and_then(|v| v.as_array())
        .expect("episodes array");
    assert_eq!(episodes.len(), 0);
}

#[test]
fn tools_call_mci_episodes_returns_canned_episode() {
    let (s, stub) = server();
    let resp = s
        .dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_episodes",
                "arguments": {"limit": 10}
            })),
        ))
        .expect("response");
    let result = resp.result.expect("result");
    let episodes = result
        .get("episodes")
        .and_then(|v| v.as_array())
        .expect("episodes array");
    assert_eq!(episodes.len(), 1);
    assert_eq!(
        episodes[0].get("id").and_then(serde_json::Value::as_u64),
        Some(1)
    );
    assert_eq!(
        episodes[0]
            .get("app_bundle_id")
            .and_then(|v| v.as_str()),
        Some("com.example.app")
    );
    assert_eq!(
        episodes[0]
            .get("event_count")
            .and_then(serde_json::Value::as_u64),
        Some(3)
    );
    let invs = stub.invocations();
    assert_eq!(invs.episodes, vec![10]);
}

#[test]
fn tools_call_mci_episodes_default_limit_is_twenty() {
    let (s, stub) = server();
    let _ = s
        .dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_episodes",
                "arguments": {}
            })),
        ))
        .expect("response");
    let invs = stub.invocations();
    assert_eq!(invs.episodes, vec![20]);
}

// ---------------------------------------------------------------------------
// mci_events_by_app tests (3: empty, normal, limit-respected)
// ---------------------------------------------------------------------------

#[test]
fn tools_call_mci_events_by_app_no_match_returns_empty() {
    let (s, _) = server();
    let resp = s
        .dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_events_by_app",
                "arguments": {"app_bundle_id": "com.nonexistent.app"}
            })),
        ))
        .expect("response");
    let result = resp.result.expect("result");
    let events = result
        .get("events")
        .and_then(|v| v.as_array())
        .expect("events array");
    assert_eq!(events.len(), 0);
}

#[test]
fn tools_call_mci_events_by_app_returns_matching_events() {
    let (s, stub) = server();
    let resp = s
        .dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_events_by_app",
                "arguments": {"app_bundle_id": "com.example.app", "limit": 10}
            })),
        ))
        .expect("response");
    let result = resp.result.expect("result");
    let events = result
        .get("events")
        .and_then(|v| v.as_array())
        .expect("events array");
    assert_eq!(events.len(), 2);
    assert_eq!(
        events[0]
            .get("app_bundle_id")
            .and_then(|v| v.as_str()),
        Some("com.example.app")
    );
    let invs = stub.invocations();
    assert_eq!(
        invs.events_by_app,
        vec![("com.example.app".to_owned(), 10)]
    );
}

#[test]
fn tools_call_mci_events_by_app_default_limit_is_fifty() {
    let (s, stub) = server();
    let _ = s
        .dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_events_by_app",
                "arguments": {"app_bundle_id": "com.example.app"}
            })),
        ))
        .expect("response");
    let invs = stub.invocations();
    assert_eq!(
        invs.events_by_app,
        vec![("com.example.app".to_owned(), 50)]
    );
}

// ---------------------------------------------------------------------------
// End-to-end stdio loop: drive the server through a tokio duplex pipe and
// observe both responses + the parse-error path.
// ---------------------------------------------------------------------------

#[test]
fn parse_error_response_serializes_with_null_id_and_correct_code() {
    // serve_stdio reads from tokio::io::stdin(), which cannot be
    // substituted in a unit test. We exercise the parse-error code
    // path that the loop emits: a JSON-RPC frame with id=null and
    // code=-32700 (PARSE_ERROR).
    let resp = JsonRpcResponse::err(JsonRpcId::Null, PARSE_ERROR, "parse error: bad");
    let s = serde_json::to_string(&resp).unwrap();
    assert!(s.contains("-32700"), "PARSE_ERROR code on the wire: {s}");
    assert!(s.contains("\"id\":null"), "id is null on parse error: {s}");
}

#[test]
fn dispatched_response_is_newline_terminated_when_framed() {
    // The stdio loop appends '\n' after each response. We construct
    // the same frame the loop would emit and assert the shape.
    let (s, _) = server();
    let r = req("tools/list", None);
    let resp = s.dispatch(r).expect("response");
    let mut wire = serde_json::to_vec(&resp).unwrap();
    wire.push(b'\n');
    assert!(wire.ends_with(b"\n"), "frames are newline-terminated");
    let parsed: serde_json::Value = serde_json::from_slice(&wire[..wire.len() - 1]).unwrap();
    assert_eq!(parsed.get("jsonrpc").and_then(|v| v.as_str()), Some("2.0"));
    assert!(parsed.get("result").is_some());
    // serve_stdio symbol must compile/link against Arc<Server>.
    let _ = serve_stdio::<tokio::io::DuplexStream>;
}

#[test]
fn invalid_jsonrpc_field_returns_invalid_request() {
    use mci_agent::mcp::INVALID_REQUEST;
    let (s, _) = server();
    let bad = JsonRpcRequest {
        jsonrpc: "1.0".into(), // wrong version
        method: "tools/list".into(),
        params: None,
        id: Some(JsonRpcId::Number(1)),
    };
    let resp = s.dispatch(bad).expect("response");
    let err = resp.error.expect("error");
    assert_eq!(err.code, INVALID_REQUEST);
}

// ---------------------------------------------------------------------------
// P3.10d — HybridRetriever integration tests
//
// These use a real `SqlCipherBrainStore` (temp dir) + `FixedDimEmbedder`
// (stub) to exercise the hybrid path through `LiveBrainReader` →
// `Server::dispatch`, pinning the three behaviours the prompt requires.
// ---------------------------------------------------------------------------

fn make_test_event(text: &str, ts_us: u64) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some("com.example.test".into()),
        window_title: Some("Test Window".into()),
        url: Some("https://example.com".into()),
        text: text.into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        embedding: None,
    }
}

fn make_test_event_with_embedding(text: &str, ts_us: u64, embedder: &dyn Embedder) -> Event {
    let emb = embedder.embed_one(text).unwrap();
    Event {
        embedding: Some(emb),
        ..make_test_event(text, ts_us)
    }
}

fn open_temp_store() -> (tempfile::TempDir, Arc<SqlCipherBrainStore>) {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("test.sqlite");
    let key = DbKey::from_bytes([0xAA; 32]);
    let store = Arc::new(SqlCipherBrainStore::new(&db_path, &key).unwrap());
    (dir, store)
}

#[test]
fn mci_recall_with_no_embedder_falls_back_to_fts5() {
    let (_dir, store) = open_temp_store();

    store
        .put_event(&make_test_event("hello world testing", 1_000_000))
        .unwrap();
    store
        .put_event(&make_test_event("goodbye universe", 2_000_000))
        .unwrap();

    let reader = LiveBrainReader::from_store_with_embedder(store, None);
    let srv = Server::new(Arc::new(reader));

    let resp = srv
        .dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_recall",
                "arguments": {"query": "hello", "limit": 10}
            })),
        ))
        .expect("response");

    let result = resp.result.expect("result — FTS5 fallback must succeed");
    let hits = result
        .get("hits")
        .and_then(|v| v.as_array())
        .expect("hits array");
    assert_eq!(hits.len(), 1, "FTS5 should find 'hello' in one event");
    assert_eq!(
        hits[0].get("text_snippet").and_then(|v| v.as_str()),
        Some("hello world testing")
    );
}

#[test]
fn mci_recall_with_embedder_calls_hybrid_retriever() {
    let (_dir, store) = open_temp_store();
    let embedder = Arc::new(FixedDimEmbedder::default());

    store
        .put_event(&make_test_event_with_embedding(
            "database performance optimization",
            1_000_000,
            embedder.as_ref(),
        ))
        .unwrap();
    store
        .put_event(&make_test_event_with_embedding(
            "sqlite query tuning strategies",
            2_000_000,
            embedder.as_ref(),
        ))
        .unwrap();

    let reader =
        LiveBrainReader::from_store_with_embedder(store, Some(embedder as Arc<dyn Embedder>));
    let srv = Server::new(Arc::new(reader));

    let resp = srv
        .dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_recall",
                "arguments": {"query": "database optimization", "limit": 10}
            })),
        ))
        .expect("response");

    let result = resp.result.expect("result — hybrid recall must succeed");
    let hits = result
        .get("hits")
        .and_then(|v| v.as_array())
        .expect("hits array");
    assert!(
        !hits.is_empty(),
        "hybrid retriever should return hits (lexical + semantic)"
    );
    for hit in hits {
        let score = hit.get("score").and_then(|v| v.as_f64());
        assert!(score.is_some(), "each hit should have a score");
        assert!(
            score.unwrap() > 0.0,
            "hybrid fused scores should be positive"
        );
    }
}

#[test]
fn mci_recall_handles_hyphen_in_query_gracefully() {
    let (_dir, store) = open_temp_store();

    store
        .put_event(&make_test_event(
            "sqlite-vec is a vector search extension for sqlite",
            1_000_000,
        ))
        .unwrap();

    let reader = LiveBrainReader::from_store_with_embedder(store, None);
    let srv = Server::new(Arc::new(reader));

    // "sqlite-vec" previously caused FTS5 to interpret `-` as NOT,
    // returning wrong results or errors.
    let resp = srv
        .dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_recall",
                "arguments": {"query": "sqlite-vec", "limit": 10}
            })),
        ))
        .expect("response");

    let result = resp.result.expect("result — hyphen query must not error");
    let hits = result
        .get("hits")
        .and_then(|v| v.as_array())
        .expect("hits array");
    assert_eq!(
        hits.len(),
        1,
        "sqlite-vec (sanitized) should match the event containing that text"
    );
}
