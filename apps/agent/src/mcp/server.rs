//! MCP server core — request dispatch + stdio loop.
//!
//! The [`Server`] holds an `Arc<dyn BrainReader>` + content-free counters,
//! and exposes [`Server::dispatch`] (one frame in, one frame out) for
//! deterministic, transport-free testing. [`serve_stdio`] wraps it in the
//! production newline-delimited stdio loop.
//!
//! # Read-only invariant (structural)
//!
//! [`Server::dispatch`] reaches the `BrainReader` only via five named
//! arms — `Recall` / `EventsSince` / `Stats` / `Episodes` /
//! `EventsByApp`. There is **no fall-through** branch that touches the
//! brain; an unknown tool name returns `METHOD_NOT_FOUND` synchronously.
//! The `BrainReader` trait itself has no mutating methods (per
//! `brain_reader.rs`).

use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};

use serde::Deserialize;
use tokio::io::{AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader};

use crate::mcp::brain_reader::{BrainReader, BrainReaderError};
use crate::mcp::jsonrpc::{
    JsonRpcId, JsonRpcRequest, JsonRpcResponse, INVALID_PARAMS, INVALID_REQUEST, METHOD_NOT_FOUND,
    PARSE_ERROR, SERVER_ERROR_GENERIC,
};
use crate::mcp::tools::{tool_definitions, ToolName};

/// Default `limit` for `mci_episodes` when the client omits it.
const DEFAULT_EPISODES_LIMIT: usize = 20;
/// Hard cap for `mci_episodes`'s `limit` parameter.
const MAX_EPISODES_LIMIT: usize = 100;
/// Default `limit` for `mci_events_by_app` when the client omits it.
const DEFAULT_EVENTS_BY_APP_LIMIT: usize = 50;
/// Hard cap for `mci_events_by_app`'s `limit` parameter.
const MAX_EVENTS_BY_APP_LIMIT: usize = 500;

/// MCP protocol version this server advertises in `initialize`.
///
/// The MCP spec uses calendar-versioned protocol revisions; Claude Code
/// 2026-Q1 negotiates `2024-11-05`. If a client passes a different
/// version we still respond with this one — the negotiation is best-effort
/// per spec, the client can decide whether to disconnect.
const MCP_PROTOCOL_VERSION: &str = "2024-11-05";

/// Default `limit` for `mci_recall` when the client omits it.
const DEFAULT_RECALL_LIMIT: usize = 10;
/// Default `limit` for `mci_events_since` when the client omits it.
const DEFAULT_EVENTS_SINCE_LIMIT: usize = 100;
/// Hard cap for `mci_recall`'s `limit` parameter (matches the
/// `inputSchema` advertised in `tools/list`).
const MAX_RECALL_LIMIT: usize = 100;
/// Hard cap for `mci_events_since`'s `limit` parameter.
const MAX_EVENTS_SINCE_LIMIT: usize = 1000;

/// Content-free per-tool request counters. Public so the supervisor
/// (eventually) can plumb them into the `HelperHealth` wire surface.
///
/// `tracing` is deliberately NOT used at the dispatch site — the macro
/// surface accepts arbitrary key=value pairs, which is exactly the
/// "user-content-could-leak" surface ADR-0012 §6 forbids on the MCP
/// boundary.
#[derive(Debug, Default)]
pub struct ServerCounters {
    /// `mci_recall` invocations (including invalid-param rejections).
    pub recall_count: AtomicU64,
    /// `mci_events_since` invocations.
    pub events_since_count: AtomicU64,
    /// `mci_stats` invocations.
    pub stats_count: AtomicU64,
    /// `mci_episodes` invocations.
    pub episodes_count: AtomicU64,
    /// `mci_events_by_app` invocations.
    pub events_by_app_count: AtomicU64,
    /// Frames that did not parse as JSON-RPC 2.0.
    pub parse_error_count: AtomicU64,
    /// Frames that named an unknown method or unknown tool.
    pub unknown_method_count: AtomicU64,
}

