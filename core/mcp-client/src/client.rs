//! [`McpClient`] — protocol layer that turns the
//! [`crate::McpTransport`] frame I/O into typed MCP method calls.
//!
//! Per V2-MCP-1 scope (memo §6.1): seven methods —
//! `initialize`, `tools/list`, `tools/call`, `resources/list`,
//! `resources/read`, `prompts/list`, `prompts/get`.
//!
//! v1 V2-MCP-3 aggregation only needs `initialize` + `tools/list` +
//! `tools/call` + `resources/list` + `resources/read`; prompts are
//! surfaced for API completeness (see memo §8.4 — kept-thin pending
//! a use case).

use std::sync::Arc;

use crate::error::{McpError, McpResult};
use crate::jsonrpc::{JsonRpcId, JsonRpcRequest, JsonRpcResponse, RequestIdAllocator};
use crate::transport::McpTransport;
use crate::types::{
    InitializeResult, PromptDef, PromptMessage, ReadResourceResult, ResourceDef, ToolDef,
    ToolResult,
};
use crate::{CLIENT_NAME, CLIENT_VERSION, MCP_PROTOCOL_VERSION};

/// Async MCP client.
///
/// Generic over the transport so a stdio test, a stdio production
/// connection, and (V2-MCP-2) an HTTP+SSE connection share the same
/// protocol code. Hold in an `Arc` for cross-task sharing.
pub struct McpClient<T: McpTransport + ?Sized> {
    transport: Arc<T>,
    ids: Arc<RequestIdAllocator>,
}

impl<T: McpTransport + ?Sized> std::fmt::Debug for McpClient<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("McpClient").finish_non_exhaustive()
    }
}

impl<T: McpTransport> McpClient<T> {
    /// Build a client over the given transport.
    ///
    /// Constrained to `T: Sized` so the typed constructor stays
    /// ergonomic; the registry holds `Arc<McpClient<dyn McpTransport>>`
    /// and uses [`McpClient::from_dyn`] below.
    #[must_use]
    pub fn new(transport: Arc<T>) -> Self {
        Self {
            transport,
            ids: Arc::new(RequestIdAllocator::new()),
        }
    }
}

impl McpClient<dyn McpTransport> {
    /// Build a client from an already-erased transport. V2-MCP-2's
    /// registry uses this to hold either a `StdioTransport` or an
    /// `HttpSseTransport` behind one `Arc<McpClient<dyn ...>>` without
    /// leaking the concrete type.
    #[must_use]
    pub fn from_dyn(transport: Arc<dyn McpTransport>) -> Self {
        Self {
            transport,
            ids: Arc::new(RequestIdAllocator::new()),
        }
    }
}

impl<T: McpTransport + ?Sized> McpClient<T> {
    /// Borrow the transport (for tests and the `ServerRegistry`).
    ///
    /// Constrained to `T: Sized` because the caller is the typed
    /// path; the registry doesn't expose its `dyn` transport.
    #[must_use]
    pub fn transport(&self) -> Arc<T>
    where
        T: Sized,
    {
        Arc::clone(&self.transport)
    }

    /// Perform the MCP `initialize` handshake.
    ///
    /// Sends `initialize` with the negotiated [`MCP_PROTOCOL_VERSION`]
    /// and follows up with the `notifications/initialized`
    /// notification per the MCP spec (server expects it before
    /// servicing `tools/*` calls).
    pub async fn initialize(&self) -> McpResult<InitializeResult> {
        let id = self.ids.next();
        let params = serde_json::json!({
            "protocolVersion": MCP_PROTOCOL_VERSION,
            "capabilities": {
                // V1 client does not advertise any client-side
                // capabilities (no sampling, no roots).
            },
            "clientInfo": {
                "name": CLIENT_NAME,
                "version": CLIENT_VERSION,
            }
        });
        let req = JsonRpcRequest::new(id, "initialize", Some(params));
        let resp = self.transport.call(req).await?;
        let value = response_result(resp)?;
        let parsed: InitializeResult = serde_json::from_value(value)
            .map_err(|e| McpError::SchemaMismatch(format!("initialize result: {e}")))?;

        // Per the MCP spec the client SHOULD send
        // `notifications/initialized` after the handshake. Best-effort
        // — a server that already considers itself ready will accept
        // either way.
        let notify = JsonRpcRequest::notification("notifications/initialized", None);
        let _ = self.transport.notify(notify).await;

        Ok(parsed)
    }

