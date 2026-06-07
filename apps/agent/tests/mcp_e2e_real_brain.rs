//! End-to-end MCP integration tests against a **real** `SqlCipherBrainStore`.
//!
//! Unlike `mcp_server.rs` (which uses `StubBrainReader` for JSON-RPC framing
//! isolation), these tests exercise the full dispatch cycle: seeded events
//! written via `put_event` → `LiveBrainReader` → `Server::dispatch` →
//! JSON-RPC response with real FTS5 / hybrid retrieval results.
//!
//! Each test creates a hermetic `tempfile`-backed encrypted brain, seeds N
//! events, constructs a `LiveBrainReader`, wraps it in `Server`, and drives
//! `Server::dispatch` directly. No subprocess, no stdio, no network.
//!
//! # CSO sign-off notes
//!
//! (a) No new write paths — tests use existing `BrainStore::put_event`.
//! (b) Read-only handle via existing `LiveBrainReader::from_store_with_embedder`.
//! (c) Hermetic — every brain lives in a `tempfile::TempDir`, disposed on drop.
//! (d) Zero new third-party crates — `tempfile` + `serde_json` already on
//!     dev-deps.

use std::sync::Arc;

use mci_agent::mcp::{
    JsonRpcId, JsonRpcRequest, JsonRpcResponse, LiveBrainReader, Server, ServerCounters,
    INVALID_PARAMS, METHOD_NOT_FOUND,
};
use mci_brain::episode_segmenter::{EpisodeId, EpisodeWriter};
use mci_brain::extraction::tier2::KIND_PERSON_NAME;
use mci_brain::graph::{Entity, EntityIdentity, EntityMention, EpisodeEdge};
use mci_brain::stubs::FixedDimEmbedder;
use mci_brain::{BrainStore, Embedder, Event, EventId, IdentityId, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn open_temp_store() -> (tempfile::TempDir, Arc<SqlCipherBrainStore>) {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("test_e2e.sqlite");
    let key = DbKey::from_bytes([0xBB; 32]);
    let store = Arc::new(SqlCipherBrainStore::new(&db_path, &key).unwrap());
    (dir, store)
}

fn make_event(text: &str, ts_us: u64) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some("com.example.test".into()),
        window_title: Some("Test Window".into()),
        url: Some("https://example.com/page".into()),
        text: text.into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: None,
    }
}

fn make_event_custom(
    text: &str,
    ts_us: u64,
    app: Option<&str>,
    title: Option<&str>,
    url: Option<&str>,
) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: app.map(str::to_owned),
        window_title: title.map(str::to_owned),
        url: url.map(str::to_owned),
        text: text.into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: None,
    }
}

fn make_event_with_embedding(text: &str, ts_us: u64, embedder: &dyn Embedder) -> Event {
    let emb = embedder.embed_one(text).unwrap();
    Event {
        embedding: Some(emb),
        ..make_event(text, ts_us)
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

fn req_with_id(method: &str, params: Option<serde_json::Value>, id: i64) -> JsonRpcRequest {
    JsonRpcRequest {
        jsonrpc: "2.0".into(),
        method: method.into(),
        params,
        id: Some(JsonRpcId::Number(id)),
    }
}

fn server_fts_only(store: Arc<SqlCipherBrainStore>) -> Server {
    let reader = LiveBrainReader::from_store_with_embedder(store, None);
    Server::new(Arc::new(reader))
}

fn server_with_embedder(store: Arc<SqlCipherBrainStore>, embedder: Arc<dyn Embedder>) -> Server {
    let reader = LiveBrainReader::from_store_with_embedder(store, Some(embedder));
    Server::new(Arc::new(reader))
}

fn extract_result(resp: Option<JsonRpcResponse>) -> serde_json::Value {
    let resp = resp.expect("expected a response");
    assert!(resp.error.is_none(), "unexpected error: {:?}", resp.error);
    resp.result.expect("expected result field")
}

fn extract_error(resp: Option<JsonRpcResponse>) -> (i64, String) {
    let resp = resp.expect("expected a response");
    let err = resp.error.expect("expected error field");
    (err.code, err.message)
}

// ---------------------------------------------------------------------------
// tools/list — exactly 5 tools
// ---------------------------------------------------------------------------

#[test]
fn tools_list_returns_exactly_five_tools_real_brain() {
    let (_dir, store) = open_temp_store();
    let srv = server_fts_only(store);

    let result = extract_result(srv.dispatch(req("tools/list", None)));
    let tools = result
        .get("tools")
        .and_then(|v| v.as_array())
        .expect("tools array");
    assert_eq!(tools.len(), 5, "MCP server must advertise exactly 5 tools");

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

// ---------------------------------------------------------------------------
// mci_stats — matches actual row count
// ---------------------------------------------------------------------------

#[test]
fn stats_empty_brain_returns_zero_counts() {
    let (_dir, store) = open_temp_store();
    let srv = server_fts_only(store);

    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_stats",
            "arguments": {}
        })),
    )));
    let stats = result.get("stats").expect("stats");
    assert_eq!(stats.get("event_count").and_then(|v| v.as_u64()), Some(0));
    assert!(stats.get("oldest_ts_us").unwrap().is_null());
    assert!(stats.get("newest_ts_us").unwrap().is_null());
}

