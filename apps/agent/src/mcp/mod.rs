//! `mci-agent mcp-serve` — localhost MCP server (P3.10b).
//!
//! Exposes a **read-only** view of the Phase-3 brain to any MCP-compatible
//! client (Claude Code, Cursor, Codex, etc.) over a JSON-RPC 2.0 stdio
//! transport. Five tools:
//!
//! - `mci_recall(query, limit)` — lexical FTS5 search, returns the top
//!   hits as compact [`EventRecord`](mci_brain::EventRecord)-shaped rows.
//! - `mci_events_since(ts_us, limit)` — timeline cursor: events newer than
//!   the cursor, ordered ascending.
//! - `mci_stats()` — content-free aggregate (event count + oldest +
//!   newest `ts_us`). Lets an agent know "how much memory is available".
//! - `mci_episodes(limit)` — recent episodes with event counts.
//! - `mci_events_by_app(app_bundle_id, limit)` — events filtered by app.
//!
//! # Protocol
//!
//! MCP stdio transport is **newline-delimited JSON** per the
//! `Model Context Protocol` spec (one JSON-RPC 2.0 message per line, no
//! `Content-Length` headers — that's LSP, not MCP). The server:
//!
//! 1. Reads one JSON object per line from stdin.
//! 2. Dispatches `initialize` / `tools/list` / `tools/call` /
//!    `notifications/*` / pings.
//! 3. Writes one JSON object per line to stdout.
//! 4. Logs operational lines to stderr (never to stdout — stdout is
//!    reserved for protocol frames).
//!
//! # Privacy invariants (CSO veto-gate per ADR-0017 §5)
//!
//! - **Read-only by construction** — there is no tools/call route that
//!   mutates the store. Adding a write tool requires a separate
//!   CSO-signed PR. The dispatcher in [`server`] structurally enumerates
//!   the five read tools; an unknown tool name returns a JSON-RPC error,
//!   never falls through to a write path.
//! - **Privacy moments (`PrivacyTombstone`) are NOT exposed by P3.10b.**
//!   An `mci_privacy_moments` tool is a future opt-in PR per ADR-0017 §5.
//! - **Content-free request counter only.** The server tracks
//!   `mci_mcp_request_count` (per-tool); no query text, no result rows,
//!   no row IDs land in any logged surface.
//! - **Snippets are truncated** at
//!   [`mci_brain::EventRecord::SNIPPET_MAX_CHARS`] bytes on a UTF-8
//!   boundary — a stray "give me 100 events" cannot page hundreds of KB
//!   through the local socket.
//!
//! # Why hand-rolled framing (not a JSON-RPC crate)
//!
//! Per ADR-0008's dependency-addition gate, every new third-party crate
//! needs a supply-chain audit. The MCP stdio framing is *one line per
//! message* — too small to justify a new dep. `serde_json::from_str` +
//! `serde_json::to_string` + `tokio::io::BufReader::read_line` is the
//! whole transport. `serde` and `serde_json` are already on the
//! workspace lockfile (via `mci-brain-ffi`), so this PR adds zero net
//! new crates.

pub mod brain_reader;
pub mod jsonrpc;
pub mod live;
pub mod server;
pub mod tools;

pub use brain_reader::{BrainReader, BrainReaderError, McpHit};
pub use jsonrpc::{
    JsonRpcError, JsonRpcId, JsonRpcRequest, JsonRpcResponse, INVALID_PARAMS, INVALID_REQUEST,
    METHOD_NOT_FOUND, PARSE_ERROR,
};
pub use live::LiveBrainReader;
pub use server::{serve_stdio, Server, ServerCounters};
pub use tools::{tool_definitions, ToolName};