impl ServerCounters {
    /// Snapshot the counters atomically-as-of-now.
    #[must_use]
    pub fn snapshot(&self) -> (u64, u64, u64, u64, u64, u64, u64) {
        (
            self.recall_count.load(Ordering::SeqCst),
            self.events_since_count.load(Ordering::SeqCst),
            self.stats_count.load(Ordering::SeqCst),
            self.episodes_count.load(Ordering::SeqCst),
            self.events_by_app_count.load(Ordering::SeqCst),
            self.parse_error_count.load(Ordering::SeqCst),
            self.unknown_method_count.load(Ordering::SeqCst),
        )
    }
}

/// The MCP server — holds the read-only brain handle + counters.
///
/// `Arc<dyn BrainReader>` so tests can substitute `StubBrainReader` for
/// `LiveBrainReader` without changing the dispatcher.
pub struct Server {
    reader: Arc<dyn BrainReader>,
    counters: Arc<ServerCounters>,
}

impl Server {
    /// Construct with a brain reader. Counters start at zero.
    #[must_use]
    pub fn new(reader: Arc<dyn BrainReader>) -> Self {
        Self {
            reader,
            counters: Arc::new(ServerCounters::default()),
        }
    }

    /// Construct with explicit counters (useful for tests that want to
    /// observe the increment behavior).
    #[must_use]
    pub fn new_with_counters(reader: Arc<dyn BrainReader>, counters: Arc<ServerCounters>) -> Self {
        Self { reader, counters }
    }

    /// Borrow the counters (for tests + the supervisor's wire frame).
    #[must_use]
    pub fn counters(&self) -> Arc<ServerCounters> {
        Arc::clone(&self.counters)
    }

    /// Dispatch one already-parsed JSON-RPC request.
    ///
    /// Returns `Some(JsonRpcResponse)` for requests (must be written to
    /// stdout) and `None` for notifications (per JSON-RPC 2.0 §4.1 — no
    /// response is allowed).
    ///
    /// **This is the structural read-only point.** Every branch that
    /// reaches `self.reader` is named here; an unknown method or unknown
    /// tool returns `METHOD_NOT_FOUND` without ever touching the brain.
    #[must_use]
    pub fn dispatch(&self, req: JsonRpcRequest) -> Option<JsonRpcResponse> {
        // INVALID_REQUEST guard — `jsonrpc` MUST be the string "2.0".
        if req.jsonrpc != "2.0" {
            // Notifications still get no response; INVALID_REQUEST only
            // makes sense for a request that carried an id.
            let id = req.id.clone().unwrap_or(JsonRpcId::Null);
            return Some(JsonRpcResponse::err(
                id,
                INVALID_REQUEST,
                "jsonrpc field must be \"2.0\"",
            ));
        }

        // Notifications (`id` absent) — silent per spec.
        req.id.as_ref()?;

        let id = req.id.clone().unwrap_or(JsonRpcId::Null);

        match req.method.as_str() {
            "initialize" => Some(Self::handle_initialize(id)),
            "tools/list" => Some(JsonRpcResponse::ok(
                id,
                serde_json::json!({ "tools": tool_definitions() }),
            )),
            "tools/call" => Some(self.handle_tools_call(id, req.params)),
            "ping" => Some(JsonRpcResponse::ok(id, serde_json::json!({}))),
            _ => {
                self.counters
                    .unknown_method_count
                    .fetch_add(1, Ordering::SeqCst);
                Some(JsonRpcResponse::err(
                    id,
                    METHOD_NOT_FOUND,
                    format!("unknown method: {}", req.method),
                ))
            }
        }
    }

    fn handle_initialize(id: JsonRpcId) -> JsonRpcResponse {
        JsonRpcResponse::ok(
            id,
            serde_json::json!({
                "protocolVersion": MCP_PROTOCOL_VERSION,
                "capabilities": {
                    "tools": {},
                },
                "serverInfo": {
                    "name": "hippocampus",
                    "version": env!("CARGO_PKG_VERSION"),
                },
                "instructions": "Hippocampus is your screen memory. It continuously captures \
                    what you see on your Mac and stores it in a private, encrypted, local-only \
                    brain. You can search it with mci_recall, browse recent activity with \
                    mci_events_since, check capture status with mci_stats, see work sessions \
                    with mci_episodes, or filter by app with mci_events_by_app. All data stays \
                    on this Mac — nothing is sent to any server.",
            }),
        )
    }