#[test]
fn stats_matches_actual_row_count_after_seeding() {
    let (_dir, store) = open_temp_store();
    for i in 0..7 {
        store
            .put_event(&make_event(
                &format!("event number {i}"),
                1_000_000 + i * 100_000,
            ))
            .unwrap();
    }
    let srv = server_fts_only(store);

    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_stats",
            "arguments": {}
        })),
    )));
    let stats = result.get("stats").expect("stats");
    assert_eq!(
        stats.get("event_count").and_then(|v| v.as_u64()),
        Some(7),
        "event_count must match exactly the number of put_event calls"
    );
    assert_eq!(
        stats.get("oldest_ts_us").and_then(|v| v.as_u64()),
        Some(1_000_000)
    );
    assert_eq!(
        stats.get("newest_ts_us").and_then(|v| v.as_u64()),
        Some(1_600_000)
    );
}

// ---------------------------------------------------------------------------
// mci_recall — FTS5 lexical path (no embedder)
// ---------------------------------------------------------------------------

#[test]
fn recall_fts5_finds_seeded_event_by_keyword() {
    let (_dir, store) = open_temp_store();
    store
        .put_event(&make_event(
            "Rust memory safety guarantees prevent data races",
            1_000_000,
        ))
        .unwrap();
    store
        .put_event(&make_event(
            "Python scripting for data analysis tasks",
            2_000_000,
        ))
        .unwrap();
    store
        .put_event(&make_event(
            "JavaScript frontend framework comparison",
            3_000_000,
        ))
        .unwrap();
    let srv = server_fts_only(store);

    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_recall",
            "arguments": {"query": "Rust memory", "limit": 10}
        })),
    )));
    let hits = result
        .get("hits")
        .and_then(|v| v.as_array())
        .expect("hits array");
    assert!(!hits.is_empty(), "FTS5 should find 'Rust memory'");
    let snippet = hits[0]
        .get("text_snippet")
        .and_then(|v| v.as_str())
        .unwrap();
    assert!(
        snippet.contains("Rust"),
        "top hit should contain 'Rust': {snippet}"
    );
}

#[test]
fn recall_fts5_returns_empty_for_unmatched_query() {
    let (_dir, store) = open_temp_store();
    store
        .put_event(&make_event("apple banana cherry", 1_000_000))
        .unwrap();
    let srv = server_fts_only(store);

    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_recall",
            "arguments": {"query": "quantum entanglement", "limit": 10}
        })),
    )));
    let hits = result
        .get("hits")
        .and_then(|v| v.as_array())
        .expect("hits array");
    assert!(hits.is_empty(), "no match expected for unrelated query");
}

#[test]
fn recall_respects_limit_parameter() {
    let (_dir, store) = open_temp_store();
    for i in 0..20 {
        store
            .put_event(&make_event(
                &format!("repeated keyword search term {i}"),
                1_000_000 + i * 100_000,
            ))
            .unwrap();
    }
    let srv = server_fts_only(store);

    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_recall",
            "arguments": {"query": "keyword search", "limit": 5}
        })),
    )));
    let hits = result
        .get("hits")
        .and_then(|v| v.as_array())
        .expect("hits array");
    assert!(
        hits.len() <= 5,
        "limit=5 must be respected, got {}",
        hits.len()
    );
}

#[test]
fn recall_default_limit_caps_at_ten() {
    let (_dir, store) = open_temp_store();
    for i in 0..15 {
        store
            .put_event(&make_event(
                &format!("term alpha bravo {i}"),
                1_000_000 + i * 100_000,
            ))
            .unwrap();
    }
    let srv = server_fts_only(store);

    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_recall",
            "arguments": {"query": "alpha bravo"}
        })),
    )));
    let hits = result
        .get("hits")
        .and_then(|v| v.as_array())
        .expect("hits array");
    assert!(hits.len() <= 10, "default limit is 10, got {}", hits.len());
}

// ---------------------------------------------------------------------------
// mci_recall — hyphen-query fix from #94
// ---------------------------------------------------------------------------

#[test]
fn recall_hyphen_query_works_end_to_end_with_real_fts5() {
    let (_dir, store) = open_temp_store();
    store
        .put_event(&make_event(
            "sqlite-vec is a vector search extension for sqlite databases",
            1_000_000,
        ))
        .unwrap();
    store
        .put_event(&make_event(
            "core-ml provides on-device machine learning inference",
            2_000_000,
        ))
        .unwrap();
    let srv = server_fts_only(store);

    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_recall",
            "arguments": {"query": "sqlite-vec", "limit": 10}
        })),
    )));
    let hits = result
        .get("hits")
        .and_then(|v| v.as_array())
        .expect("hits array");
    assert_eq!(
        hits.len(),
        1,
        "hyphen-sanitized 'sqlite-vec' should match exactly 1 event"
    );
    let snippet = hits[0]
        .get("text_snippet")
        .and_then(|v| v.as_str())
        .unwrap();
    assert!(
        snippet.contains("sqlite-vec"),
        "matched event should contain 'sqlite-vec': {snippet}"
    );
}

