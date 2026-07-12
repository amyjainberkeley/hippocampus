//! [`StdioTransport`] — spawns a child process and pipes JSON-RPC
//! 2.0 frames over its stdin / stdout.
//!
//! Wire framing: one JSON object per line on stdin/stdout (per the
//! MCP spec — no `Content-Length` headers, that is LSP). Operational
//! logs from the server are expected on stderr; this transport
//! silently drops them (the supervisor binary can plumb them to
//! tracing if needed).
//!
//! # ADR-0001 NG3 — stdio is NOT network
//!
//! Stdio transport spawns a local subprocess and talks to it through
//! its standard pipes. No socket is opened; no DNS lookup runs; no
//! network packet is sent. The trust boundary is the same as any
//! in-process function call: the subprocess inherits the user's UID
//! and runs on the same machine. **V2-MCP-1 is non-network — the
//! ADR-0001 NG3 zero-network invariant is intact.** (HTTP+SSE
//! transport in V2-MCP-2 is a separate, CSO-gated PR with an explicit
//! ADR-0001 amendment.)
//!
//! # Concurrency model
//!
//! One [`tokio::process::Child`] is spawned at construction. A
//! background task drains stdout line-by-line into the response
//! router. Concurrent `call`s are correlated by JSON-RPC id; each
//! waiter parks on a `tokio::sync::oneshot` channel registered in a
//! shared `HashMap<id, sender>`.
//!
//! Writes are serialized through a `Mutex<ChildStdin>` so two
//! concurrent `call`s cannot interleave bytes mid-frame.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{oneshot, Mutex};
use tokio::time::timeout;

use crate::error::{McpError, McpResult};
use crate::jsonrpc::{JsonRpcId, JsonRpcRequest, JsonRpcResponse};
use crate::transport::McpTransport;

/// Default per-call timeout. Tunable per-transport via
/// [`StdioTransport::with_timeout`]. The default is generous because
/// a `tools/call` against a real-world MCP server (Slack search,
/// GitHub query) can take seconds.
pub const DEFAULT_CALL_TIMEOUT: Duration = Duration::from_secs(30);

/// One pending request awaiting its response.
type PendingMap = Arc<Mutex<HashMap<String, oneshot::Sender<JsonRpcResponse>>>>;

/// Async-stdio MCP transport. Owns a child process + the reader task.
///
/// Construct with [`Self::spawn`]; drop or [`Self::close`] to tear
/// down. Cloning the transport is not supported because the
/// underlying `ChildStdin` cannot be cloned — wrap in `Arc` if shared
/// ownership is needed.
#[derive(Debug)]
pub struct StdioTransport {
    /// Child process handle (kept so [`Self::close`] can `kill`).
    child: Mutex<Option<Child>>,
    /// Writable half of the child's stdin. Serialized so concurrent
    /// `call`s cannot interleave bytes.
    stdin: Mutex<Option<ChildStdin>>,
    /// Shared map keyed by [`JsonRpcId::key`] of waiters.
    pending: PendingMap,
    /// Per-call timeout, stored as milliseconds. `AtomicU64` so the
    /// timeout can be retuned at runtime through [`Self::set_timeout`]
    /// without needing `&mut self`. Used by V2-MCP-3 to drop the
    /// timeout for an unhealthy server's retry probes.
    call_timeout_ms: AtomicU64,
    /// Flipped to true on [`Self::close`]; subsequent calls error
    /// out with [`McpError::Closed`] without touching the child.
    closed: Mutex<bool>,
    /// Reader task handle (joined on close so the test harness does
    /// not leak a runtime task between cases).
    reader_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl StdioTransport {
    /// Spawn the configured command and start the response reader.
    ///
    /// # Errors
    /// - [`McpError::Io`] if `Command::spawn` fails (binary not
    ///   found, permissions, ENOMEM, …).
    // `Command::spawn` is sync in tokio; the function itself does no
    // `.await`. The `async` shape is kept for API uniformity with the
    // rest of the transport surface — all other methods are async.
    #[allow(clippy::unused_async)]
    pub async fn spawn(
        command: &std::path::Path,
        args: &[String],
        env: &[(String, String)],
    ) -> McpResult<Self> {
        let mut cmd = Command::new(command);
        cmd.args(args)
            .env_clear()
            .envs(env.iter().cloned())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            // Capture stderr but drop it — operational logs from the
            // server. A supervisor could pipe this to tracing.
            .stderr(Stdio::piped());
        // Per-spawn: detach so the parent process does not block on
        // child exit when dropped without close().
        cmd.kill_on_drop(true);

        let mut child = cmd.spawn()?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| McpError::Io(std::io::Error::other("child stdin not piped")))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| McpError::Io(std::io::Error::other("child stdout not piped")))?;
        // stderr drained on a side task so the pipe buffer cannot
        // fill and stall the child.
        if let Some(stderr) = child.stderr.take() {
            tokio::spawn(drain_stderr(stderr));
        }

