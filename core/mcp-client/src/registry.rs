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
//! v1 V2-MCP-1 keeps this in-memory only — the on-disk
//! `~/Library/Application Support/MCI/mcp-servers.toml` persistence
//! lands in V2-MCP-2 with the registration UI + per-server consent
//! UX. The shape of [`ServerRegistration`] here is the canonical
//! on-disk schema for V2-MCP-2; aligning now lets V2-MCP-2 land as
//! a thin (de)serialization + `ConsentRecord` overlay.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use tokio::sync::RwLock;

use crate::client::McpClient;
use crate::error::{McpError, McpResult};
use crate::stdio::StdioTransport;

/// Registered MCP server spec. Mirrors the canonical Anthropic
/// `mcpServers` JSON shape used in `claude_desktop_config.json` and
/// Claude Code's `.mcp.json`:
///
/// ```json
/// { "command": "/path/to/binary", "args": ["arg"], "env": {"K":"V"} }
/// ```
///
/// `name` is the registry key (e.g. `"gbrain"`, `"slack"`); the
/// consumer-side configs use the surrounding JSON object's key for
/// the same purpose.
///
/// `transport_kind` is fixed to stdio for V2-MCP-1 (only stdio
/// transport ships). V2-MCP-2 adds `Http` and an `auth: AuthSpec`
/// field; we keep the enum here so callers can pattern-match without
/// breaking when V2-MCP-2 lands.
#[derive(Debug, Clone)]
pub struct ServerRegistration {
    /// Stable id (e.g. `"gbrain"`). Used as the registry key and as
    /// the `events.source_kind = "mcp:<id>"` discriminator that the
    /// V2-MCP-3 aggregator writes to the brain store.
    pub name: String,
    /// Path to the server's executable.
    pub command: PathBuf,
    /// CLI arguments. Empty Vec is fine.
    pub args: Vec<String>,
    /// Environment for the spawned child. Empty Vec is fine. v1 is
    /// `env_clear()`-based — only this map's pairs reach the child;
    /// the parent process env is NOT inherited (avoids accidentally
    /// passing user secrets through).
    pub env: HashMap<String, String>,
    /// Discriminator for which transport [`ServerRegistry::connect`]
    /// uses. Stdio-only in V2-MCP-1.
    pub transport_kind: TransportKind,
}

/// Which transport flavor a registration uses. V2-MCP-1 ships stdio
/// only; V2-MCP-2 adds [`Self::Http`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportKind {
    /// Local subprocess + stdio pipes. Not network.
    Stdio,
    /// HTTP + SSE remote. **Not implemented in V2-MCP-1** — attempts
    /// to connect a registration with `transport_kind = Http` return
    /// [`McpError::SchemaMismatch`] until V2-MCP-2 lands.
    Http,
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
            command: command.into(),
            args: args.into_iter().map(Into::into).collect(),
            env: HashMap::new(),
            transport_kind: TransportKind::Stdio,
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
    Connected(Arc<McpClient<StdioTransport>>),
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
    pub async fn connect(&self) -> McpResult<Arc<McpClient<StdioTransport>>> {
        // Fast path — already connected.
        if let ServerHandleState::Connected(client) = &*self.state.read().await {
            return Ok(Arc::clone(client));
        }
        let mut guard = self.state.write().await;
        match &*guard {
            ServerHandleState::Connected(client) => Ok(Arc::clone(client)),
            ServerHandleState::Closed => Err(McpError::Closed),
            ServerHandleState::NotConnected => {
                match self.registration.transport_kind {
                    TransportKind::Stdio => {
                        let env: Vec<(String, String)> = self
                            .registration
                            .env
                            .iter()
                            .map(|(k, v)| (k.clone(), v.clone()))
                            .collect();
                        let transport = StdioTransport::spawn(
                            &self.registration.command,
                            &self.registration.args,
                            &env,
                        )
                        .await?;
                        let client = Arc::new(McpClient::new(Arc::new(transport)));
                        *guard = ServerHandleState::Connected(Arc::clone(&client));
                        Ok(client)
                    }
                    TransportKind::Http => Err(McpError::SchemaMismatch(
                        "HTTP transport is V2-MCP-2; not implemented in V2-MCP-1".into(),
                    )),
                }
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
    /// first — the new spec might point at a different binary).
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
    pub async fn connect(&self, name: &str) -> McpResult<Arc<McpClient<StdioTransport>>> {
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
    }

    #[tokio::test]
    async fn http_transport_is_unsupported_in_v1() {
        let reg = ServerRegistry::new();
        let mut spec = ServerRegistration::stdio("h", "/bin/true", Vec::<String>::new());
        spec.transport_kind = TransportKind::Http;
        let h = reg.register(spec).await;
        let err = h.connect().await.expect_err("HTTP not in V1");
        assert!(matches!(err, McpError::SchemaMismatch(_)));
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
        assert_eq!(h2.registration.command, PathBuf::from("/bin/cat"));
        assert_eq!(reg.len().await, 1);
    }
}
