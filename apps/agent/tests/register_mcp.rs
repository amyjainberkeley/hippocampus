//! Integration tests for `mci-agent register-mcp` and key-resolution
//! behaviors (Fixes 1–4 from wave-15a).
//!
//! Each test overrides `$HOME` to a temporary directory so Claude Code's
//! real config is never touched.

use std::path::PathBuf;
use std::process::Command;

fn agent_bin() -> PathBuf {
    // `cargo test` puts test binaries under `target/<profile>/deps/`;
    // the actual `mci-agent` binary is at `target/<profile>/mci-agent`.
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop(); // remove test binary name
    if path.ends_with("deps") {
        path.pop(); // remove `deps/`
    }
    path.push("mci-agent");
    path
}

// -----------------------------------------------------------------------
// Fix 1: register-mcp writes to ~/.claude.json, NOT ~/.claude/settings.json
// -----------------------------------------------------------------------

#[test]
fn register_mcp_writes_to_claude_json_not_settings_json() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();

    let output = Command::new(agent_bin())
        .arg("register-mcp")
        .env("HOME", home)
        .output()
        .expect("spawn mci-agent");

    assert!(
        output.status.success(),
        "register-mcp failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let claude_json = home.join(".claude.json");
    assert!(
        claude_json.exists(),
        "~/.claude.json should exist after register-mcp"
    );

    let settings_json = home.join(".claude").join("settings.json");
    assert!(
        !settings_json.exists(),
        "~/.claude/settings.json should NOT be written by register-mcp"
    );

    let content: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&claude_json).unwrap()).unwrap();
    let servers = content
        .get("mcpServers")
        .expect("mcpServers key should exist");
    let hippo = servers
        .get("hippocampus")
        .expect("hippocampus entry should exist");
    assert_eq!(hippo.get("type").and_then(|v| v.as_str()), Some("stdio"));
    assert!(hippo.get("command").and_then(|v| v.as_str()).is_some());
    assert_eq!(
        hippo
            .get("args")
            .and_then(|v| v.as_array())
            .map(|a| a.len()),
        Some(1)
    );
}

// -----------------------------------------------------------------------
// Fix 2: register-mcp includes env block when dev.key exists
// -----------------------------------------------------------------------

#[test]
fn register_mcp_includes_env_block_when_dev_key_exists() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();

    let key_dir = home.join("Library/Application Support/MCI");
    std::fs::create_dir_all(&key_dir).unwrap();
    let key_hex = "a".repeat(64);
    std::fs::write(key_dir.join("dev.key"), &key_hex).unwrap();

    let output = Command::new(agent_bin())
        .arg("register-mcp")
        .env("HOME", home)
        .env_remove("MCI_DB_KEY_HEX")
        .output()
        .expect("spawn mci-agent");

    assert!(output.status.success());

    let content: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(home.join(".claude.json")).unwrap()).unwrap();
    let hippo = &content["mcpServers"]["hippocampus"];
    let env = hippo
        .get("env")
        .expect("env block should be present when dev.key exists");
    assert_eq!(
        env.get("MCI_DB_KEY_HEX").and_then(|v| v.as_str()),
        Some(key_hex.as_str())
    );
}

/// The env block is now always written, because it carries `MCI_DB_PATH`
/// as well as the key. Only the key half is conditional.
#[test]
fn register_mcp_omits_only_the_key_when_dev_key_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();

    let output = Command::new(agent_bin())
        .arg("register-mcp")
        .env("HOME", home)
        .env_remove("MCI_DB_KEY_HEX")
        .output()
        .expect("spawn mci-agent");

    assert!(output.status.success());

    let content: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(home.join(".claude.json")).unwrap()).unwrap();
    let env = &content["mcpServers"]["hippocampus"]["env"];
    assert!(
        env.get("MCI_DB_KEY_HEX").is_none(),
        "no key exists, so none should be recorded"
    );
    assert!(
        env.get("MCI_DB_PATH").is_some(),
        "the brain path must be recorded even with no key"
    );
}

