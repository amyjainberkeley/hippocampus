//! V2-MCP-2 on-disk registration config.
//!
//! Schema lives at `~/Library/Application Support/MCI/mcp-servers.toml`
//! (mode 0600, uid-matched — same precedent as the V2-P10
//! `user-allowlist.toml` from PR #251). The onboarding "Connect MCP
//! Servers" slide writes this file; the agent reads it on start and
//! constructs one [`crate::HttpSseTransport`] per enabled entry.
//!
//! # Schema (binding, schema version 1)
//!
//! ```toml
//! # Schema version 1. Edited via Hippocampus onboarding; manual edits
//! # supported but uid + mode must match.
//! [[server]]
//! name = "gchat"                                # required, unique, [a-zA-Z0-9_-]
//! url  = "http://127.0.0.1:7890/mcp"            # required, loopback-only
//! auth_header = "Bearer sk-..."                 # optional; sent as Authorization
//! enabled = true                                # optional, default true
//! ```
//!
//! # Reject rules (Audit row #6)
//!
//! - Duplicate `name` values → [`ConfigError::DuplicateName`].
//! - Unknown top-level keys or unknown fields inside `[[server]]` →
//!   [`ConfigError::UnknownField`] (toml's `deny_unknown_fields`).
//! - Empty / disallowed-character `name` → [`ConfigError::BadName`].
//! - Empty `url` → [`ConfigError::EmptyUrl`].
//!
//! The URL itself is NOT loopback-validated by this loader — that is
//! deferred to [`crate::transport::loopback::LoopbackHost::parse`] at
//! the call site so the validator error surfaces as a typed
//! [`crate::LoopbackError`] rather than being collapsed into a generic
//! "bad URL" string. [`McpServersConfig::register_all`] does the
//! validation + registration in one pass.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::registry::{ServerRegistration, ServerRegistry};
use crate::transport::loopback::{LoopbackError, LoopbackHost};

/// File name relative to `~/Library/Application Support/MCI/`.
pub const DEFAULT_FILE_NAME: &str = "mcp-servers.toml";

/// Top-level on-disk shape. `#[serde(deny_unknown_fields)]` rejects any
/// extra keys we did not document — Audit row #6.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct McpServersConfig {
    /// One row per registered server. `Default::default()` is an empty
    /// vec — the file is allowed to have zero `[[server]]` blocks, in
    /// which case [`Self::register_all`] is a no-op.
    #[serde(default, rename = "server")]
    pub servers: Vec<McpServerEntry>,
}

/// One `[[server]]` block.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct McpServerEntry {
    /// Stable name used as the registry key. Restricted to
    /// `[a-zA-Z0-9_-]+` so that it's safe as a `events.source_kind`
    /// discriminator.
    pub name: String,
    /// SSE GET URL. Loopback-only per ADR-0001 amendment 2026-05-31.
    pub url: String,
    /// Optional `Authorization` header value. NEVER logged. The
    /// onboarding UI persists it verbatim; the transport sends it on
    /// every request.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auth_header: Option<String>,
    /// Whether to construct a transport for this server at agent
    /// startup. Defaults to true. Disabled rows stay in the file so
    /// the user can re-enable without losing the URL / auth.
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

const fn default_enabled() -> bool {
    true
}