    fn handle_tools_call(
        &self,
        id: JsonRpcId,
        params: Option<serde_json::Value>,
    ) -> JsonRpcResponse {
        // tools/call params shape: { "name": "...", "arguments": {...} }
        let Some(params) = params else {
            return JsonRpcResponse::err(
                id,
                INVALID_PARAMS,
                "tools/call requires params {name, arguments}",
            );
        };
        let Some(name) = params
            .get("name")
            .and_then(|v| v.as_str())
            .map(str::to_owned)
        else {
            return JsonRpcResponse::err(
                id,
                INVALID_PARAMS,
                "tools/call params.name must be a string",
            );
        };
        let args = params
            .get("arguments")
            .cloned()
            .unwrap_or_else(|| serde_json::json!({}));

        let Some(tool) = ToolName::from_wire(&name) else {
            self.counters
                .unknown_method_count
                .fetch_add(1, Ordering::SeqCst);
            return JsonRpcResponse::err(id, METHOD_NOT_FOUND, format!("unknown tool: {name}"));
        };

        // STRUCTURAL READ-ONLY POINT — five named branches, no fall-through.
        match tool {
            ToolName::Recall => {
                self.counters.recall_count.fetch_add(1, Ordering::SeqCst);
                self.handle_recall(id, args)
            }
            ToolName::EventsSince => {
                self.counters
                    .events_since_count
                    .fetch_add(1, Ordering::SeqCst);
                self.handle_events_since(id, args)
            }
            ToolName::Stats => {
                self.counters.stats_count.fetch_add(1, Ordering::SeqCst);
                self.handle_stats(id)
            }
            ToolName::Episodes => {
                self.counters.episodes_count.fetch_add(1, Ordering::SeqCst);
                self.handle_episodes(id, args)
            }
            ToolName::EventsByApp => {
                self.counters
                    .events_by_app_count
                    .fetch_add(1, Ordering::SeqCst);
                self.handle_events_by_app(id, args)
            }
        }
    }

    fn handle_recall(&self, id: JsonRpcId, args: serde_json::Value) -> JsonRpcResponse {
        #[derive(Deserialize)]
        struct RecallArgs {
            query: String,
            #[serde(default)]
            limit: Option<usize>,
        }
        let parsed: RecallArgs = match serde_json::from_value::<RecallArgs>(args) {
            Ok(v) => v,
            Err(e) => {
                return JsonRpcResponse::err(id, INVALID_PARAMS, format!("mci_recall args: {e}"))
            }
        };
        if parsed.query.trim().is_empty() {
            return JsonRpcResponse::err(id, INVALID_PARAMS, "mci_recall: query must be non-empty");
        }
        let limit = parsed
            .limit
            .unwrap_or(DEFAULT_RECALL_LIMIT)
            .clamp(1, MAX_RECALL_LIMIT);

        match self.reader.recall(&parsed.query, limit) {
            Ok(hits) => {
                let hits_json: Vec<serde_json::Value> = hits
                    .iter()
                    .map(|h| {
                        serde_json::json!({
                            "event_id": h.record.event_id.0,
                            "ts_us": h.record.ts_us,
                            "app_bundle_id": h.record.app_bundle_id,
                            "window_title": h.record.window_title,
                            "url": h.record.url,
                            "text_snippet": h.record.text_snippet,
                            "score": h.score,
                            "entities": h.entities,
                            "linked_event_ids": h.linked_event_ids,
                        })
                    })
                    .collect();
                JsonRpcResponse::ok(
                    id,
                    serde_json::json!({
                        "content": [
                            {
                                "type": "text",
                                "text": serde_json::to_string(&hits_json)
                                    .unwrap_or_else(|_| "[]".to_owned()),
                            }
                        ],
                        "hits": hits_json,
                        "isError": false,
                    }),
                )
            }
            Err(e) => brain_err_to_response(id, &e),
        }
    }

