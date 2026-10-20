//! `mci-agent send-card` end to end (SPEC 5.3.10): the request comes on
//! standard input, never in arguments, and the card says what goes in the
//! tool's message box. Nothing is sent: a card is either a link to open or
//! a copy.
//!
//! Every child runs with an explicitly built environment (AGENTS.md test
//! hygiene): only PATH, HOME and the development key gate.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

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
        .env("MCI_EMBEDDER_DISABLED", "1")
        .env("MCI_BRIEF_TZ_OFFSET_SECONDS", "0");
    command
}

fn empty_memory(dir: &Path) -> PathBuf {
    let db = dir.join("mci.sqlite");
    drop(SqlCipherBrainStore::new(&db, &DbKey::from_bytes([0x5a; 32])).expect("make the memory"));
    db
}

fn send_card(home: &Path, db: &Path, args: &[&str], request: &[u8]) -> Output {
    let mut child = command(home)
        .arg("send-card")
        .args(args)
        .args(["--json", "--db-path"])
        .arg(db)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn mci-agent");
    // A child that refused its arguments may have gone before it read.
    let _ = child.stdin.take().unwrap().write_all(request);
    child.wait_with_output().unwrap()
}

fn card(output: &Output) -> serde_json::Value {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout.clone()).unwrap();
    assert_eq!(text.trim_end().lines().count(), 1, "one line of JSON");
    serde_json::from_str(&text).expect("valid JSON")
}

#[test]
fn a_card_says_what_goes_in_the_box_and_sends_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let db = empty_memory(dir.path());
    let card = card(&send_card(
        dir.path(),
        &db,
        &[],
        br#"{"to": "copy", "question": "Why does rounding drift?", "moments": [], "session": null,
             "item": null, "include_about_me": false, "include_screenshot": false}"#,
    ));
    let message = card["message"].as_str().unwrap();
    assert!(!message.is_empty());
    assert_eq!(
        card["chars"].as_u64().unwrap(),
        u64::try_from(message.chars().count()).unwrap()
    );
    assert_eq!(card["copy"], true, "a copy for `to: copy`");
    assert_eq!(card["open"], serde_json::Value::Null);
    for key in [
        "folder",
        "included",
        "left_out",
        "shortened",
        "people_messages",
        "screenshot_moment",
    ] {
        assert!(card.get(key).is_some(), "{key}");
    }
}

/// Until the builder lands, every card is today's Copy for Your AI: the
/// packet `context` makes, focused on the question.
#[test]
fn until_the_builder_lands_the_card_is_todays_copy_for_your_ai() {
    let dir = tempfile::tempdir().unwrap();
    let db = empty_memory(dir.path());
    let card = card(&send_card(
        dir.path(),
        &db,
        &[],
        br#"{"to": "claude", "question": "Why does rounding drift?"}"#,
    ));
    let context = command(dir.path())
        .args([
            "context",
            "--focus",
            "Why does rounding drift?",
            "--max-tokens",
            "1200",
        ])
        .args(["--max-evidence", "24", "--format", "markdown", "--db-path"])
        .arg(&db)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(context.status.success());
    assert_eq!(
        card["message"].as_str().unwrap(),
        String::from_utf8(context.stdout).unwrap()
    );
    assert_eq!(card["copy"], true);
}

#[test]
fn a_bad_request_is_refused_without_repeating_it() {
    let dir = tempfile::tempdir().unwrap();
    let db = empty_memory(dir.path());
    for request in [&b"{\"question\": \"private words\""[..], &b""[..]] {
        let output = send_card(dir.path(), &db, &[], request);
        assert_eq!(output.status.code(), Some(2));
        assert!(output.stdout.is_empty());
        assert!(!String::from_utf8_lossy(&output.stderr).contains("private words"));
    }
}

#[test]
fn a_question_given_as_an_argument_is_refused() {
    // Arguments show in the process list, so send-card takes none.
    let dir = tempfile::tempdir().unwrap();
    let db = empty_memory(dir.path());
    let output = send_card(
        dir.path(),
        &db,
        &["Why does rounding drift?"],
        br#"{"to": "copy"}"#,
    );
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("standard input"), "{stderr}");
    assert!(!stderr.contains("rounding"), "{stderr}");
}
