//! Integration tests for `mci-agent mcp-sync`.
//!
//! Pins the gap this closes. The V2-MCP-3 aggregator pulls resources
//! from user-registered MCP servers into the brain, tagged
//! `app_bundle_id = "mcp:<server>"`. It was constructed at exactly one
//! place, `spawn_mcp_aggregator` in `apps/agent/src/bin/mci_agent.rs`,
//! inside the `--drain-stdin` arm. `--drain-stdin` is live capture and
//! live capture ships off, so a server the user registered in
//! `mcp-servers.toml` never reached the brain.
//!
//! Two levels here, on purpose:
//!
//! - **Library.** [`mci_agent::mcp_sync::run_mcp_sync`] against a real
//!   `SqlCipherBrainStore` and a real loopback MCP server, so the
//!   assertions can read rows and counters directly.
//! - **CLI.** The actual `mci-agent` binary, run as a subprocess with
//!   `HOME` pointed at a temp dir so it resolves the real default config
//!   path. This is what proves the exit codes and the user-facing
//!   messages, which no library test can.
//!
//! # Why the HTTP stub and not the stdio echo fixture
//!
//! `core/mcp-client/tests/fixtures/echo_server.rs` is a stdio MCP
//! server, and `mcp-servers.toml` cannot register one: the schema in
//! `core/mcp-client/src/config.rs` carries `url` only, and
//! `register_all` builds `ServerRegistration::http` exclusively. A
//! stdio row is unreachable from the config file, so it cannot exercise
//! the path this command takes. These tests reuse
//! `core/mcp-client/tests/stub_server.rs`, the loopback HTTP+SSE stub
//! that `mcp_aggregator_wiring.rs` already shares the same way.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use mci_agent::mcp_sync::{run_mcp_sync, McpSyncError, SyncOutcome, CONFIG_EXAMPLE};
use mci_brain::{BrainStore, EventId, SqlCipherBrainStore};
use mci_core::crypto::DbKey;
use mci_mcp_client::McpServersConfig;
use tempfile::TempDir;

// Same sharing trick `mcp_aggregator_wiring.rs` uses. `#[path]` resolves
// relative to this file.
#[path = "../../../core/mcp-client/tests/stub_server.rs"]
mod stub_server;
use stub_server::{StubMcpServer, StubResource};

const KEY_BYTES: [u8; 32] = [0xAB; 32];
const KEY_HEX: &str = "abababababababababababababababababababababababababababababababab";

fn open_store(path: &Path) -> Arc<SqlCipherBrainStore> {
    Arc::new(SqlCipherBrainStore::new(path, &DbKey::from_bytes(KEY_BYTES)).expect("open store"))
}

/// Write `body` to `<home>/Library/Application Support/MCI/mcp-servers.toml`
/// at `mode`, creating the directory. Returns the file path.
fn write_config(home: &Path, body: &str, mode: u32) -> PathBuf {
    let dir = home.join("Library/Application Support/MCI");
    std::fs::create_dir_all(&dir).expect("create config dir");
    let path = dir.join("mcp-servers.toml");
    std::fs::write(&path, body).expect("write config");
    let mut perms = std::fs::metadata(&path).expect("stat config").permissions();
    perms.set_mode(mode);
    std::fs::set_permissions(&path, perms).expect("chmod config");
    path
}

fn one_server_toml(name: &str, port: u16) -> String {
    format!("[[server]]\nname = \"{name}\"\nurl = \"http://127.0.0.1:{port}/sse\"\n")
}

/// Sweep every event in the store. There is no "list all" read on the
/// trait, so walk ids from 1 the way `mcp_aggregator_wiring.rs` does.
fn read_all(store: &SqlCipherBrainStore) -> Vec<mci_brain::Event> {
    let mut out = Vec::new();
    for i in 1u64..500 {
        match store.get_event(EventId(i)) {
            Ok(Some(ev)) => out.push(ev),
            Ok(None) => continue,
            Err(_) => break,
        }
    }
    out
}

/// Run the real `mci-agent mcp-sync` as a subprocess. `HOME` is the temp
/// dir, so the binary resolves the production config path inside it.
/// Returns `(exit code, stdout + stderr)`.
async fn run_cli(home: &Path, db_path: &Path) -> (i32, String) {
    let out = tokio::process::Command::new(env!("CARGO_BIN_EXE_mci-agent"))
        .arg("mcp-sync")
        .arg("--db-path")
        .arg(db_path)
        .env("HOME", home)
        .env("MCI_DB_KEY_HEX", KEY_HEX)
        .env_remove("MCI_DB_PATH")
        .env_remove("MCI_CRASH_REPORT_URL")
        .env_remove("MCI_CRASH_REPORT_OPTED_IN")
        .output()
        .await
        .expect("spawn mci-agent");
    let mut combined = String::from_utf8_lossy(&out.stdout).into_owned();
    combined.push_str(&String::from_utf8_lossy(&out.stderr));
    (out.status.code().unwrap_or(-1), combined)
}

