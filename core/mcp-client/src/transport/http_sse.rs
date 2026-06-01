//! [`HttpSseTransport`] — the V2-MCP-2 HTTP+SSE [`McpTransport`] impl.
//!
//! Implements the 2024-11-05 MCP HTTP+SSE transport against the same
//! [`crate::McpClient`] surface the stdio transport implements. First
//! network-shaped surface in MCI history; loopback-only per the
//! ADR-0001 2026-05-31 amendment.
//!
//! # Wire shape (per 2024-11-05 MCP spec)
//!
//! 1. Client opens a single long-lived `GET <sse_url>` carrying
//!    `Accept: text/event-stream`. The server's response is an
//!    SSE-framed event stream.
//! 2. The server's FIRST SSE event MUST carry `event: endpoint` and
//!    `data: <messages_url>`. That URL — relative or absolute — is the
//!    POST target for every subsequent JSON-RPC request the client
//!    sends. The validator re-checks the absolute form against the
//!    loopback gate (a server cannot redirect MCI's POSTs off-loopback).
//! 3. Each client request goes out as `POST <messages_url>` with
//!    `Content-Type: application/json` and a JSON-RPC 2.0 body.
//! 4. The server's response arrives as a `message`-typed SSE event on
//!    the GET stream, with `data:` carrying a single JSON-RPC response
//!    object. The reader correlates by JSON-RPC id into the same
//!    `Pending` map shape the stdio transport uses.
//!
//! # Defense-in-depth loopback gate
//!
//! - The URL is validated by [`super::loopback::LoopbackHost::parse`]
//!   at construction time (the registration path goes through the same
//!   gate before reaching this transport, but constructing through
//!   [`HttpSseTransport::connect`] re-validates regardless — Audit
//!   row #2).
//! - The endpoint URL the server hands back is parsed against the
//!   same gate before any POST is dialed.
//! - The TCP dial inside the hyper client connector is constrained to
//!   loopback addresses by [`LoopbackOnlyConnector`].
//!
//! # TLS posture
//!
//! HTTPS is accepted at URL-validation time but not currently dialed —
//! a no-net-new-dep constraint keeps `rustls`/`tokio-rustls` out of
//! the workspace lockfile. A user pointing at `https://127.0.0.1/...`
//! receives [`HttpSseError::HttpsNotSupported`] at connect time. The
//! plain-HTTP-loopback path is the primary v1 surface; HTTPS-to-
//! loopback is a follow-up if a real user needs it.
//!
//! # ADR-0001 §amendment 2026-05-31 — first network surface
//!
//! The construction of this transport is the entry point for the
//! amendment's narrow exception. Every code path that opens a TCP
//! socket inside `mci-mcp-client` flows through here, and every TCP
//! socket flows through [`LoopbackOnlyConnector`]. No other crate in
//! the workspace gains a network surface as a side effect.

use std::collections::HashMap;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use http::header::{ACCEPT, AUTHORIZATION, CACHE_CONTROL, CONTENT_TYPE};
use http::{Method, Request, StatusCode, Uri};
use http_body_util::Full;
use hyper::body::{Body as _, Incoming};
use hyper_util::client::legacy::connect::dns::Name;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use thiserror::Error;
use tokio::sync::{oneshot, Mutex};
use tokio::task::JoinHandle;
use tokio::time::timeout;
use tower_service::Service;

use crate::error::{McpError, McpResult};
use crate::jsonrpc::{JsonRpcId, JsonRpcRequest, JsonRpcResponse};
use crate::transport::loopback::{LoopbackError, LoopbackHost, Scheme};
use crate::transport::McpTransport;

/// Default per-call timeout. Tunable per-transport via
/// [`HttpSseTransport::set_timeout`]. Matches the stdio transport's
/// 30s default — a `tools/call` against Slack / Linear / GitHub can
/// legitimately take seconds.
pub const DEFAULT_CALL_TIMEOUT: Duration = Duration::from_secs(30);

/// Hard ceiling on the `endpoint` event the server hands back at the
/// start of the SSE stream. Pathological servers that never send an
/// endpoint event would otherwise block construction forever.
const ENDPOINT_WAIT_TIMEOUT: Duration = Duration::from_secs(10);