/// Every failure shape this loader can report.
///
/// Errors are content-free at the variant boundary — the offending
/// row's name surfaces only by index so an emit'd log doesn't leak
/// the user's secrets. The onboarding UI / agent supervisor renders
/// these into human messages at the call site.
#[derive(Debug, Error)]
pub enum ConfigError {
    /// The file did not exist; the agent treats this as "zero servers
    /// configured" rather than a fatal error.
    #[error("config file not found")]
    NotFound,
    /// Read-side I/O failure (permissions, transient).
    #[error("config I/O: {0}")]
    Io(#[from] std::io::Error),
    /// The file existed but its mode/uid does not match the security
    /// contract. The reader refuses to ingest a world-readable or
    /// other-uid-owned config — Audit row #5.
    #[error("config file permissions are not 0600 / uid-matched (audit row #5)")]
    Permissions,
    /// The TOML did not parse, or had unknown / mistyped fields.
    #[error("config parse: {0}")]
    Parse(String),
    /// The same `name` appears in two `[[server]]` blocks.
    #[error("duplicate server name at row {index}")]
    DuplicateName {
        /// 0-based index of the second occurrence.
        index: usize,
    },
    /// A `[[server]]` had an empty / disallowed-character `name`.
    #[error("invalid server name at row {index} (must match [a-zA-Z0-9_-]+)")]
    BadName {
        /// 0-based index of the offending row.
        index: usize,
    },
    /// A `[[server]]` had an empty `url`.
    #[error("empty url at row {index}")]
    EmptyUrl {
        /// 0-based index of the offending row.
        index: usize,
    },
    /// A `[[server]]`'s URL failed the loopback gate.
    #[error("server at row {index}: {source}")]
    Loopback {
        /// 0-based index of the offending row.
        index: usize,
        /// The loopback-validator's typed error.
        #[source]
        source: LoopbackError,
    },
}

impl McpServersConfig {
    /// Default config path: `~/Library/Application Support/MCI/mcp-servers.toml`.
    #[must_use]
    pub fn default_path() -> PathBuf {
        let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
        home.join("Library/Application Support/MCI")
            .join(DEFAULT_FILE_NAME)
    }

    /// Read + parse the config at the given path.
    ///
    /// Validates POSIX permissions (mode 0600, uid-matched). A missing
    /// file is NOT an error — returns [`ConfigError::NotFound`] which
    /// the caller treats as "zero servers configured".
    ///
    /// # Errors
    /// See [`ConfigError`].
    pub async fn load(path: &Path) -> Result<Self, ConfigError> {
        match tokio::fs::metadata(path).await {
            Ok(meta) => {
                validate_permissions(&meta)?;
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Err(ConfigError::NotFound);
            }
            Err(e) => return Err(ConfigError::Io(e)),
        }
        let body = tokio::fs::read_to_string(path).await?;
        let cfg: Self = toml::from_str(&body).map_err(|e| ConfigError::Parse(e.to_string()))?;
        cfg.check_invariants()?;
        Ok(cfg)
    }

    /// Validate the cross-row invariants (duplicate names, etc.)
    /// without DNS resolution. Cheap; called by [`Self::load`].
    pub fn check_invariants(&self) -> Result<(), ConfigError> {
        use std::collections::HashSet;
        let mut seen: HashSet<&str> = HashSet::new();
        for (idx, entry) in self.servers.iter().enumerate() {
            if !is_valid_name(&entry.name) {
                return Err(ConfigError::BadName { index: idx });
            }
            if entry.url.trim().is_empty() {
                return Err(ConfigError::EmptyUrl { index: idx });
            }
            if !seen.insert(entry.name.as_str()) {
                return Err(ConfigError::DuplicateName { index: idx });
            }
        }
        Ok(())
    }

