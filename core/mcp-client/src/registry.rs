//! [`ServerRegistry`] — in-memory map of registered MCP servers +
//! lazy per-server connection lifecycle.
//!
//! Per the scoping memo §6.1:
//!
//! > `ServerRegistration { name, command, args, env }` — represents a
//! > registered MCP server.
//! > In-memory `ServerRegistry` holding registrations + lazy
//! > connection per server. Connection lifecycle: register → connect
//! > → call → close.
//!
//! V2-MCP-1 shipped stdio-only registrations. V2-MCP-2 adds the
//! [`ServerSpec::Http`] variant carrying `{url, auth_header}` and the
//! `~/Library/Application Support/MCI/mcp-servers.toml` persistence
//! shape (see [`crate::config`]). The lazy-connect / lazy-reconnect
//! lifecycle stays unchanged; only the transport selected by
//! `connect()` differs.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use tokio::sync::RwLock;

use crate::client::McpClient;
use crate::error::{McpError, McpResult};
use crate::stdio::StdioTransport;
use crate::transport::http_sse::HttpSseTransport;
use crate::transport::loopback::LoopbackHost;
use crate::transport::McpTransport;

/// One registered MCP server. The two variants mirror the two
/// transports the client core supports.
///
/// `stdio` describes a local subprocess (process-local IPC, not
/// network); `http` describes a loopback HTTP+SSE peer admitted by the
/// ADR-0001 amendment dated 2026-05-31.
#[derive(Debug, Clone)]
pub enum ServerSpec {
    /// Spawn the named binary and pipe JSON-RPC over its stdin/stdout.
    /// Mirrors the canonical Anthropic `mcpServers` JSON shape used by
    /// `claude_desktop_config.json` and Claude Code's `.mcp.json`.
    Stdio {
        /// Path to the server's executable.
        command: PathBuf,
        /// CLI arguments. Empty Vec is fine.
        args: Vec<String>,
        /// Environment for the spawned child. v1 is `env_clear()`-based
        /// — only this map's pairs reach the child; the parent
        /// process env is NOT inherited (no accidental secret leak).
        env: HashMap<String, String>,
    },
    /// Open a loopback HTTP+SSE connection to the given URL. The URL
    /// must have already passed [`LoopbackHost::parse`] — the
    /// registration path stores the validated [`LoopbackHost`] here,
    /// not the raw string.
    Http {
        /// Loopback-validated SSE URL.
        sse_url: LoopbackHost,
        /// Optional `Authorization` header value. NEVER logged
        /// (Audit row #7).
        auth_header: Option<String>,
    },
}

/// Registered MCP server spec. Mirrors the canonical Anthropic
/// `mcpServers` JSON shape used in `claude_desktop_config.json` and
/// Claude Code's `.mcp.json`, plus the V2-MCP-2 HTTP variant.
///
/// `name` is the registry key (e.g. `"gbrain"`, `"gchat"`, `"slack"`).
/// The on-disk `mcp-servers.toml` schema is the canonical V2-MCP-2
/// persistence shape and is enforced by [`crate::config`].
#[derive(Debug, Clone)]
pub struct ServerRegistration {
    /// Stable id (e.g. `"gbrain"`). Used as the registry key and as
    /// the `events.source_kind = "mcp:<id>"` discriminator that the
    /// V2-MCP-3 aggregator writes to the brain store.
    pub name: String,
    /// Which transport this registration uses.
    pub spec: ServerSpec,
}

impl ServerRegistration {
    /// Convenience constructor for a stdio registration with no env.
    #[must_use]
    pub fn stdio(
        name: impl Into<String>,
        command: impl Into<PathBuf>,
        args: impl IntoIterator<Item = impl Into<String>>,
    ) -> Self {
        Self {
            name: name.into(),
            spec: ServerSpec::Stdio {
                command: command.into(),
                args: args.into_iter().map(Into::into).collect(),
                env: HashMap::new(),
            },
        }
    }

    /// Convenience constructor for an HTTP registration.
    ///
    /// The caller is responsible for having already validated `sse_url`
    /// through [`LoopbackHost::parse`]. The type system enforces that:
    /// the constructor takes a [`LoopbackHost`], not a raw string.
    #[must_use]
    pub fn http(
        name: impl Into<String>,
        sse_url: LoopbackHost,
        auth_header: Option<String>,
    ) -> Self {
        Self {
            name: name.into(),
            spec: ServerSpec::Http {
                sse_url,
                auth_header,
            },
        }
    }