    fn handle_events_since(&self, id: JsonRpcId, args: serde_json::Value) -> JsonRpcResponse {
        #[derive(Deserialize)]
        struct EventsSinceArgs {
            ts_us: u64,
            #[serde(default)]
            limit: Option<usize>,
        }
        let parsed: EventsSinceArgs = match serde_json::from_value::<EventsSinceArgs>(args) {
            Ok(v) => v,
            Err(e) => {
                return JsonRpcResponse::err(
                    id,
                    INVALID_PARAMS,
                    format!("mci_events_since args: {e}"),
                )
            }
        };
        let limit = parsed
            .limit
            .unwrap_or(DEFAULT_EVENTS_SINCE_LIMIT)
            .clamp(1, MAX_EVENTS_SINCE_LIMIT);

        match self.reader.events_since(parsed.ts_us, limit) {
            Ok(rows) => {
                let rows_json: Vec<serde_json::Value> = rows
                    .iter()
                    .map(|r| {
                        serde_json::json!({
                            "event_id": r.event_id.0,
                            "ts_us": r.ts_us,
                            "app_bundle_id": r.app_bundle_id,
                            "window_title": r.window_title,
                            "url": r.url,
                            "text_snippet": r.text_snippet,
                        })
                    })
                    .collect();
                JsonRpcResponse::ok(
                    id,
                    serde_json::json!({
                        "content": [
                            {
                                "type": "text",
                                "text": serde_json::to_string(&rows_json)
                                    .unwrap_or_else(|_| "[]".to_owned()),
                            }
                        ],
                        "events": rows_json,
                        "isError": false,
                    }),
                )
            }
            Err(e) => brain_err_to_response(id, &e),
        }
    }

    fn handle_stats(&self, id: JsonRpcId) -> JsonRpcResponse {
        match self.reader.stats() {
            Ok(s) => {
                let payload = serde_json::json!({
                    "event_count": s.event_count,
                    "oldest_ts_us": s.oldest_ts_us,
                    "newest_ts_us": s.newest_ts_us,
                    "entity_count": s.entity_count,
                    "entity_mention_count": s.entity_mention_count,
                    "entity_identity_count": s.entity_identity_count,
                    "episode_edge_count": s.episode_edge_count,
                });
                JsonRpcResponse::ok(
                    id,
                    serde_json::json!({
                        "content": [
                            {
                                "type": "text",
                                "text": serde_json::to_string(&payload)
                                    .unwrap_or_else(|_| "{}".to_owned()),
                            }
                        ],
                        "stats": payload,
                        "isError": false,
                    }),
                )
            }
            Err(e) => brain_err_to_response(id, &e),
        }
    }

    fn handle_episodes(&self, id: JsonRpcId, args: serde_json::Value) -> JsonRpcResponse {
        #[derive(Deserialize)]
        struct EpisodesArgs {
            #[serde(default)]
            limit: Option<usize>,
        }
        let parsed: EpisodesArgs = match serde_json::from_value::<EpisodesArgs>(args) {
            Ok(v) => v,
            Err(e) => {
                return JsonRpcResponse::err(id, INVALID_PARAMS, format!("mci_episodes args: {e}"))
            }
        };
        let limit = parsed
            .limit
            .unwrap_or(DEFAULT_EPISODES_LIMIT)
            .clamp(1, MAX_EPISODES_LIMIT);

        match self.reader.episodes(limit) {
            Ok(eps) => {
                let eps_json: Vec<serde_json::Value> = eps
                    .iter()
                    .map(|ep| {
                        serde_json::json!({
                            "id": ep.id,
                            "app_bundle_id": ep.app_bundle_id,
                            "ts_start": ep.ts_start,
                            "ts_end": ep.ts_end,
                            "event_count": ep.event_count,
                        })
                    })
                    .collect();
                JsonRpcResponse::ok(
                    id,
                    serde_json::json!({
                        "content": [
                            {
                                "type": "text",
                                "text": serde_json::to_string(&eps_json)
                                    .unwrap_or_else(|_| "[]".to_owned()),
                            }
                        ],
                        "episodes": eps_json,
                        "isError": false,
                    }),
                )
            }
            Err(e) => brain_err_to_response(id, &e),
        }
    }

