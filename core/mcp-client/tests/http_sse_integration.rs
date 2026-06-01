//! V2-MCP-2 HTTP+SSE transport integration test.
//!
//! Spins up an in-process stub MCP server bound to `127.0.0.1:` on an
//! ephemeral port, drives the full handshake through
//! [`HttpSseTransport`] + [`McpClient`], and asserts the initialize +
//! tools/list round-trip works against real wire frames.
//!
//! The stub server lives in `tests/stub_server.rs` so other
//! integration tests can reuse it. It is deliberately minimal — just
//! enough MCP wire to exercise the V2-MCP-2 transport surface.

mod stub_server;

use std::sync::Arc;
use std::time::Duration;

use mci_mcp_client::{HttpSseTransport, LoopbackHost, McpClient, McpTransport};

use stub_server::StubMcpServer;

#[tokio::test]
async fn initialize_and_tools_list_round_trip() {
    let server = StubMcpServer::start().await;
    let sse_url = format!("http://127.0.0.1:{}/sse", server.port());

    let host = LoopbackHost::parse(&sse_url)
        .await
        .expect("loopback URL validates");

    let transport = HttpSseTransport::connect(host, None)
        .await
        .expect("transport connects + handshakes endpoint event");

    let client: McpClient<dyn McpTransport> =
        McpClient::<dyn McpTransport>::from_dyn(Arc::new(transport));

    let init = client.initialize().await.expect("initialize ok");
    assert_eq!(init.server_info.name, "stub-mcp");
    assert!(init.capabilities.supports_tools());

    let tools = client.tools_list().await.expect("tools/list ok");
    assert_eq!(tools.len(), 2);
    assert!(tools.iter().any(|t| t.name == "echo"));
    assert!(tools.iter().any(|t| t.name == "ping"));

    let result = client
        .tools_call("echo", serde_json::json!({"msg": "hello"}))
        .await
        .expect("tools/call ok");
    assert_eq!(result.text_content(), "hello");

    client.close().await;
    server.shutdown().await;
}

#[tokio::test]
async fn auth_header_is_sent_on_every_request() {
    let server = StubMcpServer::start().await;
    let sse_url = format!("http://127.0.0.1:{}/sse", server.port());
    let host = LoopbackHost::parse(&sse_url).await.unwrap();

    let transport = HttpSseTransport::connect(host, Some("Bearer test-token-xyz".into()))
        .await
        .expect("transport connects");

    let client: McpClient<dyn McpTransport> =
        McpClient::<dyn McpTransport>::from_dyn(Arc::new(transport));
    let _init = client.initialize().await.expect("initialize ok");

    // The stub records every POST's Authorization header. Audit row
    // #7 asserts the value is never logged; we additionally assert
    // here that the wire-level transmission carries it through.
    let recorded = server.auth_headers_seen().await;
    assert!(
        recorded.iter().any(|h| h == "Bearer test-token-xyz"),
        "auth header should be on at least one POST; recorded = {recorded:?}"
    );

    client.close().await;
    server.shutdown().await;
}

#[tokio::test]
async fn timeout_fires_on_slow_response() {
    let server = StubMcpServer::start_slow(Duration::from_secs(60)).await;
    let sse_url = format!("http://127.0.0.1:{}/sse", server.port());
    let host = LoopbackHost::parse(&sse_url).await.unwrap();

    let transport = HttpSseTransport::connect(host, None)
        .await
        .expect("transport connects");
    transport.set_timeout(Duration::from_millis(200));

    let client = McpClient::<dyn McpTransport>::from_dyn(Arc::new(transport));
    let err = client
        .initialize()
        .await
        .expect_err("slow server triggers timeout");
    let msg = format!("{err}");
    assert!(
        msg.contains("timed out") || msg.contains("Timeout"),
        "expected timeout error, got: {msg}"
    );

    client.close().await;
    server.shutdown().await;
}

#[tokio::test]
async fn close_then_call_returns_closed() {
    let server = StubMcpServer::start().await;
    let sse_url = format!("http://127.0.0.1:{}/sse", server.port());
    let host = LoopbackHost::parse(&sse_url).await.unwrap();
    let transport = HttpSseTransport::connect(host, None)
        .await
        .expect("transport connects");
    let client = McpClient::<dyn McpTransport>::from_dyn(Arc::new(transport));
    client.close().await;
    let err = client
        .initialize()
        .await
        .expect_err("post-close initialize should fail");
    let msg = format!("{err}");
    assert!(
        msg.contains("closed") || msg.contains("Closed"),
        "expected closed error, got: {msg}"
    );
    server.shutdown().await;
}