// ---------------------------------------------------------------------------
// The pass itself
// ---------------------------------------------------------------------------

#[tokio::test]
async fn sync_writes_events_carrying_the_mcp_source_prefix() {
    let home = TempDir::new().expect("tempdir");
    let store = open_store(&home.path().join("brain.sqlite"));

    let server = StubMcpServer::start().await;
    server
        .set_resources(vec![
            StubResource::new(
                "svc://channels/C1",
                "design-review",
                "the design looks good",
            ),
            StubResource::new(
                "svc://channels/C2",
                "engineering",
                "we shipped mcp-sync today",
            ),
        ])
        .await;
    let cfg = write_config(home.path(), &one_server_toml("slack", server.port()), 0o600);

    let outcome = run_mcp_sync(&cfg, Arc::clone(&store))
        .await
        .expect("sync runs");
    let SyncOutcome::Ran(stats) = outcome else {
        panic!("expected a pass to run, got {outcome:?}");
    };

    assert_eq!(stats.servers_contacted, 1);
    assert_eq!(stats.servers_ok, 1, "the stub server should answer");
    assert_eq!(stats.servers_failed, 0);
    assert_eq!(stats.resources_discovered, 2);
    assert_eq!(stats.resources_materialized, 2);
    assert_eq!(stats.resources_cataloged, 0);
    assert_eq!(
        stats.events_written, 2,
        "counted as a store delta, not as rows offered"
    );

    let events = read_all(&store);
    assert_eq!(events.len(), 2);
    for ev in &events {
        // The `mcp:` prefix is the structural discriminator the chat
        // surface routes prompt-injection mitigation on. Losing it is
        // the failure this asserts against.
        assert_eq!(
            ev.app_bundle_id.as_deref(),
            Some("mcp:slack"),
            "every synced event carries the mcp: source tag"
        );
        assert_eq!(ev.cascade_reason, 0, "MCP events ingest at the Allow arm");
    }
    let bodies: Vec<&str> = events.iter().map(|e| e.text.as_str()).collect();
    assert!(bodies.iter().any(|b| b.contains("the design looks good")));
    assert!(bodies
        .iter()
        .any(|b| b.contains("we shipped mcp-sync today")));

    server.shutdown().await;
}

#[tokio::test]
async fn a_second_sync_writes_nothing() {
    // The aggregator's dedupe set is in-memory and per-process. A
    // command that exits would start cold every time and duplicate
    // everything, so the sync seeds the set from the brain first. This
    // is the assertion that keeps that wired.
    let home = TempDir::new().expect("tempdir");
    let db = home.path().join("brain.sqlite");
    let store = open_store(&db);

    let server = StubMcpServer::start().await;
    server
        .set_resources(vec![
            StubResource::new("svc://r1", "r1", "first body"),
            StubResource::new("svc://r2", "r2", "second body"),
        ])
        .await;
    let cfg = write_config(home.path(), &one_server_toml("gchat", server.port()), 0o600);

    let SyncOutcome::Ran(first) = run_mcp_sync(&cfg, Arc::clone(&store)).await.expect("first")
    else {
        panic!("first run should sync");
    };
    assert_eq!(first.events_written, 2);
    let count_after_first = store.stats().expect("stats").event_count;

    let SyncOutcome::Ran(second) = run_mcp_sync(&cfg, Arc::clone(&store))
        .await
        .expect("second")
    else {
        panic!("second run should sync");
    };
    assert_eq!(
        second.events_written, 0,
        "a re-run over an unchanged server writes nothing"
    );
    assert_eq!(
        second.resources_materialized, 0,
        "nothing is re-read, so nothing is re-materialized"
    );
    assert_eq!(
        second.resources_discovered, 2,
        "the resources are still discovered; they are just skipped"
    );
    assert_eq!(
        store.stats().expect("stats").event_count,
        count_after_first,
        "no duplicate rows in the brain"
    );

    server.shutdown().await;
}