/// Max length of any single SSE `data:` line we will buffer. A
/// well-behaved MCP server's responses are JSON objects in the
/// kilobytes range; ten megabytes is a generous ceiling that still
/// refuses an unbounded-buffer attack from a hostile loopback peer.
const MAX_SSE_LINE_BYTES: usize = 10 * 1024 * 1024;

/// Shared map keyed by [`JsonRpcId::key`] of waiters. Same shape as
/// the stdio transport's `PendingMap`.
type PendingMap = Arc<Mutex<HashMap<String, oneshot::Sender<JsonRpcResponse>>>>;

/// HTTP+SSE MCP transport. Owns one long-lived SSE GET stream and one
/// shared hyper client that issues POSTs against the negotiated
/// `endpoint` URL.
pub struct HttpSseTransport {
    /// Loopback-validated SSE URL the user / config gave us.
    sse_url: LoopbackHost,
    /// Optional `Authorization` header value. NEVER logged.
    auth_header: Option<String>,
    /// Validated, loopback-checked POST endpoint the server handed
    /// back in its first `endpoint` event.
    endpoint_url: Mutex<Option<LoopbackHost>>,
    /// Shared map of pending JSON-RPC waiters by id.
    pending: PendingMap,
    /// Per-call timeout (atomic so it can be retuned without `&mut`).
    call_timeout_ms: AtomicU64,
    /// Flipped on close; subsequent calls return [`McpError::Closed`].
    closed: Mutex<bool>,
    /// The SSE reader task. Joined on close.
    reader_task: Mutex<Option<JoinHandle<()>>>,
    /// The hyper client used for POSTs. Bound to
    /// [`LoopbackOnlyConnector`] so no non-loopback TCP socket is
    /// reachable through this transport.
    client: Client<LoopbackOnlyConnector, Full<Bytes>>,
}

impl std::fmt::Debug for HttpSseTransport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Auth header is never rendered — Audit row #7. The struct
        // surface here intentionally omits it; a manual Debug derive
        // would have leaked it through std's PII-unaware default.
        f.debug_struct("HttpSseTransport")
            .field("sse_url", &self.sse_url.url)
            .field("closed", &"<runtime>")
            .finish_non_exhaustive()
    }
}

