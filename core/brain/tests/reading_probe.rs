//! `reading-probe` answers RULINGS X7: one JSON object per stdin line in,
//! one `{"main","rest"}` line out, from the same reader the app uses.

use std::io::Write;
use std::process::{Command, Stdio};

use mci_brain::reading::reading;
use mci_brain::EventSource;
use serde_json::{json, Value};

fn ask(input: &str) -> Vec<Value> {
    let mut child = Command::new(env!("CARGO_BIN_EXE_reading-probe"))
        .env_clear()
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("reading-probe starts");
    child
        .stdin
        .take()
        .expect("stdin")
        .write_all(input.as_bytes())
        .expect("write questions");
    let output = child.wait_with_output().expect("reading-probe exits");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("utf-8 answers")
        .lines()
        .map(|line| serde_json::from_str(line).expect("each answer is one JSON object"))
        .collect()
}

#[test]
fn each_question_line_gets_one_answer_line_from_the_reader() {
    let stored = "[app=com.apple.Notes | title=Launch plan | url=? | ts=2026-10-12T14:02:00.000Z]\nThe beta opens on October 21. Everything below has to be true by then, and nothing else is in\nscope. \u{4e09}\n\n\u{1e}\n\u{25cf} iCloud\nNotes 17";
    let questions = [
        json!({"stored": stored, "source": "screen_ocr", "app": "com.apple.Notes", "title": "Launch plan"}),
        json!({"stored": stored, "source": "browser_page", "app": null, "title": null}),
        json!({"stored": stored}),
    ];
    let mut input = String::new();
    for question in &questions {
        input.push_str(&question.to_string());
        input.push_str("\n\n");
    }
    let answers = ask(&input);
    assert_eq!(answers.len(), 3, "blank lines get no answer");

    let expected = reading(
        stored,
        EventSource::ScreenOcr,
        Some("com.apple.Notes"),
        Some("Launch plan"),
    );
    assert_eq!(
        answers[0],
        json!({"main": expected.main, "rest": expected.rest})
    );
    assert_eq!(
        answers[0]["main"],
        "The beta opens on October 21. Everything below has to be true by then, and nothing else is in scope."
    );
    assert_eq!(answers[0]["rest"], "iCloud\nNotes 17");

    let as_stored = reading(stored, EventSource::Unknown, None, None);
    for answer in &answers[1..] {
        assert_eq!(
            answer,
            &json!({"main": as_stored.main, "rest": ""}),
            "no cleaning for other sources"
        );
        assert!(!answer["main"].as_str().unwrap().contains('\u{1e}'));
        assert!(!answer["main"].as_str().unwrap().contains("[app="));
    }
}

#[test]
fn a_line_that_is_not_a_question_is_answered_with_an_error_and_the_rest_still_answered() {
    let answers = ask("not json\n{\"source\": \"screen_ocr\"}\n{\"stored\": \"Plain text\"}\n");
    assert_eq!(answers.len(), 3);
    assert!(answers[0]["error"].is_string());
    assert!(answers[1]["error"].is_string(), "stored is required");
    assert_eq!(answers[2], json!({"main": "Plain text", "rest": ""}));
}