    /// Stable discriminator for telemetry / health logs. Renders
    /// `"stdio"` or `"http"` — never includes the path or URL.
    #[must_use]
    pub fn transport_kind(&self) -> &'static str {
        match &self.spec {
            ServerSpec::Stdio { .. } => "stdio",
            ServerSpec::Http { .. } => "http",
        }
    }
}

/// One server's lifecycle state inside the registry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionState {
    /// Registered but no connection has been opened.
    Registered,
    /// Connection is live; [`ServerRegistry::client`] returns the
    /// shared [`McpClient`].
    Connected,
    /// [`ServerRegistry::close`] was called; the entry is kept for
    /// the registration list, but `client` returns `Err(Closed)`.
    Closed,
}

/// One registered server. Held in an `Arc` so the same handle can be
/// returned across calls; multi-task access goes through `RwLock`
/// on the inner state.
pub struct ServerHandle {
    /// The original registration spec.
    pub registration: ServerRegistration,
    state: RwLock<ServerHandleState>,
}

enum ServerHandleState {
    NotConnected,
    Connected(Arc<McpClient<dyn McpTransport>>),
    Closed,
}

impl ServerHandle {
    fn new(registration: ServerRegistration) -> Self {
        Self {
            registration,
            state: RwLock::new(ServerHandleState::NotConnected),
        }
    }

    /// Snapshot the connection state.
    pub async fn state(&self) -> ConnectionState {
        match &*self.state.read().await {
            ServerHandleState::NotConnected => ConnectionState::Registered,
            ServerHandleState::Connected(_) => ConnectionState::Connected,
            ServerHandleState::Closed => ConnectionState::Closed,
        }
    }

    /// Open the connection if not already open; return the client.
    ///
    /// Idempotent: a second call returns the same `Arc<McpClient>`.
    /// Concurrent first-time callers race on the write lock; the
    /// loser sees the winner's client.
    pub async fn connect(&self) -> McpResult<Arc<McpClient<dyn McpTransport>>> {
        // Fast path — already connected.
        if let ServerHandleState::Connected(client) = &*self.state.read().await {
            return Ok(Arc::clone(client));
        }
        let mut guard = self.state.write().await;
        match &*guard {
            ServerHandleState::Connected(client) => Ok(Arc::clone(client)),
            ServerHandleState::Closed => Err(McpError::Closed),
            ServerHandleState::NotConnected => {
                let transport: Arc<dyn McpTransport> = match &self.registration.spec {
                    ServerSpec::Stdio {
                        command,
                        args,
                        env,
                    } => {
                        let env: Vec<(String, String)> = env
                            .iter()
                            .map(|(k, v)| (k.clone(), v.clone()))
                            .collect();
                        let t = StdioTransport::spawn(command, args, &env).await?;
                        Arc::new(t)
                    }
                    ServerSpec::Http {
                        sse_url,
                        auth_header,
                    } => {
                        let t = HttpSseTransport::connect(
                            sse_url.clone(),
                            auth_header.clone(),
                        )
                        .await?;
                        Arc::new(t)
                    }
                };
                let client = Arc::new(McpClient::<dyn McpTransport>::from_dyn(transport));
                *guard = ServerHandleState::Connected(Arc::clone(&client));
                Ok(client)
            }
        }
    }

    /// Close the connection; the registration record stays so the
    /// registry can list it as `Closed`.
    pub async fn close(&self) {
        let mut guard = self.state.write().await;
        let prev = std::mem::replace(&mut *guard, ServerHandleState::Closed);
        if let ServerHandleState::Connected(client) = prev {
            client.close().await;
        }
    }
}

/// In-memory registry of [`ServerHandle`]s keyed by registration
/// name. Cloning the registry shares the underlying map (Arc-cheap).
#[derive(Default, Clone)]
pub struct ServerRegistry {
    handles: Arc<RwLock<HashMap<String, Arc<ServerHandle>>>>,
}

impl ServerRegistry {
    /// Construct an empty registry.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a server. If a registration with the same name
    /// exists, this replaces it (closing the existing connection
    /// first — the new spec might point at a different binary or URL).
    pub async fn register(&self, registration: ServerRegistration) -> Arc<ServerHandle> {
        let name = registration.name.clone();
        let new_handle = Arc::new(ServerHandle::new(registration));
        let prev = {
            let mut map = self.handles.write().await;
            map.insert(name, Arc::clone(&new_handle))
        };
        if let Some(prev) = prev {
            prev.close().await;
        }
        new_handle
    }

