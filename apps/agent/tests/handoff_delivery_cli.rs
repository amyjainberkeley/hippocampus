//! End-to-end checks for `connect --all`, `disconnect --all` and the doctor's
//! handoff sections, driven through the real binary under a temporary HOME.
//!
//! Every invocation passes `--no-refresh-agent`: the `LaunchAgent` path talks
//! to the user's real launchd domain and is covered by unit tests with an
//! injected runner instead. The subprocess environment is built from
//! scratch so no key material or unrelated variables leak in.

use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use mci_brain::SqlCipherBrainStore;
use mci_core::crypto::DbKey;

fn agent_bin() -> PathBuf {
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop();
    if path.ends_with("deps") {
        path.pop();
    }
    path.push("mci-agent");
    path
}

fn fake_client(path: &Path) {
    std::fs::write(path, b"#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
}

/// A minimal, explicit environment: HOME, a PATH for `/bin/sh`, and the
/// Codex home. Nothing inherited.
fn run(home: &Path, codex_home: &Path, fakes: Option<&Path>, args: &[&str]) -> Output {
    let mut command = Command::new(agent_bin());
    command
        .args(args)
        .env_clear()
        .env("HOME", home)
        .env("PATH", "/usr/bin:/bin")
        .env("CODEX_HOME", codex_home)
        .env("MCI_BRIEF_TZ_OFFSET_SECONDS", "-25200");
    if let Some(fake) = fakes {
        command
            .env("MCI_CLAUDE_BINARY", fake)
            .env("MCI_CODEX_BINARY", fake);
    }
    command.output().expect("run mci-agent")
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

fn json(path: &Path) -> serde_json::Value {
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

#[test]
fn register_clients_preserves_hooks_and_refresh_configuration() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let codex_home = home.join("codex-home");
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    std::fs::create_dir_all(&codex_home).unwrap();
    let launch_agents = home.join("Library/LaunchAgents");
    std::fs::create_dir_all(&launch_agents).unwrap();
    let fake = temp.path().join("fake-client");
    fake_client(&fake);
    let brain = home.join("brain.sqlite");
    let protected = [
        (home.join(".claude/settings.json"), "{\"theme\":\"dark\"}\n"),
        (codex_home.join("hooks.json"), "{\"hooks\":{}}\n"),
        (
            launch_agents.join("ai.hippocampus.refresh.plist"),
            "untouched existing fixture\n",
        ),
    ];
    for (path, content) in &protected {
        std::fs::write(path, content).unwrap();
    }
    let output = run(
        &home,
        &codex_home,
        Some(&fake),
        &[
            "register-clients",
            "--no-refresh-agent",
            "--db-path",
            brain.to_str().unwrap(),
        ],
    );
    assert!(output.status.success(), "{}", stderr(&output));
    for (path, content) in &protected {
        assert_eq!(std::fs::read_to_string(path).unwrap(), *content);
    }
    assert!(json(&home.join(".claude.json"))["mcpServers"]["hippocampus"].is_object());
    assert!(std::fs::read_to_string(codex_home.join("config.toml"))
        .unwrap()
        .contains("mcp_servers.hippocampus"));
    assert!(
        !brain.exists(),
        "registration must not open/import the brain"
    );
    assert!(stdout(&output).contains("Session hooks and transcript refresh were not changed"));
}

#[test]
#[allow(clippy::too_many_lines)] // One story: install, repeat, disconnect, repeat.
fn connect_installs_both_hooks_and_disconnect_removes_only_ours() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let codex_home = home.join("codex-home");
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    std::fs::create_dir_all(&codex_home).unwrap();
    let fake = temp.path().join("fake-client");
    fake_client(&fake);
    let brain = home.join("brain.sqlite");

    // Claude Code: an unrelated PreToolUse hook and the group the
    // Hippocampus.app Swift installer writes.
    let settings = home.join(".claude/settings.json");
    std::fs::write(
        &settings,
        serde_json::to_string_pretty(&serde_json::json!({
            "hooks": {
                "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo pre"}]}],
                "SessionStart": [{"matcher": "startup|resume|clear|compact", "hooks": [{
                    "type": "command",
                    "command": "'/Applications/Hippocampus.app/Contents/MacOS/Hippocampus' '--claude-session-context' '--db-path' '/old'",
                    "timeout": 10
                }]}]
            },
            "theme": "dark"
        }))
        .unwrap(),
    )
    .unwrap();
    // Codex: someone else's SessionStart hook and hooks switched off.
    let hooks = codex_home.join("hooks.json");
    std::fs::write(
        &hooks,
        serde_json::to_string_pretty(&serde_json::json!({
            "description": "mine",
            "hooks": {"SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "echo theirs"}]}]}
        }))
        .unwrap(),
    )
    .unwrap();
    let config = codex_home.join("config.toml");
    std::fs::write(&config, "model = \"gpt-5\"\n\n[features]\nhooks = false\n").unwrap();

    let first = run(
        &home,
        &codex_home,
        Some(&fake),
        &[
            "connect",
            "--all",
            "--no-refresh-agent",
            "--db-path",
            brain.to_str().unwrap(),
        ],
    );
    assert!(first.status.success(), "stderr: {}", stderr(&first));
    let out = stdout(&first);
    assert!(
        out.contains("  claude-code: MCP registered, SessionStart hook updated\n"),
        "{out}"
    );
    assert!(
        out.contains("  codex: MCP registered, SessionStart hook installed (config.toml sets [features] hooks = false;"),
        "{out}"
    );
    assert!(
        out.contains("  refresh: LaunchAgent skipped (--no-refresh-agent)\n"),
        "{out}"
    );
    assert!(!home.join("Library/LaunchAgents").exists());

    let exe = agent_bin().canonicalize().unwrap();
    let expected_claude = format!(
        "'{}' handoff --format claude-hook --db-path '{}'",
        exe.display(),
        brain.display()
    );
    let value = json(&settings);
    assert_eq!(value["theme"], "dark");
    assert_eq!(
        value["hooks"]["PreToolUse"][0]["hooks"][0]["command"],
        "echo pre"
    );
    let groups = value["hooks"]["SessionStart"].as_array().unwrap();
    assert_eq!(groups.len(), 1, "the Swift group is replaced, not kept");
    assert_eq!(groups[0]["matcher"], "startup|resume|clear|compact");
    assert_eq!(groups[0]["hooks"][0]["command"], expected_claude);
    assert_eq!(groups[0]["hooks"][0]["timeout"], 10);

    let value = json(&hooks);
    assert_eq!(value["description"], "mine");
    let groups = value["hooks"]["SessionStart"].as_array().unwrap();
    assert_eq!(groups.len(), 2);
    assert_eq!(groups[0]["hooks"][0]["command"], "echo theirs");
    assert_eq!(groups[1]["matcher"], "*");
    assert_eq!(
        groups[1]["hooks"][0]["command"],
        format!(
            "'{}' handoff --format codex-hook --db-path '{}'",
            exe.display(),
            brain.display()
        )
    );
    assert_eq!(groups[1]["hooks"][0]["additionalContextLimit"], 2500);
    let config_text = std::fs::read_to_string(&config).unwrap();
    assert!(
        config_text.contains("hooks = false"),
        "never flipped: {config_text}"
    );
    assert!(config_text.contains("[mcp_servers.hippocampus]"));

    // Idempotent.
    let settings_before = std::fs::read(&settings).unwrap();
    let hooks_before = std::fs::read(&hooks).unwrap();
    let second = run(
        &home,
        &codex_home,
        Some(&fake),
        &[
            "connect",
            "--all",
            "--no-refresh-agent",
            "--db-path",
            brain.to_str().unwrap(),
        ],
    );
    assert!(second.status.success(), "stderr: {}", stderr(&second));
    let out = stdout(&second);
    assert!(
        out.contains(
            "  claude-code: MCP already registered, SessionStart hook already installed\n"
        ),
        "{out}"
    );
    assert!(
        out.contains("  codex: MCP already registered, SessionStart hook already installed"),
        "{out}"
    );
    assert_eq!(std::fs::read(&settings).unwrap(), settings_before);
    assert_eq!(std::fs::read(&hooks).unwrap(), hooks_before);

    // Disconnect takes only ours.
    let third = run(
        &home,
        &codex_home,
        Some(&fake),
        &["disconnect", "--all", "--no-refresh-agent"],
    );
    assert!(third.status.success(), "stderr: {}", stderr(&third));
    let out = stdout(&third);
    assert!(
        out.contains("  claude-code: SessionStart hook removed, MCP registration left in place\n"),
        "{out}"
    );
    assert!(
        out.contains("  codex: SessionStart hook removed, MCP registration left in place\n"),
        "{out}"
    );
    let value = json(&settings);
    assert_eq!(value["theme"], "dark");
    assert_eq!(
        value["hooks"]["PreToolUse"][0]["hooks"][0]["command"],
        "echo pre"
    );
    assert!(value["hooks"].get("SessionStart").is_none());
    let value = json(&hooks);
    assert_eq!(value["description"], "mine");
    assert_eq!(value["hooks"]["SessionStart"].as_array().unwrap().len(), 1);
    assert_eq!(
        value["hooks"]["SessionStart"][0]["hooks"][0]["command"],
        "echo theirs"
    );
    let claude_json = json(&home.join(".claude.json"));
    assert!(claude_json["mcpServers"]["hippocampus"].is_object());
    assert!(std::fs::read_to_string(&config)
        .unwrap()
        .contains("[mcp_servers.hippocampus]"));

    let fourth = run(
        &home,
        &codex_home,
        Some(&fake),
        &["disconnect", "--all", "--no-refresh-agent"],
    );
    assert!(fourth.status.success());
    assert!(stdout(&fourth).contains(
        "  claude-code: SessionStart hook not installed, MCP registration left in place\n"
    ));
}

