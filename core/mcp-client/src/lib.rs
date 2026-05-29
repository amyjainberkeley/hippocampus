//! `mci-mcp-client` — pure-Rust MCP client core + stdio transport.
//!
//! V2-MCP-1 (see `docs/research/v2-mcp-aggregation-scoping-2026-05-29.md`
//! §6.1). The Hippocampus aggregator (V2-MCP-3, separate PR) uses this
//! crate to call into third-party MCP servers — gbrain (local stdio),
//! Slack/Linear/GitHub MCPs, etc. — and materialize their content into
//! the v2 entity-graph.
//!
//! # Scope of this crate
//!
//! - JSON-RPC 2.0 client framing ([`jsonrpc`]).
//! - Async [`McpTransport`] trait + sync [`BlockingMcpTransport`] trait
//!   ([`transport`]). The async trait is the primary surface; the
//!   blocking trait is a convenience for synchronous callers that own
//!   their own runtime.
//! - [`StdioTransport`] (subprocess + framed stdio reader).
//! - [`McpClient`] over any [`McpTransport`]:
//!   `initialize`, `tools_list`, `tools_call`, `resources_list`,
//!   `resources_read`, `prompts_list`, `prompts_get`.
//! - [`ServerRegistration`] + [`ServerRegistry`] for lazy multi-server
//!   connection lifecycle.
//!
//! # Not in scope (separate PRs)
//!
//! - HTTP + SSE transport — V2-MCP-2 (ADR-0001 amendment owed).
//! - Registration UI / per-server consent — V2-MCP-2.
//! - Materialize-to-brain logic + cascade-equivalent redaction —
//!   V2-MCP-3.
//! - Recall surface integration — V2-MCP-4.
//!
//! # ADR-0001 NG3 compliance
//!
//! Stdio transport is **process-local IPC**, not network. Spawning a
//! child process and piping JSON-RPC over its stdio is the same trust
//! boundary as any other in-process call. **V2-MCP-1 does NOT violate
//! the zero-network invariant.** The HTTP+SSE transport in V2-MCP-2
//! does, and lands with an explicit ADR-0001 amendment + CSO sign-off
//! at that time.

#![forbid(unsafe_code)]

pub mod client;
pub mod error;
pub mod jsonrpc;
pub mod registry;
pub mod stdio;
pub mod transport;
pub mod types;

pub use client::{BlockingMcpClient, McpClient};
pub use error::{McpError, McpResult};
pub use jsonrpc::{
    JsonRpcError, JsonRpcId, JsonRpcRequest, JsonRpcResponse, INVALID_PARAMS, INVALID_REQUEST,
    METHOD_NOT_FOUND, PARSE_ERROR, SERVER_ERROR_GENERIC,
};
pub use registry::{ConnectionState, ServerHandle, ServerRegistration, ServerRegistry};
pub use stdio::{StdioTransport, DEFAULT_CALL_TIMEOUT};
pub use transport::{BlockingMcpTransport, McpTransport};
pub use types::{
    InitializeResult, PromptDef, PromptMessage, ReadResourceResult, ResourceContent, ResourceDef,
    ServerCapabilities, ServerInfo, ToolDef, ToolResult,
};

/// MCP protocol version this client advertises in `initialize`.
///
/// Mirrors `apps/agent/src/mcp/server.rs`'s `MCP_PROTOCOL_VERSION`
/// (calendar-versioned per the canonical Anthropic spec). Claude Code
/// 2026-Q1 negotiates the same string. Per spec the negotiation is
/// best-effort: a server that advertises a different version is still
/// callable; the client logs the mismatch but proceeds.
pub const MCP_PROTOCOL_VERSION: &str = "2024-11-05";

/// Identification this client sends in `initialize` so a peer-side
/// MCP server's `clientInfo` log can name the consumer. The version
/// tracks the crate's `Cargo.toml` so a bump shows up in MCP logs.
pub const CLIENT_NAME: &str = "mci-mcp-client";
/// Identification version sent alongside [`CLIENT_NAME`].
pub const CLIENT_VERSION: &str = env!("CARGO_PKG_VERSION");