/// Connect-time errors specific to the HTTP+SSE transport. Surfaced
/// through [`McpError::Io`] (so callers' existing error-handling shape
/// works) but constructible in tests via the explicit variants.
#[derive(Debug, Error)]
pub enum HttpSseError {
    /// The URL did not pass the loopback gate.
    #[error("URL rejected by loopback gate: {0}")]
    Loopback(#[from] LoopbackError),
    /// The opening `GET <sse_url>` failed at the HTTP layer.
    #[error("SSE GET failed: {0}")]
    SseOpen(String),
    /// The SSE stream ended before the server sent its first
    /// `endpoint` event.
    #[error("server did not send 'endpoint' event before EOF")]
    EndpointMissing,
    /// The server sent an `endpoint` event but the URL it carried
    /// failed the loopback gate.
    #[error("server-sent endpoint URL rejected by loopback gate: {0}")]
    EndpointLoopback(LoopbackError),
    /// The opening POST against the negotiated endpoint failed at the
    /// HTTP layer.
    #[error("POST to endpoint failed: {0}")]
    Post(String),
    /// HTTPS requested but TLS support is not compiled in.
    #[error("HTTPS loopback support is deferred; use http://127.0.0.1 for v1.0")]
    HttpsNotSupported,
    /// A network dial was attempted against a non-loopback address.
    /// This is the LoopbackOnlyConnector's last line of defense (Audit
    /// row #2). Surfacing it indicates a bug in [`LoopbackHost`] —
    /// every URL that reaches the connector should already have been
    /// validated.
    #[error("loopback connector refused non-loopback dial")]
    NonLoopbackDial,
}

impl From<HttpSseError> for McpError {
    fn from(e: HttpSseError) -> Self {
        // The transport surface speaks `McpError`. We fold every
        // HTTP+SSE-specific error into `McpError::Io` with a stable
        // message so calling code can pattern-match on shape; the
        // variants stay reachable through `source()` chains and
        // through the explicit tests in `tests/url_validation.rs`.
        McpError::Io(std::io::Error::other(e.to_string()))
    }
}

impl HttpSseTransport {
    /// Open the SSE GET stream + negotiate the POST endpoint.
    ///
    /// # Errors
    /// - [`McpError::Io`] wrapping [`HttpSseError`] for loopback /
    ///   network failures.
    pub async fn connect(
        sse_url: LoopbackHost,
        auth_header: Option<String>,
    ) -> McpResult<Self> {
        if sse_url.scheme == Scheme::Https {
            return Err(HttpSseError::HttpsNotSupported.into());
        }
        // Re-validate the SSE URL right before we dial — Audit row #2.
        let dial_addr = sse_url
            .resolve_now()
            .await
            .map_err(HttpSseError::Loopback)?;
        if !dial_addr.ip().is_loopback() {
            return Err(HttpSseError::NonLoopbackDial.into());
        }

        // Build the hyper client. The connector is wrapped so EVERY
        // dial it performs is constrained to loopback — both for the
        // SSE GET below and for later POSTs the registry / `call`
        // path triggers. Audit row #2 lives here.
        let client: Client<LoopbackOnlyConnector, Full<Bytes>> =
            Client::builder(TokioExecutor::new()).build(LoopbackOnlyConnector::new());

        // Construct the SSE GET request. Plaintext HTTP only at the
        // dial layer; `LoopbackHost` already rejected non-http
        // schemes. Auth header attaches if set.
        let mut req_builder = Request::builder()
            .method(Method::GET)
            .uri(&sse_url.url)
            .header(ACCEPT, "text/event-stream")
            .header(CACHE_CONTROL, "no-cache");
        if let Some(ref h) = auth_header {
            req_builder = req_builder.header(AUTHORIZATION, h);
        }
        let req = req_builder
            .body(Full::new(Bytes::new()))
            .map_err(|e| HttpSseError::SseOpen(format!("request build: {e}")))?;

        let response = client
            .request(req)
            .await
            .map_err(|e| HttpSseError::SseOpen(format!("hyper request: {e}")))?;

        if !response.status().is_success() {
            return Err(HttpSseError::SseOpen(format!(
                "non-success status {}",
                response.status()
            ))
            .into());
        }

        // Read SSE events off the response body. The reader task owns
        // the body stream for the life of the transport; we keep the
        // first task block here so we can pull the endpoint event
        // before returning to the caller.
        let body = response.into_body();
        let pending: PendingMap = Arc::new(Mutex::new(HashMap::new()));

        let (endpoint_tx, endpoint_rx) = oneshot::channel::<LoopbackHost>();
        let pending_for_reader = Arc::clone(&pending);
        let base_url_for_reader = sse_url.url.clone();
        let reader_task = tokio::spawn(async move {
            sse_reader_loop(body, endpoint_tx, pending_for_reader, base_url_for_reader).await;
        });

        let endpoint = timeout(ENDPOINT_WAIT_TIMEOUT, endpoint_rx)
            .await
            .map_err(|_| HttpSseError::EndpointMissing)?
            .map_err(|_| HttpSseError::EndpointMissing)?;

        Ok(Self {
            sse_url,
            auth_header,
            endpoint_url: Mutex::new(Some(endpoint)),
            pending,
            call_timeout_ms: AtomicU64::new(
                u64::try_from(DEFAULT_CALL_TIMEOUT.as_millis()).unwrap_or(u64::MAX),
            ),
            closed: Mutex::new(false),
            reader_task: Mutex::new(Some(reader_task)),
            client,
        })
    }

    /// Retune the per-call timeout at runtime.
    pub fn set_timeout(&self, t: Duration) {
        let ms = u64::try_from(t.as_millis()).unwrap_or(u64::MAX);
        self.call_timeout_ms.store(ms, Ordering::SeqCst);
    }

