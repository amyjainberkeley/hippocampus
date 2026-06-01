//! V2-MCP-2 — agent-side bootstrap for the MCP-client registry.
//!
//! Reads `~/Library/Application Support/MCI/mcp-servers.toml` on boot,
//! constructs a [`mci_mcp_client::ServerRegistry`] populated with one
//! HTTP entry per enabled `[[server]]` block, and logs each
//! registration. The registry is returned to the caller so the agent
//! process owns it for its lifetime — V2-MCP-3's aggregator (cycle
//! 8.30, Director-Brain) consumes it without a re-init.
//!
//! v1 posture (intentional scope cap):
//!
//! - Each entry is REGISTERED but NOT eagerly CONNECTED. The first
//!   `connect()` call on a [`ServerHandle`] opens the SSE stream; V2-
//!   MCP-3 controls when that happens (per-call lazy connect matches
//!   the stdio surface's lifecycle).
//! - Loopback validation has already passed inside
//!   [`McpServersConfig::register_all`]; failures surface here as a
//!   structured log line + a skipped row, never as a process abort.
//! - No file-watcher: edits to `mcp-servers.toml` require an agent
//!   restart to take effect (matches the V2-P10 `user-allowlist.toml`
//!   precedent in PR #251). A future PR can add `notify`-based
//!   reloading if a user need surfaces.
//!
//! ADR-0001 §amendment 2026-05-31 / Audit row #8 + #9: this module is
//! the integration site for the HttpSseTransport. Construction-graph
//! wiring lives here so a future regression in agent startup that
//! drops the registry surfaces as a missing call.

use std::path::PathBuf;
use std::sync::Arc;

use mci_mcp_client::{ConfigError, McpServersConfig, ServerRegistry};

/// Boot-side result of registry construction. Returned so the caller
/// can log a one-line summary AND retain the registry for V2-MCP-3.
pub struct McpClientBoot {
    /// The shared registry. Holds N entries (N = `registered_count`).
    pub registry: Arc<ServerRegistry>,
    /// Path the loader tried (for the log line).
    pub config_path: PathBuf,
    /// Number of entries successfully registered. Zero is a normal
    /// outcome — most users will not have any MCP servers configured.
    pub registered_count: usize,
    /// Outcome shape: did the file exist + parse + validate? Used by
    /// the log line to distinguish "no config" from "bad config".
    pub status: BootStatus,
}

/// What happened during boot.
pub enum BootStatus {
    /// File did not exist — zero servers, expected on a fresh install.
    NoConfig,
    /// At least one row registered (count in [`McpClientBoot`]).
    Ok,
    /// File existed but its permissions did not pass the security
    /// gate (mode 0600 + uid-matched). The agent treats this as
    /// "skip the file, don't crash" — same as a missing file from a
    /// product standpoint, but worth logging differently for debug.
    InsecurePermissions,
    /// File parsed but had a structural issue (duplicate name, etc.)
    /// OR one of its rows failed the loopback gate. The error string
    /// is content-free per ConfigError's discipline.
    ConfigError(String),
}

impl McpClientBoot {
    /// One-line summary suitable for stderr logging. Never includes
    /// auth headers or URLs (§5.4 content-free discipline).
    #[must_use]
    pub fn log_line(&self) -> String {
        match &self.status {
            BootStatus::NoConfig => format!(
                "mci-agent: mcp-servers.toml not found at {} — zero MCP servers registered (expected on fresh install)",
                self.config_path.display()
            ),
            BootStatus::Ok => format!(
                "mci-agent: mcp-servers.toml ok at {} — {} server(s) registered",
                self.config_path.display(),
                self.registered_count
            ),
            BootStatus::InsecurePermissions => format!(
                "mci-agent: mcp-servers.toml at {} has insecure permissions (not mode 0600 / uid-matched) — refusing to load",
                self.config_path.display()
            ),
            BootStatus::ConfigError(msg) => format!(
                "mci-agent: mcp-servers.toml at {} rejected — {} ({} server(s) registered before refusal)",
                self.config_path.display(),
                msg,
                self.registered_count
            ),
        }
    }
}