    /// Validate every enabled row's URL against the loopback gate and
    /// register each as an [`ServerRegistration::http`] in the given
    /// registry. Disabled rows are skipped.
    ///
    /// # Errors
    /// - [`ConfigError::Loopback`] on the first URL that fails the
    ///   gate. No partial registration: rows BEFORE the failing row
    ///   ARE registered (the registry is mutated as we go); the agent
    ///   supervisor logs the row and continues. This matches the
    ///   stdio surface's "best-effort spawn" posture.
    pub async fn register_all(&self, registry: &ServerRegistry) -> Result<usize, ConfigError> {
        let mut count = 0;
        for (idx, entry) in self.servers.iter().enumerate() {
            if !entry.enabled {
                continue;
            }
            let host = LoopbackHost::parse(&entry.url)
                .await
                .map_err(|source| ConfigError::Loopback { index: idx, source })?;
            let reg = ServerRegistration::http(entry.name.clone(), host, entry.auth_header.clone());
            registry.register(reg).await;
            count += 1;
        }
        Ok(count)
    }
}

fn is_valid_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

#[cfg(unix)]
fn validate_permissions(meta: &std::fs::Metadata) -> Result<(), ConfigError> {
    use std::os::unix::fs::MetadataExt;
    let mode = meta.mode() & 0o777;
    if mode & 0o077 != 0 {
        return Err(ConfigError::Permissions);
    }
    if meta.uid() != current_uid() {
        return Err(ConfigError::Permissions);
    }
    Ok(())
}

/// One narrowly-scoped `unsafe` to read the running process's real uid
/// through `libc::getuid()`. The lib root uses `#![deny(unsafe_code)]`;
/// this `#[allow]` is the single exception in the crate. `getuid(3)`
/// cannot fail and is async-signal-safe.
///
/// Real uid (not effective) matches the Swift onboarding writer's
/// `getuid()` call inside `apps/onboarding/Sources/OnboardingKit/
/// McpServersStore.swift` and is consistent with the
/// `apps/agent/src/user_allowlist.rs` reader from Director-Brain V2-P10
/// (PR #276), which validates `user-allowlist.toml` against `getuid()`
/// rather than `geteuid()`. For `mci-agent` the two are equal (the
/// agent never changes uid), but aligning the discipline across both
/// readers ("real uid == the uid the Swift side asserted on write") is
/// the binding invariant for future audits.
#[cfg(unix)]
#[allow(unsafe_code)]
fn current_uid() -> u32 {
    // Safety: `getuid()` is a thread-safe POSIX call with no
    // pre-conditions and no failure mode. Returns the calling
    // process's real uid as `uid_t` (u32 on every supported
    // macOS / Linux ABI).
    unsafe { libc::getuid() }
}

#[cfg(not(unix))]
fn validate_permissions(_meta: &std::fs::Metadata) -> Result<(), ConfigError> {
    // Non-Unix targets (Windows) do not have POSIX permission bits.
    // The Windows agent will gain an ACL-based equivalent when the
    // Windows port (DESIGN.md Phase 9) lands; for now, accept.
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_empty_config() {
        let cfg: McpServersConfig = toml::from_str("").unwrap();
        assert!(cfg.servers.is_empty());
        cfg.check_invariants().unwrap();
    }

    #[test]
    fn parses_minimal_config() {
        let body = r#"
[[server]]
name = "gchat"
url = "http://127.0.0.1:7890/mcp"
"#;
        let cfg: McpServersConfig = toml::from_str(body).unwrap();
        assert_eq!(cfg.servers.len(), 1);
        assert_eq!(cfg.servers[0].name, "gchat");
        assert!(cfg.servers[0].enabled);
        assert!(cfg.servers[0].auth_header.is_none());
    }

    #[test]
    fn parses_full_config() {
        let body = r#"
[[server]]
name = "gchat"
url = "http://127.0.0.1:7890/mcp"
auth_header = "Bearer x"
enabled = false
"#;
        let cfg: McpServersConfig = toml::from_str(body).unwrap();
        assert_eq!(cfg.servers[0].auth_header.as_deref(), Some("Bearer x"));
        assert!(!cfg.servers[0].enabled);
    }

    #[test]
    fn rejects_unknown_field() {
        let body = r#"
[[server]]
name = "x"
url = "http://127.0.0.1/"
extra_field = "no"
"#;
        let err = toml::from_str::<McpServersConfig>(body).expect_err("unknown field");
        let msg = err.to_string();
        assert!(msg.contains("extra_field"), "got: {msg}");
    }

    #[test]
    fn rejects_unknown_top_level() {
        let body = r#"
totally_made_up = true

[[server]]
name = "x"
url = "http://127.0.0.1/"
"#;
        let err = toml::from_str::<McpServersConfig>(body).expect_err("unknown top-level");
        let msg = err.to_string();
        assert!(msg.contains("totally_made_up"), "got: {msg}");
    }

    #[test]
    fn duplicate_name_fails_invariants() {
        let body = r#"
[[server]]
name = "x"
url = "http://127.0.0.1/"

[[server]]
name = "x"
url = "http://127.0.0.2/"
"#;
        let cfg: McpServersConfig = toml::from_str(body).unwrap();
        let err = cfg.check_invariants().expect_err("duplicate");
        assert!(matches!(err, ConfigError::DuplicateName { index: 1 }));
    }

    #[test]
    fn bad_name_fails_invariants() {
        let body = r#"
[[server]]
name = "has spaces"
url = "http://127.0.0.1/"
"#;
        let cfg: McpServersConfig = toml::from_str(body).unwrap();
        let err = cfg.check_invariants().expect_err("bad name");
        assert!(matches!(err, ConfigError::BadName { index: 0 }));
    }

    #[test]
    fn empty_url_fails_invariants() {
        let body = r#"
[[server]]
name = "x"
url = ""
"#;
        let cfg: McpServersConfig = toml::from_str(body).unwrap();
        let err = cfg.check_invariants().expect_err("empty url");
        assert!(matches!(err, ConfigError::EmptyUrl { index: 0 }));
    }

    #[tokio::test]
    async fn register_all_skips_disabled() {
        let cfg = McpServersConfig {
            servers: vec![
                McpServerEntry {
                    name: "a".into(),
                    url: "http://127.0.0.1/mcp".into(),
                    auth_header: None,
                    enabled: true,
                },
                McpServerEntry {
                    name: "b".into(),
                    url: "http://127.0.0.1/mcp".into(),
                    auth_header: None,
                    enabled: false,
                },
            ],
        };
        let reg = ServerRegistry::new();
        let count = cfg.register_all(&reg).await.unwrap();
        assert_eq!(count, 1);
        assert_eq!(reg.len().await, 1);
        assert!(reg.get("a").await.is_some());
        assert!(reg.get("b").await.is_none());
    }

    #[tokio::test]
    async fn register_all_rejects_non_loopback_url() {
        let cfg = McpServersConfig {
            servers: vec![McpServerEntry {
                name: "bad".into(),
                url: "http://192.168.1.1/mcp".into(),
                auth_header: None,
                enabled: true,
            }],
        };
        let reg = ServerRegistry::new();
        let err = cfg.register_all(&reg).await.expect_err("non-loopback");
        assert!(matches!(err, ConfigError::Loopback { index: 0, .. }));
    }

    #[tokio::test]
    async fn load_missing_file_returns_not_found() {
        let err = McpServersConfig::load(Path::new("/tmp/does-not-exist-mci-cfg.toml"))
            .await
            .expect_err("missing");
        assert!(matches!(err, ConfigError::NotFound));
    }

    #[tokio::test]
    async fn load_rejects_loose_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile_dir();
        let path = dir.join("mcp-servers.toml");
        tokio::fs::write(&path, "").await.unwrap();
        let mut perms = tokio::fs::metadata(&path).await.unwrap().permissions();
        perms.set_mode(0o644);
        tokio::fs::set_permissions(&path, perms).await.unwrap();
        let err = McpServersConfig::load(&path)
            .await
            .expect_err("loose perms");
        assert!(matches!(err, ConfigError::Permissions));
        let _ = tokio::fs::remove_file(&path).await;
    }

    #[tokio::test]
    async fn load_accepts_0600() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile_dir();
        let path = dir.join("mcp-servers.toml");
        let body = r#"
[[server]]
name = "x"
url = "http://127.0.0.1/mcp"
"#;
        tokio::fs::write(&path, body).await.unwrap();
        let mut perms = tokio::fs::metadata(&path).await.unwrap().permissions();
        perms.set_mode(0o600);
        tokio::fs::set_permissions(&path, perms).await.unwrap();
        let cfg = McpServersConfig::load(&path).await.expect("0600 load");
        assert_eq!(cfg.servers.len(), 1);
        let _ = tokio::fs::remove_file(&path).await;
    }

    fn tempfile_dir() -> PathBuf {
        // Per-call counter so multiple tests sharing this helper do
        // not clobber each other's files. Order of test execution is
        // not guaranteed; a stable per-process subdir was not enough.
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let mut p = std::env::temp_dir();
        p.push(format!("mci-mcp-client-config-{}-{n}", std::process::id()));
        std::fs::create_dir_all(&p).unwrap();
        p
    }
}