    /// Look up a registered server by name.
    pub async fn get(&self, name: &str) -> Option<Arc<ServerHandle>> {
        self.handles.read().await.get(name).cloned()
    }

    /// Snapshot the current registration list (cloned `ServerRegistration`s).
    pub async fn list(&self) -> Vec<ServerRegistration> {
        self.handles
            .read()
            .await
            .values()
            .map(|h| h.registration.clone())
            .collect()
    }

    /// Number of registered servers.
    pub async fn len(&self) -> usize {
        self.handles.read().await.len()
    }

    /// True iff no servers are registered.
    pub async fn is_empty(&self) -> bool {
        self.handles.read().await.is_empty()
    }

    /// Connect (or reuse) the connection for `name`.
    ///
    /// # Errors
    /// - [`McpError::Closed`] if no registration with that name exists
    ///   (modeled as "the implicit handle is closed"). Callers that
    ///   need to distinguish unknown-name from closed should
    ///   [`Self::get`] first.
    pub async fn connect(&self, name: &str) -> McpResult<Arc<McpClient<dyn McpTransport>>> {
        let handle = self
            .handles
            .read()
            .await
            .get(name)
            .cloned()
            .ok_or(McpError::Closed)?;
        handle.connect().await
    }

    /// Close one server's connection (registration stays).
    pub async fn close(&self, name: &str) {
        let handle = self.handles.read().await.get(name).cloned();
        if let Some(h) = handle {
            h.close().await;
        }
    }

    /// Close every connection. Registrations are preserved so a
    /// subsequent [`Self::connect`] can re-open them.
    pub async fn close_all(&self) {
        let handles: Vec<_> = self.handles.read().await.values().cloned().collect();
        for h in handles {
            h.close().await;
        }
    }

    /// Drop a registration entirely (closing first if connected).
    /// Returns true if a registration was removed.
    pub async fn deregister(&self, name: &str) -> bool {
        let removed = self.handles.write().await.remove(name);
        if let Some(h) = removed {
            h.close().await;
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn register_and_list_round_trip() {
        let reg = ServerRegistry::new();
        assert!(reg.is_empty().await);
        let h = reg
            .register(ServerRegistration::stdio(
                "alpha",
                "/bin/echo",
                Vec::<String>::new(),
            ))
            .await;
        assert_eq!(h.registration.name, "alpha");
        assert_eq!(reg.len().await, 1);
        let list = reg.list().await;
        assert_eq!(list[0].name, "alpha");
        assert_eq!(h.state().await, ConnectionState::Registered);
        assert_eq!(h.registration.transport_kind(), "stdio");
    }

    #[tokio::test]
    async fn deregister_returns_false_for_unknown_name() {
        let reg = ServerRegistry::new();
        assert!(!reg.deregister("nope").await);
    }

    #[tokio::test]
    async fn re_registering_replaces_existing_handle() {
        let reg = ServerRegistry::new();
        let _h1 = reg
            .register(ServerRegistration::stdio(
                "a",
                "/bin/echo",
                Vec::<String>::new(),
            ))
            .await;
        let h2 = reg
            .register(ServerRegistration::stdio(
                "a",
                "/bin/cat",
                Vec::<String>::new(),
            ))
            .await;
        match &h2.registration.spec {
            ServerSpec::Stdio { command, .. } => {
                assert_eq!(command, &PathBuf::from("/bin/cat"));
            }
            ServerSpec::Http { .. } => panic!("expected stdio spec"),
        }
        assert_eq!(reg.len().await, 1);
    }

    #[tokio::test]
    async fn http_registration_carries_loopback_host() {
        let host = LoopbackHost::parse("http://127.0.0.1:7890/sse")
            .await
            .unwrap();
        let reg = ServerRegistration::http("h", host, Some("Bearer x".into()));
        assert_eq!(reg.transport_kind(), "http");
        match &reg.spec {
            ServerSpec::Http {
                sse_url,
                auth_header,
            } => {
                assert_eq!(sse_url.host, "127.0.0.1");
                assert_eq!(auth_header.as_deref(), Some("Bearer x"));
            }
            ServerSpec::Stdio { .. } => panic!("expected http"),
        }
    }
}