#[test]
fn recall_multiple_hyphens_in_query() {
    let (_dir, store) = open_temp_store();
    store
        .put_event(&make_event(
            "all-MiniLM-L6-v2 is a sentence transformer model",
            1_000_000,
        ))
        .unwrap();
    let srv = server_fts_only(store);

    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_recall",
            "arguments": {"query": "all-MiniLM-L6-v2", "limit": 10}
        })),
    )));
    let hits = result
        .get("hits")
        .and_then(|v| v.as_array())
        .expect("hits array");
    assert!(
        !hits.is_empty(),
        "multi-hyphen query should not error or return empty"
    );
}

// ---------------------------------------------------------------------------
// mci_recall — hybrid path (with embedder)
// ---------------------------------------------------------------------------

#[test]
fn recall_hybrid_returns_hits_with_positive_scores() {
    let (_dir, store) = open_temp_store();
    let embedder = Arc::new(FixedDimEmbedder::default());

    store
        .put_event(&make_event_with_embedding(
            "database optimization techniques for production workloads",
            1_000_000,
            embedder.as_ref(),
        ))
        .unwrap();
    store
        .put_event(&make_event_with_embedding(
            "query tuning and index strategies in sqlite",
            2_000_000,
            embedder.as_ref(),
        ))
        .unwrap();
    store
        .put_event(&make_event_with_embedding(
            "cooking recipes for Italian pasta dishes",
            3_000_000,
            embedder.as_ref(),
        ))
        .unwrap();

    let srv = server_with_embedder(store, embedder);

    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_recall",
            "arguments": {"query": "database optimization", "limit": 10}
        })),
    )));
    let hits = result
        .get("hits")
        .and_then(|v| v.as_array())
        .expect("hits array");
    assert!(!hits.is_empty(), "hybrid retriever should return hits");
    for hit in hits {
        let score = hit.get("score").and_then(|v| v.as_f64()).unwrap();
        assert!(score > 0.0, "fused scores must be positive: {score}");
    }
}

// ---------------------------------------------------------------------------
// mci_recall — response shape
// ---------------------------------------------------------------------------

#[test]
fn recall_response_carries_content_array_and_hits() {
    let (_dir, store) = open_temp_store();
    store
        .put_event(&make_event("recall shape test content", 5_000_000))
        .unwrap();
    let srv = server_fts_only(store);

    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_recall",
            "arguments": {"query": "recall shape", "limit": 5}
        })),
    )));

    let content = result
        .get("content")
        .and_then(|v| v.as_array())
        .expect("content array");
    assert_eq!(content.len(), 1);
    assert_eq!(
        content[0].get("type").and_then(|v| v.as_str()),
        Some("text")
    );
    assert!(result.get("hits").is_some());
    assert_eq!(result.get("isError").and_then(|v| v.as_bool()), Some(false));
}

#[test]
fn recall_hit_carries_all_event_fields() {
    let (_dir, store) = open_temp_store();
    store
        .put_event(&make_event_custom(
            "field presence check text",
            7_000_000,
            Some("com.apple.Safari"),
            Some("GitHub - Pull Request"),
            Some("https://github.com/amyjainberkeley/hippocampus/pull/95"),
        ))
        .unwrap();
    let srv = server_fts_only(store);

    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_recall",
            "arguments": {"query": "field presence", "limit": 1}
        })),
    )));
    let hits = result.get("hits").and_then(|v| v.as_array()).expect("hits");
    assert_eq!(hits.len(), 1);
    let hit = &hits[0];
    assert!(hit.get("event_id").and_then(|v| v.as_u64()).is_some());
    assert_eq!(hit.get("ts_us").and_then(|v| v.as_u64()), Some(7_000_000));
    assert_eq!(
        hit.get("app_bundle_id").and_then(|v| v.as_str()),
        Some("com.apple.Safari")
    );
    assert_eq!(
        hit.get("window_title").and_then(|v| v.as_str()),
        Some("GitHub - Pull Request")
    );
    assert_eq!(
        hit.get("url").and_then(|v| v.as_str()),
        Some("https://github.com/amyjainberkeley/hippocampus/pull/95")
    );
    assert!(hit.get("score").and_then(|v| v.as_f64()).is_some());
}

// ---------------------------------------------------------------------------
// mci_recall — error paths
// ---------------------------------------------------------------------------

#[test]
fn recall_empty_query_returns_invalid_params() {
    let (_dir, store) = open_temp_store();
    store.put_event(&make_event("noise", 1_000_000)).unwrap();
    let srv = server_fts_only(store);

    let (code, _msg) = extract_error(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_recall",
            "arguments": {"query": ""}
        })),
    )));
    assert_eq!(code, INVALID_PARAMS);
}

#[test]
fn recall_whitespace_only_query_returns_invalid_params() {
    let (_dir, store) = open_temp_store();
    let srv = server_fts_only(store);

    let (code, _msg) = extract_error(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_recall",
            "arguments": {"query": "   "}
        })),
    )));
    assert_eq!(code, INVALID_PARAMS);
}