    /// List the server's tools.
    pub async fn tools_list(&self) -> McpResult<Vec<ToolDef>> {
        let id = self.ids.next();
        let req = JsonRpcRequest::new(id, "tools/list", None);
        let resp = self.transport.call(req).await?;
        let value = response_result(resp)?;
        let tools = value
            .get("tools")
            .cloned()
            .ok_or_else(|| McpError::SchemaMismatch("tools/list missing 'tools'".into()))?;
        serde_json::from_value(tools)
            .map_err(|e| McpError::SchemaMismatch(format!("tools/list 'tools': {e}")))
    }

    /// Invoke a tool.
    pub async fn tools_call(
        &self,
        name: &str,
        arguments: serde_json::Value,
    ) -> McpResult<ToolResult> {
        let id = self.ids.next();
        let params = serde_json::json!({
            "name": name,
            "arguments": arguments,
        });
        let req = JsonRpcRequest::new(id, "tools/call", Some(params));
        let resp = self.transport.call(req).await?;
        let value = response_result(resp)?;
        serde_json::from_value(value)
            .map_err(|e| McpError::SchemaMismatch(format!("tools/call result: {e}")))
    }

    /// List the server's resources.
    pub async fn resources_list(&self) -> McpResult<Vec<ResourceDef>> {
        let id = self.ids.next();
        let req = JsonRpcRequest::new(id, "resources/list", None);
        let resp = self.transport.call(req).await?;
        let value = response_result(resp)?;
        let resources = value
            .get("resources")
            .cloned()
            .ok_or_else(|| McpError::SchemaMismatch("resources/list missing 'resources'".into()))?;
        serde_json::from_value(resources)
            .map_err(|e| McpError::SchemaMismatch(format!("resources/list 'resources': {e}")))
    }

    /// Read a resource by URI.
    pub async fn resources_read(&self, uri: &str) -> McpResult<ReadResourceResult> {
        let id = self.ids.next();
        let params = serde_json::json!({ "uri": uri });
        let req = JsonRpcRequest::new(id, "resources/read", Some(params));
        let resp = self.transport.call(req).await?;
        let value = response_result(resp)?;
        serde_json::from_value(value)
            .map_err(|e| McpError::SchemaMismatch(format!("resources/read result: {e}")))
    }

    /// List the server's prompts. v1 has no caller (memo §8.4) — the
    /// method is surfaced for API completeness.
    pub async fn prompts_list(&self) -> McpResult<Vec<PromptDef>> {
        let id = self.ids.next();
        let req = JsonRpcRequest::new(id, "prompts/list", None);
        let resp = self.transport.call(req).await?;
        let value = response_result(resp)?;
        let prompts = value
            .get("prompts")
            .cloned()
            .ok_or_else(|| McpError::SchemaMismatch("prompts/list missing 'prompts'".into()))?;
        serde_json::from_value(prompts)
            .map_err(|e| McpError::SchemaMismatch(format!("prompts/list 'prompts': {e}")))
    }

    /// Fetch a prompt by name + arguments. v1 has no caller (memo
    /// §8.4) — surfaced for API completeness.
    pub async fn prompts_get(
        &self,
        name: &str,
        arguments: serde_json::Value,
    ) -> McpResult<Vec<PromptMessage>> {
        let id = self.ids.next();
        let params = serde_json::json!({
            "name": name,
            "arguments": arguments,
        });
        let req = JsonRpcRequest::new(id, "prompts/get", Some(params));
        let resp = self.transport.call(req).await?;
        let value = response_result(resp)?;
        let messages = value
            .get("messages")
            .cloned()
            .ok_or_else(|| McpError::SchemaMismatch("prompts/get missing 'messages'".into()))?;
        let arr: Vec<serde_json::Value> = serde_json::from_value(messages)
            .map_err(|e| McpError::SchemaMismatch(format!("prompts/get 'messages': {e}")))?;
        Ok(arr.into_iter().map(PromptMessage).collect())
    }

    /// Close the underlying transport. After close every further
    /// call returns [`McpError::Closed`].
    pub async fn close(&self) {
        self.transport.close().await;
    }
}

impl<T: McpTransport + ?Sized> Clone for McpClient<T> {
    fn clone(&self) -> Self {
        Self {
            transport: Arc::clone(&self.transport),
            ids: Arc::clone(&self.ids),
        }
    }
}