/// Detection also probes fixed install paths (`/usr/local/bin/claude`,
/// `Codex.app`), so a bare HOME does not guarantee "not installed" on a
/// developer Mac. The host-independent invariant: a client is either skipped
/// with no file created, or fully installed with our group in the file.
#[test]
fn connect_never_leaves_a_client_half_configured() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let codex_home = home.join("codex-home");
    std::fs::create_dir_all(&home).unwrap();
    let brain = home.join("brain.sqlite");

    let output = run(
        &home,
        &codex_home,
        None,
        &[
            "connect",
            "--all",
            "--no-refresh-agent",
            "--db-path",
            brain.to_str().unwrap(),
        ],
    );
    assert!(output.status.success(), "stderr: {}", stderr(&output));
    let out = stdout(&output);
    for (name, file, marker) in [
        (
            "claude-code",
            home.join(".claude/settings.json"),
            "handoff --format claude-hook",
        ),
        (
            "codex",
            codex_home.join("hooks.json"),
            "handoff --format codex-hook",
        ),
    ] {
        let skipped = out.contains(&format!("  {name}: not installed, skipped\n"));
        let installed = out.contains(&format!(
            "  {name}: MCP registered, SessionStart hook installed"
        ));
        assert!(
            skipped ^ installed,
            "{name} must be one or the other: {out}"
        );
        if skipped {
            assert!(
                !file.exists(),
                "{name} skipped but {} exists",
                file.display()
            );
        } else {
            let text = std::fs::read_to_string(&file).unwrap();
            assert!(text.contains(marker), "{name}: {text}");
        }
    }
    assert!(out.contains("  refresh: LaunchAgent skipped (--no-refresh-agent)\n"));
    assert!(!home.join("Library/LaunchAgents").exists());
}

