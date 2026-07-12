//! Minimal HTTP+SSE MCP server stub. Just enough wire to exercise
//! the V2-MCP-2 transport's handshake + tool call paths.
//!
//! Wire shape (per the 2024-11-05 MCP HTTP+SSE transport spec):
//!
//! - `GET /sse` returns `text/event-stream` immediately and emits:
//!     1. `event: endpoint\ndata: /messages\n\n`
//!     2. For every POST: a `message`-typed event with the JSON-RPC
//!        response body.
//! - `POST /messages` accepts a JSON-RPC body, replies `202 Accepted`
//!   with empty body, and pushes the response onto the SSE event
//!   stream.
//!
//! Bind to `127.0.0.1:0` so the OS picks an ephemeral port and
//! parallel test runs do not collide.

#![allow(dead_code)] // Each integration test only uses a subset.

use std::collections::HashMap;
use std::convert::Infallible;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use bytes::Bytes;
use http::{Method, Request, Response, StatusCode};
use http_body_util::BodyExt;
use hyper::body::{Body, Frame, Incoming};
use hyper::service::Service;
use hyper_util::rt::TokioIo;
use tokio::net::TcpListener;
use tokio::sync::{mpsc, Mutex};
use tokio::task::JoinHandle;

/// One stub resource the server advertises. V2-MCP-3 integration
/// tests register a set of these so a single stub can drive both the
/// "small body → materialize" and "large body → catalog" branches.
#[derive(Debug, Clone)]
pub struct StubResource {
    /// `resources/list` URI.
    pub uri: String,
    /// `resources/list` name (becomes `Event.window_title`).
    pub name: String,
    /// `resources/list` mime type.
    pub mime: String,
    /// `resources/read` body. Length drives the materialize-or-catalog
    /// branch in V2-MCP-3.
    pub body: String,
}

impl StubResource {
    /// Convenience: build a minimal text resource.
    #[must_use]
    pub fn new(uri: &str, name: &str, body: &str) -> Self {
        Self {
            uri: uri.to_owned(),
            name: name.to_owned(),
            mime: "text/plain".to_owned(),
            body: body.to_owned(),
        }
    }
}

/// Server-wide stub configuration. Mutable across the server's
/// lifetime via [`StubMcpServer::set_resources`] / [`StubMcpServer::set_tools`].
#[derive(Debug, Default, Clone)]
struct StubConfig {
    resources: Vec<StubResource>,
    tools: Vec<(String, Option<String>)>,
}

/// One running stub server bound to a 127.0.0.1 ephemeral port.
pub struct StubMcpServer {
    port: u16,
    auth_headers: Arc<Mutex<Vec<String>>>,
    config: Arc<Mutex<StubConfig>>,
    shutdown_tx: Option<mpsc::Sender<()>>,
    task: Option<JoinHandle<()>>,
}

impl StubMcpServer {
    /// Start a normal stub server with instant responses.
    pub async fn start() -> Self {
        Self::start_inner(None).await
    }

    /// Start a stub that delays responses by `delay`. Used by the
    /// timeout test to confirm the per-call timer fires.
    pub async fn start_slow(delay: Duration) -> Self {
        Self::start_inner(Some(delay)).await
    }

    async fn start_inner(delay: Option<Duration>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let port = listener.local_addr().expect("local_addr").port();
        let auth_headers = Arc::new(Mutex::new(Vec::<String>::new()));
        // Shared SSE-sender pool. Lifted to server-wide state because
        // hyper's client may open separate TCP connections for the
        // long-lived GET /sse and the per-call POST /messages — both
        // need to find the same senders list.
        let sse_senders = Arc::new(Mutex::new(Vec::<mpsc::Sender<String>>::new()));
        let config = Arc::new(Mutex::new(StubConfig::default()));
        let (shutdown_tx, mut shutdown_rx) = mpsc::channel::<()>(1);
        let auth_clone = Arc::clone(&auth_headers);
        let sse_clone = Arc::clone(&sse_senders);
        let cfg_clone = Arc::clone(&config);

        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = shutdown_rx.recv() => return,
                    accepted = listener.accept() => {
                        let (sock, _) = match accepted {
                            Ok(v) => v,
                            Err(_) => continue,
                        };
                        let auth = Arc::clone(&auth_clone);
                        let senders = Arc::clone(&sse_clone);
                        let cfg = Arc::clone(&cfg_clone);
                        let conn_delay = delay;
                        tokio::spawn(async move {
                            let svc = StubService::new(senders, auth, cfg, conn_delay);
                            let _ = hyper::server::conn::http1::Builder::new()
                                .keep_alive(true)
                                .serve_connection(TokioIo::new(sock), svc)
                                .await;
                        });
                    }
                }
            }
        });

        Self {
            port,
            auth_headers,
            config,
            shutdown_tx: Some(shutdown_tx),
            task: Some(task),
        }
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// Register the resource set advertised by `resources/list` +
    /// served by `resources/read`. Overrides any prior set.
    pub async fn set_resources(&self, resources: Vec<StubResource>) {
        let mut c = self.config.lock().await;
        c.resources = resources;
    }

    /// Register the tool catalog advertised by `tools/list`. Each
    /// pair is `(name, optional_description)`. Overrides any prior
    /// set; default is two tools (`echo` + `ping`) so the V2-MCP-2
    /// integration tests keep passing without explicit setup.
    pub async fn set_tools(&self, tools: Vec<(String, Option<String>)>) {
        let mut c = self.config.lock().await;
        c.tools = tools;
    }

    /// Snapshot the Authorization header values the stub recorded
    /// across every POST.
    pub async fn auth_headers_seen(&self) -> Vec<String> {
        self.auth_headers.lock().await.clone()
    }

    pub async fn shutdown(mut self) {
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.send(()).await;
        }
        if let Some(t) = self.task.take() {
            t.abort();
            let _ = t.await;
        }
    }
}

