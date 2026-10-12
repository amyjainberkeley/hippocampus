//! The user's verdicts on what Hippocampus believes about them.
//!
//! The app cannot write the brain while the daemon holds it, so the command
//! bar drops one small file per verdict into an inbox: a proposition id and
//! `confirm` or `reject`, nothing else. Each understanding cycle applies and
//! removes them. A rejected proposition is kept as rejected so it is never
//! proposed again; a confirmed one becomes certain.

use std::path::{Path, PathBuf};

use serde::Deserialize;

use mci_brain::understanding::PropositionStatus;
use mci_brain::{SqlCipherBrainStore, StoreError};

/// `~/Library/Application Support/Hippocampus/understanding-feedback`.
#[must_use]
pub fn inbox_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| {
        PathBuf::from(home).join("Library/Application Support/Hippocampus/understanding-feedback")
    })
}

#[derive(Deserialize)]
struct Verdict {
    id: i64,
    verdict: String,
}

/// Apply and remove every verdict in `dir`. Returns how many were applied.
/// Malformed files are removed without effect.
///
/// # Errors
/// Store failures (the file is kept for the next cycle).
pub fn apply_inbox(store: &SqlCipherBrainStore, dir: &Path, now_us: u64) -> Result<usize, StoreError> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Ok(0);
    };
    let mut files: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
        .collect();
    files.sort();
    let mut applied = 0;
    for file in files {
        let verdict: Option<Verdict> = std::fs::read(&file)
            .ok()
            .filter(|bytes| bytes.len() < 1024)
            .and_then(|bytes| serde_json::from_slice(&bytes).ok());
        if let Some(verdict) = verdict {
            let done = match verdict.verdict.as_str() {
                "reject" => store.set_proposition_status(verdict.id, PropositionStatus::Rejected, now_us)?,
                "confirm" => store.confirm_proposition(verdict.id, now_us)?,
                _ => false,
            };
            if done {
                applied += 1;
            }
        }
        let _ = std::fs::remove_file(&file);
    }
    Ok(applied)
}

#[cfg(test)]
mod tests {
    use super::*;
    use mci_brain::understanding::{NewProposition, PropositionKind};
    use mci_brain::{BrainStore, Event, EventId, EventSource};
    use mci_core::crypto::DbKey;

    #[test]
    fn verdicts_are_applied_once_and_removed() {
        let dir = tempfile::tempdir().unwrap();
        let store = SqlCipherBrainStore::new(&dir.path().join("b.sqlite"), &DbKey::from_bytes([5; 32])).unwrap();
        let event = Event {
            id: EventId(0), ts_us: 1, app_bundle_id: Some("com.apple.Notes".into()), window_title: None, url: None,
            text: "t".into(), summary: None, entities: None, episode_id: None, cascade_reason: 0,
            keyframe_blob: None, tab_id: None, embedding: None,
        };
        let e = store.put_event_with_source(&event, EventSource::ScreenOcr).unwrap();
        let new = |text: &str| NewProposition {
            text: text.into(), reasoning: String::new(), kind: PropositionKind::Habit,
            confidence: 0.6, decay: 0.5, model: "t".into(),
        };
        let wrong = store.insert_proposition(&new("Amy dislikes meetings on Fridays"), &[e.0 as i64], 1).unwrap();
        let right = store.insert_proposition(&new("Amy writes Rust in the mornings"), &[e.0 as i64], 1).unwrap();
        let inbox = dir.path().join("inbox");
        std::fs::create_dir(&inbox).unwrap();
        std::fs::write(inbox.join("1.json"), format!(r#"{{"id":{wrong},"verdict":"reject"}}"#)).unwrap();
        std::fs::write(inbox.join("2.json"), format!(r#"{{"id":{right},"verdict":"confirm"}}"#)).unwrap();
        std::fs::write(inbox.join("3.json"), "not json").unwrap();
        assert_eq!(apply_inbox(&store, &inbox, 5).unwrap(), 2);
        assert_eq!(std::fs::read_dir(&inbox).unwrap().count(), 0);
        let active = store.propositions_with_status(PropositionStatus::Active, 10).unwrap();
        assert_eq!(active.len(), 1);
        assert_eq!(active[0].id, right);
        assert!((active[0].confidence - 1.0).abs() < 1e-9);
        assert_eq!(store.propositions_with_status(PropositionStatus::Rejected, 10).unwrap()[0].id, wrong);
    }
}