const CONTRACT_TABLES_SQL: &str = "
    CREATE TABLE IF NOT EXISTS import_cursors (
      path          TEXT PRIMARY KEY,
      byte_offset   INTEGER NOT NULL,
      file_size     INTEGER NOT NULL,
      mtime_us      INTEGER NOT NULL,
      updated_at_us INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS handoff_deliveries (
      id             INTEGER PRIMARY KEY AUTOINCREMENT,
      ts_us          INTEGER NOT NULL,
      client         TEXT NOT NULL,
      project_root   TEXT NOT NULL,
      packet_sha256  TEXT NOT NULL,
      token_estimate INTEGER NOT NULL,
      event_ids      TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS handoff_deliveries_ts ON handoff_deliveries(ts_us);
";

fn run_doctor(home: &Path, codex_home: &Path, brain: &Path) -> Output {
    Command::new(agent_bin())
        .args(["doctor", "--db-path"])
        .arg(brain)
        .env_clear()
        .env("HOME", home)
        .env("PATH", "/usr/bin:/bin")
        .env("CODEX_HOME", codex_home)
        .env("MCI_BRIEF_TZ_OFFSET_SECONDS", "-25200")
        .env("MCI_DEVELOPMENT_FILE_KEY", "1")
        .env(
            "MCI_DB_KEYCHAIN_SERVICE",
            "ai.hippocampus.tests.handoff.missing",
        )
        .env("MCI_DB_KEYCHAIN_ACCOUNT", "never-created")
        .env("MCI_DB_KEYCHAIN_STORAGE_MODEL", "file-keychain-acl-v1")
        .env("MCI_DB_KEY_HEX", "aa".repeat(32))
        .output()
        .expect("run doctor")
}

#[test]
fn doctor_reports_transcripts_and_delivery_with_and_without_the_tables() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let codex_home = home.join("codex-home");
    std::fs::create_dir_all(&home).unwrap();
    let brain = home.join("brain.sqlite");
    let key = DbKey::from_bytes([0xaa; 32]);
    drop(SqlCipherBrainStore::new(&brain, &key).expect("create brain"));
    {
        // Migrations 0011 and 0012 create these on every fresh brain. Drop them
        // so the first doctor run sees an older brain, which is the case the
        // "not available yet" wording exists for.
        let db = mci_core::store::open(&brain, &key).expect("open brain read-write");
        db.conn()
            .execute_batch("DROP INDEX IF EXISTS handoff_deliveries_ts; DROP TABLE IF EXISTS handoff_deliveries; DROP TABLE IF EXISTS import_cursors;")
            .unwrap();
    }
    let claude_transcript = home.join(".claude/projects/-Users-amy-proj/session.jsonl");
    let codex_transcript = codex_home.join("sessions/2026/09/26/rollout.jsonl");
    for path in [&claude_transcript, &codex_transcript] {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, "{}\n").unwrap();
    }

    let before = run_doctor(&home, &codex_home, &brain);
    let out = stdout(&before);
    assert!(out.starts_with("Hippocampus doctor: "), "{out}");
    assert!(
        out.contains("  [warn] transcripts        claude-code: 1 files; codex: 1 files; import cursors not available yet\n"),
        "{out}"
    );
    assert!(
        out.contains("  [warn] delivery           claude-code hook NOT installed; codex hook NOT installed\n"),
        "{out}"
    );
    assert!(
        out.contains("  [warn] refresh agent      not installed; packets only refresh when a session starts\n"),
        "{out}"
    );
    assert!(!out.contains('\u{2014}'), "no em dashes: {out}");

    // Stream A and B tables, created with the contract SQL.
    let db = mci_core::store::open(&brain, &key).expect("open brain read-write");
    db.conn().execute_batch(CONTRACT_TABLES_SQL).unwrap();
    db.conn()
        .execute_batch(&format!(
            "INSERT INTO import_cursors (path, byte_offset, file_size, mtime_us, updated_at_us) VALUES ('{}', 3, 3, 1, 1790327400000000);
             INSERT INTO handoff_deliveries (ts_us, client, project_root, packet_sha256, token_estimate, event_ids)
             VALUES (1790415667000000, 'claude-code', '/Users/amy/hippo-work/hippocampus', 'abc', 583, '[5012]');",
            claude_transcript.display()
        ))
        .unwrap();
    drop(db);
    let exe = agent_bin().canonicalize().unwrap();
    std::fs::create_dir_all(home.join(".claude")).unwrap();
    std::fs::write(
        home.join(".claude/settings.json"),
        serde_json::json!({"hooks": {"SessionStart": [{"matcher": "startup|resume|clear|compact", "hooks": [{
            "type": "command",
            "command": format!("'{}' handoff --format claude-hook --db-path '{}'", exe.display(), brain.display()),
            "timeout": 10
        }]}]}})
        .to_string(),
    )
    .unwrap();

    let after = run_doctor(&home, &codex_home, &brain);
    let out = stdout(&after);
    assert!(
        out.contains("  [ok  ] transcripts        claude-code: 1 files, 1 newer than last import (2026-09-25 02:10); codex: 1 files, none imported yet\n"),
        "{out}"
    );
    assert!(
        out.contains("  [warn] delivery           claude-code hook installed, last packet 2026-09-26 02:41 for /Users/amy/hippo-work/hippocampus (583 tokens); codex hook NOT installed\n"),
        "{out}"
    );
    assert!(
        out.contains("Run `mci-agent connect --all` to install the SessionStart hooks."),
        "{out}"
    );
}