/// `mcp-serve` otherwise opens the hardcoded default path. Registering
/// without recording which brain was actually filled produced a server
/// that started cleanly against an empty or missing database.
#[test]
fn register_mcp_records_the_db_path_it_was_given() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let brain = home.join("somewhere-else/brain.sqlite");

    let output = Command::new(agent_bin())
        .arg("register-mcp")
        .arg("--db-path")
        .arg(&brain)
        .env("HOME", home)
        .env_remove("MCI_DB_KEY_HEX")
        .output()
        .expect("spawn mci-agent");

    assert!(output.status.success());

    let content: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(home.join(".claude.json")).unwrap()).unwrap();
    assert_eq!(
        content["mcpServers"]["hippocampus"]["env"]["MCI_DB_PATH"].as_str(),
        Some(brain.to_str().unwrap()),
        "the registered brain must be the one the user pointed at"
    );
}

/// The docs tell users to export `MCI_DB_KEY_HEX`; registration used to
/// read only `dev.key` and silently drop it.
#[test]
fn register_mcp_honours_the_key_env_var_without_a_dev_key_file() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let key_hex = "b".repeat(64);

    let output = Command::new(agent_bin())
        .arg("register-mcp")
        .env("HOME", home)
        .env("MCI_DB_KEY_HEX", &key_hex)
        .output()
        .expect("spawn mci-agent");

    assert!(output.status.success());

    let content: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(home.join(".claude.json")).unwrap()).unwrap();
    assert_eq!(
        content["mcpServers"]["hippocampus"]["env"]["MCI_DB_KEY_HEX"].as_str(),
        Some(key_hex.as_str())
    );
}

/// A stale entry naming a binary that no longer exists is what breaks a
/// real user: Claude Code reports `failed to connect` and nothing says why.
/// Re-running must replace the path rather than keep the dead one.
#[test]
fn register_mcp_replaces_a_stale_command_path() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    std::fs::write(
        home.join(".claude.json"),
        r#"{"mcpServers":{"hippocampus":{"type":"stdio","command":"/nope/gone/mci-agent","args":["mcp-serve"]},"other":{"command":"keep-me"}}}"#,
    )
    .unwrap();

    let output = Command::new(agent_bin())
        .arg("register-mcp")
        .env("HOME", home)
        .env_remove("MCI_DB_KEY_HEX")
        .output()
        .expect("spawn mci-agent");
    assert!(output.status.success());

    let content: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(home.join(".claude.json")).unwrap()).unwrap();
    let cmd = content["mcpServers"]["hippocampus"]["command"]
        .as_str()
        .unwrap();
    assert_ne!(cmd, "/nope/gone/mci-agent", "stale path must be replaced");
    assert!(
        std::path::Path::new(cmd).exists(),
        "the recorded command must exist on disk: {cmd}"
    );
    assert_eq!(
        content["mcpServers"]["other"]["command"].as_str(),
        Some("keep-me"),
        "other MCP servers must survive untouched"
    );
}

#[test]
fn register_mcp_warns_stderr_when_dev_key_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();

    let output = Command::new(agent_bin())
        .arg("register-mcp")
        .env("HOME", home)
        .output()
        .expect("spawn mci-agent");

    assert!(output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("brain key not yet generated"),
        "stderr should warn about missing dev.key, got: {stderr}"
    );
}

// -----------------------------------------------------------------------
// Fix 3: mcp-serve falls back to dev.key when env var unset / empty
// -----------------------------------------------------------------------

#[test]
fn mcp_serve_falls_back_to_dev_key_when_env_unset() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();

    let key_dir = home.join("Library/Application Support/MCI");
    std::fs::create_dir_all(&key_dir).unwrap();
    let key_hex = "ab".repeat(32);
    std::fs::write(key_dir.join("dev.key"), &key_hex).unwrap();

    // mcp-serve will fail because there's no brain file — but it should
    // get past the key resolution step (exit 12 = brain open fail, not 10 = no key).
    let output = Command::new(agent_bin())
        .arg("mcp-serve")
        .env("HOME", home)
        .env_remove("MCI_DB_KEY_HEX")
        .output()
        .expect("spawn mci-agent");

    let code = output.status.code().unwrap_or(-1);
    assert_ne!(
        code, 10,
        "mcp-serve should not fail with 'key not set' when dev.key exists (got exit {code})"
    );
}

