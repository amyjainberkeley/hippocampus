//! One-shot MCP sync: pull every registered MCP server's resources into
//! the brain, then exit.
//!
//! # Why this exists
//!
//! The V2-MCP-3 aggregator is the connector story. It walks each server
//! the user registered in `mcp-servers.toml`, reads what that server
//! offers, and persists it as Events tagged `app_bundle_id =
//! "mcp:<server-name>"`. It is built and tested.
//!
//! It was also unreachable. [`crate::mcp_aggregator::McpAggregator`] is
//! constructed at exactly one place, `spawn_mcp_aggregator` in
//! `apps/agent/src/bin/mci_agent.rs`, and that call sits inside the
//! `--drain-stdin` arm. `--drain-stdin` is live capture, live capture
//! ships default-OFF, so on a normal install the aggregator never ran
//! and a registered MCP server never reached the brain. Nothing about
//! the aggregator was broken. Nothing called it.
//!
//! This module is the missing caller: the same aggregator, driven for
//! one pass instead of forever. There is no second copy of the reconcile
//! logic here. [`McpAggregator::reconcile_once`] is the single pass the
//! loop already used, and this calls it directly, so the two paths
//! cannot drift.
//!
//! # Idempotence across processes
//!
//! The aggregator dedupes resources through an in-memory set scoped to
//! one process lifetime. For the long-running agent that is correct. For
//! a command that runs and exits it is not: every invocation would start
//! cold, re-read every resource, and write a duplicate event for each
//! one. So before reconciling, this seeds the aggregator's seen-set from
//! the brain itself via
//! [`SqlCipherBrainStore::distinct_urls_for_app`] — the aggregator
//! writes the resource URI verbatim into `events.url`, so for an
//! `mcp:<server>` tag that URL set is exactly the already-ingested set.
//! A second `mcp-sync` over an unchanged server writes nothing.
//!
//! # Counting
//!
//! `events_written` is measured as a delta on the store's own event
//! count, not as the number of resources the aggregator offered. The two
//! differ: a `put_event` can fail, and a resource skipped by the
//! seen-set is discovered but never written. Reporting the offered count
//! is the trap that made a no-op re-run claim it had done work.
//!
//! # What this does not change
//!
//! The `mcp:` provenance prefix, the materialize-or-catalog policy, and
//! the Fork F6 = A "no cascade-equivalent at MCP ingest" posture are all
//! the aggregator's, untouched. See
//! [`crate::mcp_aggregator`] for why each is load-bearing.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use mci_brain::{BrainStore, SqlCipherBrainStore};
use mci_mcp_client::{McpServersConfig, ServerRegistry};

use crate::mcp_aggregator::{source_tag, McpAggregator};
use crate::mcp_client_supervisor::{boot_at, BootStatus};

/// A minimal `mcp-servers.toml` that parses and registers. Shown to the
/// user when the file does not exist yet, and kept here so the README,
/// the CLI guidance, and the loader's schema cannot drift apart.
pub const CONFIG_EXAMPLE: &str = "\
[[server]]
name = \"my-server\"                       # required, unique, [a-zA-Z0-9_-]
url  = \"http://127.0.0.1:7890/mcp\"       # required, must be loopback
# auth_header = \"Bearer sk-...\"          # optional, sent as Authorization
# enabled = true                          # optional, defaults to true
";

/// Canonical config path: `~/Library/Application Support/MCI/mcp-servers.toml`.
#[must_use]
pub fn default_config_path() -> PathBuf {
    McpServersConfig::default_path()
}

/// What one sync pass did. Every field is a content-free counter: no
/// server URLs, no resource bodies, no tool names.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct McpSyncStats {
    /// Servers registered from the config file, so servers contacted.
    pub servers_contacted: u64,
    /// Servers whose full pass succeeded.
    pub servers_ok: u64,
    /// Servers that failed to connect, handshake, or finish in time.
    pub servers_failed: u64,
    /// Tools seen in `tools/list`. Cataloged in memory only; this
    /// command invokes nothing.
    pub tools_cataloged: u64,
    /// Resources named by `resources/list`, including ones already
    /// ingested by an earlier run.
    pub resources_discovered: u64,
    /// Resources read and persisted with their body.
    pub resources_materialized: u64,
    /// Resources persisted as a `[CATALOG_ONLY ...]` row: body over the
    /// size cap, or the read failed.
    pub resources_cataloged: u64,
    /// Events actually written, measured as a store delta.
    pub events_written: u64,
}

