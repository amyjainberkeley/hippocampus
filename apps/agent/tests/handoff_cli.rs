//! The built `mci-agent` binary: hook envelopes on every failure path,
//! stdin cwd, markdown and json packets, the delivery ledger, and `today`.
//!
//! Every child runs with an explicitly constructed environment (AGENTS.md
//! test hygiene): no inherited keys, only PATH, HOME and the dev key gate.

mod handoff_fixture;

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::Instant;

use handoff_fixture::{fixture_brain, key, KEY_HEX};
use mci_agent::handoff::{fallback_envelope, DISCLAIMER, NO_MEMORY_HOOK_TEXT};
use mci_brain::SqlCipherBrainStore;

fn agent_bin() -> PathBuf {
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop();
    if path.ends_with("deps") {
        path.pop();
    }
    path.push("mci-agent");
    path
}

fn agent(home: &Path, key_hex: &str) -> Command {
    let mut command = Command::new(agent_bin());
    command
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin")
        // The fixture's day boundaries are Pacific; without this the
        // rendered day follows the host zone (UTC on CI).
        .env("TZ", "America/Los_Angeles")
        .env("HOME", home)
        .env("MCI_DEVELOPMENT_FILE_KEY", "1")
        .env("MCI_DB_KEY_HEX", key_hex)
        .stdin(Stdio::null());
    command
}

