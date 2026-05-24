//! Fixture-day loader.
//!
//! A fixture day is a JSONL file under `fixtures/days/<name>.jsonl`.
//! Each line is one synthetic event with the same shape as
//! [`mci_brain::Event`] but without the encrypted-store columns the
//! eval doesn't need. Loading produces a `Vec<EventRecord>` ready to
//! pass to a `BriefAuthor`.

use std::path::{Path, PathBuf};

use mci_brain::{EventId, EventRecord};
use serde::Deserialize;
use thiserror::Error;

/// One line of a fixture-day JSONL file.
///
/// `event_id` is explicit so the gold reference can pin which events
/// the brief is expected to mention.
#[derive(Debug, Clone, Deserialize)]
pub struct FixtureEvent {
    /// Synthetic event id. MUST be unique within a fixture day.
    pub event_id: u64,
    /// Capture timestamp in microseconds since UNIX epoch.
    pub ts_us: u64,
    /// Frontmost app bundle identifier.
    #[serde(default)]
    pub app_bundle_id: Option<String>,
    /// Focused window title.
    #[serde(default)]
    pub window_title: Option<String>,
    /// Active browser tab URL (only set for browser apps).
    #[serde(default)]
    pub url: Option<String>,
    /// OCR'd or otherwise extracted text content for this event.
    pub text: String,
}

/// A loaded fixture day.
#[derive(Debug, Clone)]
pub struct FixtureDay {
    /// Base name of the fixture (the JSONL stem, e.g. `"day_light"`).
    pub name: String,
    /// Source path the events were read from.
    pub source_path: PathBuf,
    /// Events in the order they appeared in the JSONL.
    pub events: Vec<FixtureEvent>,
}

impl FixtureDay {
    /// Load `fixtures/days/<name>.jsonl` from `dir`.
    ///
    /// # Errors
    ///
    /// Returns an error if the file is missing, unreadable, or contains
    /// invalid JSON / duplicate event ids.
    pub fn load(dir: &Path, name: &str) -> Result<Self, FixtureError> {
        let source_path = dir.join("days").join(format!("{name}.jsonl"));
        let raw = std::fs::read_to_string(&source_path).map_err(|e| FixtureError::Io {
            path: source_path.clone(),
            source: e,
        })?;

        let mut events = Vec::new();
        let mut seen_ids = std::collections::HashSet::new();
        for (line_no, line) in raw.lines().enumerate() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let event: FixtureEvent =
                serde_json::from_str(line).map_err(|e| FixtureError::Parse {
                    path: source_path.clone(),
                    line: line_no + 1,
                    source: e,
                })?;
            if !seen_ids.insert(event.event_id) {
                return Err(FixtureError::DuplicateEventId {
                    path: source_path,
                    event_id: event.event_id,
                });
            }
            events.push(event);
        }

        if events.is_empty() {
            return Err(FixtureError::Empty { path: source_path });
        }

        Ok(Self {
            name: name.to_owned(),
            source_path,
            events,
        })
    }

    /// Project fixture events into the `EventRecord` shape consumed by
    /// `BriefAuthor::author`.
    #[must_use]
    pub fn to_event_records(&self) -> Vec<EventRecord> {
        self.events
            .iter()
            .map(|e| EventRecord {
                event_id: EventId(e.event_id),
                ts_us: e.ts_us,
                app_bundle_id: e.app_bundle_id.clone(),
                window_title: e.window_title.clone(),
                url: e.url.clone(),
                text_snippet: EventRecord::truncate_snippet(&e.text),
            })
            .collect()
    }

    /// All event ids in this fixture, in file order.
    #[must_use]
    pub fn event_ids(&self) -> Vec<u64> {
        self.events.iter().map(|e| e.event_id).collect()
    }
}

/// Fixture-load errors.
#[derive(Debug, Error)]
pub enum FixtureError {
    /// Fixture file was missing or unreadable.
    #[error("fixture: io on {path}: {source}")]
    Io {
        /// Path that failed to open.
        path: PathBuf,
        /// Underlying I/O error.
        #[source]
        source: std::io::Error,
    },
    /// A JSONL line failed to parse.
    #[error("fixture: parse {path}:{line}: {source}")]
    Parse {
        /// Path of the bad fixture.
        path: PathBuf,
        /// 1-based line number where the parse failed.
        line: usize,
        /// Underlying parse error.
        #[source]
        source: serde_json::Error,
    },
    /// Two events shared the same `event_id`.
    #[error("fixture: {path}: duplicate event_id {event_id}")]
    DuplicateEventId {
        /// Path of the bad fixture.
        path: PathBuf,
        /// The duplicated id.
        event_id: u64,
    },
    /// Fixture contained zero events.
    #[error("fixture: {path}: empty (zero events)")]
    Empty {
        /// Path of the empty fixture.
        path: PathBuf,
    },
}
