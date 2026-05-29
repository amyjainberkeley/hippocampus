//! [`McpError`] — the single error type this crate produces.
//!
//! Surfaces every failure mode the client can encounter into one enum
//! so callers (V2-MCP-3 aggregator, V2-MCP-4 chat live-search) can
//! pattern-match on a stable shape.

use std::io;

use crate::jsonrpc::JsonRpcError;

/// Result alias used throughout the crate.
pub type McpResult<T> = std::result::Result<T, McpError>;

/// Every failure the MCP client can report. The variants align with
/// the failure modes the scoping memo §2.5 calls out:
/// server-unreachable / server-returned-error / schema-mismatch /
/// timeout.
#[derive(Debug, thiserror::Error)]
pub enum McpError {
    /// The transport failed at the OS level — spawn refused, pipe
    /// broken, write blocked, child exited.
    #[error("transport I/O: {0}")]
    Io(#[from] io::Error),

    /// The peer sent a frame that did not parse as JSON-RPC 2.0
    /// (malformed JSON or missing `jsonrpc: "2.0"`).
    #[error("malformed JSON-RPC frame: {reason}")]
    MalformedFrame {
        /// One-line description of what failed. Never includes the
        /// payload bytes to avoid leaking server-supplied content
        /// into telemetry (§5.4 content-free discipline).
        reason: String,
    },

    /// The peer returned a JSON-RPC error response. Carries the raw
    /// error object so callers can route by `code` (e.g.,
    /// [`crate::jsonrpc::METHOD_NOT_FOUND`] → "this server does not
    /// expose that tool").
    #[error("JSON-RPC error {0:?}")]
    Rpc(JsonRpcError),

    /// A `tools/call` or `resources/read` returned a result whose shape
    /// does not match the documented contract (missing `content` array,
    /// non-string `text`, etc.). The caller cannot recover; the server
    /// is either misbehaving or speaking a different MCP version.
    #[error("schema mismatch: {0}")]
    SchemaMismatch(String),

    /// The per-call timeout fired before a response arrived.
    #[error("call timed out after {timeout_ms}ms (method={method})")]
    Timeout {
        /// Configured timeout that elapsed.
        timeout_ms: u64,
        /// JSON-RPC method that did not respond.
        method: String,
    },

    /// The transport has been closed (subprocess exited cleanly or via
    /// [`crate::McpTransport::close`]). Further calls will not succeed.
    #[error("transport closed")]
    Closed,

    /// Local serialization of a request payload failed. Typically
    /// indicates a bug in the caller — `serde_json::Value` arguments
    /// should always serialize.
    #[error("serialize: {0}")]
    Serialize(#[from] serde_json::Error),
}

impl McpError {
    /// True for errors that callers should NOT auto-retry — schema
    /// mismatches and JSON-RPC `METHOD_NOT_FOUND` mean retry will not
    /// help. Used by the §2.5 exponential-backoff state machine in
    /// V2-MCP-3 (separate PR).
    #[must_use]
    pub fn is_permanent(&self) -> bool {
        match self {
            McpError::MalformedFrame { .. }
            | McpError::SchemaMismatch(_)
            | McpError::Closed
            | McpError::Serialize(_) => true,
            McpError::Rpc(e) => e.code == crate::jsonrpc::METHOD_NOT_FOUND,
            McpError::Io(_) | McpError::Timeout { .. } => false,
        }
    }
}
