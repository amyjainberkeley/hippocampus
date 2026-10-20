//! `mci-agent work --json` end to end (SPEC 3.12.2): the window's one read
//! for Working On and Web Pages answers in the shape the window decodes,
//! one line of JSON, over a made-up memory.
//!
//! Every child runs with an explicitly built environment (AGENTS.md test
//! hygiene): only PATH, HOME and the development key gate.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use mci_brain::SqlCipherBrainStore;
use mci_core::crypto::DbKey;

const KEY: [u8; 32] = [0x5a; 32];

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
        .env("MCI_EMBEDDER_DISABLED", "1")
        .stdin(Stdio::null());
    command
}

/// An empty memory, made the way the app makes one.
fn empty_memory(dir: &Path) -> PathBuf {
    let db = dir.join("mci.sqlite");
    drop(SqlCipherBrainStore::new(&db, &DbKey::from_bytes(KEY)).expect("make the memory"));
    db
}

fn json(command: &mut Command) -> serde_json::Value {
    let output = command.output().expect("spawn mci-agent");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).unwrap();
    assert_eq!(text.trim_end().lines().count(), 1, "one line of JSON");
    serde_json::from_str(&text).expect("valid JSON")
}

fn assert_work_shape(value: &serde_json::Value) {
    assert!(value["generated_us"].as_u64().unwrap() > 0);
    assert!(value["items"].is_array());
    assert!(value["pages"].is_array());
    assert!(value["moment_items"].is_object());
}

#[test]
fn work_answers_in_the_shape_the_window_reads() {
    let dir = tempfile::tempdir().unwrap();
    let db = empty_memory(dir.path());
    let value = json(
        command(dir.path())
            .arg("work")
            .arg("--json")
            .arg("--db-path")
            .arg(&db),
    );
    assert_work_shape(&value);
    assert_eq!(value["items"], serde_json::json!([]));
    assert_eq!(value["pages"], serde_json::json!([]));
    assert_eq!(value["moment_items"], serde_json::json!({}));
}

#[test]
fn one_item_and_moment_lookups_answer_in_the_same_shape() {
    let dir = tempfile::tempdir().unwrap();
    let db = empty_memory(dir.path());
    for extra in [
        &["--item", "w_9c41e2"][..],
        &["--item", "w_9c41e2", "--before", "1760304000000000"][..],
        &["--moments", "4812,4790"][..],
        &["--days", "14"][..],
        &["--some-future-flag"][..],
    ] {
        let value = json(
            command(dir.path())
                .arg("work")
                .args(extra)
                .arg("--json")
                .arg("--db-path")
                .arg(&db),
        );
        assert_work_shape(&value);
    }
}

#[test]
fn a_bad_flag_value_fails_without_repeating_it() {
    let dir = tempfile::tempdir().unwrap();
    let db = empty_memory(dir.path());
    for (flag, value) in [
        ("--days", "private-words"),
        ("--item", "private words"),
        ("--moments", "1,private-words"),
    ] {
        let output = command(dir.path())
            .args(["work", "--json", flag, value, "--db-path"])
            .arg(&db)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(2), "{flag}");
        assert!(output.stdout.is_empty());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains(flag), "{stderr}");
        assert!(!stderr.contains("private"), "{stderr}");
    }
}

#[test]
fn a_memory_that_cannot_be_opened_is_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let missing = dir.path().join("missing.sqlite");
    let output = command(dir.path())
        .args(["work", "--json", "--db-path"])
        .arg(&missing)
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert!(!missing.exists(), "a read never makes a memory");
}

#[test]
fn without_json_it_is_the_same_answer_indented() {
    let dir = tempfile::tempdir().unwrap();
    let db = empty_memory(dir.path());
    let output = command(dir.path())
        .args(["work", "--db-path"])
        .arg(&db)
        .output()
        .unwrap();
    assert!(output.status.success());
    let text = String::from_utf8(output.stdout).unwrap();
    assert!(text.trim_end().lines().count() > 1);
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_work_shape(&value);
}