fn run(command: &mut Command) -> Output {
    command.output().expect("spawn mci-agent")
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn envelope_context(output: &Output) -> String {
    let text = stdout(output);
    assert_eq!(
        text.lines().count(),
        1,
        "exactly one line on stdout: {text:?}"
    );
    let value: serde_json::Value = serde_json::from_str(text.trim()).expect("envelope json");
    assert_eq!(value["hookSpecificOutput"]["hookEventName"], "SessionStart");
    value["hookSpecificOutput"]["additionalContext"]
        .as_str()
        .expect("additionalContext string")
        .to_owned()
}

#[test]
fn a_missing_brain_prints_the_fallback_envelope_and_exits_zero() {
    let home = tempfile::tempdir().unwrap();
    for format in ["claude-hook", "codex-hook"] {
        let started = Instant::now();
        let output = run(agent(home.path(), KEY_HEX).args([
            "handoff",
            "--format",
            format,
            "--db-path",
            "/nonexistent/hippocampus/brain.sqlite",
            "--cwd",
            "/tmp",
            "--no-refresh",
        ]));
        assert!(output.status.success(), "hook formats always exit 0");
        assert_eq!(stdout(&output).trim(), fallback_envelope());
        assert_eq!(envelope_context(&output), NO_MEMORY_HOOK_TEXT);
        assert!(
            String::from_utf8_lossy(&output.stderr).contains("no brain at"),
            "diagnostics go to stderr"
        );
        assert!(started.elapsed().as_secs() < 8, "well inside the deadline");
    }
}

#[test]
fn a_missing_brain_is_an_error_for_the_cli_formats() {
    let home = tempfile::tempdir().unwrap();
    let output = run(agent(home.path(), KEY_HEX).args([
        "handoff",
        "--db-path",
        "/nonexistent/hippocampus/brain.sqlite",
        "--cwd",
        "/tmp",
        "--no-refresh",
    ]));
    assert!(!output.status.success());
    assert!(stdout(&output).is_empty());
}

#[test]
fn a_wrong_key_prints_the_fallback_envelope_and_exits_zero() {
    let (_dir, db, root, _records) = fixture_brain();
    let home = tempfile::tempdir().unwrap();
    let wrong = "02".repeat(32);
    let output = run(agent(home.path(), &wrong).args([
        "handoff",
        "--format",
        "claude-hook",
        "--db-path",
        &db.display().to_string(),
        "--cwd",
        &root.join("hippocampus").display().to_string(),
        "--no-refresh",
    ]));
    assert!(output.status.success());
    assert_eq!(stdout(&output).trim(), fallback_envelope());
}

#[test]
fn markdown_packet_from_a_temp_brain_records_a_delivery() {
    let (_dir, db, root, _records) = fixture_brain();
    let home = tempfile::tempdir().unwrap();
    let output = run(agent(home.path(), KEY_HEX).args([
        "handoff",
        "--db-path",
        &db.display().to_string(),
        "--cwd",
        &root.join("hippocampus").display().to_string(),
        "--no-refresh",
        "--client",
        "test-client",
    ]));
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = stdout(&output);
    assert!(text.starts_with(DISCLAIMER));
    assert!(text.contains("# Handoff: hippocampus ("));
    assert!(text.contains("## Sources"));

    let store = SqlCipherBrainStore::open_readonly(&db, &key()).unwrap();
    let deliveries = store.recent_handoff_deliveries(5).unwrap();
    assert_eq!(deliveries.len(), 1, "one ledger row per run");
    assert_eq!(deliveries[0].client, "test-client");
    assert_eq!(
        deliveries[0].project_root,
        root.join("hippocampus").display().to_string()
    );
    assert!(deliveries[0].token_estimate > 0 && deliveries[0].token_estimate <= 600);
    let ids: Vec<u64> = serde_json::from_str(&deliveries[0].event_ids_json).unwrap();
    assert!(!ids.is_empty());
    assert_eq!(deliveries[0].packet_sha256.len(), 64);
}

#[test]
fn json_format_carries_packet_and_state() {
    let (_dir, db, root, _records) = fixture_brain();
    let home = tempfile::tempdir().unwrap();
    let output = run(agent(home.path(), KEY_HEX).args([
        "handoff",
        "--format",
        "json",
        "--max-tokens",
        "200",
        "--db-path",
        &db.display().to_string(),
        "--cwd",
        &root.join("hippocampus").display().to_string(),
        "--no-refresh",
    ]));
    assert!(output.status.success());
    let value: serde_json::Value = serde_json::from_str(&stdout(&output)).unwrap();
    assert_eq!(value["client"], "cli");
    assert_eq!(value["state"]["name"], "hippocampus");
    assert!(value["token_estimate"].as_u64().unwrap() <= 200);
    assert!(value["packet"].as_str().unwrap().starts_with(DISCLAIMER));
}

#[test]
fn stdin_hook_json_supplies_the_cwd() {
    let (_dir, db, root, _records) = fixture_brain();
    let home = tempfile::tempdir().unwrap();
    let mut child = agent(home.path(), KEY_HEX)
        .args([
            "handoff",
            "--format",
            "codex-hook",
            "--db-path",
            &db.display().to_string(),
            "--no-refresh",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn");
    let payload = serde_json::json!({
        "cwd": root.join("hippocampus").display().to_string(),
        "hook_event_name": "SessionStart",
        "source": "startup",
    })
    .to_string();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(payload.as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    let context = envelope_context(&output);
    assert!(context.contains("# Handoff: hippocampus ("), "{context}");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("hook_event_name=SessionStart"), "{stderr}");

    let store = SqlCipherBrainStore::open_readonly(&db, &key()).unwrap();
    let deliveries = store.recent_handoff_deliveries(5).unwrap();
    assert_eq!(
        deliveries[0].client, "codex",
        "client inferred from the format"
    );
}

#[test]
fn an_unknown_project_in_hook_format_is_the_no_memory_envelope() {
    let (_dir, db, root, _records) = fixture_brain();
    let home = tempfile::tempdir().unwrap();
    let output = run(agent(home.path(), KEY_HEX).args([
        "handoff",
        "--format",
        "claude-hook",
        "--db-path",
        &db.display().to_string(),
        "--cwd",
        &root.join("never-seen").display().to_string(),
        "--no-refresh",
    ]));
    assert!(output.status.success());
    assert_eq!(envelope_context(&output), NO_MEMORY_HOOK_TEXT);
}

#[test]
fn today_prints_the_daily_packet() {
    let (_dir, db, _root, _records) = fixture_brain();
    let home = tempfile::tempdir().unwrap();
    let output = run(agent(home.path(), KEY_HEX).args([
        "today",
        "--date",
        "2026-09-25",
        "--db-path",
        &db.display().to_string(),
    ]));
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = stdout(&output);
    assert!(text.starts_with("# Today, 2026-09-25 ("), "{text}");
    assert!(text.contains("## hippocampus ("));
    assert!(text.contains("## onekit ("));

    let output = run(agent(home.path(), KEY_HEX).args([
        "today",
        "--date",
        "2026-09-25",
        "--format",
        "json",
        "--db-path",
        &db.display().to_string(),
    ]));
    assert!(output.status.success());
    let value: serde_json::Value = serde_json::from_str(&stdout(&output)).unwrap();
    assert_eq!(value["date"], "2026-09-25");
    assert_eq!(value["projects"].as_array().unwrap().len(), 2);

    let output = run(agent(home.path(), KEY_HEX).args([
        "today",
        "--date",
        "nope",
        "--db-path",
        &db.display().to_string(),
    ]));
    assert!(!output.status.success());
}

#[test]
fn bad_format_values_are_rejected_per_command() {
    let home = tempfile::tempdir().unwrap();
    let output = run(agent(home.path(), KEY_HEX).args(["handoff", "--format", "xml"]));
    assert!(!output.status.success());
    let output = run(agent(home.path(), KEY_HEX).args(["today", "--format", "claude-hook"]));
    assert!(!output.status.success());
    let output = run(agent(home.path(), KEY_HEX).args(["context", "--format", "claude-hook"]));
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("markdown or json"));
}
