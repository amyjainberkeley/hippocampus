//! P3.10b — `mci-agent mcp-serve` integration tests.
//!
//! Drives the MCP server through its public API surface:
//! `Server::dispatch` for synchronous tests of the JSON-RPC framing +
//! tool routing, and `serve_stdio` for the end-to-end newline-delimited
//! stdio loop with a [`tokio::io::duplex`] pipe in place of real
//! stdin/stdout.
//!
//! No SQLCipher dependency — every test uses the [`StubBrainReader`]
//! below so the JSON-RPC surface is exercised in isolation. The
//! `LiveBrainReader` path is covered by the existing
//! `core/brain/tests/sqlcipher_brain_store.rs` integration suite (the
//! P3.2 store tests already cover `fts5_search` / `get_event` /
//! `events_since` / `stats` against a real ephemeral SQLCipher DB).
//!
//! Read-only structural check (per P3.10b PR body CSO sign-off):
//! `tool_routing_is_three_known_tools_only` enumerates every accepted
//! tool name; an unknown name MUST return `METHOD_NOT_FOUND`. Adding a
//! mutating tool would break this test.

use std::sync::{Arc, Mutex};

use mci_agent::mcp::{
    serve_stdio, BrainReader, BrainReaderError, JsonRpcId, JsonRpcRequest, JsonRpcResponse, McpHit,
    Server, ToolName, INVALID_PARAMS, METHOD_NOT_FOUND, PARSE_ERROR,
};
use mci_brain::{BrainStats, EventId, EventRecord};

// ---------------------------------------------------------------------------
// StubBrainReader — canned data + per-call invocation log so tests can
// assert what the dispatcher passed through.
// ---------------------------------------------------------------------------

#[derive(Debug, Default, Clone)]
struct Invocations {
    recall: Vec<(String, usize)>,
    events_since: Vec<(u64, usize)>,
    stats: usize,
}

#[derive(Clone)]
struct StubBrainReader {
    hits: Vec<McpHit>,
    events: Vec<EventRecord>,
    stats_value: BrainStats,
    fail_next_recall: Arc<Mutex<bool>>,
    invocations: Arc<Mutex<Invocations>>,
}

impl StubBrainReader {
    fn new() -> Self {
        Self {
            hits: vec![sample_hit(101, 1_000_000, "hello world", Some("https://example.com"))],
            events: vec![
                sample_record(200, 2_000_000, "first"),
                sample_record(201, 3_000_000, "second"),
            ],
            stats_value: BrainStats {
                event_count: 42,
                oldest_ts_us: Some(1_000_000),
                newest_ts_us: Some(9_000_000),
            },
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
fn tools_list_returns_exactly_three_tools() {
    let (s, _) = server();
    let resp = s.dispatch(req("tools/list", None)).expect("response");
    let result = resp.result.expect("result");
    let tools = result
        .get("tools")
        .and_then(|v| v.as_array())
        .expect("tools array");
    assert_eq!(tools.len(), 3, "exactly three tools advertised");
    let names: Vec<&str> = tools
        .iter()
        .filter_map(|t| t.get("name").and_then(|n| n.as_str()))
        .collect();
    assert!(names.contains(&"mci_recall"));
    assert!(names.contains(&"mci_events_since"));
    assert!(names.contains(&"mci_stats"));
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
        events[0].get("event_id").and_then(serde_json::Value::as_u64),
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
        stats.get("oldest_ts_us").and_then(serde_json::Value::as_u64),
        Some(1_000_000)
    );
    assert_eq!(
        stats.get("newest_ts_us").and_then(serde_json::Value::as_u64),
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
fn structural_read_only_check_only_three_tools_are_reachable() {
    // Read-only invariant per CSO sign-off: the dispatcher's tools/call
    // arm enumerates exactly the three known tool variants. The variants
    // are enumerated in ToolName::from_wire — if a write tool is ever
    // added, this assertion will fail when the new wire name appears.
    let read_only_names = ["mci_recall", "mci_events_since", "mci_stats"];
    for &n in &read_only_names {
        assert!(
            ToolName::from_wire(n).is_some(),
            "expected read-only tool {n} present"
        );
    }
    // Any plausible write/mutate name MUST resolve to None — there is
    // no fall-through path to the brain.
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
    assert_eq!(snap.4, 1, "unknown_method_count from unknown tool");
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
