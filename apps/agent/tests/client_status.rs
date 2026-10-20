//! `mci-agent clients --json` end to end (SPEC 3.8): the AI Tools page's
//! read. It is content-free: it needs no key and never opens the memory.
//!
//! Every child runs with an explicitly built environment (AGENTS.md test
//! hygiene): only PATH and HOME, and no key at all.

use std::path::PathBuf;
use std::process::{Command, Stdio};

fn agent() -> PathBuf {
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop();
    if path.ends_with("deps") {
        path.pop();
    }
    path.push("mci-agent");
    path
}

#[test]
fn clients_names_the_tools_without_a_key_or_a_memory() {
    let dir = tempfile::tempdir().unwrap();
    let memory = dir.path().join("no-memory-here.sqlite");
    let output = Command::new(agent())
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", dir.path())
        .args(["clients", "--json", "--db-path"])
        .arg(&memory)
        .stdin(Stdio::null())
        .output()
        .expect("spawn mci-agent");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).unwrap();
    assert_eq!(text.trim_end().lines().count(), 1, "one line of JSON");
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    let ids: Vec<&str> = value["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tool| tool["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["claude-code", "codex"]);
    assert!(!memory.exists(), "clients never makes or opens a memory");
}
