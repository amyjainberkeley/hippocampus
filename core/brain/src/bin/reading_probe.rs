//! `reading-probe` — the bench's way into the Rust reader (RULINGS X7).
//!
//! Reads one JSON object per stdin line,
//! `{"stored": "...", "source": "screen_ocr", "app": "...", "title": "..."}`,
//! and answers each with one line, `{"main": "...", "rest": "..."}`, from
//! [`mci_brain::reading::reading`]. `source` is a stored source label
//! (`screen_ocr`, `browser_page_with_ocr`, …); a missing or unknown label is
//! `unknown`. `app` and `title` may be missing or null. A line that is not
//! such an object is answered with `{"error": "..."}`, so answers stay in step
//! with questions. Blank lines get no answer.
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

fn answer(line: &str) -> serde_json::Value {
    match serde_json::from_str::<Question>(line) {
        Ok(question) => {
            let source = EventSource::from_stored(question.source.as_deref().unwrap_or(""));
            let read = reading(
                &question.stored,
                source,
                question.app.as_deref(),
                question.title.as_deref(),
            );
            serde_json::json!({ "main": read.main, "rest": read.rest })
        }
        Err(error) => serde_json::json!({ "error": error.to_string() }),
    }
}

fn main() -> io::Result<()> {
    let stdin = io::stdin();
    let mut out = io::stdout().lock();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        writeln!(out, "{}", answer(&line))?;
        out.flush()?;
    }
    Ok(())
}
