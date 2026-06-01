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
//! - [`HttpSseTransport`] (loopback HTTP+SSE — V2-MCP-2).
//! - Loopback URL validator ([`transport::loopback::LoopbackHost`]) +
//!   `LoopbackOnlyConnector` enforcing the ADR-0001 amendment dated
//!   2026-05-31.
//! - [`McpClient`] over any [`McpTransport`]:
//!   `initialize`, `tools_list`, `tools_call`, `resources_list`,
//!   `resources_read`, `prompts_list`, `prompts_get`.
//! - [`ServerRegistration`] + [`ServerRegistry`] for lazy multi-server
//!   connection lifecycle (stdio + http).
//! - [`config::McpServersConfig`] + on-disk schema for
//!   `~/Library/Application Support/MCI/mcp-servers.toml`.
//!
//! # Not in scope (separate PRs)
//!
//! - Materialize-to-brain logic + cascade-equivalent redaction at
//!   ingest — V2-MCP-3 (cycle 8.30, Director-Brain). Note that per
//!   CRS Fork-6 = A ratified 2026-05-31, MCP-server response content
//!   ingests as-is into the brain; the cascade-equivalent path here
//!   refers to the deep-hook surfaces (Messages / Mail) which run
//!   through a DIFFERENT pipeline.
//! - Recall surface integration — V2-MCP-4.
//! - Discovery / auto-probe of loopback MCP servers — explicitly out
//!   of scope for v1.0 per ADR-0001 amendment §"Operational rules".
//!
//! # ADR-0001 posture
//!
//! Stdio transport is process-local IPC, not network — the trust
//! boundary is the same as any other in-process call. The HTTP+SSE
//! transport, added in V2-MCP-2, is the first network-shaped surface
//! in MCI history. It is bound to loopback-only addresses by the
//! ADR-0001 2026-05-31 amendment AND by defense-in-depth gates in
//! [`transport::loopback`] and [`transport::http_sse`]; no other crate
//! in the workspace gains a network surface as a side effect.

// V2-MCP-1 used `#![forbid(unsafe_code)]`; V2-MCP-2 narrows that to
// `deny` so the `mcp-servers.toml` uid-match check (Audit row #5) can
// call `libc::geteuid()` from one `#[allow(unsafe_code)]`-tagged
// helper in `config.rs`. Every other module remains unsafe-free —
// the `deny` lint surfaces any future intrusion at build time.
#![deny(unsafe_code)]

pub mod client;
pub mod config;
pub mod error;
pub mod jsonrpc;
pub mod registry;
pub mod stdio;
pub mod transport;
pub mod types;

pub use client::{BlockingMcpClient, McpClient};
pub use config::{ConfigError, McpServerEntry, McpServersConfig};
pub use error::{McpError, McpResult};
pub use jsonrpc::{
    JsonRpcError, JsonRpcId, JsonRpcRequest, JsonRpcResponse, INVALID_PARAMS, INVALID_REQUEST,
    METHOD_NOT_FOUND, PARSE_ERROR, SERVER_ERROR_GENERIC,
};
pub use registry::{ConnectionState, ServerHandle, ServerRegistration, ServerRegistry, ServerSpec};
pub use stdio::{StdioTransport, DEFAULT_CALL_TIMEOUT};
pub use transport::http_sse::{HttpSseError, HttpSseTransport};
pub use transport::loopback::{LoopbackError, LoopbackHost};
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