#[test]
fn recall_missing_query_field_returns_invalid_params() {
    let (_dir, store) = open_temp_store();
    let srv = server_fts_only(store);

    let (code, _msg) = extract_error(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_recall",
            "arguments": {}
        })),
    )));
    assert_eq!(code, INVALID_PARAMS);
}

// ---------------------------------------------------------------------------
// mci_events_since — pagination cursor advances correctly
// ---------------------------------------------------------------------------

#[test]
fn events_since_returns_events_after_cursor() {
    let (_dir, store) = open_temp_store();
    let ts = [1_000_000_u64, 2_000_000, 3_000_000, 4_000_000, 5_000_000];
    for (i, &t) in ts.iter().enumerate() {
        store
            .put_event(&make_event(&format!("event at {t}"), t))
            .unwrap();
        let _ = i;
    }
    let srv = server_fts_only(store);

    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_events_since",
            "arguments": {"ts_us": 2_500_000_u64, "limit": 100}
        })),
    )));
    let events = result
        .get("events")
        .and_then(|v| v.as_array())
        .expect("events array");
    assert_eq!(events.len(), 3, "3 events after ts_us=2_500_000");
    let timestamps: Vec<u64> = events
        .iter()
        .filter_map(|e| e.get("ts_us").and_then(|v| v.as_u64()))
        .collect();
    assert_eq!(timestamps, vec![3_000_000, 4_000_000, 5_000_000]);
}

#[test]
fn events_since_pagination_cursor_advances() {
    let (_dir, store) = open_temp_store();
    for i in 0..10 {
        store
            .put_event(&make_event(
                &format!("paginated event {i}"),
                1_000_000 + i * 100_000,
            ))
            .unwrap();
    }
    let srv = server_fts_only(store);

    // Page 1: first 3 events after ts=0
    let result1 = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_events_since",
            "arguments": {"ts_us": 0_u64, "limit": 3}
        })),
    )));
    let page1 = result1
        .get("events")
        .and_then(|v| v.as_array())
        .expect("page1");
    assert_eq!(page1.len(), 3);

    let last_ts_page1 = page1[2].get("ts_us").and_then(|v| v.as_u64()).unwrap();

    // Page 2: next 3 events using last_ts from page 1 as cursor
    let result2 = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_events_since",
            "arguments": {"ts_us": last_ts_page1, "limit": 3}
        })),
    )));
    let page2 = result2
        .get("events")
        .and_then(|v| v.as_array())
        .expect("page2");
    assert_eq!(page2.len(), 3);

    let first_ts_page2 = page2[0].get("ts_us").and_then(|v| v.as_u64()).unwrap();
    assert!(
        first_ts_page2 > last_ts_page1,
        "cursor must advance: page2 first ts ({first_ts_page2}) > page1 last ts ({last_ts_page1})"
    );

    // Page 3: next 3
    let last_ts_page2 = page2[2].get("ts_us").and_then(|v| v.as_u64()).unwrap();
    let result3 = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_events_since",
            "arguments": {"ts_us": last_ts_page2, "limit": 3}
        })),
    )));
    let page3 = result3
        .get("events")
        .and_then(|v| v.as_array())
        .expect("page3");
    assert_eq!(page3.len(), 3);

    // Page 4: only 1 remaining
    let last_ts_page3 = page3[2].get("ts_us").and_then(|v| v.as_u64()).unwrap();
    let result4 = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_events_since",
            "arguments": {"ts_us": last_ts_page3, "limit": 3}
        })),
    )));
    let page4 = result4
        .get("events")
        .and_then(|v| v.as_array())
        .expect("page4");
    assert_eq!(page4.len(), 1, "only 1 event remaining after 9 consumed");

    // Page 5: exhausted
    let last_ts_page4 = page4[0].get("ts_us").and_then(|v| v.as_u64()).unwrap();
    let result5 = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_events_since",
            "arguments": {"ts_us": last_ts_page4, "limit": 3}
        })),
    )));
    let page5 = result5
        .get("events")
        .and_then(|v| v.as_array())
        .expect("page5");
    assert!(
        page5.is_empty(),
        "cursor past all events should return empty"
    );
}

#[test]
fn events_since_returns_ascending_order() {
    let (_dir, store) = open_temp_store();
    // Insert out of order to verify SQL sorts correctly
    for &ts in &[5_000_000_u64, 1_000_000, 3_000_000, 2_000_000, 4_000_000] {
        store
            .put_event(&make_event(&format!("ts={ts}"), ts))
            .unwrap();
    }
    let srv = server_fts_only(store);

    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_events_since",
            "arguments": {"ts_us": 0_u64, "limit": 100}
        })),
    )));
    let events = result
        .get("events")
        .and_then(|v| v.as_array())
        .expect("events");
    let timestamps: Vec<u64> = events
        .iter()
        .filter_map(|e| e.get("ts_us").and_then(|v| v.as_u64()))
        .collect();
    assert_eq!(
        timestamps,
        vec![1_000_000, 2_000_000, 3_000_000, 4_000_000, 5_000_000],
        "events_since must return ascending ts_us order"
    );
}

#[test]
fn events_since_empty_brain_returns_empty() {
    let (_dir, store) = open_temp_store();
    let srv = server_fts_only(store);

    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_events_since",
            "arguments": {"ts_us": 0_u64, "limit": 100}
        })),
    )));
    let events = result
        .get("events")
        .and_then(|v| v.as_array())
        .expect("events");
    assert!(events.is_empty());
}