/// The three ways a sync can end without being an error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SyncOutcome {
    /// No config file. Zero servers configured, which is the normal
    /// state of a fresh install, not a failure.
    NoConfig {
        /// Where the file would have been read from.
        path: PathBuf,
    },
    /// The config parsed but registered nothing: no `[[server]]` blocks,
    /// or every one of them has `enabled = false`.
    NoServers {
        /// The file that was read.
        path: PathBuf,
    },
    /// A pass ran against at least one server.
    Ran(McpSyncStats),
}

/// Why a sync could not run. Each message is written to be read by a
/// user, not chained from a library error.
#[derive(Debug, thiserror::Error)]
pub enum McpSyncError {
    /// The file exists but is not private to this user. The loader
    /// refuses it as an audit requirement, because the file can hold an
    /// API token.
    #[error(
        "{path}\n  is readable by more than your user account, or is owned by someone else, \
         so it was not loaded.\n  \
         It can hold an API token, so Hippocampus refuses to read it otherwise.\n  \
         Fix it with:\n    chmod 600 \"{path}\"\n  \
         and check that you own it with:\n    ls -l \"{path}\""
    )]
    InsecurePermissions {
        /// The offending file.
        path: String,
    },
    /// The file exists and is private but could not be used: bad TOML,
    /// an unknown field, a duplicate name, or a URL that is not
    /// loopback.
    #[error(
        "{path}\n  could not be used: {detail}\n  \
         Every server needs a unique name matching [a-zA-Z0-9_-] and a loopback url \
         (127.0.0.1 or localhost)."
    )]
    BadConfig {
        /// The offending file.
        path: String,
        /// The loader's reason, already content-free.
        detail: String,
    },
    /// A read against the brain store failed.
    #[error("brain store: {0}")]
    Store(String),
}

/// What to tell a user who has no `mcp-servers.toml` yet. Names the
/// path, shows a working entry, and gives the two commands that create
/// the file with the permissions the loader requires.
#[must_use]
pub fn no_config_guidance(path: &Path) -> String {
    let display = path.display();
    let dir = path
        .parent()
        .map_or_else(|| ".".to_owned(), |p| p.display().to_string());
    format!(
        "No MCP servers are configured, so there was nothing to sync.\n\
         \n\
         Servers are registered in a file that does not exist yet:\n  \
         {display}\n\
         \n\
         Create it, and make it readable only by you:\n  \
         mkdir -p \"{dir}\"\n  \
         touch \"{display}\"\n  \
         chmod 600 \"{display}\"\n\
         \n\
         Then add one block per server:\n\
         \n\
         {CONFIG_EXAMPLE}\n\
         The url must be loopback. Run `mci-agent mcp-sync` again once it is saved."
    )
}

/// What to tell a user whose config exists but registers nothing.
#[must_use]
pub fn no_servers_guidance(path: &Path) -> String {
    format!(
        "No MCP servers are enabled, so there was nothing to sync.\n\
         \n\
         Read {}, and it registered zero servers. Either it has no\n\
         [[server]] blocks, or every one of them sets enabled = false.\n\
         \n\
         A working entry looks like:\n\
         \n\
         {CONFIG_EXAMPLE}",
        path.display()
    )
}

/// Run one reconcile pass over every server registered in the config at
/// `config_path`, then return. Never loops, never sleeps.
///
/// A missing file is [`SyncOutcome::NoConfig`], not an error: having no
/// MCP servers is the normal state. A file that exists but cannot be
/// trusted or parsed IS an error, because the user meant something by
/// writing it and silently ingesting nothing would hide that.
///
/// # Errors
/// See [`McpSyncError`].
pub async fn run_mcp_sync(
    config_path: &Path,
    store: Arc<SqlCipherBrainStore>,
) -> Result<SyncOutcome, McpSyncError> {
    let boot = boot_at(config_path).await;
    match &boot.status {
        BootStatus::NoConfig => {
            return Ok(SyncOutcome::NoConfig {
                path: config_path.to_owned(),
            })
        }
        BootStatus::InsecurePermissions => {
            return Err(McpSyncError::InsecurePermissions {
                path: config_path.display().to_string(),
            })
        }
        BootStatus::ConfigError(detail) => {
            return Err(McpSyncError::BadConfig {
                path: config_path.display().to_string(),
                detail: detail.clone(),
            })
        }
        BootStatus::Ok => {}
    }
    if boot.registered_count == 0 {
        return Ok(SyncOutcome::NoServers {
            path: config_path.to_owned(),
        });
    }
    sync_registry(&boot.registry, store)
        .await
        .map(SyncOutcome::Ran)
}