/// Sync wrapper. Holds a tokio current-thread runtime so callers
/// without an outer runtime can block on calls. Construction does
/// **not** spawn a thread — every `*_blocking` call drives the
/// runtime inline.
pub struct BlockingMcpClient<T: McpTransport + 'static> {
    inner: McpClient<T>,
    runtime: tokio::runtime::Runtime,
}

impl<T: McpTransport + 'static> BlockingMcpClient<T> {
    /// Wrap an async [`McpClient`] in a blocking adapter.
    ///
    /// # Errors
    /// - [`McpError::Io`] if the tokio current-thread runtime cannot
    ///   be built (extremely rare — would mean the process is OOM).
    pub fn new(inner: McpClient<T>) -> McpResult<Self> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(McpError::Io)?;
        Ok(Self { inner, runtime })
    }

    /// Synchronous `initialize`.
    pub fn initialize(&self) -> McpResult<InitializeResult> {
        self.runtime.block_on(self.inner.initialize())
    }

    /// Synchronous `tools/list`.
    pub fn tools_list(&self) -> McpResult<Vec<ToolDef>> {
        self.runtime.block_on(self.inner.tools_list())
    }

    /// Synchronous `tools/call`.
    pub fn tools_call(&self, name: &str, arguments: serde_json::Value) -> McpResult<ToolResult> {
        self.runtime
            .block_on(self.inner.tools_call(name, arguments))
    }

    /// Synchronous `resources/list`.
    pub fn resources_list(&self) -> McpResult<Vec<ResourceDef>> {
        self.runtime.block_on(self.inner.resources_list())
    }

    /// Synchronous `resources/read`.
    pub fn resources_read(&self, uri: &str) -> McpResult<ReadResourceResult> {
        self.runtime.block_on(self.inner.resources_read(uri))
    }

    /// Synchronous `prompts/list`.
    pub fn prompts_list(&self) -> McpResult<Vec<PromptDef>> {
        self.runtime.block_on(self.inner.prompts_list())
    }

    /// Synchronous `prompts/get`.
    pub fn prompts_get(
        &self,
        name: &str,
        arguments: serde_json::Value,
    ) -> McpResult<Vec<PromptMessage>> {
        self.runtime
            .block_on(self.inner.prompts_get(name, arguments))
    }

    /// Synchronous close.
    pub fn close(&self) {
        self.runtime.block_on(self.inner.close());
    }
}