#[test]
fn events_since_response_carries_content_array() {
    let (_dir, store) = open_temp_store();
    store
        .put_event(&make_event("shape check", 1_000_000))
        .unwrap();
    let srv = server_fts_only(store);

    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_events_since",
            "arguments": {"ts_us": 0_u64, "limit": 10}
        })),
    )));
    let content = result
        .get("content")
        .and_then(|v| v.as_array())
        .expect("content array");
    assert_eq!(content.len(), 1);
    assert_eq!(
        content[0].get("type").and_then(|v| v.as_str()),
        Some("text")
    );
    assert_eq!(result.get("isError").and_then(|v| v.as_bool()), Some(false));
}

// ---------------------------------------------------------------------------
// mci_events_since — error paths
// ---------------------------------------------------------------------------

#[test]
fn events_since_missing_ts_us_returns_invalid_params() {
    let (_dir, store) = open_temp_store();
    let srv = server_fts_only(store);

    let (code, _msg) = extract_error(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_events_since",
            "arguments": {}
        })),
    )));
    assert_eq!(code, INVALID_PARAMS);
}

// ---------------------------------------------------------------------------
// JSON-RPC protocol correctness
// ---------------------------------------------------------------------------

#[test]
fn unknown_tool_returns_method_not_found_real_brain() {
    let (_dir, store) = open_temp_store();
    let srv = server_fts_only(store);

    let (code, msg) = extract_error(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_put_event",
            "arguments": {}
        })),
    )));
    assert_eq!(code, METHOD_NOT_FOUND);
    assert!(msg.contains("mci_put_event"), "error should name the tool");
}

#[test]
fn unknown_method_returns_method_not_found_real_brain() {
    let (_dir, store) = open_temp_store();
    let srv = server_fts_only(store);

    let (code, _msg) = extract_error(srv.dispatch(req("brain/write", None)));
    assert_eq!(code, METHOD_NOT_FOUND);
}

#[test]
fn notification_returns_no_response_real_brain() {
    let (_dir, store) = open_temp_store();
    let srv = server_fts_only(store);

    let n = JsonRpcRequest {
        jsonrpc: "2.0".into(),
        method: "notifications/initialized".into(),
        params: None,
        id: None,
    };
    assert!(
        srv.dispatch(n).is_none(),
        "notification must not produce a response"
    );
}

#[test]
fn response_ids_match_request_ids() {
    let (_dir, store) = open_temp_store();
    store
        .put_event(&make_event("id match test", 1_000_000))
        .unwrap();
    let srv = server_fts_only(store);

    for id in [1, 42, 999] {
        let resp = srv
            .dispatch(req_with_id(
                "tools/call",
                Some(serde_json::json!({
                    "name": "mci_stats",
                    "arguments": {}
                })),
                id,
            ))
            .expect("response");
        match &resp.id {
            JsonRpcId::Number(n) => assert_eq!(*n, id),
            other => panic!("expected Number({id}), got {other:?}"),
        }
    }
}

// ---------------------------------------------------------------------------
// Counters track across real dispatches
// ---------------------------------------------------------------------------

#[test]
fn counters_track_real_brain_dispatches() {
    let (_dir, store) = open_temp_store();
    store
        .put_event(&make_event("counter test content", 1_000_000))
        .unwrap();
    let counters = Arc::new(ServerCounters::default());
    let reader = LiveBrainReader::from_store_with_embedder(store, None);
    let srv = Server::new_with_counters(Arc::new(reader), Arc::clone(&counters));

    // 2x recall
    for q in ["counter", "test"] {
        let _ = srv.dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_recall",
                "arguments": {"query": q}
            })),
        ));
    }
    // 1x events_since
    let _ = srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_events_since",
            "arguments": {"ts_us": 0_u64}
        })),
    ));
    // 3x stats
    for _ in 0..3 {
        let _ = srv.dispatch(req(
            "tools/call",
            Some(serde_json::json!({
                "name": "mci_stats",
                "arguments": {}
            })),
        ));
    }
    // 1x unknown tool
    let _ = srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_delete_all",
            "arguments": {}
        })),
    ));

    let (recall, events, stats, _episodes, _events_by_app, _parse, unknown) =
        counters.snapshot();
    assert_eq!(recall, 2, "recall_count");
    assert_eq!(events, 1, "events_since_count");
    assert_eq!(stats, 3, "stats_count");
    assert_eq!(unknown, 1, "unknown_method_count");
}

// ---------------------------------------------------------------------------
// Cross-tool consistency: stats count matches events_since full scan
// ---------------------------------------------------------------------------

