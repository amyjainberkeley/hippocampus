//! Disconnect (SPEC 5.5): `mci-agent clients --disconnect` takes out
//! exactly the look-up entries Connect put in, under the registry's safety
//! rules, and leaves every other byte of each tool's settings as it was. A
//! `hippocampus` entry that isn't Hippocampus's is never touched.
//!
//! Every child runs with an explicitly built environment (AGENTS.md test
//! hygiene) in a made-up home: only PATH, HOME and the tools' own folders.

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

fn agent() -> PathBuf {
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop();
    if path.ends_with("deps") {
        path.pop();
    }
    path.push("mci-agent");
    path
}

fn run(home: &Path, extra_env: &[(&str, &Path)], args: &[&str]) -> Output {
    let mut command = Command::new(agent());
    command
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", home)
        .args(args)
        .stdin(Stdio::null());
    for (name, value) in extra_env {
        command.env(name, value);
    }
    command.output().expect("spawn mci-agent")
}

fn json(output: &Output) -> serde_json::Value {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("JSON")
}

/// Codex's settings as a person keeps them: comments, blank lines and their
/// own servers, in their own order.
const CODEX_CONFIG: &str = "# my codex\nmodel = \"gpt-5\"\n\n[mcp_servers.docs]\ncommand = \"docs-server\" # local docs\nargs = [\"--stdio\"]\n\n[features]\nhooks = true\n";

#[test]
fn disconnect_takes_out_exactly_what_connect_put_in() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let db = home.join("mci.sqlite");
    let db = db.to_str().unwrap();
    // Claude Code's file, already in the shape the registry writes.
    let claude_original = serde_json::to_vec_pretty(&serde_json::json!({
        "theme": "dark",
        "mcpServers": {"docs": {"type": "stdio", "command": "docs-server", "args": []}},
        "projects": {}
    }))
    .unwrap();
    std::fs::write(home.join(".claude.json"), &claude_original).unwrap();
    std::fs::create_dir_all(home.join(".codex")).unwrap();
    std::fs::write(home.join(".codex/config.toml"), CODEX_CONFIG).unwrap();

    let connect = run(home, &[], &["register-clients", "--db-path", db]);
    assert!(
        connect.status.success(),
        "{}",
        String::from_utf8_lossy(&connect.stderr)
    );
    let claude_connected = std::fs::read_to_string(home.join(".claude.json")).unwrap();
    assert!(claude_connected.contains("\"hippocampus\""));
    let codex_connected = std::fs::read_to_string(home.join(".codex/config.toml")).unwrap();
    assert!(codex_connected.contains("[mcp_servers.hippocampus]"));

    let status = json(&run(home, &[], &["clients", "--json"]));
    assert_eq!(status["tools"][0]["look_ups"], "on");
    assert_eq!(status["tools"][1]["look_ups"], "on");

    let answer = json(&run(
        home,
        &[],
        &["clients", "--disconnect", "all", "--json"],
    ));
    assert_eq!(answer["disconnected"][0]["look_ups"], "removed");
    assert_eq!(answer["disconnected"][1]["look_ups"], "removed");
    assert_eq!(answer["tools"][0]["look_ups"], "off");
    assert_eq!(answer["tools"][1]["look_ups"], "off");
    assert_eq!(
        std::fs::read(home.join(".claude.json")).unwrap(),
        claude_original,
        "Claude Code's file is as it was before Connect"
    );
    assert_eq!(
        std::fs::read_to_string(home.join(".codex/config.toml")).unwrap(),
        CODEX_CONFIG,
        "Codex's file is as it was before Connect, comments and all"
    );

    // Nothing left to take out: said, and nothing written.
    let again = json(&run(
        home,
        &[],
        &["clients", "--disconnect", "codex", "--json"],
    ));
    assert_eq!(again["disconnected"][0]["look_ups"], "none");
    assert_eq!(
        std::fs::read_to_string(home.join(".codex/config.toml")).unwrap(),
        CODEX_CONFIG
    );
}

#[test]
fn a_hippocampus_entry_that_isnt_ours_is_never_touched() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let theirs =
        "[mcp_servers.hippocampus]\ncommand = \"/opt/someone-else/server\"\nargs = [\"serve\"]\n";
    std::fs::create_dir_all(home.join(".codex")).unwrap();
    std::fs::write(home.join(".codex/config.toml"), theirs).unwrap();
    let answer = json(&run(
        home,
        &[],
        &["clients", "--disconnect", "codex", "--json"],
    ));
    assert_eq!(answer["disconnected"][0]["look_ups"], "failed");
    assert_eq!(
        std::fs::read_to_string(home.join(".codex/config.toml")).unwrap(),
        theirs
    );
}

#[test]
fn claude_config_dir_is_where_claude_codes_entry_is_taken_from() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let moved = home.join("claude-config");
    std::fs::create_dir_all(&moved).unwrap();
    let db = home.join("mci.sqlite");
    let original = serde_json::to_vec_pretty(&serde_json::json!({"theme": "light"})).unwrap();
    std::fs::write(moved.join(".claude.json"), &original).unwrap();
    let env = [("CLAUDE_CONFIG_DIR", moved.as_path())];
    let connect = run(
        home,
        &env,
        &["register-clients", "--db-path", db.to_str().unwrap()],
    );
    assert!(
        connect.status.success(),
        "{}",
        String::from_utf8_lossy(&connect.stderr)
    );
    assert!(std::fs::read_to_string(moved.join(".claude.json"))
        .unwrap()
        .contains("hippocampus"));
    assert!(
        !home.join(".claude.json").exists(),
        "never the home folder's"
    );
    let answer = json(&run(
        home,
        &env,
        &["clients", "--disconnect", "claude-code", "--json"],
    ));
    assert_eq!(answer["disconnected"][0]["look_ups"], "removed");
    assert_eq!(std::fs::read(moved.join(".claude.json")).unwrap(), original);
}

#[test]
fn an_unknown_tool_is_refused_before_anything_is_read() {
    let dir = tempfile::tempdir().unwrap();
    let output = run(
        dir.path(),
        &[],
        &["clients", "--disconnect", "everything", "--json"],
    );
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
}
