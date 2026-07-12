//! JSON-RPC 2.0 client framing (request / response / error).
//!
//! Mirrors the producer-side framing at `apps/agent/src/mcp/jsonrpc.rs`
//! — the wire shape is symmetric, but the client owns the **id
//! allocator** (servers echo ids; clients mint them).
//!
//! Per the JSON-RPC 2.0 spec + the MCP stdio transport contract:
//! one JSON object per line on stdin/stdout. No `Content-Length`
//! headers — that is LSP, not MCP.

use std::sync::atomic::{AtomicI64, Ordering};

use serde::{Deserialize, Serialize};

/// JSON-RPC 2.0 standard error: malformed JSON on the wire.
pub const PARSE_ERROR: i64 = -32700;
/// JSON-RPC 2.0 standard error: the request object is invalid.
pub const INVALID_REQUEST: i64 = -32600;
/// JSON-RPC 2.0 standard error: the method does not exist.
pub const METHOD_NOT_FOUND: i64 = -32601;
/// JSON-RPC 2.0 standard error: the params object is invalid.
pub const INVALID_PARAMS: i64 = -32602;
/// JSON-RPC 2.0 reserved range for implementation-defined server
/// errors. Surfaces through [`crate::McpError::Rpc`].
pub const SERVER_ERROR_GENERIC: i64 = -32000;

/// JSON-RPC 2.0 id. Numeric and string ids are both spec-legal; this
/// crate mints integer ids on the wire (see [`RequestIdAllocator`])
/// but accepts both shapes on the response path so a server using
/// UUID strings can still be talked to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum JsonRpcId {
    /// Integer id — what this client mints by default.
    Number(i64),
    /// String id — accepted on responses if the server uses them.
    String(String),
    /// Explicit JSON `null`. Spec-legal but unusual.
    Null,
}

impl JsonRpcId {
    /// Stable string form used as a hash key in the response router.
    #[must_use]
    pub fn key(&self) -> String {
        match self {
            JsonRpcId::Number(n) => format!("n:{n}"),
            JsonRpcId::String(s) => format!("s:{s}"),
            JsonRpcId::Null => "null".to_owned(),
        }
    }
}

/// Outgoing JSON-RPC 2.0 request frame.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcRequest {
    /// MUST be the string `"2.0"`.
    pub jsonrpc: String,
    /// Method name (e.g. `"initialize"`, `"tools/call"`).
    pub method: String,
    /// Method parameters. `None` is legal for parameter-less methods
    /// like `ping`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub params: Option<serde_json::Value>,
    /// Request id; absent ⇒ notification (no response expected).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<JsonRpcId>,
}

impl JsonRpcRequest {
    /// Build a JSON-RPC 2.0 request with the given id, method, and
    /// optional params.
    #[must_use]
    pub fn new(
        id: JsonRpcId,
        method: impl Into<String>,
        params: Option<serde_json::Value>,
    ) -> Self {
        Self {
            jsonrpc: "2.0".to_owned(),
            method: method.into(),
            params,
            id: Some(id),
        }
    }

    /// Build a JSON-RPC 2.0 notification (no `id`, no response).
    #[must_use]
    pub fn notification(method: impl Into<String>, params: Option<serde_json::Value>) -> Self {
        Self {
            jsonrpc: "2.0".to_owned(),
            method: method.into(),
            params,
            id: None,
        }
    }
}

/// Incoming JSON-RPC 2.0 response frame (what the client reads from
/// the server's stdout).
#[derive(Debug, Clone, Deserialize)]
pub struct JsonRpcResponse {
    /// MUST be the string `"2.0"`. The client rejects anything else as
    /// [`crate::McpError::MalformedFrame`].
    pub jsonrpc: String,
    /// Echoes the request id. JSON-RPC 2.0 §5: even on error the
    /// response MUST carry the same id.
    pub id: JsonRpcId,
    /// Success payload. Mutually exclusive with [`Self::error`].
    #[serde(default)]
    pub result: Option<serde_json::Value>,
    /// Error payload. Mutually exclusive with [`Self::result`].
    #[serde(default)]
    pub error: Option<JsonRpcError>,
}

/// JSON-RPC 2.0 error object.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcError {
    /// Standard or implementation-defined error code.
    pub code: i64,
    /// Short human-readable description.
    pub message: String,
    /// Optional structured data.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
}

/// Monotonic id allocator. JSON-RPC requires that each in-flight
/// request carries a unique id so the response router can correlate.
/// `AtomicI64` because requests may be issued from multiple tasks
/// sharing the same client.
#[derive(Debug, Default)]
pub struct RequestIdAllocator {
    next: AtomicI64,
}

impl RequestIdAllocator {
    /// Build an allocator starting at id 1.
    #[must_use]
    pub fn new() -> Self {
        Self {
            next: AtomicI64::new(1),
        }
    }

    /// Mint the next id.
    #[must_use]
    pub fn next(&self) -> JsonRpcId {
        JsonRpcId::Number(self.next.fetch_add(1, Ordering::SeqCst))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_serializes_without_optional_fields() {
        let req = JsonRpcRequest::new(JsonRpcId::Number(1), "ping", None);
        let s = serde_json::to_string(&req).expect("serialize");
        assert!(s.contains("\"jsonrpc\":\"2.0\""));
        assert!(s.contains("\"method\":\"ping\""));
        assert!(s.contains("\"id\":1"));
        assert!(!s.contains("\"params\""));
    }

    #[test]
    fn notification_omits_id() {
        let req = JsonRpcRequest::notification("notifications/initialized", None);
        let s = serde_json::to_string(&req).expect("serialize");
        assert!(!s.contains("\"id\""));
    }

    #[test]
    fn response_round_trips() {
        let raw = r#"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#;
        let resp: JsonRpcResponse = serde_json::from_str(raw).expect("parse");
        assert_eq!(resp.id, JsonRpcId::Number(7));
        assert!(resp.result.is_some());
        assert!(resp.error.is_none());
    }

    #[test]
    fn error_response_round_trips() {
        let raw =
            r#"{"jsonrpc":"2.0","id":"abc","error":{"code":-32601,"message":"no such method"}}"#;
        let resp: JsonRpcResponse = serde_json::from_str(raw).expect("parse");
        assert_eq!(resp.id, JsonRpcId::String("abc".into()));
        let err = resp.error.expect("error present");
        assert_eq!(err.code, METHOD_NOT_FOUND);
        assert_eq!(err.message, "no such method");
    }

    #[test]
    fn allocator_is_monotonic() {
        let alloc = RequestIdAllocator::new();
        let ids = (0..4).map(|_| alloc.next()).collect::<Vec<_>>();
        assert_eq!(
            ids,
            vec![
                JsonRpcId::Number(1),
                JsonRpcId::Number(2),
                JsonRpcId::Number(3),
                JsonRpcId::Number(4),
            ]
        );
    }

    #[test]
    fn id_key_is_stable() {
        assert_eq!(JsonRpcId::Number(7).key(), "n:7");
        assert_eq!(JsonRpcId::String("abc".into()).key(), "s:abc");
        assert_eq!(JsonRpcId::Null.key(), "null");
    }
}