#[test]
fn stats_count_consistent_with_events_since_full_scan() {
    let (_dir, store) = open_temp_store();
    let n = 12;
    for i in 0..n {
        store
            .put_event(&make_event(
                &format!("consistency check {i}"),
                1_000_000 + i * 100_000,
            ))
            .unwrap();
    }
    let srv = server_fts_only(store);

    let stats_result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_stats",
            "arguments": {}
        })),
    )));
    let event_count = stats_result
        .get("stats")
        .and_then(|s| s.get("event_count"))
        .and_then(|v| v.as_u64())
        .unwrap();

    let events_result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_events_since",
            "arguments": {"ts_us": 0_u64, "limit": 1000}
        })),
    )));
    let events_len = events_result
        .get("events")
        .and_then(|v| v.as_array())
        .unwrap()
        .len() as u64;

    assert_eq!(
        event_count, events_len,
        "mci_stats.event_count must equal full mci_events_since scan length"
    );
}

// ---------------------------------------------------------------------------
// initialize — protocol handshake
// ---------------------------------------------------------------------------

#[test]
fn initialize_returns_capabilities_and_server_info_real_brain() {
    let (_dir, store) = open_temp_store();
    let srv = server_fts_only(store);

    let result = extract_result(srv.dispatch(req(
        "initialize",
        Some(serde_json::json!({"protocolVersion": "2024-11-05"})),
    )));
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
        Some("hippocampus")
    );
    assert!(
        result.get("instructions").and_then(|v| v.as_str()).is_some(),
        "initialize must include instructions for Claude Code"
    );
}

// ---------------------------------------------------------------------------
// Hermetic isolation: two brains in one test don't interfere
// ---------------------------------------------------------------------------

#[test]
fn two_brains_are_isolated() {
    let (_dir1, store1) = open_temp_store();
    let (_dir2, store2) = open_temp_store();

    store1
        .put_event(&make_event("brain one alpha", 1_000_000))
        .unwrap();
    store2
        .put_event(&make_event("brain two beta", 2_000_000))
        .unwrap();
    store2
        .put_event(&make_event("brain two gamma", 3_000_000))
        .unwrap();

    let srv1 = server_fts_only(store1);
    let srv2 = server_fts_only(store2);

    let stats1 = extract_result(srv1.dispatch(req(
        "tools/call",
        Some(serde_json::json!({"name": "mci_stats", "arguments": {}})),
    )));
    let stats2 = extract_result(srv2.dispatch(req(
        "tools/call",
        Some(serde_json::json!({"name": "mci_stats", "arguments": {}})),
    )));

    assert_eq!(
        stats1
            .get("stats")
            .and_then(|s| s.get("event_count"))
            .and_then(|v| v.as_u64()),
        Some(1)
    );
    assert_eq!(
        stats2
            .get("stats")
            .and_then(|s| s.get("event_count"))
            .and_then(|v| v.as_u64()),
        Some(2)
    );
}

// ---------------------------------------------------------------------------
// Phase-6-close recall-surface fusion — additive entities[] /
// linked_event_ids[] + graph stat counts surface through Server::dispatch.
// ---------------------------------------------------------------------------

fn graph_entity(kind: &str, name: &str) -> Entity {
    Entity {
        id: Entity::derive_id(kind, name),
        kind: kind.to_string(),
        canonical_name: name.to_string(),
        summary: None,
        summary_embedding: None,
        content_hash: Entity::derive_content_hash(kind, name),
        created_ts_us: 1,
        updated_ts_us: 1,
    }
}

fn graph_mention(entity: &Entity, event_id: EventId) -> EntityMention {
    EntityMention {
        id: EntityMention::derive_id(&entity.id, event_id, "ner", None),
        entity_id: entity.id.clone(),
        event_id,
        mention_text: None,
        confidence: 1.0,
        extractor_kind: "ner".to_string(),
        ts_us: 1,
    }
}

fn graph_shared_edge(a: EpisodeId, b: EpisodeId, identity: &IdentityId) -> EpisodeEdge {
    let (lo, hi) = if a.0 <= b.0 { (a, b) } else { (b, a) };
    EpisodeEdge {
        id: EpisodeEdge::derive_shared_identity_id(lo, hi, identity),
        src_episode_id: lo,
        dst_episode_id: hi,
        edge_kind: EpisodeEdge::KIND_SHARED_IDENTITY.to_string(),
        evidence_entity_ids: None,
        ts_us: 1,
    }
}

