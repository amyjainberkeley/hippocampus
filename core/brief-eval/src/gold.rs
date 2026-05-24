//! Gold-reference loader.
//!
//! For each fixture day under `fixtures/days/<name>.jsonl`, there is a
//! matching gold spec under `fixtures/gold/<name>.json`. The spec is
//! hand-authored and pins what a passing brief MUST look like:
//!
//! - `required_facts`: substrings (case-insensitive) the brief body
//!   must contain. Chosen from the fixture's events (apps, named
//!   artifacts, key actions).
//! - `forbidden_terms`: substrings that MUST NOT appear — names of
//!   apps/products the fixture deliberately doesn't include, so the
//!   scorer catches hallucination.
//! - `min_words` / `max_words`: word-count tolerance for the body.
//! - `min_citations`: minimum number of distinct `[event:N]` markers
//!   that resolve to a real fixture event.
//! - `min_section_bullets`: minimum number of bullet lines (`- ...`).
//! - `notes`: free-text description of the day's character (light /
//!   deep-work / fragmented / etc.) for human readers.

use std::path::{Path, PathBuf};

use serde::Deserialize;
use thiserror::Error;

/// Gold spec for one fixture day.
///
/// Tuned per-fixture; the eval framework doesn't impose a global shape.
/// Thresholds applied at scoring time come from
/// [`crate::scorer::PassThresholds`].
#[derive(Debug, Clone, Deserialize)]
pub struct GoldBrief {
    /// Free-text description (light / deep-work / fragmented / etc.).
    pub notes: String,
    /// Substrings the brief body MUST contain (case-insensitive).
    #[serde(default)]
    pub required_facts: Vec<String>,
    /// Substrings the brief body MUST NOT contain (case-insensitive).
    /// Used to catch hallucination — names of apps or products that
    /// were deliberately excluded from the fixture.
    #[serde(default)]
    pub forbidden_terms: Vec<String>,
    /// Minimum word count for the brief body.
    pub min_words: usize,
    /// Maximum word count for the brief body.
    pub max_words: usize,
    /// Minimum number of resolved citations.
    #[serde(default = "default_min_citations")]
    pub min_citations: usize,
    /// Minimum number of bullet lines (`- ` or `* `) in the body.
    #[serde(default = "default_min_bullets")]
    pub min_section_bullets: usize,
}

fn default_min_citations() -> usize {
    1
}

fn default_min_bullets() -> usize {
    2
}

impl GoldBrief {
    /// Load `fixtures/gold/<name>.json` from `dir`.
    ///
    /// # Errors
    ///
    /// Returns an error if the file is missing or fails to parse.
    pub fn load(dir: &Path, name: &str) -> Result<Self, GoldError> {
        let path = dir.join("gold").join(format!("{name}.json"));
        let raw = std::fs::read_to_string(&path).map_err(|e| GoldError::Io {
            path: path.clone(),
            source: e,
        })?;
        serde_json::from_str(&raw).map_err(|e| GoldError::Parse { path, source: e })
    }
}

/// Gold-load errors.
#[derive(Debug, Error)]
pub enum GoldError {
    /// Gold file was missing or unreadable.
    #[error("gold: io on {path}: {source}")]
    Io {
        /// Path that failed to open.
        path: PathBuf,
        /// Underlying I/O error.
        #[source]
        source: std::io::Error,
    },
    /// The gold JSON failed to parse.
    #[error("gold: parse {path}: {source}")]
    Parse {
        /// Path of the bad gold file.
        path: PathBuf,
        /// Underlying parse error.
        #[source]
        source: serde_json::Error,
    },
}