#[test]
fn mcp_serve_falls_back_to_dev_key_when_env_empty() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();

    let key_dir = home.join("Library/Application Support/MCI");
    std::fs::create_dir_all(&key_dir).unwrap();
    let key_hex = "cd".repeat(32);
    std::fs::write(key_dir.join("dev.key"), &key_hex).unwrap();

    let output = Command::new(agent_bin())
        .arg("mcp-serve")
        .env("HOME", home)
        .env("MCI_DB_KEY_HEX", "")
        .output()
        .expect("spawn mci-agent");

    let code = output.status.code().unwrap_or(-1);
    assert_ne!(
        code, 10,
        "mcp-serve should treat empty MCI_DB_KEY_HEX as missing and fall back to dev.key (got exit {code})"
    );
}

// -----------------------------------------------------------------------
// Fix 4: --strict exits non-zero; without --strict prints loud warning
// -----------------------------------------------------------------------

#[test]
fn drain_stdin_strict_exits_nonzero_on_no_key() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();

    let output = Command::new(agent_bin())
        .args(["--drain-stdin", "--strict"])
        .env("HOME", home)
        .env_remove("MCI_DB_KEY_HEX")
        .stdin(std::process::Stdio::null())
        .output()
        .expect("spawn mci-agent");

    assert!(
        !output.status.success(),
        "--strict should cause non-zero exit when brain key missing"
    );
}

#[test]
fn drain_stdin_no_strict_prints_loud_warning_and_continues() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();

    // Without --strict, drain-stdin should succeed (health-only drain)
    // even when key is missing. stdin=null causes immediate EOF → clean exit.
    let output = Command::new(agent_bin())
        .arg("--drain-stdin")
        .env("HOME", home)
        .env_remove("MCI_DB_KEY_HEX")
        .stdin(std::process::Stdio::null())
        .output()
        .expect("spawn mci-agent");

    assert!(
        output.status.success(),
        "without --strict, drain-stdin should succeed with health-only fallback"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("no brain key found") || stderr.contains("Health-only drain"),
        "should warn about missing key, got: {stderr}"
    );
}

/// `~/.claude.json` carries the brain key, so a user tightening it to 0600
/// is doing the right thing. Writing through a temp file and renaming would
/// silently hand the destination the temp file's umask-derived mode and
/// widen it back to world-readable.
#[test]
fn register_mcp_preserves_a_tightened_file_mode() {
    use std::os::unix::fs::PermissionsExt;

    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let settings = home.join(".claude.json");
    std::fs::write(&settings, r#"{"mcpServers":{}}"#).unwrap();
    std::fs::set_permissions(&settings, std::fs::Permissions::from_mode(0o600)).unwrap();

    let output = Command::new(agent_bin())
        .arg("register-mcp")
        .env("HOME", home)
        .env_remove("MCI_DB_KEY_HEX")
        .output()
        .expect("spawn mci-agent");
    assert!(output.status.success());

    let mode = std::fs::metadata(&settings).unwrap().permissions().mode() & 0o777;
    assert_eq!(
        mode, 0o600,
        "a tightened mode must survive the rewrite, got {mode:o}"
    );
}

/// Creating the file for the first time: we are writing a key into it, so
/// it should not start out world-readable either.
#[test]
fn register_mcp_creates_the_file_private() {
    use std::os::unix::fs::PermissionsExt;

    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();

    let output = Command::new(agent_bin())
        .arg("register-mcp")
        .env("HOME", home)
        .env_remove("MCI_DB_KEY_HEX")
        .output()
        .expect("spawn mci-agent");
    assert!(output.status.success());

    let mode = std::fs::metadata(home.join(".claude.json"))
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(
        mode, 0o600,
        "a freshly created config must be 0600, got {mode:o}"
    );
}