/// Unwrap a JSON-RPC `result` from a response, mapping `error` and
/// missing result into the right [`McpError`] variants.
fn response_result(resp: JsonRpcResponse) -> McpResult<serde_json::Value> {
    if let Some(err) = resp.error {
        return Err(McpError::Rpc(err));
    }
    // Successful response: id must round-trip; we tolerate any id
    // shape since the transport already matched on key().
    if matches!(resp.id, JsonRpcId::Null) {
        // A null id on a success response is technically out-of-spec
        // (a request had a non-null id, the response should echo it).
        // Treat as schema mismatch so the aggregator can mark the
        // server unhealthy.
        return Err(McpError::SchemaMismatch(
            "response id was null on a success response".into(),
        ));
    }
    resp.result.ok_or_else(|| {
        McpError::SchemaMismatch("response missing both 'result' and 'error'".into())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use std::sync::Mutex;

    /// In-memory transport that returns canned responses keyed by
    /// JSON-RPC method.
    struct StubTransport {
        responses: Mutex<std::collections::HashMap<String, serde_json::Value>>,
        errors: Mutex<std::collections::HashMap<String, crate::jsonrpc::JsonRpcError>>,
        calls: Mutex<Vec<(String, Option<serde_json::Value>)>>,
        notifications: Mutex<Vec<(String, Option<serde_json::Value>)>>,
    }

    impl StubTransport {
        fn new() -> Self {
            Self {
                responses: Mutex::new(std::collections::HashMap::new()),
                errors: Mutex::new(std::collections::HashMap::new()),
                calls: Mutex::new(Vec::new()),
                notifications: Mutex::new(Vec::new()),
            }
        }
        fn set_response(&self, method: &str, value: serde_json::Value) {
            self.responses
                .lock()
                .unwrap()
                .insert(method.to_owned(), value);
        }
        fn set_error(&self, method: &str, err: crate::jsonrpc::JsonRpcError) {
            self.errors.lock().unwrap().insert(method.to_owned(), err);
        }
    }

    #[async_trait]
    impl McpTransport for StubTransport {
        async fn call(&self, request: JsonRpcRequest) -> McpResult<JsonRpcResponse> {
            self.calls
                .lock()
                .unwrap()
                .push((request.method.clone(), request.params.clone()));
            let id = request.id.clone().unwrap_or(JsonRpcId::Null);
            if let Some(err) = self.errors.lock().unwrap().get(&request.method).cloned() {
                return Ok(JsonRpcResponse {
                    jsonrpc: "2.0".into(),
                    id,
                    result: None,
                    error: Some(err),
                });
            }
            let val = self
                .responses
                .lock()
                .unwrap()
                .get(&request.method)
                .cloned()
                .unwrap_or(serde_json::json!({}));
            Ok(JsonRpcResponse {
                jsonrpc: "2.0".into(),
                id,
                result: Some(val),
                error: None,
            })
        }
        async fn notify(&self, n: JsonRpcRequest) -> McpResult<()> {
            self.notifications
                .lock()
                .unwrap()
                .push((n.method, n.params));
            Ok(())
        }
        async fn close(&self) {}
    }

    #[tokio::test]
    async fn initialize_round_trips() {
        let stub = Arc::new(StubTransport::new());
        stub.set_response(
            "initialize",
            serde_json::json!({
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "stub", "version": "0.0.0"}
            }),
        );
        let client = McpClient::new(stub.clone());
        let info = client.initialize().await.expect("initialize ok");
        assert_eq!(info.server_info.name, "stub");
        assert!(info.capabilities.supports_tools());
        // notifications/initialized went through.
        let notifs = stub.notifications.lock().unwrap();
        assert_eq!(notifs.len(), 1);
        assert_eq!(notifs[0].0, "notifications/initialized");
    }

    #[tokio::test]
    async fn tools_list_returns_tools() {
        let stub = Arc::new(StubTransport::new());
        stub.set_response(
            "tools/list",
            serde_json::json!({
                "tools": [
                    {"name": "echo", "description": "echoes"},
                    {"name": "ping"}
                ]
            }),
        );
        let client = McpClient::new(stub);
        let tools = client.tools_list().await.expect("ok");
        assert_eq!(tools.len(), 2);
        assert_eq!(tools[0].name, "echo");
    }

    #[tokio::test]
    async fn tools_call_returns_tool_result() {
        let stub = Arc::new(StubTransport::new());
        stub.set_response(
            "tools/call",
            serde_json::json!({
                "content": [{"type": "text", "text": "hello"}],
                "isError": false
            }),
        );
        let client = McpClient::new(stub);
        let result = client
            .tools_call("echo", serde_json::json!({"msg": "hi"}))
            .await
            .expect("ok");
        assert_eq!(result.text_content(), "hello");
        assert!(!result.is_error);
    }

    #[tokio::test]
    async fn rpc_error_surfaces_as_mcp_error() {
        let stub = Arc::new(StubTransport::new());
        stub.set_error(
            "tools/call",
            crate::jsonrpc::JsonRpcError {
                code: crate::jsonrpc::METHOD_NOT_FOUND,
                message: "unknown tool".into(),
                data: None,
            },
        );
        let client = McpClient::new(stub);
        let err = client
            .tools_call("nope", serde_json::json!({}))
            .await
            .expect_err("expected rpc err");
        match err {
            McpError::Rpc(e) => assert_eq!(e.code, crate::jsonrpc::METHOD_NOT_FOUND),
            other => panic!("wrong variant: {other:?}"),
        }
    }

    #[tokio::test]
    async fn schema_mismatch_when_tools_list_missing_tools_field() {
        let stub = Arc::new(StubTransport::new());
        stub.set_response("tools/list", serde_json::json!({"wrong": "shape"}));
        let client = McpClient::new(stub);
        let err = client.tools_list().await.expect_err("schema mismatch");
        assert!(matches!(err, McpError::SchemaMismatch(_)));
    }

    #[tokio::test]
    async fn resources_read_round_trips() {
        let stub = Arc::new(StubTransport::new());
        stub.set_response(
            "resources/read",
            serde_json::json!({
                "contents": [
                    {"uri": "file:///a.txt", "text": "hi", "mimeType": "text/plain"}
                ]
            }),
        );
        let client = McpClient::new(stub);
        let result = client.resources_read("file:///a.txt").await.expect("ok");
        assert_eq!(result.contents.len(), 1);
        assert_eq!(result.contents[0].text.as_deref(), Some("hi"));
    }
}