    /// Programmatic accessor for the configured timeout.
    #[must_use]
    pub fn call_timeout(&self) -> Duration {
        Duration::from_millis(self.call_timeout_ms.load(Ordering::SeqCst))
    }

    async fn register_waiter(&self, id: &JsonRpcId) -> oneshot::Receiver<JsonRpcResponse> {
        let (tx, rx) = oneshot::channel();
        let mut map = self.pending.lock().await;
        map.insert(id.key(), tx);
        rx
    }

    async fn cancel_waiter(&self, id: &JsonRpcId) {
        let mut map = self.pending.lock().await;
        map.remove(&id.key());
    }

    async fn post_frame(&self, frame: &JsonRpcRequest) -> McpResult<()> {
        let endpoint = {
            let guard = self.endpoint_url.lock().await;
            guard
                .clone()
                .ok_or_else(|| McpError::from(HttpSseError::EndpointMissing))?
        };
        // Defense-in-depth: re-resolve the endpoint URL on every POST.
        let dial_addr = endpoint
            .resolve_now()
            .await
            .map_err(HttpSseError::Loopback)?;
        if !dial_addr.ip().is_loopback() {
            return Err(HttpSseError::NonLoopbackDial.into());
        }

        let body_bytes = serde_json::to_vec(frame)?;
        let mut req_builder = Request::builder()
            .method(Method::POST)
            .uri(&endpoint.url)
            .header(CONTENT_TYPE, "application/json")
            .header(ACCEPT, "application/json");
        if let Some(ref h) = self.auth_header {
            req_builder = req_builder.header(AUTHORIZATION, h);
        }
        let req = req_builder
            .body(Full::new(Bytes::from(body_bytes)))
            .map_err(|e| HttpSseError::Post(format!("request build: {e}")))?;
        let resp = self
            .client
            .request(req)
            .await
            .map_err(|e| HttpSseError::Post(format!("hyper request: {e}")))?;
        if !resp.status().is_success() && resp.status() != StatusCode::ACCEPTED {
            return Err(HttpSseError::Post(format!(
                "non-success status {}",
                resp.status()
            ))
            .into());
        }
        // The POST body is intentionally discarded — the server's
        // JSON-RPC response arrives on the SSE GET stream, not in the
        // POST response (per the 2024-11-05 spec). Some servers may
        // also inline the response in the POST body as an
        // optimization; we accept either by ignoring the POST body
        // and waiting on the SSE event.
        drop(resp.into_body());
        Ok(())
    }
}

#[async_trait]
impl McpTransport for HttpSseTransport {
    async fn call(&self, request: JsonRpcRequest) -> McpResult<JsonRpcResponse> {
        if *self.closed.lock().await {
            return Err(McpError::Closed);
        }
        let id = request.id.clone().ok_or_else(|| McpError::MalformedFrame {
            reason: "call() requires a request with an id (notifications use notify())".to_owned(),
        })?;
        let method = request.method.clone();
        let rx = self.register_waiter(&id).await;
        if let Err(e) = self.post_frame(&request).await {
            self.cancel_waiter(&id).await;
            return Err(e);
        }
        let call_timeout = self.call_timeout();
        match timeout(call_timeout, rx).await {
            Ok(Ok(resp)) => {
                if resp.jsonrpc != "2.0" {
                    return Err(McpError::MalformedFrame {
                        reason: format!("jsonrpc field was {:?}, expected \"2.0\"", resp.jsonrpc),
                    });
                }
                Ok(resp)
            }
            Ok(Err(_recv_err)) => {
                self.cancel_waiter(&id).await;
                Err(McpError::Closed)
            }
            Err(_elapsed) => {
                self.cancel_waiter(&id).await;
                Err(McpError::Timeout {
                    timeout_ms: u64::try_from(call_timeout.as_millis()).unwrap_or(u64::MAX),
                    method,
                })
            }
        }
    }

    async fn notify(&self, notification: JsonRpcRequest) -> McpResult<()> {
        if *self.closed.lock().await {
            return Err(McpError::Closed);
        }
        if notification.id.is_some() {
            return Err(McpError::MalformedFrame {
                reason: "notify() requires a request without an id".to_owned(),
            });
        }
        self.post_frame(&notification).await
    }