/// One pass over an already-built registry. Split out from
/// [`run_mcp_sync`] so a caller that holds a registry from somewhere
/// other than the config file (a test, or a future in-app "sync now"
/// button) reaches the same code.
///
/// # Errors
/// [`McpSyncError::Store`] if the before/after event count or the
/// seen-set read fails. A single server failing to connect is counted in
/// `servers_failed`, not returned, so one dead server cannot strand the
/// rest.
pub async fn sync_registry(
    registry: &Arc<ServerRegistry>,
    store: Arc<SqlCipherBrainStore>,
) -> Result<McpSyncStats, McpSyncError> {
    let registrations = registry.list().await;
    let aggregator = McpAggregator::new(
        Arc::clone(registry),
        Arc::clone(&store) as Arc<dyn BrainStore>,
        None,
    );

    // Restart-idempotence: teach this cold process what earlier runs
    // already ingested. See the module doc.
    for registration in &registrations {
        let tag = source_tag(&registration.name);
        let seen = store
            .distinct_urls_for_app(&tag)
            .map_err(|e| McpSyncError::Store(e.to_string()))?;
        aggregator
            .seed_seen_resources(&registration.name, seen)
            .await;
    }

    // Count what the store gained, not what the aggregator offered. The
    // writers can reject or skip; the delta cannot lie.
    let before = store
        .stats()
        .map_err(|e| McpSyncError::Store(e.to_string()))?
        .event_count;
    aggregator.reconcile_once().await;
    let after = store
        .stats()
        .map_err(|e| McpSyncError::Store(e.to_string()))?
        .event_count;

    let snap = aggregator.stats().snapshot();
    Ok(McpSyncStats {
        servers_contacted: registrations.len() as u64,
        servers_ok: snap.server_reconciles_ok,
        servers_failed: snap.server_reconciles_err,
        tools_cataloged: snap.tools_cataloged,
        resources_discovered: snap.resources_discovered,
        resources_materialized: snap.resources_materialized,
        resources_cataloged: snap.resources_catalog_only,
        events_written: after.saturating_sub(before),
    })
}

/// One-line summary of a pass, in the shape the other `mci-agent` arms
/// report.
#[must_use]
pub fn render_stats(stats: &McpSyncStats) -> String {
    format!(
        "{} server(s) contacted, {} failed to connect, {} resource(s) discovered, \
         {} materialized, {} cataloged, {} event(s) written.",
        stats.servers_contacted,
        stats.servers_failed,
        stats.resources_discovered,
        stats.resources_materialized,
        stats.resources_cataloged,
        stats.events_written,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guidance_names_the_path_and_shows_an_example() {
        let path = PathBuf::from("/home/someone/Library/Application Support/MCI/mcp-servers.toml");
        let msg = no_config_guidance(&path);
        assert!(msg.contains("mcp-servers.toml"));
        assert!(msg.contains("/home/someone/Library/Application Support/MCI"));
        assert!(msg.contains("chmod 600"));
        assert!(msg.contains("[[server]]"));
    }

    #[test]
    fn permission_error_says_what_to_run() {
        let err = McpSyncError::InsecurePermissions {
            path: "/tmp/mcp-servers.toml".to_owned(),
        };
        let msg = err.to_string();
        assert!(msg.contains("chmod 600"), "must be actionable: {msg}");
        assert!(
            !msg.contains("ConfigError"),
            "must not leak the error chain: {msg}"
        );
    }

    #[test]
    fn render_stats_reports_every_counter() {
        let line = render_stats(&McpSyncStats {
            servers_contacted: 2,
            servers_ok: 1,
            servers_failed: 1,
            tools_cataloged: 4,
            resources_discovered: 9,
            resources_materialized: 5,
            resources_cataloged: 2,
            events_written: 7,
        });
        assert!(line.contains("2 server(s) contacted"));
        assert!(line.contains("1 failed to connect"));
        assert!(line.contains("9 resource(s) discovered"));
        assert!(line.contains("5 materialized"));
        assert!(line.contains("2 cataloged"));
        assert!(line.contains("7 event(s) written"));
    }
}
