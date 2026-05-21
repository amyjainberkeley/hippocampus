//! JSON-RPC 2.0 framing — request/response types + standard error codes.
//!
//! Per the JSON-RPC 2.0 spec (<https://www.jsonrpc.org/specification>) +
//! the MCP stdio transport contract:
//!
//! - Every frame is **one JSON object per line** on stdin/stdout.
//! - Requests carry `{"jsonrpc": "2.0", "id": ..., "method": "...", "params": {...}}`.
//! - Notifications carry `{"jsonrpc": "2.0", "method": "...", "params": {...}}`
//!   (no `id`; the server MUST NOT respond).
//! - Responses carry `{"jsonrpc": "2.0", "id": ..., "result": ...}` or
//!   `{"jsonrpc": "2.0", "id": ..., "error": {"code": ..., "message": ..., "data": ...}}`.
//!
//! This module deliberately stays small — the JSON-RPC surface is one
//! line per message; a full RPC framework crate would be 1000× the
//! supply-chain audit cost.

use serde::{Deserialize, Serialize};

/// JSON-RPC 2.0 standard error: malformed JSON on the wire.
pub const PARSE_ERROR: i64 = -32700;
/// JSON-RPC 2.0 standard error: the request object is invalid
/// (missing `jsonrpc` / `method`, wrong type, etc.).
pub const INVALID_REQUEST: i64 = -32600;
/// JSON-RPC 2.0 standard error: the method does not exist.
pub const METHOD_NOT_FOUND: i64 = -32601;
/// JSON-RPC 2.0 standard error: the params object is invalid for the
/// method (missing required field, wrong type, ...).
pub const INVALID_PARAMS: i64 = -32602;
/// JSON-RPC 2.0 reserved range for implementation-defined server errors.
/// We use this for backend failures from [`super::BrainReader`].
pub const SERVER_ERROR_GENERIC: i64 = -32000;

/// JSON-RPC 2.0 id. Numeric and string ids are both spec-legal; some MCP
/// clients use UUID strings while others use auto-incremented integers.
///
/// `null` is also legal (for "notification-with-id" exotic dialects);
/// we accept it and echo it back as-is.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum JsonRpcId {
    /// Integer id — what most MCP clients (Claude Code included) emit.
    Number(i64),
    /// String id — UUID-style.
    String(String),
    /// Explicit JSON `null`.
    Null,
}

/// Incoming JSON-RPC 2.0 request frame.
///
/// `id` is absent for notifications (per JSON-RPC 2.0 §4.1). We model
/// this with `#[serde(default)]` + `Option<JsonRpcId>`. `params` is
/// `serde_json::Value` so each tool's `inputSchema` validation can run
/// inside the dispatcher rather than failing the whole frame.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcRequest {
    /// MUST be the string `"2.0"`. We reject anything else as
    /// `INVALID_REQUEST` so a client using JSON-RPC 1.0 framing gets a
    /// useful error.
    pub jsonrpc: String,
    /// Method name (e.g. `"tools/list"`, `"tools/call"`).
    pub method: String,
    /// Method parameters. `None` is legal (some MCP methods take no
    /// params, e.g. `initialize` minus the protocol version).
    #[serde(default)]
    pub params: Option<serde_json::Value>,
    /// Request id; absent ⇒ notification.
    #[serde(default)]
    pub id: Option<JsonRpcId>,
}

/// Outgoing JSON-RPC 2.0 response frame.
///
/// Exactly one of `result` / `error` is present per the spec. We model
/// this with two `Option` fields + `skip_serializing_if = "Option::is_none"`
/// so the wire format keeps only the populated field.
#[derive(Debug, Clone, Serialize)]
pub struct JsonRpcResponse {
    /// Always `"2.0"`.
    pub jsonrpc: &'static str,
    /// Echoes the request id. JSON-RPC 2.0 §5: even on error the response
    /// MUST carry the same id (or `null` if the id could not be parsed).
    pub id: JsonRpcId,
    /// Success payload. Absent on error responses.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    /// Error payload. Absent on success responses.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcError>,
}

impl JsonRpcResponse {
    /// Build a success response.
    #[must_use]
    pub fn ok(id: JsonRpcId, result: serde_json::Value) -> Self {
        Self {
            jsonrpc: "2.0",
            id,
            result: Some(result),
            error: None,
        }
    }

    /// Build an error response.
    #[must_use]
    pub fn err(id: JsonRpcId, code: i64, message: impl Into<String>) -> Self {
        Self {
            jsonrpc: "2.0",
            id,
            result: None,
            error: Some(JsonRpcError {
                code,
                message: message.into(),
                data: None,
            }),
        }
    }
}

/// JSON-RPC 2.0 error object.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcError {
    /// Standard or implementation-defined error code.
    pub code: i64,
    /// Short human-readable description.
    pub message: String,
    /// Optional structured data. Always omitted from the wire when
    /// `None`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_round_trips_with_integer_id() {
        let raw = r#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#;
        let req: JsonRpcRequest = serde_json::from_str(raw).expect("parse");
        assert_eq!(req.jsonrpc, "2.0");
        assert_eq!(req.method, "tools/list");
        assert_eq!(req.id, Some(JsonRpcId::Number(7)));
        assert!(req.params.is_none());
    }

    #[test]
    fn request_accepts_string_id() {
        let raw = r#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#;
        let req: JsonRpcRequest = serde_json::from_str(raw).expect("parse");
        assert_eq!(req.id, Some(JsonRpcId::String("abc".into())));
    }

    #[test]
    fn notification_has_no_id() {
        let raw = r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#;
        let req: JsonRpcRequest = serde_json::from_str(raw).expect("parse");
        assert!(req.id.is_none());
    }

    #[test]
    fn response_ok_serializes_without_error_field() {
        let resp = JsonRpcResponse::ok(JsonRpcId::Number(1), serde_json::json!({"a": 1}));
        let s = serde_json::to_string(&resp).expect("serialize");
        assert!(s.contains("\"result\":"));
        assert!(!s.contains("\"error\":"));
    }

    #[test]
    fn response_err_serializes_without_result_field() {
        let resp = JsonRpcResponse::err(JsonRpcId::Number(2), METHOD_NOT_FOUND, "no such method");
        let s = serde_json::to_string(&resp).expect("serialize");
        assert!(s.contains("\"error\":"));
        assert!(s.contains("-32601"));
        assert!(!s.contains("\"result\":"));
    }
}
