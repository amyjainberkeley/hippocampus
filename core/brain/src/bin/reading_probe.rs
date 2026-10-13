//! `reading-probe` — the bench's way into the Rust reader (RULINGS X7).
//!
//! Reads one JSON object per stdin line,
//! `{"stored": "...", "source": "screen_ocr", "app": "...", "title": "..."}`,
//! and answers each with one line, `{"main": "...", "rest": "..."}`, from
//! [`mci_brain::reading::reading`]. `source` is a stored source label
//! (`screen_ocr`, `browser_page_with_ocr`, …); a missing or unknown label is
//! `unknown`. `app` and `title` may be missing or null. A line that is not
//! such an object, or not UTF-8, is answered with `{"error":"bad_input"}`, so
//! answers stay in step with questions. Blank lines get no answer. It exits 0
//! at the end of its input, and non-zero only when it cannot write.
//!
//! ```bash
//! cargo run -p mci-brain --bin reading-probe < questions.jsonl
//! ```
//!
//! It reads nothing but stdin and writes nothing but stdout.

use std::io::{self, BufRead, Write};

use mci_brain::reading::reading;
use mci_brain::EventSource;
use serde::Deserialize;

#[derive(Deserialize)]
struct Question {
    stored: String,
    #[serde(default)]
    source: Option<String>,
    #[serde(default)]
    app: Option<String>,
    #[serde(default)]
    title: Option<String>,
}

fn answer(line: &[u8]) -> serde_json::Value {
    let question = std::str::from_utf8(line)
        .ok()
        .and_then(|line| serde_json::from_str::<Question>(line).ok());
    match question {
        Some(question) => {
            let source = EventSource::from_stored(question.source.as_deref().unwrap_or(""));
            let read = reading(
                &question.stored,
                source,
                question.app.as_deref(),
                question.title.as_deref(),
            );
            serde_json::json!({ "main": read.main, "rest": read.rest })
        }
        None => serde_json::json!({ "error": "bad_input" }),
    }
}

fn main() -> io::Result<()> {
    let mut input = io::stdin().lock();
    let mut out = io::stdout().lock();
    let mut line = Vec::new();
    loop {
        line.clear();
        if input.read_until(b'\n', &mut line)? == 0 {
            return Ok(());
        }
        let question = line.strip_suffix(b"\n").unwrap_or(&line);
        if std::str::from_utf8(question).is_ok_and(|text| text.trim().is_empty()) {
            continue;
        }
        writeln!(out, "{}", answer(question))?;
        out.flush()?;
    }
}