#[tokio::test]
async fn a_new_resource_after_a_sync_is_picked_up() {
    // The flip side of idempotence: skipping seen URIs must not mean
    // skipping everything forever.
    let home = TempDir::new().expect("tempdir");
    let store = open_store(&home.path().join("brain.sqlite"));

    let server = StubMcpServer::start().await;
    server
        .set_resources(vec![StubResource::new("svc://r1", "r1", "first body")])
        .await;
    let cfg = write_config(home.path(), &one_server_toml("svc", server.port()), 0o600);

    let SyncOutcome::Ran(first) = run_mcp_sync(&cfg, Arc::clone(&store)).await.expect("first")
    else {
        panic!("first run should sync");
    };
    assert_eq!(first.events_written, 1);

    server
        .set_resources(vec![
            StubResource::new("svc://r1", "r1", "first body"),
            StubResource::new("svc://r2", "r2", "brand new body"),
        ])
        .await;

    let SyncOutcome::Ran(second) = run_mcp_sync(&cfg, Arc::clone(&store))
        .await
        .expect("second")
    else {
        panic!("second run should sync");
    };
    assert_eq!(second.resources_discovered, 2);
    assert_eq!(
        second.events_written, 1,
        "only the new resource is written the second time"
    );

    let bodies: Vec<String> = read_all(&store).into_iter().map(|e| e.text).collect();
    assert!(bodies.iter().any(|b| b.contains("brand new body")));

    server.shutdown().await;
}

#[tokio::test]
async fn an_oversized_resource_is_cataloged_and_counted_apart() {
    // The materialize-or-catalog split is the aggregator's, but the
    // report has to keep the two apart or the numbers mean nothing.
    let home = TempDir::new().expect("tempdir");
    let store = open_store(&home.path().join("brain.sqlite"));

    let big = "X".repeat(600 * 1024); // over the 512 KB materialize cap
    let server = StubMcpServer::start().await;
    server
        .set_resources(vec![
            StubResource::new("svc://small", "small", "a short body"),
            StubResource::new("svc://big", "big", &big),
        ])
        .await;
    let cfg = write_config(
        home.path(),
        &one_server_toml("notion", server.port()),
        0o600,
    );

    let SyncOutcome::Ran(stats) = run_mcp_sync(&cfg, store).await.expect("sync") else {
        panic!("expected a pass to run");
    };
    assert_eq!(stats.resources_discovered, 2);
    assert_eq!(stats.resources_materialized, 1);
    assert_eq!(stats.resources_cataloged, 1);
    assert_eq!(stats.events_written, 2, "both land as rows");

    server.shutdown().await;
}

#[tokio::test]
async fn a_server_that_is_not_running_is_counted_not_fatal() {
    let home = TempDir::new().expect("tempdir");
    let store = open_store(&home.path().join("brain.sqlite"));
    // Port 1 is reserved and nothing listens there.
    let cfg = write_config(home.path(), &one_server_toml("ghost", 1), 0o600);

    let SyncOutcome::Ran(stats) = run_mcp_sync(&cfg, store)
        .await
        .expect("sync still returns Ok")
    else {
        panic!("expected a pass to run");
    };
    assert_eq!(stats.servers_contacted, 1);
    assert_eq!(stats.servers_ok, 0);
    assert_eq!(stats.servers_failed, 1);
    assert_eq!(stats.events_written, 0);
}

// ---------------------------------------------------------------------------
// Config problems
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_missing_config_is_zero_servers_configured_not_an_error() {
    let home = TempDir::new().expect("tempdir");
    let store = open_store(&home.path().join("brain.sqlite"));
    let cfg = home
        .path()
        .join("Library/Application Support/MCI/mcp-servers.toml");

    let outcome = run_mcp_sync(&cfg, store).await.expect("not an error");
    assert_eq!(outcome, SyncOutcome::NoConfig { path: cfg });
}

#[tokio::test]
async fn a_config_with_no_enabled_servers_reports_zero_servers() {
    let home = TempDir::new().expect("tempdir");
    let store = open_store(&home.path().join("brain.sqlite"));
    let cfg = write_config(
        home.path(),
        "[[server]]\nname = \"off\"\nurl = \"http://127.0.0.1:9/mcp\"\nenabled = false\n",
        0o600,
    );

    let outcome = run_mcp_sync(&cfg, store).await.expect("not an error");
    assert_eq!(outcome, SyncOutcome::NoServers { path: cfg });
}

#[tokio::test]
async fn a_world_readable_config_is_refused_in_plain_language() {
    let home = TempDir::new().expect("tempdir");
    let store = open_store(&home.path().join("brain.sqlite"));
    let cfg = write_config(home.path(), &one_server_toml("svc", 9), 0o644);

    let err = run_mcp_sync(&cfg, store).await.expect_err("must refuse");
    assert!(
        matches!(err, McpSyncError::InsecurePermissions { .. }),
        "got {err:?}"
    );
    let msg = err.to_string();
    assert!(msg.contains("chmod 600"), "must say how to fix it: {msg}");
    assert!(
        msg.contains("mcp-servers.toml"),
        "must name the file: {msg}"
    );
    assert!(
        !msg.contains("audit row"),
        "the loader's internal wording must not reach the user: {msg}"
    );
}

