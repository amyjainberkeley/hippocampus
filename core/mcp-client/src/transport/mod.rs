//! [`McpTransport`] — the abstract wire over which the client speaks
//! JSON-RPC 2.0 to one MCP server.
//!
//! V2-MCP-1 ships one impl: [`crate::stdio::StdioTransport`] (process-
//! local IPC, not network). V2-MCP-2 adds the HTTP+SSE impl at
//! [`http_sse::HttpSseTransport`] — first network-shaped surface in MCI
//! history. The HTTP+SSE impl is bound to a loopback-only constraint
//! enforced both at registration time and per-call connect time; see
//! [`loopback::LoopbackHost`] for the URL gate and the ADR-0001
//! amendment dated 2026-05-31 for the policy framing.
//!
//! # Sync vs async
//!
//! - [`McpTransport`] is **async** (via `#[async_trait]`) — it is the
//!   primary surface because stdio and HTTP+SSE both have natural
//!   async impls (tokio process / SSE long-poll).
//! - [`BlockingMcpTransport`] is a **sync** convenience for callers
//!   that own their own runtime and want a synchronous call shape.
//!   Its blanket impl wraps an async [`McpTransport`] in a tokio
//!   `current_thread` runtime per call — fine for occasional sync
//!   call sites, not for hot paths.

use async_trait::async_trait;

use crate::error::McpResult;
use crate::jsonrpc::{JsonRpcRequest, JsonRpcResponse};

pub mod http_sse;
pub mod loopback;

pub use http_sse::HttpSseTransport;
pub use loopback::{LoopbackError, LoopbackHost};

/// Abstract bidirectional JSON-RPC 2.0 transport.
///
/// A transport owns one persistent connection to one MCP server. The
/// [`crate::ServerRegistry`] holds N transports — one per registered
/// server — and dispatches by server id.
///
/// # Concurrency
///
/// The trait requires `Send + Sync` so a single transport can be held
/// in an `Arc` and called from multiple tasks. Implementations are
/// responsible for serialization between concurrent calls (the stdio
/// impl uses an internal `Mutex` to serialize wire frames; HTTP+SSE
/// can fan out per-connection without).
#[async_trait]
pub trait McpTransport: Send + Sync {
    /// Send one JSON-RPC request, await its response.
    ///
    /// Notifications (id-less requests) MUST NOT be sent through
    /// `call` — use [`Self::notify`] instead.
    ///
    /// # Errors
    /// - [`crate::McpError::Io`] if the transport's underlying
    ///   pipe / socket fails.
    /// - [`crate::McpError::MalformedFrame`] if the server returns a
    ///   non-JSON-RPC frame.
    /// - [`crate::McpError::Timeout`] if the per-call deadline elapses.
    /// - [`crate::McpError::Closed`] if [`Self::close`] has been called.
    async fn call(&self, request: JsonRpcRequest) -> McpResult<JsonRpcResponse>;

    /// Send a notification (no response expected).
    ///
    /// Default impl writes the frame and returns. Implementations
    /// that do not support notifications (none currently) may return
    /// [`crate::McpError::Closed`].
    async fn notify(&self, notification: JsonRpcRequest) -> McpResult<()>;

    /// Tear down the transport, freeing OS resources (subprocess
    /// kill / socket close). Idempotent. After `close`, further
    /// [`Self::call`] returns [`crate::McpError::Closed`].
    async fn close(&self);
}

/// Synchronous counterpart to [`McpTransport`]. Convenience for sync
/// call sites; not the primary surface.
///
/// Callers that own a tokio runtime should prefer [`McpTransport`]
/// directly. This trait exists so a non-async caller (e.g. a
/// scripting / CLI context) can talk to an MCP server without
/// spinning up a runtime by hand.
pub trait BlockingMcpTransport: Send + Sync {
    /// Send one JSON-RPC request, block on the response.
    ///
    /// # Errors
    /// See [`McpTransport::call`].
    fn call_blocking(&self, request: JsonRpcRequest) -> McpResult<JsonRpcResponse>;

    /// Tear down the transport.
    fn close_blocking(&self);
}