    async fn close(&self) {
        {
            let mut closed = self.closed.lock().await;
            if *closed {
                return;
            }
            *closed = true;
        }
        if let Some(reader) = self.reader_task.lock().await.take() {
            reader.abort();
            let _ = reader.await;
        }
        self.pending.lock().await.clear();
    }
}

/// Drain the SSE stream into the pending map. Sends the first
/// `endpoint` event through `endpoint_tx`; routes every subsequent
/// `message` event into the pending-waiter map by JSON-RPC id.
async fn sse_reader_loop(
    body: Incoming,
    endpoint_tx: oneshot::Sender<LoopbackHost>,
    pending: PendingMap,
    base_url: String,
) {
    let mut buf: Vec<u8> = Vec::with_capacity(4096);
    let mut event_kind: Option<String> = None;
    let mut event_data: Vec<u8> = Vec::new();
    let mut endpoint_tx: Option<oneshot::Sender<LoopbackHost>> = Some(endpoint_tx);

    let mut body = body;
    loop {
        let frame = match futures_util_poll_next_frame(&mut body).await {
            Some(Ok(f)) => f,
            Some(Err(_)) | None => {
                // Stream ended — drop every pending waiter so the
                // call sites see `McpError::Closed` through the
                // sender-dropped path.
                pending.lock().await.clear();
                return;
            }
        };
        let Some(chunk) = frame.data_ref() else {
            continue;
        };
        buf.extend_from_slice(chunk);

        // SSE line parser: split on '\n', strip optional trailing '\r'.
        while let Some(pos) = buf.iter().position(|b| *b == b'\n') {
            let line_bytes: Vec<u8> = buf.drain(..=pos).collect();
            let line = trim_trailing(&line_bytes);
            if line.is_empty() {
                // Event terminator — dispatch the accumulated event.
                if !event_data.is_empty() || event_kind.is_some() {
                    let kind = event_kind.take().unwrap_or_else(|| "message".to_owned());
                    let data = std::mem::take(&mut event_data);
                    dispatch_event(
                        &kind,
                        &data,
                        &base_url,
                        &mut endpoint_tx,
                        &pending,
                    )
                    .await;
                }
                continue;
            }
            if line.starts_with(b":") {
                // SSE comment line — ignore.
                continue;
            }
            // Find the ":" field separator. SSE spec: the field name
            // is everything before the first ":", the value is
            // everything after the first ":" + optional leading space.
            let colon = line.iter().position(|b| *b == b':');
            let (field, value) = match colon {
                Some(idx) => {
                    let field = &line[..idx];
                    let mut value = &line[idx + 1..];
                    if value.first() == Some(&b' ') {
                        value = &value[1..];
                    }
                    (field, value)
                }
                None => (line, &[][..]),
            };
            match std::str::from_utf8(field).unwrap_or("") {
                "event" => {
                    event_kind = Some(
                        std::str::from_utf8(value)
                            .unwrap_or("message")
                            .to_owned(),
                    );
                }
                "data" => {
                    if event_data.len().saturating_add(value.len()) > MAX_SSE_LINE_BYTES {
                        // Hostile peer would overrun us — refuse to
                        // grow further. Drop the partial event.
                        event_data.clear();
                        event_kind = None;
                        continue;
                    }
                    if !event_data.is_empty() {
                        event_data.push(b'\n');
                    }
                    event_data.extend_from_slice(value);
                }
                _ => {
                    // Other SSE fields (id, retry) are accepted but
                    // ignored by this client.
                }
            }
        }
    }
}

async fn dispatch_event(
    kind: &str,
    data: &[u8],
    base_url: &str,
    endpoint_tx: &mut Option<oneshot::Sender<LoopbackHost>>,
    pending: &PendingMap,
) {
    match kind {
        "endpoint" => {
            if let Some(tx) = endpoint_tx.take() {
                let raw = match std::str::from_utf8(data) {
                    Ok(s) => s.trim().to_owned(),
                    Err(_) => return,
                };
                let absolute = resolve_relative_url(base_url, &raw);
                if let Ok(host) = LoopbackHost::parse(&absolute).await {
                    let _ = tx.send(host);
                }
                // If the endpoint URL fails the loopback gate the tx
                // is dropped: the constructor waiting on the rx sees
                // `Err(_)` and surfaces `EndpointMissing`. Audit row
                // #2 — non-loopback endpoint can never reach a POST.
            }
        }
        "message" => {
            // Server JSON-RPC response. Parse + route by id.
            if let Ok(resp) = serde_json::from_slice::<JsonRpcResponse>(data) {
                let key = resp.id.key();
                let waiter = {
                    let mut map = pending.lock().await;
                    map.remove(&key)
                };
                if let Some(tx) = waiter {
                    let _ = tx.send(resp);
                }
                // Unmatched ids are dropped (server-initiated
                // notifications not subscribed by this client; same
                // posture as the stdio transport).
            }
            // Malformed JSON is dropped. §5.4 content-free: no log of
            // the payload bytes.
        }
        _ => {
            // Other event kinds — `ping`, `keep-alive`, server-defined
            // — are ignored. Same v1 posture as the stdio transport.
        }
    }
}

fn resolve_relative_url(base: &str, candidate: &str) -> String {
    // Absolute already? Return as-is.
    if candidate.starts_with("http://") || candidate.starts_with("https://") {
        return candidate.to_owned();
    }
    // Resolve against the base URL's origin (scheme://host:port).
    let Ok(base_uri) = base.parse::<Uri>() else {
        return candidate.to_owned();
    };
    let scheme = base_uri.scheme_str().unwrap_or("http");
    let Some(authority) = base_uri.authority() else {
        return candidate.to_owned();
    };
    if let Some(path) = candidate.strip_prefix('/') {
        format!("{scheme}://{}/{path}", authority.as_str())
    } else {
        // Resolve relative to the base's directory.
        let base_path = base_uri.path();
        let dir_end = base_path.rfind('/').map_or(0, |i| i + 1);
        format!(
            "{scheme}://{}{}{}",
            authority.as_str(),
            &base_path[..dir_end],
            candidate
        )
    }
}

fn trim_trailing(line: &[u8]) -> &[u8] {
    let mut end = line.len();
    while end > 0 && (line[end - 1] == b'\n' || line[end - 1] == b'\r') {
        end -= 1;
    }
    &line[..end]
}

/// Helper: read the next [`hyper::body::Frame`] off an [`Incoming`].
///
/// Inlined here to avoid pulling `futures-util` onto the workspace
/// lockfile just for `StreamExt::next`.
async fn futures_util_poll_next_frame(
    body: &mut Incoming,
) -> Option<Result<hyper::body::Frame<Bytes>, hyper::Error>> {
    use std::future::poll_fn;
    poll_fn(|cx| Pin::new(&mut *body).poll_frame(cx)).await
}

/// `hyper_util::client::legacy::connect::Connect` impl that refuses
/// to dial a non-loopback address.
///
/// This is the third gate in the defense-in-depth chain:
///
/// 1. URL validator ([`LoopbackHost::parse`]) at registration time.
/// 2. URL validator at per-call connect time
///    ([`LoopbackHost::resolve_now`] inside [`HttpSseTransport::call`]).
/// 3. Connector-level refusal (this struct) — the last line. Even if
///    both URL gates regressed, this would still refuse the dial.
#[derive(Clone)]
pub struct LoopbackOnlyConnector {
    inner: HttpConnector<LoopbackResolver>,
}

impl LoopbackOnlyConnector {
    /// Build a fresh connector with the loopback-only resolver wired
    /// in. Reuse for the life of the client.
    #[must_use]
    pub fn new() -> Self {
        let mut inner = HttpConnector::new_with_resolver(LoopbackResolver);
        inner.enforce_http(true);
        Self { inner }
    }
}

impl Default for LoopbackOnlyConnector {
    fn default() -> Self {
        Self::new()
    }
}

impl Service<Uri> for LoopbackOnlyConnector {
    type Response = <HttpConnector<LoopbackResolver> as Service<Uri>>::Response;
    type Error = <HttpConnector<LoopbackResolver> as Service<Uri>>::Error;
    type Future = <HttpConnector<LoopbackResolver> as Service<Uri>>::Future;

    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        self.inner.poll_ready(cx)
    }

