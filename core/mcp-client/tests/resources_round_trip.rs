//! V2-MCP-3 stub-server extension test: exercises the
//! `resources/list` + `resources/read` handlers that V2-MCP-3 added
//! to `tests/stub_server.rs`. Drives the new wire shape end-to-end
//! through `HttpSseTransport` + `McpClient` so a regression in either
//! the stub or the client trips a failure inside this crate's tests.
//!
//! The V2-MCP-3 aggregator integration tests live in
//! `apps/agent/tests/mcp_aggregator_wiring.rs` (cross-crate); these
//! tests stay inside `mci-mcp-client` so the V2-MCP-2 transport +
//! V2-MCP-3 stub extension are validated together without the agent
//! crate's brain dependency.

mod stub_server;

use std::sync::Arc;

use mci_mcp_client::{HttpSseTransport, LoopbackHost, McpClient, McpTransport};

use stub_server::{StubMcpServer, StubResource};

#[tokio::test]
async fn resources_list_and_read_round_trip() {
    let server = StubMcpServer::start().await;
    server
        .set_resources(vec![
            StubResource::new("notion://page/a", "Plan", "the body of plan"),
            StubResource::new("notion://page/b", "Notes", "the body of notes"),
        ])
        .await;

    let sse_url = format!("http://127.0.0.1:{}/sse", server.port());
    let host = LoopbackHost::parse(&sse_url).await.unwrap();
    let transport = HttpSseTransport::connect(host, None).await.unwrap();
    let client: McpClient<dyn McpTransport> =
        McpClient::<dyn McpTransport>::from_dyn(Arc::new(transport));
    let _init = client.initialize().await.expect("initialize ok");

    let resources = client.resources_list().await.expect("resources/list ok");
    assert_eq!(resources.len(), 2);
    let uris: Vec<&str> = resources.iter().map(|r| r.uri.as_str()).collect();
    assert!(uris.contains(&"notion://page/a"));
    assert!(uris.contains(&"notion://page/b"));

    let read_a = client
        .resources_read("notion://page/a")
        .await
        .expect("read a ok");
    assert_eq!(read_a.contents.len(), 1);
    assert_eq!(read_a.contents[0].text.as_deref(), Some("the body of plan"));
    assert_eq!(read_a.contents[0].uri, "notion://page/a");

    let read_b = client
        .resources_read("notion://page/b")
        .await
        .expect("read b ok");
    assert_eq!(read_b.contents[0].text.as_deref(), Some("the body of notes"));

    client.close().await;
    server.shutdown().await;
}

#[tokio::test]
async fn set_tools_overrides_default_catalog() {
    let server = StubMcpServer::start().await;
    server
        .set_tools(vec![
            ("custom_tool".to_owned(), Some("does a thing".to_owned())),
        ])
        .await;
    let sse_url = format!("http://127.0.0.1:{}/sse", server.port());
    let host = LoopbackHost::parse(&sse_url).await.unwrap();
    let transport = HttpSseTransport::connect(host, None).await.unwrap();
    let client = McpClient::<dyn McpTransport>::from_dyn(Arc::new(transport));
    let _init = client.initialize().await.expect("initialize ok");

    let tools = client.tools_list().await.expect("tools/list ok");
    assert_eq!(tools.len(), 1);
    assert_eq!(tools[0].name, "custom_tool");
    assert_eq!(tools[0].description.as_deref(), Some("does a thing"));

    client.close().await;
    server.shutdown().await;
}

#[tokio::test]
async fn resources_list_empty_when_none_registered() {
    let server = StubMcpServer::start().await;
    // Do not call set_resources — default is empty.
    let sse_url = format!("http://127.0.0.1:{}/sse", server.port());
    let host = LoopbackHost::parse(&sse_url).await.unwrap();
    let transport = HttpSseTransport::connect(host, None).await.unwrap();
    let client = McpClient::<dyn McpTransport>::from_dyn(Arc::new(transport));
    let _init = client.initialize().await.expect("initialize ok");

    let resources = client.resources_list().await.expect("ok");
    assert!(resources.is_empty(), "no resources expected; got {resources:?}");

    client.close().await;
    server.shutdown().await;
}
