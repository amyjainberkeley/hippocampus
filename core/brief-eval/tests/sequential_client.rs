//! Hermetic scripted-client protocol checks, not actual-agent quality measurements.

use std::io::Write;
use std::process::{Command, Output, Stdio};

use serde_json::Value;
use tempfile::TempDir;

fn client(directory: &TempDir) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_sequential-memory-eval"));
    command
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("TMPDIR", directory.path())
        .current_dir(directory.path());
    command
}

fn invoke(input: &[u8]) -> Output {
    let directory = tempfile::tempdir().unwrap();
    let mut child = client(&directory)
        .arg("--policy-client")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input).unwrap();
    let output = child.wait_with_output().unwrap();
    assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
    output
}

#[test]
fn exported_requests_round_trip_through_an_isolated_scripted_client_without_answers_or_execution() {
    let directory = tempfile::tempdir().unwrap();
    let report_path = directory.path().join("report.json");
    let requests_path = directory.path().join("requests.json");
    let generated = client(&directory)
        .arg("--out")
        .arg(&report_path)
        .arg("--requests-out")
        .arg(&requests_path)
        .output()
        .unwrap();
    assert!(
        generated.status.success(),
        "{}",
        String::from_utf8_lossy(&generated.stderr)
    );
    let report: Value = serde_json::from_slice(&std::fs::read(&report_path).unwrap()).unwrap();
    assert_eq!(report["actual_client_run"], false);
    let requests: Vec<Value> =
        serde_json::from_slice(&std::fs::read(&requests_path).unwrap()).unwrap();
    assert_eq!(requests.len(), 42);
    for (arm, task, expected) in [
        (
            "governed_memory",
            "corrected",
            vec!["cargo", "test", "--test", "beta"],
        ),
        (
            "simple_context",
            "malicious-source",
            vec!["cargo", "check", "--all-targets"],
        ),
        (
            "governed_memory",
            "deleted-source",
            vec!["cargo", "check", "--all-targets"],
        ),
    ] {
        let request = requests
            .iter()
            .find(|r| r["arm"] == arm && r["task"]["id"] == task)
            .unwrap();
        assert!(request.get("gold").is_none());
        let result = invoke(&serde_json::to_vec(request).unwrap());
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        let response: Value = serde_json::from_slice(&result.stdout).unwrap();
        assert_eq!(response["argv"], serde_json::json!(expected));
        let outcome = report["arms"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["arm"] == arm)
            .unwrap()["outcomes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|o| o["task_id"] == task)
            .unwrap();
        assert_eq!(response, outcome["actual"]);
    }
    let mut files: Vec<_> = std::fs::read_dir(directory.path())
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .collect();
    files.sort();
    assert_eq!(files, ["report.json", "requests.json"]);
}

#[test]
fn client_rejects_oversized_and_malformed_requests() {
    for input in [vec![b' '; 16_385], b"{\"version\":999}".to_vec()] {
        let result = invoke(&input);
        assert!(!result.status.success());
        assert!(result.stdout.is_empty());
    }
}