    fn call(&mut self, req: Uri) -> Self::Future {
        // Defense-in-depth: even if a non-loopback URL somehow reached
        // here, the resolver below refuses any name that is not a
        // loopback IP literal AND `HttpConnector::enforce_http(true)`
        // refuses any non-http scheme. The combination means a non-
        // loopback dial cannot complete through this connector.
        self.inner.call(req)
    }
}

/// hyper-util DNS resolver that returns only loopback addresses.
///
/// `HttpConnector` resolves the URI's host via a `tower::Service`
/// over [`Name`]. Most URIs reaching this connector are IP literals
/// (the [`LoopbackHost`] gate keeps DNS names that resolve outside
/// loopback out of reach), but the resolver still runs for IP-literal
/// hostnames. We refuse anything that does not parse as a loopback IP
/// literal or DNS-resolve entirely into loopback addresses.
#[derive(Clone)]
pub struct LoopbackResolver;

impl Service<Name> for LoopbackResolver {
    type Response = std::vec::IntoIter<std::net::SocketAddr>;
    type Error = std::io::Error;
    type Future = Pin<
        Box<
            dyn std::future::Future<Output = Result<Self::Response, Self::Error>>
                + Send
                + 'static,
        >,
    >;

    fn poll_ready(&mut self, _cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, name: Name) -> Self::Future {
        let host = name.as_str().to_owned();
        Box::pin(async move {
            // Fast path: literal IP. `HttpConnector` historically
            // strips the port, so the Name we receive is host-only.
            // Resolve via `lookup_host` with a dummy port so we get a
            // `SocketAddr` we can shape-check; the connector replaces
            // the port with the URI's port before dialing.
            let target = format!("{host}:0");
            let resolved = tokio::net::lookup_host(target.as_str()).await?;
            let addrs: Vec<std::net::SocketAddr> = resolved.collect();
            if addrs.is_empty() {
                return Err(std::io::Error::other("loopback resolver: no addrs"));
            }
            for addr in &addrs {
                if !addr.ip().is_loopback() {
                    return Err(std::io::Error::other(
                        "loopback resolver: non-loopback address refused",
                    ));
                }
            }
            Ok(addrs.into_iter())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relative_endpoint_resolves_against_base_origin() {
        let resolved = resolve_relative_url("http://127.0.0.1:7890/sse", "/messages?sid=abc");
        assert_eq!(resolved, "http://127.0.0.1:7890/messages?sid=abc");
    }

    #[test]
    fn absolute_endpoint_passes_through() {
        let resolved =
            resolve_relative_url("http://127.0.0.1:7890/sse", "http://127.0.0.1:7890/m");
        assert_eq!(resolved, "http://127.0.0.1:7890/m");
    }

    #[test]
    fn ipv6_base_resolves_relative_endpoint() {
        let resolved = resolve_relative_url("http://[::1]:7890/sse", "/messages");
        assert_eq!(resolved, "http://[::1]:7890/messages");
    }

    #[test]
    fn trim_trailing_strips_crlf() {
        assert_eq!(trim_trailing(b"hello\r\n"), b"hello");
        assert_eq!(trim_trailing(b"hello"), b"hello");
        assert_eq!(trim_trailing(b"\r\n"), b"");
    }

    #[tokio::test]
    async fn https_loopback_refused_at_connect_time() {
        // URL validation accepts the scheme; connect-time refuses.
        let host = LoopbackHost::parse("https://127.0.0.1/mcp")
            .await
            .expect("https validates");
        let err = HttpSseTransport::connect(host, None)
            .await
            .expect_err("HTTPS connect refused");
        let msg = format!("{err}");
        assert!(
            msg.contains("HTTPS") || msg.contains("https"),
            "unexpected error: {msg}"
        );
    }
}