/// WIRING-PROOF (MCP output): a real cross-app graph seeded under the store,
/// recalled through the production `LiveBrainReader` → `Server::dispatch`,
/// returns the additive `entities[]` + `linked_event_ids[]` on the hit.
#[test]
fn recall_surfaces_entities_and_cross_app_linked_event_ids() {
    let (_dir, store) = open_temp_store();

    // ep1 = Safari (the pricing page the query finds), ep2 = Messages.
    let ep1 = store
        .create_episode(0, 100, Some("com.apple.Safari"))
        .unwrap();
    let ep2 = store
        .create_episode(0, 100, Some("com.apple.MobileSMS"))
        .unwrap();

    let alice = graph_entity(KIND_PERSON_NAME, "Alice");
    store.put_entity(&alice).unwrap();

    // E1 (Safari): the lexical hit for "pricing", mentioning Alice.
    let e1 = Event {
        episode_id: Some(ep1.0),
        ..make_event("quarterly pricing roadmap", 1_000_000)
    };
    let id1 = store.put_event(&e1).unwrap();
    store.put_entity_mention(&graph_mention(&alice, id1)).unwrap();

    // E2 (Messages): the cross-app counterpart, in ep2.
    let e2 = Event {
        episode_id: Some(ep2.0),
        ..make_event("note to alice about it", 1_100_000)
    };
    let id2 = store.put_event(&e2).unwrap();
    store.put_entity_mention(&graph_mention(&alice, id2)).unwrap();

    let identity = EntityIdentity::derive_identity_id("person", "alice");
    store
        .put_episode_edges(&[graph_shared_edge(ep1, ep2, &identity)])
        .unwrap();

    // FTS5-only recall — the enrichment runs on every hit regardless of the
    // hybrid/lexical path. "pricing" matches E1's text.
    let srv = server_fts_only(store);
    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_recall",
            "arguments": { "query": "pricing", "limit": 10 }
        })),
    )));

    let hits = result.get("hits").and_then(|v| v.as_array()).expect("hits");
    let hit = hits
        .iter()
        .find(|h| h.get("event_id").and_then(serde_json::Value::as_u64) == Some(id1.0))
        .expect("E1 must be a recall hit");

    // Additive schema present + populated.
    let entities: Vec<&str> = hit
        .get("entities")
        .and_then(|v| v.as_array())
        .expect("entities[] present")
        .iter()
        .filter_map(serde_json::Value::as_str)
        .collect();
    assert_eq!(entities, vec!["Alice"], "hit must surface its mentioned entity");

    let linked: Vec<u64> = hit
        .get("linked_event_ids")
        .and_then(|v| v.as_array())
        .expect("linked_event_ids[] present")
        .iter()
        .filter_map(serde_json::Value::as_u64)
        .collect();
    assert_eq!(
        linked,
        vec![id2.0],
        "cross-app dot-connect: E1's episode links to E2 via the shared_identity edge"
    );
}

/// The four new V2-P6 graph counts surface through the `mci_stats` tool.
#[test]
fn stats_surfaces_graph_counts_through_server() {
    let (_dir, store) = open_temp_store();
    let ep1 = store
        .create_episode(0, 100, Some("com.apple.Safari"))
        .unwrap();
    let ep2 = store
        .create_episode(0, 100, Some("com.apple.MobileSMS"))
        .unwrap();
    let alice = graph_entity(KIND_PERSON_NAME, "Alice");
    store.put_entity(&alice).unwrap();
    let e1 = Event {
        episode_id: Some(ep1.0),
        ..make_event("pricing", 1_000_000)
    };
    let id1 = store.put_event(&e1).unwrap();
    let e2 = Event {
        episode_id: Some(ep2.0),
        ..make_event("alice", 1_100_000)
    };
    store.put_event(&e2).unwrap();
    store.put_entity_mention(&graph_mention(&alice, id1)).unwrap();
    let identity = EntityIdentity::derive_identity_id("person", "alice");
    store
        .put_entity_identity(&EntityIdentity {
            id: EntityIdentity::derive_id(&identity, &alice.id),
            entity_id: alice.id.clone(),
            identity_id: identity.clone(),
            identity_kind: "person".into(),
            identity_canonical_name: "Alice".into(),
            rule: "anchor".into(),
            confidence: 1.0,
            ts_us: 1,
        })
        .unwrap();
    store
        .put_episode_edges(&[graph_shared_edge(ep1, ep2, &identity)])
        .unwrap();

    let srv = server_fts_only(store);
    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({"name": "mci_stats", "arguments": {}})),
    )));
    let stats = result.get("stats").expect("stats");
    assert_eq!(stats.get("entity_count").and_then(|v| v.as_u64()), Some(1));
    assert_eq!(
        stats.get("entity_mention_count").and_then(|v| v.as_u64()),
        Some(1)
    );
    assert_eq!(
        stats.get("entity_identity_count").and_then(|v| v.as_u64()),
        Some(1)
    );
    assert_eq!(
        stats.get("episode_edge_count").and_then(|v| v.as_u64()),
        Some(1)
    );
}

