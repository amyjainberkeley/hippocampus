use std::path::{Path, PathBuf};
use std::process::{Command, Output};

fn agent_bin() -> PathBuf {
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop();
    if path.ends_with("deps") {
        path.pop();
    }
    path.push("mci-agent");
    path
}

fn run_daemon_once(home: &Path, codex_home: &Path, brain: &Path) -> Output {
    Command::new(agent_bin())
        .args([
            "--device-id-path",
            home.join("device-id").to_str().unwrap(),
            "--log-path",
            home.join("health.jsonl").to_str().unwrap(),
            "--db-path",
            brain.to_str().unwrap(),
            "--drain-stdin",
        ])
        .env("HOME", home)
        .env("CODEX_HOME", codex_home)
        .env("MCI_CAPTURE_ENABLED", "0")
        .env_remove("MCI_DB_KEY_HEX")
        .env_remove("MCI_DB_KEY_FILE")
        .env_remove("MCI_DEVELOPMENT_FILE_KEY")
        .output()
        .expect("run mci-agent daemon once")
}

#[test]
fn daemon_startup_repairs_existing_legacy_client_entries() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let codex_home = home.join("codex-home");
    std::fs::create_dir(&codex_home).unwrap();
    let brain = home.join("brain.sqlite");
    let old_brain = home.join("old.sqlite");
    let raw_key = "11".repeat(32);

    let claude = serde_json::json!({
        "theme": "keep-me",
        "mcpServers": {
            "hippocampus": {
                "command": "/old/Hippocampus.app/Contents/MacOS/mci-agent",
                "args": ["mcp-serve", "--db-path", old_brain],
                "env": {
                    "MCI_DB_PATH": old_brain,
                    "MCI_DB_KEY_HEX": raw_key,
                }
            }
        }
    });
    std::fs::write(
        home.join(".claude.json"),
        serde_json::to_vec_pretty(&claude).unwrap(),
    )
    .unwrap();
    std::fs::write(
        codex_home.join("config.toml"),
        format!(
            "theme = \"keep-me\"\n\n[mcp_servers.hippocampus]\ncommand = \"/old/Hippocampus.app/Contents/MacOS/mci-agent\"\nargs = [\"mcp-serve\", \"--db-path\", \"{}\"]\n\n[mcp_servers.hippocampus.env]\nMCI_DB_PATH = \"{}\"\nMCI_DB_KEY_HEX = \"{}\"\n",
            old_brain.display(),
            old_brain.display(),
            raw_key,
        ),
    )
    .unwrap();

    let output = run_daemon_once(home, &codex_home, &brain);
    assert!(
        output.status.success(),
        "capture-off daemon should drain EOF successfully: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let claude_after: serde_json::Value =
        serde_json::from_slice(&std::fs::read(home.join(".claude.json")).unwrap()).unwrap();
    let claude_entry = &claude_after["mcpServers"]["hippocampus"];
    assert_eq!(claude_after["theme"], "keep-me");
    assert_eq!(
        claude_entry["command"],
        agent_bin().to_string_lossy().as_ref()
    );
    assert_eq!(
        claude_entry["env"]["MCI_DB_PATH"],
        brain.to_string_lossy().as_ref()
    );
    assert!(claude_entry["env"].get("MCI_DB_KEY_HEX").is_none());
    assert_eq!(
        claude_entry["env"]["MCI_DB_KEYCHAIN_SERVICE"],
        "ai.hippocampus.brain"
    );

    let codex_after = std::fs::read_to_string(codex_home.join("config.toml")).unwrap();
    assert!(codex_after.contains("theme = \"keep-me\""));
    assert!(codex_after.contains(agent_bin().to_string_lossy().as_ref()));
    assert!(codex_after.contains(brain.to_string_lossy().as_ref()));
    assert!(codex_after.contains("MCI_DB_KEYCHAIN_SERVICE = \"ai.hippocampus.brain\""));
    assert!(!codex_after.contains("MCI_DB_KEY_HEX"));
    assert!(!codex_after.contains(&raw_key));
}
