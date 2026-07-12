//! MCI brief-author quality eval framework.
//!
//! Offline, reproducible scorer for the `BriefAuthor` surface (ADR-0018,
//! ADR-0028). Loads a fixture day (JSONL of synthetic events), runs a
//! `BriefAuthor` against it, compares the generated brief to a
//! hand-authored gold reference, and reports a structured pass/fail
//! per metric.
//!
//! The eval is the gate behind `DOGFOOD_V1.md` item #20: when the CEO
//! runs the Core ML conversion (`OWNER_TASKS` #17) and points the eval
//! at the resulting `.mlmodelc`, the report decides whether `Qwen3-1.7B`
//! INT4 is good enough to ship.
//!
//! # No protected-set touch
//!
//! Per `AGENT_PROTOCOL` §5, brief quality is not in the protected set.
//! This crate adds no capture path, no crypto, no sync, no store
//! mutation. It reads fixture files, runs the existing `BriefAuthor`
//! trait, and prints a report. All fixture data is synthetic.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub mod fixture;
pub mod gold;
pub mod report;
pub mod scorer;
pub mod scripted;

pub use fixture::{FixtureDay, FixtureError, FixtureEvent};
pub use gold::{GoldBrief, GoldError};
pub use report::{EvalReport, FixtureOutcome, MetricScore};
pub use scorer::{score_brief, PassThresholds};
pub use scripted::ScriptedLlamaBackend;

use std::path::{Path, PathBuf};

/// Default name of the per-fixture scripted-LLM output file.
///
/// The scripted backend reads this Markdown file as if the LLM had
/// produced it. Gives the eval a deterministic, hand-shaped output
/// the scorer can grade — proves the framework works without invoking
/// any model.
pub const SCRIPTED_OUTPUT_FILENAME: &str = "scripted.md";

/// Locate the bundled fixtures directory relative to the crate root.
///
/// Production callers (the `brief-eval` bin + integration tests) read
/// from `$CARGO_MANIFEST_DIR/fixtures/`.
#[must_use]
pub fn bundled_fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures")
}

/// List every fixture day shipped in the corpus.
///
/// Returns the bare names (e.g. `"day_light"`) — the caller pairs each
/// with the JSONL events file, the gold spec, and the scripted output.
///
/// # Errors
///
/// Returns an error if `dir/days/` is unreadable or contains a non-UTF-8
/// filename.
pub fn list_fixture_names(dir: &Path) -> Result<Vec<String>, std::io::Error> {
    let days = dir.join("days");
    let mut names = Vec::new();
    for entry in std::fs::read_dir(&days)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("jsonl") {
            continue;
        }
        if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
            names.push(stem.to_owned());
        }
    }
    names.sort();
    Ok(names)
}