/// PRODUCTION-PATH WIRING PROOF — the `w_entity` arm fires through the
/// `FtsSanitizingStore` decorator the live hybrid recall path wraps the store
/// in. This is the construction-graph proof the bounce of PR #307 exists for.
///
/// The arm, its store reads, and the `recall_fusion.rs` integration tests all
/// shipped at the inert commit — but `recall_fusion.rs` drives
/// `HybridRetriever` over the **concrete** `SqlCipherBrainStore`, so it never
/// exercised the production decorator. `LiveBrainReader::recall_hybrid` wraps
/// the store in `FtsSanitizingStore` before handing it to the retriever; until
/// that wrapper delegated the query-side entity reads
/// (`mention_match_for_events` / `find_entity_by_alias` / `identity_of_entity` /
/// `identity_members`) to the inner store, those calls hit the `BrainStore`
/// trait defaults (`Ok(empty)` / `Err`, both swallowed) and the entity arm was
/// silently `0` for every candidate in production — the exact inertness this
/// test catches.
///
/// Seed: two events tying on lexical + semantic signal (identical text +
/// identical `FixedDimEmbedder` embedding). `e_alice` is OLDER but carries an
/// NER mention of `Alice` and sits in a Safari episode cross-app-linked to a
/// Messages episode; `e_plain` is NEWER and mentions nothing — so absent the
/// entity arm `e_plain` wins on recency. A query naming `Alice` must rank
/// `e_alice` above `e_plain` (arm fired through the wrapper) and surface the
/// dot-connect (`entities == [Alice]`, `linked_event_ids` populated).
#[test]
fn w_entity_arm_fires_through_fts_sanitizing_store_in_production_recall() {
    use std::time::{SystemTime, UNIX_EPOCH};
    const HOUR_US: u64 = 3_600_000_000;

    let (_dir, store) = open_temp_store();
    let embedder = Arc::new(FixedDimEmbedder::default());

    // Anchor event timestamps near the real wall clock so the recency arm —
    // which uses `SystemTime::now()` inside `recall_hybrid`, not injectable —
    // is meaningful: `e_plain` is the newest, the recency winner the entity
    // arm must overcome.
    let now_us = u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_micros(),
    )
    .unwrap();

    // ep1 = Safari (holds the entity hit), ep2 = Messages (cross-app link).
    let ep1 = store
        .create_episode(0, 100, Some("com.apple.Safari"))
        .unwrap();
    let ep2 = store
        .create_episode(0, 100, Some("com.apple.MobileSMS"))
        .unwrap();

    let alice = graph_entity(KIND_PERSON_NAME, "Alice");
    store.put_entity(&alice).unwrap();

    // e_alice: older, in ep1, mentions Alice via NER. The literal text does
    // NOT contain "Alice" (a resolved-mention scenario) — so the entity arm,
    // not lexical overlap, is what can lift it.
    let e_alice = Event {
        episode_id: Some(ep1.0),
        ..make_event_with_embedding(
            "pricing discussion notes",
            now_us - HOUR_US - 60_000_000,
            embedder.as_ref(),
        )
    };
    let id_alice = store.put_event(&e_alice).unwrap();
    store
        .put_entity_mention(&graph_mention(&alice, id_alice))
        .unwrap();

    // e_plain: newest, identical text + embedding, no mention, no episode —
    // wins on recency absent the entity arm.
    let e_plain = make_event_with_embedding(
        "pricing discussion notes",
        now_us - 60_000_000,
        embedder.as_ref(),
    );
    let id_plain = store.put_event(&e_plain).unwrap();

    // e_linked: cross-app counterpart in ep2, reachable from e_alice's episode
    // via the shared_identity edge.
    let e_linked = Event {
        episode_id: Some(ep2.0),
        ..make_event_with_embedding(
            "note to alice about it",
            now_us - 2 * HOUR_US,
            embedder.as_ref(),
        )
    };
    let id_linked = store.put_event(&e_linked).unwrap();

    let identity = EntityIdentity::derive_identity_id("person", "alice");
    store
        .put_episode_edges(&[graph_shared_edge(ep1, ep2, &identity)])
        .unwrap();

    // Drive the PRODUCTION hybrid path: `server_with_embedder` builds a
    // `LiveBrainReader` whose `recall_hybrid` wraps the store in
    // `FtsSanitizingStore`.
    let srv = server_with_embedder(store, embedder);
    let result = extract_result(srv.dispatch(req(
        "tools/call",
        Some(serde_json::json!({
            "name": "mci_recall",
            "arguments": { "query": "Alice pricing discussion", "limit": 10 }
        })),
    )));

    let hits = result
        .get("hits")
        .and_then(|v| v.as_array())
        .expect("hits array");
    let pos = |id: u64| {
        hits.iter()
            .position(|h| h.get("event_id").and_then(serde_json::Value::as_u64) == Some(id))
    };
    let pos_alice = pos(id_alice.0).expect("e_alice must be a recall hit");
    let pos_plain = pos(id_plain.0).expect("e_plain must be a recall hit");

    // THE WIRING PROOF: the entity-naming query lifts the older Alice-
    // mentioning event above the newer plain recency winner. Fails when the
    // w_entity arm is inert (FtsSanitizingStore not delegating the entity
    // reads) — both events then tie on lex+sem and e_plain wins on recency.
    assert!(
        pos_alice < pos_plain,
        "w_entity arm must rank the Alice-mentioning event (pos {pos_alice}) above the \
         recency winner (pos {pos_plain}); the arm is inert through FtsSanitizingStore. hits={hits:?}"
    );

    // Dot-connect surface on the entity hit.
    let alice_hit = &hits[pos_alice];
    let entities: Vec<&str> = alice_hit
        .get("entities")
        .and_then(|v| v.as_array())
        .expect("entities[] present")
        .iter()
        .filter_map(serde_json::Value::as_str)
        .collect();
    assert_eq!(
        entities,
        vec!["Alice"],
        "entity hit must surface its mentioned entity"
    );

    let linked: Vec<u64> = alice_hit
        .get("linked_event_ids")
        .and_then(|v| v.as_array())
        .expect("linked_event_ids[] present")
        .iter()
        .filter_map(serde_json::Value::as_u64)
        .collect();
    assert!(
        linked.contains(&id_linked.0),
        "cross-app dot-connect: e_alice's episode must link to e_linked via the \
         shared_identity edge; got {linked:?}"
    );
}