/// Per-connection state. The senders list is server-wide so that a
/// GET /sse on connection A and a POST /messages on connection B
/// rendezvous on the same set of streams.
#[derive(Clone)]
struct StubService {
    sse_senders: Arc<Mutex<Vec<mpsc::Sender<String>>>>,
    auth_headers: Arc<Mutex<Vec<String>>>,
    config: Arc<Mutex<StubConfig>>,
    delay: Option<Duration>,
}

impl StubService {
    fn new(
        sse_senders: Arc<Mutex<Vec<mpsc::Sender<String>>>>,
        auth_headers: Arc<Mutex<Vec<String>>>,
        config: Arc<Mutex<StubConfig>>,
        delay: Option<Duration>,
    ) -> Self {
        Self {
            sse_senders,
            auth_headers,
            config,
            delay,
        }
    }
}

impl Service<Request<Incoming>> for StubService {
    type Response = Response<StubBody>;
    type Error = Infallible;
    type Future = Pin<
        Box<dyn std::future::Future<Output = Result<Self::Response, Self::Error>> + Send + 'static>,
    >;

    fn call(&self, req: Request<Incoming>) -> Self::Future {
        let svc = self.clone();
        Box::pin(async move { Ok(svc.dispatch(req).await) })
    }
}

impl StubService {
    async fn dispatch(self, req: Request<Incoming>) -> Response<StubBody> {
        match (req.method(), req.uri().path()) {
            (&Method::GET, "/sse") => self.handle_sse().await,
            (&Method::POST, "/messages") => self.handle_message(req).await,
            _ => Response::builder()
                .status(StatusCode::NOT_FOUND)
                .body(StubBody::empty())
                .unwrap(),
        }
    }

    async fn handle_sse(self) -> Response<StubBody> {
        let (tx, rx) = mpsc::channel::<String>(32);
        self.sse_senders.lock().await.push(tx.clone());
        // First event: endpoint negotiation.
        let _ = tx
            .send("event: endpoint\ndata: /messages\n\n".to_owned())
            .await;
        let body = StubBody::sse(rx);
        Response::builder()
            .status(StatusCode::OK)
            .header(http::header::CONTENT_TYPE, "text/event-stream")
            .header(http::header::CACHE_CONTROL, "no-cache")
            .body(body)
            .unwrap()
    }

    async fn handle_message(self, req: Request<Incoming>) -> Response<StubBody> {
        if let Some(auth) = req.headers().get(http::header::AUTHORIZATION) {
            if let Ok(s) = auth.to_str() {
                self.auth_headers.lock().await.push(s.to_owned());
            }
        }
        let body_bytes = match req.into_body().collect().await {
            Ok(b) => b.to_bytes(),
            Err(_) => return Self::bad_request(),
        };
        let req_json: serde_json::Value = match serde_json::from_slice(&body_bytes) {
            Ok(v) => v,
            Err(_) => return Self::bad_request(),
        };
        let cfg = self.config.lock().await.clone();
        let response = build_response(&req_json, &cfg);
        // Notifications (no id) get no response.
        if let Some(resp) = response {
            let frame = format!("event: message\ndata: {resp}\n\n");
            // Send to every live SSE GET connection. Tests use ONE
            // connection at a time, but a faulty test could open
            // multiple — we send to all of them.
            if let Some(delay) = self.delay {
                let senders: Vec<_> = self.sse_senders.lock().await.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(delay).await;
                    for tx in senders {
                        let _ = tx.send(frame.clone()).await;
                    }
                });
            } else {
                for tx in self.sse_senders.lock().await.iter() {
                    let _ = tx.send(frame.clone()).await;
                }
            }
        }
        Response::builder()
            .status(StatusCode::ACCEPTED)
            .body(StubBody::empty())
            .unwrap()
    }

    fn bad_request() -> Response<StubBody> {
        Response::builder()
            .status(StatusCode::BAD_REQUEST)
            .body(StubBody::empty())
            .unwrap()
    }
}