#[tokio::test]
async fn a_non_loopback_url_is_refused_with_the_reason() {
    let home = TempDir::new().expect("tempdir");
    let store = open_store(&home.path().join("brain.sqlite"));
    let cfg = write_config(
        home.path(),
        "[[server]]\nname = \"remote\"\nurl = \"http://192.168.1.10:7890/mcp\"\n",
        0o600,
    );

    let err = run_mcp_sync(&cfg, store).await.expect_err("must refuse");
    assert!(matches!(err, McpSyncError::BadConfig { .. }), "got {err:?}");
    assert!(
        err.to_string().contains("loopback"),
        "the message should explain the rule: {err}"
    );
}

#[tokio::test]
async fn the_example_we_print_loads_through_the_real_loader() {
    // The guidance shows a config block. If it does not parse, the
    // instructions are worse than none.
    let home = TempDir::new().expect("tempdir");
    let cfg = write_config(home.path(), CONFIG_EXAMPLE, 0o600);
    let loaded = McpServersConfig::load(&cfg).await.expect("example loads");
    assert_eq!(loaded.servers.len(), 1);
    assert_eq!(loaded.servers[0].name, "my-server");
    assert!(loaded.servers[0].enabled, "enabled defaults to true");
}

// ---------------------------------------------------------------------------
// The binary. Exit codes and user-facing messages.
// ---------------------------------------------------------------------------

#[tokio::test]
async fn cli_help_lists_mcp_sync() {
    let out = tokio::process::Command::new(env!("CARGO_BIN_EXE_mci-agent"))
        .arg("--help")
        .output()
        .await
        .expect("spawn");
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    assert!(text.contains("mcp-sync"), "--help must list the subcommand");
    assert!(
        text.contains("mcp-servers.toml"),
        "--help must name the config file"
    );
}

#[tokio::test]
async fn cli_exits_zero_and_says_where_to_create_the_config() {
    let home = TempDir::new().expect("tempdir");
    let (code, out) = run_cli(home.path(), &home.path().join("brain.sqlite")).await;

    assert_eq!(code, 0, "no config is not a failure. output: {out}");
    assert!(
        out.contains("Library/Application Support/MCI/mcp-servers.toml"),
        "must name the path to create: {out}"
    );
    assert!(
        out.contains("chmod 600"),
        "must say how to create it: {out}"
    );
    assert!(out.contains("[[server]]"), "must show an example: {out}");
}

#[tokio::test]
async fn cli_refuses_a_world_readable_config_and_says_how_to_fix_it() {
    let home = TempDir::new().expect("tempdir");
    write_config(home.path(), &one_server_toml("svc", 9), 0o644);
    let (code, out) = run_cli(home.path(), &home.path().join("brain.sqlite")).await;

    assert_ne!(code, 0, "a config that cannot be trusted is a failure");
    assert!(out.contains("chmod 600"), "must be actionable: {out}");
}

#[tokio::test]
async fn cli_pulls_a_registered_server_into_the_brain_and_re_runs_clean() {
    let home = TempDir::new().expect("tempdir");
    let db = home.path().join("brain.sqlite");

    let server = StubMcpServer::start().await;
    server
        .set_resources(vec![StubResource::new(
            "svc://hello",
            "hello",
            "hello from the fixture server",
        )])
        .await;
    write_config(
        home.path(),
        &one_server_toml("fixture", server.port()),
        0o600,
    );

    let (code, out) = run_cli(home.path(), &db).await;
    assert_eq!(code, 0, "output: {out}");
    assert!(
        out.contains("1 event(s) written"),
        "the report must carry real numbers: {out}"
    );

    {
        let store = open_store(&db);
        let events = read_all(&store);
        assert_eq!(events.len(), 1, "the resource reached the brain");
        assert_eq!(events[0].app_bundle_id.as_deref(), Some("mcp:fixture"));
        assert!(events[0].text.contains("hello from the fixture server"));
    }

    // Second invocation, a genuinely cold process.
    let (code2, out2) = run_cli(home.path(), &db).await;
    assert_eq!(code2, 0, "output: {out2}");
    assert!(
        out2.contains("0 event(s) written"),
        "a re-run must report doing nothing: {out2}"
    );

    {
        let store = open_store(&db);
        assert_eq!(
            store.stats().expect("stats").event_count,
            1,
            "no duplicate row from the second process"
        );
    }

    server.shutdown().await;
}