/// Boot the MCP-client registry at the default path. Always returns
/// a [`ServerRegistry`] (possibly empty); never crashes the agent on
/// a missing / malformed / insecure config.
pub async fn boot_default() -> McpClientBoot {
    let path = McpServersConfig::default_path();
    boot_at(&path).await
}

/// Boot the MCP-client registry at a specific path. Mirror of
/// [`boot_default`] for tests and future CLI overrides.
pub async fn boot_at(path: &std::path::Path) -> McpClientBoot {
    let registry = Arc::new(ServerRegistry::new());
    match McpServersConfig::load(path).await {
        Ok(cfg) => match cfg.register_all(&registry).await {
            Ok(n) => McpClientBoot {
                registry,
                config_path: path.to_owned(),
                registered_count: n,
                status: BootStatus::Ok,
            },
            Err(e) => {
                // `register_all` mutates the registry up to the failing
                // row. We surface the count of successful registrations
                // separately so the log line is accurate.
                let registered = registry.len().await;
                McpClientBoot {
                    registry,
                    config_path: path.to_owned(),
                    registered_count: registered,
                    status: BootStatus::ConfigError(e.to_string()),
                }
            }
        },
        Err(ConfigError::NotFound) => McpClientBoot {
            registry,
            config_path: path.to_owned(),
            registered_count: 0,
            status: BootStatus::NoConfig,
        },
        Err(ConfigError::Permissions) => McpClientBoot {
            registry,
            config_path: path.to_owned(),
            registered_count: 0,
            status: BootStatus::InsecurePermissions,
        },
        Err(other) => McpClientBoot {
            registry,
            config_path: path.to_owned(),
            registered_count: 0,
            status: BootStatus::ConfigError(other.to_string()),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn missing_file_yields_no_config_status() {
        let boot = boot_at(std::path::Path::new(
            "/tmp/non-existent-mci-mcp-servers-test.toml",
        ))
        .await;
        assert!(matches!(boot.status, BootStatus::NoConfig));
        assert_eq!(boot.registered_count, 0);
        let line = boot.log_line();
        assert!(line.contains("not found"));
    }

    #[tokio::test]
    async fn valid_config_registers_entries() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile_dir();
        let path = dir.join("mcp-servers.toml");
        let body = r#"
[[server]]
name = "ok"
url = "http://127.0.0.1:9999/sse"
"#;
        tokio::fs::write(&path, body).await.unwrap();
        let mut perms = tokio::fs::metadata(&path).await.unwrap().permissions();
        perms.set_mode(0o600);
        tokio::fs::set_permissions(&path, perms).await.unwrap();
        let boot = boot_at(&path).await;
        assert!(
            matches!(boot.status, BootStatus::Ok),
            "expected Ok, got log: {}",
            boot.log_line()
        );
        assert_eq!(boot.registered_count, 1);
        let _ = tokio::fs::remove_file(&path).await;
    }

    #[tokio::test]
    async fn non_loopback_url_yields_config_error_with_count_zero() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile_dir();
        let path = dir.join("mcp-servers.toml");
        let body = r#"
[[server]]
name = "bad"
url = "http://192.168.1.1:9999/sse"
"#;
        tokio::fs::write(&path, body).await.unwrap();
        let mut perms = tokio::fs::metadata(&path).await.unwrap().permissions();
        perms.set_mode(0o600);
        tokio::fs::set_permissions(&path, perms).await.unwrap();
        let boot = boot_at(&path).await;
        assert!(matches!(boot.status, BootStatus::ConfigError(_)));
        assert_eq!(boot.registered_count, 0);
        let _ = tokio::fs::remove_file(&path).await;
    }

    fn tempfile_dir() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static C: AtomicU64 = AtomicU64::new(0);
        let n = C.fetch_add(1, Ordering::SeqCst);
        let mut p = std::env::temp_dir();
        p.push(format!("mci-agent-mcpsup-{}-{n}", std::process::id()));
        std::fs::create_dir_all(&p).unwrap();
        p
    }
}