        let pending: PendingMap = Arc::new(Mutex::new(HashMap::new()));
        let reader_task = tokio::spawn(reader_loop(stdout, Arc::clone(&pending)));

        Ok(Self {
            child: Mutex::new(Some(child)),
            stdin: Mutex::new(Some(stdin)),
            pending,
            call_timeout_ms: AtomicU64::new(
                u64::try_from(DEFAULT_CALL_TIMEOUT.as_millis()).unwrap_or(u64::MAX),
            ),
            closed: Mutex::new(false),
            reader_task: Mutex::new(Some(reader_task)),
        })
    }

    /// Builder-style override of the per-call timeout.
    #[must_use]
    pub fn with_timeout(self, t: Duration) -> Self {
        self.set_timeout(t);
        self
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

    /// Convenience: spawn from a string path + iter of arg strings.
    pub async fn spawn_simple(
        command: impl Into<PathBuf>,
        args: impl IntoIterator<Item = impl Into<String>>,
    ) -> McpResult<Self> {
        let command = command.into();
        let args: Vec<String> = args.into_iter().map(Into::into).collect();
        Self::spawn(&command, &args, &[]).await
    }

    async fn write_frame(&self, frame: &JsonRpcRequest) -> McpResult<()> {
        let mut serialized = serde_json::to_string(frame)?;
        serialized.push('\n');
        let mut guard = self.stdin.lock().await;
        let Some(stdin) = guard.as_mut() else {
            return Err(McpError::Closed);
        };
        stdin.write_all(serialized.as_bytes()).await?;
        stdin.flush().await?;
        Ok(())
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
}

#[async_trait]
impl McpTransport for StdioTransport {
    async fn call(&self, request: JsonRpcRequest) -> McpResult<JsonRpcResponse> {
        if *self.closed.lock().await {
            return Err(McpError::Closed);
        }
        let id = request.id.clone().ok_or_else(|| McpError::MalformedFrame {
            reason: "call() requires a request with an id (notifications use notify())".to_owned(),
        })?;
        let method = request.method.clone();
        let rx = self.register_waiter(&id).await;
        self.write_frame(&request).await?;
        let call_timeout = self.call_timeout();

        match timeout(call_timeout, rx).await {
            Ok(Ok(resp)) => {
                if resp.jsonrpc != "2.0" {
                    return Err(McpError::MalformedFrame {
                        reason: format!("jsonrpc field was {:?}, expected \"2.0\"", resp.jsonrpc),
                    });
                }
                if let Some(err) = resp.error {
                    return Err(McpError::Rpc(err));
                }
                Ok(JsonRpcResponse {
                    jsonrpc: resp.jsonrpc,
                    id: resp.id,
                    result: resp.result,
                    error: None,
                })
            }
            Ok(Err(_recv_err)) => {
                // Reader task dropped the sender ⇒ pipe closed.
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
        self.write_frame(&notification).await
    }

    async fn close(&self) {
        {
            let mut closed = self.closed.lock().await;
            if *closed {
                return;
            }
            *closed = true;
        }
        // Drop stdin first so the child's read loop sees EOF and
        // exits cleanly when it can.
        {
            let mut guard = self.stdin.lock().await;
            let _ = guard.take();
        }
        // Kill the child if it is still running. `kill_on_drop` will
        // also reap it, but we explicitly start_kill so close() is
        // immediate (matters for tests that spawn + close many).
        if let Some(mut child) = self.child.lock().await.take() {
            let _ = child.start_kill();
            let _ = child.wait().await;
        }
        if let Some(reader) = self.reader_task.lock().await.take() {
            // The reader task exits when stdout returns EOF; aborting
            // here is a belt-and-braces for the kill-without-EOF case.
            reader.abort();
            let _ = reader.await;
        }
        // Wake any remaining waiters with a Closed by dropping all
        // their senders.
        self.pending.lock().await.clear();
    }
}

/// Async stderr drainer — keeps the child's stderr pipe from filling.
/// Lines are dropped (the supervisor binary can plumb them to tracing
/// in a follow-up; v1 keeps the surface small).
async fn drain_stderr(stderr: tokio::process::ChildStderr) {
    let mut lines = BufReader::new(stderr).lines();
    while let Ok(Some(_line)) = lines.next_line().await {
        // Intentionally dropped: ADR-0001 §5.4 content-free telemetry
        // discipline means we do not log server-supplied bytes here.
    }
}

/// Async reader: pulls one JSON-RPC response per line from the
/// child's stdout, routes it to the matching waiter by id.
async fn reader_loop(stdout: tokio::process::ChildStdout, pending: PendingMap) {
    let mut lines = BufReader::new(stdout).lines();
    loop {
        match lines.next_line().await {
            Ok(Some(line)) => {
                if line.trim().is_empty() {
                    continue;
                }
                let parsed: Result<JsonRpcResponse, _> = serde_json::from_str(&line);
                match parsed {
                    Ok(resp) => {
                        let key = resp.id.key();
                        let waiter = {
                            let mut map = pending.lock().await;
                            map.remove(&key)
                        };
                        if let Some(tx) = waiter {
                            let _ = tx.send(resp);
                        }
                        // Unmatched ids = server emitted a frame we
                        // were not waiting for (e.g. a notification
                        // from the server). v1 drops them. The MCP
                        // spec defines several server→client
                        // notifications; future PRs can subscribe.
                    }
                    Err(_parse_err) => {
                        // Drop malformed frames. The call site that
                        // waited for an id will hit its timeout and
                        // surface McpError::Timeout. Logging the
                        // parse error would carry server-supplied
                        // bytes, which violates §5.4 content-free.
                    }
                }
            }
            Ok(None) => {
                // EOF on stdout ⇒ child exited / pipe closed. Drop
                // every pending waiter so they return McpError::Closed
                // through the channel-closed path.
                pending.lock().await.clear();
                return;
            }
            Err(_io_err) => {
                pending.lock().await.clear();
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn spawn_missing_binary_returns_io_error() {
        let err = StdioTransport::spawn_simple("/tmp/this/does/not/exist", Vec::<String>::new())
            .await
            .expect_err("expected spawn failure");
        assert!(matches!(err, McpError::Io(_)));
    }

    #[tokio::test]
    async fn closed_call_returns_closed() {
        // Use `cat` as a no-op subprocess: it echoes stdin to stdout,
        // so any JSON-RPC frame we write comes back verbatim (which
        // happens to satisfy id-correlation by accident — convenient
        // for the close-path test).
        let t = StdioTransport::spawn_simple("/bin/cat", Vec::<String>::new())
            .await
            .expect("spawn cat");
        t.close().await;
        let req = JsonRpcRequest::new(JsonRpcId::Number(1), "ping", None);
        let err = t.call(req).await.expect_err("post-close call");
        assert!(matches!(err, McpError::Closed));
    }
}