    fn handle_events_by_app(&self, id: JsonRpcId, args: serde_json::Value) -> JsonRpcResponse {
        #[derive(Deserialize)]
        struct EventsByAppArgs {
            app_bundle_id: String,
            #[serde(default)]
            limit: Option<usize>,
        }
        let parsed: EventsByAppArgs = match serde_json::from_value::<EventsByAppArgs>(args) {
            Ok(v) => v,
            Err(e) => {
                return JsonRpcResponse::err(
                    id,
                    INVALID_PARAMS,
                    format!("mci_events_by_app args: {e}"),
                )
            }
        };
        if parsed.app_bundle_id.trim().is_empty() {
            return JsonRpcResponse::err(
                id,
                INVALID_PARAMS,
                "mci_events_by_app: app_bundle_id must be non-empty",
            );
        }
        let limit = parsed
            .limit
            .unwrap_or(DEFAULT_EVENTS_BY_APP_LIMIT)
            .clamp(1, MAX_EVENTS_BY_APP_LIMIT);

        match self.reader.events_by_app(&parsed.app_bundle_id, limit) {
            Ok(rows) => {
                let rows_json: Vec<serde_json::Value> = rows
                    .iter()
                    .map(|r| {
                        serde_json::json!({
                            "event_id": r.event_id.0,
                            "ts_us": r.ts_us,
                            "app_bundle_id": r.app_bundle_id,
                            "window_title": r.window_title,
                            "url": r.url,
                            "text_snippet": r.text_snippet,
                        })
                    })
                    .collect();
                JsonRpcResponse::ok(
                    id,
                    serde_json::json!({
                        "content": [
                            {
                                "type": "text",
                                "text": serde_json::to_string(&rows_json)
                                    .unwrap_or_else(|_| "[]".to_owned()),
                            }
                        ],
                        "events": rows_json,
                        "isError": false,
                    }),
                )
            }
            Err(e) => brain_err_to_response(id, &e),
        }
    }
}

fn brain_err_to_response(id: JsonRpcId, e: &BrainReaderError) -> JsonRpcResponse {
    match e {
        BrainReaderError::InvalidInput(m) => JsonRpcResponse::err(id, INVALID_PARAMS, m.clone()),
        BrainReaderError::Backend(m) => JsonRpcResponse::err(id, SERVER_ERROR_GENERIC, m.clone()),
    }
}

/// Run the production stdio loop: read newline-delimited JSON-RPC frames
/// from stdin, dispatch through `server`, write responses to stdout.
///
/// On EOF on stdin, returns `Ok(())`. On any write failure, returns
/// `Err(io)` — the supervisor logs to stderr and exits non-zero.
///
/// Lines that fail to parse as JSON-RPC return a `PARSE_ERROR` response
/// with `id: null` (per JSON-RPC 2.0 §5).
///
/// # Errors
/// Propagates any `tokio::io::Error` from stdin/stdout.
pub async fn serve_stdio<W>(server: Arc<Server>, mut out: W) -> std::io::Result<()>
where
    W: AsyncWrite + Unpin,
{
    let stdin = tokio::io::stdin();
    let mut reader = BufReader::new(stdin);
    let mut line = String::new();

    loop {
        line.clear();
        let n = reader.read_line(&mut line).await?;
        if n == 0 {
            // EOF — client closed its end of the pipe. Graceful exit.
            return Ok(());
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let response = match serde_json::from_str::<JsonRpcRequest>(trimmed) {
            Ok(req) => server.dispatch(req),
            Err(e) => {
                server
                    .counters
                    .parse_error_count
                    .fetch_add(1, Ordering::SeqCst);
                Some(JsonRpcResponse::err(
                    JsonRpcId::Null,
                    PARSE_ERROR,
                    format!("parse error: {e}"),
                ))
            }
        };
        if let Some(resp) = response {
            write_response(&mut out, &resp).await?;
        }
    }
}

async fn write_response<W>(out: &mut W, resp: &JsonRpcResponse) -> std::io::Result<()>
where
    W: AsyncWrite + Unpin,
{
    // Serialize then push a single '\n' — MCP stdio is line-delimited.
    let mut bytes = serde_json::to_vec(resp)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    bytes.push(b'\n');
    out.write_all(&bytes).await?;
    out.flush().await?;
    Ok(())
}

// Compile-time tripwire: `Server` MUST stay `Send + Sync` so it can sit
// behind `Arc<Server>` across the tokio runtime. If a future field
// breaks that, this line stops compiling.
#[allow(dead_code)]
fn _server_is_send_sync() {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<Server>();
}