fn build_response(req: &serde_json::Value, cfg: &StubConfig) -> Option<String> {
    let method = req.get("method")?.as_str()?;
    let id = req.get("id").cloned();
    if id.is_none() {
        // Notification — no response.
        return None;
    }
    let result = match method {
        "initialize" => serde_json::json!({
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}, "resources": {}},
            "serverInfo": {"name": "stub-mcp", "version": "0.0.1"}
        }),
        "tools/list" => {
            // Default catalog preserves the V2-MCP-2 integration test
            // expectations (echo + ping) for any call site that did
            // not invoke `set_tools`.
            let tools: Vec<serde_json::Value> = if cfg.tools.is_empty() {
                vec![
                    serde_json::json!({"name": "echo", "description": "echoes back"}),
                    serde_json::json!({"name": "ping"}),
                ]
            } else {
                cfg.tools
                    .iter()
                    .map(|(name, desc)| match desc {
                        Some(d) => serde_json::json!({"name": name, "description": d}),
                        None => serde_json::json!({"name": name}),
                    })
                    .collect()
            };
            serde_json::json!({ "tools": tools })
        }
        "tools/call" => {
            let params = req.get("params").cloned().unwrap_or_default();
            let args = params
                .get("arguments")
                .cloned()
                .unwrap_or(serde_json::Value::Null);
            let msg = args
                .get("msg")
                .and_then(|v| v.as_str())
                .unwrap_or("default")
                .to_owned();
            serde_json::json!({
                "content": [{"type": "text", "text": msg}],
                "isError": false
            })
        }
        "resources/list" => {
            // V2-MCP-3 surface: serve the configured resource list.
            let resources: Vec<serde_json::Value> = cfg
                .resources
                .iter()
                .map(|r| {
                    serde_json::json!({
                        "uri": r.uri,
                        "name": r.name,
                        "mimeType": r.mime,
                    })
                })
                .collect();
            serde_json::json!({ "resources": resources })
        }
        "resources/read" => {
            let params = req.get("params").cloned().unwrap_or_default();
            let uri = params
                .get("uri")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_owned();
            let body = cfg.resources.iter().find(|r| r.uri == uri).map_or_else(
                || (String::new(), "text/plain".to_owned()),
                |r| (r.body.clone(), r.mime.clone()),
            );
            serde_json::json!({
                "contents": [
                    {
                        "uri": uri,
                        "text": body.0,
                        "mimeType": body.1,
                    }
                ]
            })
        }
        _ => serde_json::json!({}),
    };
    Some(
        serde_json::json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        })
        .to_string(),
    )
}

/// One-shot hyper body for the stub server. Either holds an SSE
/// `mpsc::Receiver` for streaming text events or a single `Bytes`
/// buffer.
pub enum StubBody {
    Sse(mpsc::Receiver<String>),
    Once(Option<Bytes>),
}

impl StubBody {
    fn empty() -> Self {
        Self::Once(None)
    }

    fn sse(rx: mpsc::Receiver<String>) -> Self {
        Self::Sse(rx)
    }
}

impl Body for StubBody {
    type Data = Bytes;
    type Error = Infallible;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        match &mut *self {
            StubBody::Sse(rx) => match rx.poll_recv(cx) {
                Poll::Ready(Some(s)) => Poll::Ready(Some(Ok(Frame::data(Bytes::from(s))))),
                Poll::Ready(None) => Poll::Ready(None),
                Poll::Pending => Poll::Pending,
            },
            StubBody::Once(slot) => match slot.take() {
                Some(b) => Poll::Ready(Some(Ok(Frame::data(b)))),
                None => Poll::Ready(None),
            },
        }
    }
}

// Silence the "fields never read" warnings when only one test pulls
// from this module — every field IS used by at least one test, but
// rust-analyzer's per-test conditional compilation produces warnings.
#[allow(dead_code)]
fn _unused_marker(_: HashMap<String, String>) {}
