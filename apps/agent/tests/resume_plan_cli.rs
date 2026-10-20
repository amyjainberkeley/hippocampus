//! `mci-agent resume-plan --item <id> --json` end to end (SPEC-DELTA 3):
//! what the Resume sheet lists for one Working On item, in the shape the
//! window decodes. It opens nothing and sends nothing.
//!
//! Every child runs with an explicitly built environment (AGENTS.md test
//! hygiene): only PATH, HOME and the development key gate.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use mci_brain::SqlCipherBrainStore;
use mci_core::crypto::DbKey;

fn agent() -> PathBuf {
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop();
    if path.ends_with("deps") {
        path.pop();
    }
    path.push("mci-agent");
    path
}

fn command(home: &Path) -> Command {
    let mut command = Command::new(agent());
    command
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", home)
        .env("MCI_DEVELOPMENT_FILE_KEY", "1")
        .env("MCI_DB_KEY_HEX", "5a".repeat(32))
        .stdin(Stdio::null());
    command
}

fn empty_memory(dir: &Path) -> PathBuf {
    let db = dir.join("mci.sqlite");
    drop(SqlCipherBrainStore::new(&db, &DbKey::from_bytes([0x5a; 32])).expect("make the memory"));
    db
}

#[test]
fn a_plan_lists_what_resume_would_open() {
    let dir = tempfile::tempdir().unwrap();
    let db = empty_memory(dir.path());
    let output = command(dir.path())
        .args(["resume-plan", "--item", "w_9c41e2", "--json", "--db-path"])
        .arg(&db)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).unwrap();
    assert_eq!(text.trim_end().lines().count(), 1, "one line of JSON");
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value, serde_json::json!({"items": []}));
}

#[test]
fn a_plan_needs_an_items_id() {
    let dir = tempfile::tempdir().unwrap();
    let db = empty_memory(dir.path());
    for extra in [&[][..], &["--item"][..], &["--item", "trailhead shop"][..]] {
        let output = command(dir.path())
            .arg("resume-plan")
            .args(extra)
            .args(["--json", "--db-path"])
            .arg(&db)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(2), "{extra:?}");
        assert!(output.stdout.is_empty());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("--item"), "{stderr}");
        assert!(!stderr.contains("trailhead"), "{stderr}");
    }
}
