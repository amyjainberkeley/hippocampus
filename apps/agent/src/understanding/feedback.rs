//! The user's verdicts on what Hippocampus believes about them.
//!
//! The app cannot write the brain while the daemon holds it, so the command
//! bar drops one small file per verdict into an inbox: a proposition id and
//! `confirm` or `reject`, nothing else. Each understanding cycle applies and
//! removes them. A rejected proposition is kept as rejected so it is never
//! proposed again; a confirmed one becomes certain, and the confirmation is
//! kept so a rebuild of the user model does not lose it.
//!
//! The id the person saw may have been revised since: a verdict lands on the
//! newest revision of it, and a confirmation never brings back a row that was
//! retired. An item merged into another is the exception: nothing records
//! which item absorbed it, so a verdict on it is removed without effect. The
//! inbox is handed to the worker through `Understanding::new`; readers and
//! tests pass a folder of their own or none, so only the daemon over the
//! owner's memory ever empties the owner's inbox.
//!
//! A verdict is `{milliseconds}-{id}.json` while the window can withdraw it
//! (its Undo removes that file). A cycle takes each file, renaming it to
//! `{milliseconds}-{id}.taken`, before it reads it. A rename is atomic, so
//! either the Undo wins and the verdict is never applied, or the Undo finds
//! the file gone and the verdict is being applied.

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

/// The inbox the worker over a memory applies: the app's, unless the memory
/// was opened with the development file key. The app writes ids from the
/// owner's memory; in a development memory they would name other items.
#[must_use]
pub fn inbox_for_memory(opened_with_development_key: bool) -> Option<PathBuf> {
    if opened_with_development_key {
        None
    } else {
        inbox_dir()
    }
}

#[derive(Deserialize)]
struct Verdict {
    id: i64,
    verdict: String,
}

/// A verdict the window can still withdraw.
const GIVEN: &str = "json";
/// A verdict a cycle has taken.
const TAKEN: &str = "taken";

/// What applying an inbox did.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct InboxOutcome {
    /// Verdicts applied.
    pub applied: usize,
    /// Files naming an item that no longer exists, removed without effect.
    pub unknown: usize,
    /// Verdicts on an item that was merged into another, removed without
    /// effect: nothing records which item absorbed it.
    pub merged_away: usize,
}

/// Apply and remove every verdict in `dir`, in the order they were given.
/// Each file is taken before it is read; one the window withdrew first is
/// left alone, and so is one that cannot be taken now (the next cycle tries
/// again). Removed without effect: malformed files, files naming an item
/// that no longer exists, and verdicts on an item that was merged into
/// another. Each of the last two writes a log line that names nothing.
///
/// # Errors
/// Store failures (the taken file stays, and the next cycle applies it).
pub fn apply_inbox(store: &SqlCipherBrainStore, dir: &Path, now_us: u64) -> Result<InboxOutcome, StoreError> {
    apply_files(store, &verdict_files(dir), now_us)
}

/// The verdict files in `dir`, given or taken, in the order they were given:
/// by name (`{milliseconds}-{id}`), a taken file before a given one of the
/// same name.
fn verdict_files(dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut files: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == GIVEN || ext == TAKEN))
        .collect();
    files.sort_by_cached_key(|path| {
        (path.file_stem().map(ToOwned::to_owned), path.extension().is_some_and(|ext| ext == GIVEN))
    });
    files
}

fn apply_files(store: &SqlCipherBrainStore, files: &[PathBuf], now_us: u64) -> Result<InboxOutcome, StoreError> {
    let mut outcome = InboxOutcome::default();
    for file in files {
        let Some(taken) = take(file) else {
            continue;
        };
        let verdict: Option<Verdict> = std::fs::read(&taken)
            .ok()
            .filter(|bytes| bytes.len() < 1024)
            .and_then(|bytes| serde_json::from_slice(&bytes).ok());
        let reject = match verdict.as_ref().map(|v| v.verdict.as_str()) {
            Some("reject") => Some(true),
            Some("confirm") => Some(false),
            _ => None,
        };
        if let (Some(verdict), Some(reject)) = (verdict, reject) {
            match store.newest_revision(verdict.id)? {
                Some((_, PropositionStatus::Retired)) => {
                    outcome.merged_away += 1;
                    eprintln!("mci-agent: understanding: removed a verdict on an item that was merged into another");
                }
                Some((id, _)) => {
                    let done = if reject {
                        store.set_proposition_status(id, PropositionStatus::Rejected, now_us)?
                    } else {
                        store.confirm_proposition(id, now_us)?
                    };
                    if done {
                        outcome.applied += 1;
                    }
                }
                None => {
                    outcome.unknown += 1;
                    eprintln!("mci-agent: understanding: removed a verdict on an item that no longer exists");
                }
            }
        }
        let _ = std::fs::remove_file(&taken);
    }
    Ok(outcome)
}

/// Take a verdict before reading it, so the window can no longer withdraw
/// it. `None` when the window withdrew it first, or when it cannot be taken
/// now. A file already taken (by a cycle that was interrupted, or that met a
/// store failure) is returned as it is.
fn take(file: &Path) -> Option<PathBuf> {
    if file.extension().is_some_and(|ext| ext == TAKEN) {
        return Some(file.to_path_buf());
    }
    let taken = file.with_extension(TAKEN);
    std::fs::rename(file, &taken).ok().map(|()| taken)
}

#[cfg(test)]
mod tests {
    use super::*;
    use mci_brain::understanding::{NewProposition, PropositionKind};
    use mci_brain::{BrainStore, Event, EventId, EventSource};
    use mci_core::crypto::DbKey;

    fn memory(dir: &Path) -> (SqlCipherBrainStore, i64) {
        let store = SqlCipherBrainStore::new(&dir.join("b.sqlite"), &DbKey::from_bytes([5; 32])).unwrap();
        let event = Event {
            id: EventId(0), ts_us: 1, app_bundle_id: Some("com.apple.Notes".into()), window_title: None, url: None,
            text: "t".into(), summary: None, entities: None, episode_id: None, cascade_reason: 0,
            keyframe_blob: None, tab_id: None, embedding: None,
        };
        let e = store.put_event_with_source(&event, EventSource::ScreenOcr).unwrap();
        (store, i64::try_from(e.0).unwrap())
    }

    fn new(text: &str) -> NewProposition {
        NewProposition {
            text: text.into(), reasoning: String::new(), kind: PropositionKind::Habit,
            confidence: 0.6, decay: 0.5, model: "t".into(),
        }
    }

    /// An empty inbox in the test's own folder, never the owner's.
    fn inbox(dir: &Path) -> PathBuf {
        let inbox = dir.join("inbox");
        std::fs::create_dir(&inbox).unwrap();
        inbox
    }

    fn give(inbox: &Path, name: &str, id: i64, verdict: &str) {
        std::fs::write(inbox.join(format!("{name}.json")), format!(r#"{{"id":{id},"verdict":"{verdict}"}}"#)).unwrap();
    }

    fn ids(store: &SqlCipherBrainStore, status: PropositionStatus) -> Vec<i64> {
        store.propositions_with_status(status, 10).unwrap().into_iter().map(|p| p.id).collect()
    }

    fn applied(applied: usize) -> InboxOutcome {
        InboxOutcome { applied, ..InboxOutcome::default() }
    }

    #[test]
    fn verdicts_are_applied_once_and_removed() {
        let dir = tempfile::tempdir().unwrap();
        let (store, e) = memory(dir.path());
        let wrong = store.insert_proposition(&new("Amy dislikes meetings on Fridays"), &[e], 1).unwrap();
        let right = store.insert_proposition(&new("Amy writes Rust in the mornings"), &[e], 1).unwrap();
        let inbox = inbox(dir.path());
        give(&inbox, "1", wrong, "reject");
        give(&inbox, "2", right, "confirm");
        std::fs::write(inbox.join("3.json"), "not json").unwrap();
        assert_eq!(apply_inbox(&store, &inbox, 5).unwrap(), applied(2));
        assert_eq!(std::fs::read_dir(&inbox).unwrap().count(), 0);
        let active = store.propositions_with_status(PropositionStatus::Active, 10).unwrap();
        assert_eq!(active.len(), 1);
        assert_eq!(active[0].id, right);
        assert!((active[0].confidence - 1.0).abs() < 1e-9);
        assert_eq!(store.propositions_with_status(PropositionStatus::Rejected, 10).unwrap()[0].id, wrong);
        assert_eq!(store.confirmed_proposition_ids().unwrap(), std::collections::HashSet::from([right]));
    }

    #[test]
    fn a_verdict_on_a_revised_id_lands_on_its_newest_descendant() {
        let dir = tempfile::tempdir().unwrap();
        let (store, e) = memory(dir.path());
        let first = store.insert_proposition(&new("Amy writes Rust in the mornings"), &[e], 1).unwrap();
        let second = store.revise_proposition(first, &new("Amy writes Rust most mornings"), &[e], 2).unwrap();
        let newest = store.revise_proposition(second, &new("Amy writes Rust most mornings before ten"), &[e], 3).unwrap();
        let shown = store.insert_proposition(&new("Amy dislikes meetings on Fridays"), &[e], 4).unwrap();
        let live = store.revise_proposition(shown, &new("Amy dislikes long meetings on Fridays"), &[e], 5).unwrap();
        let inbox = inbox(dir.path());
        give(&inbox, "1", first, "confirm");
        give(&inbox, "2", shown, "reject");

        assert_eq!(apply_inbox(&store, &inbox, 6).unwrap(), applied(2));
        assert_eq!(store.confirmed_proposition_ids().unwrap(), std::collections::HashSet::from([newest]));
        assert_eq!(ids(&store, PropositionStatus::Active), vec![newest], "the newest revision is the one confirmed");
        assert_eq!(ids(&store, PropositionStatus::Rejected), vec![live], "a reject does not leave the live revision showing");
        let mut retired = ids(&store, PropositionStatus::Retired);
        retired.sort_unstable();
        assert_eq!(retired, vec![first, second, shown]);
    }

    #[test]
    fn a_confirm_does_not_bring_back_a_retired_row() {
        let dir = tempfile::tempdir().unwrap();
        let (store, e) = memory(dir.path());
        // Merged into another claim, so nothing revised it.
        let merged = store.insert_proposition(&new("Amy writes Rust in the mornings"), &[e], 1).unwrap();
        store.set_proposition_status(merged, PropositionStatus::Retired, 2).unwrap();
        let inbox = inbox(dir.path());
        give(&inbox, "1", merged, "confirm");

        assert_eq!(apply_inbox(&store, &inbox, 3).unwrap(), InboxOutcome { merged_away: 1, ..InboxOutcome::default() });
        assert_eq!(ids(&store, PropositionStatus::Retired), vec![merged]);
        assert!(ids(&store, PropositionStatus::Active).is_empty());
        assert!(store.confirmed_proposition_ids().unwrap().is_empty());
        assert_eq!(std::fs::read_dir(&inbox).unwrap().count(), 0);
    }

    #[test]
    fn a_verdict_on_an_item_merged_into_another_is_counted_and_has_no_effect() {
        let dir = tempfile::tempdir().unwrap();
        let (store, e) = memory(dir.path());
        // What a merge leaves: `kept` revised into `merged`, and `absorbed`
        // retired with no link to `merged`.
        let kept = store.insert_proposition(&new("Amy dislikes meetings on Fridays"), &[e], 1).unwrap();
        let absorbed = store.insert_proposition(&new("Amy avoids meetings on Friday afternoons"), &[e], 1).unwrap();
        store.set_proposition_status(absorbed, PropositionStatus::Retired, 2).unwrap();
        let merged = store.revise_proposition(kept, &new("Amy avoids meetings on Fridays"), &[e], 2).unwrap();
        let inbox = inbox(dir.path());
        give(&inbox, "1", absorbed, "reject");
        give(&inbox, "2", absorbed, "confirm");

        assert_eq!(apply_inbox(&store, &inbox, 3).unwrap(), InboxOutcome { merged_away: 2, ..InboxOutcome::default() });
        assert!(ids(&store, PropositionStatus::Rejected).is_empty(), "no row is marked on a guess");
        assert!(store.confirmed_proposition_ids().unwrap().is_empty());
        assert_eq!(ids(&store, PropositionStatus::Active), vec![merged]);
        assert_eq!(std::fs::read_dir(&inbox).unwrap().count(), 0);
    }

    #[test]
    fn a_reject_removes_the_confirmation() {
        let dir = tempfile::tempdir().unwrap();
        let (store, e) = memory(dir.path());
        let id = store.insert_proposition(&new("Amy writes Rust in the mornings"), &[e], 1).unwrap();
        let inbox = inbox(dir.path());
        give(&inbox, "1", id, "confirm");
        apply_inbox(&store, &inbox, 2).unwrap();
        assert_eq!(store.confirmed_proposition_ids().unwrap(), std::collections::HashSet::from([id]));

        give(&inbox, "2", id, "reject");
        assert_eq!(apply_inbox(&store, &inbox, 3).unwrap(), applied(1));
        assert!(store.confirmed_proposition_ids().unwrap().is_empty());
        assert_eq!(ids(&store, PropositionStatus::Rejected), vec![id]);
    }

    #[test]
    fn a_verdict_on_an_unknown_id_is_counted_and_removed() {
        let dir = tempfile::tempdir().unwrap();
        let (store, _) = memory(dir.path());
        let inbox = inbox(dir.path());
        give(&inbox, "1", 4242, "confirm");
        give(&inbox, "2", 4243, "maybe");

        assert_eq!(apply_inbox(&store, &inbox, 1).unwrap(), InboxOutcome { unknown: 1, ..InboxOutcome::default() });
        assert_eq!(std::fs::read_dir(&inbox).unwrap().count(), 0);
        assert_eq!(apply_inbox(&store, &dir.path().join("missing"), 1).unwrap(), InboxOutcome::default());
    }

    #[test]
    fn a_verdict_withdrawn_before_it_is_taken_has_no_effect() {
        let dir = tempfile::tempdir().unwrap();
        let (store, e) = memory(dir.path());
        let kept = store.insert_proposition(&new("Amy writes Rust in the mornings"), &[e], 1).unwrap();
        let forgotten = store.insert_proposition(&new("Amy dislikes meetings on Fridays"), &[e], 1).unwrap();
        let inbox = inbox(dir.path());
        give(&inbox, "1", kept, "reject");
        give(&inbox, "2", forgotten, "reject");
        let listed = verdict_files(&inbox);
        // The window's Undo, after the cycle listed the inbox.
        std::fs::remove_file(inbox.join("1.json")).unwrap();

        assert_eq!(apply_files(&store, &listed, 2).unwrap(), applied(1));
        assert_eq!(ids(&store, PropositionStatus::Active), vec![kept]);
        assert_eq!(ids(&store, PropositionStatus::Rejected), vec![forgotten]);
        assert_eq!(std::fs::read_dir(&inbox).unwrap().count(), 0);
    }

    #[test]
    fn a_taken_verdict_cannot_be_withdrawn_and_the_next_cycle_applies_it() {
        let dir = tempfile::tempdir().unwrap();
        let (store, e) = memory(dir.path());
        let id = store.insert_proposition(&new("Amy writes Rust in the mornings"), &[e], 1).unwrap();
        let inbox = inbox(dir.path());
        give(&inbox, "1000-1", id, "confirm");
        give(&inbox, "2000-1", id, "reject");
        // A cycle took the first verdict and stopped before applying it.
        assert_eq!(take(&inbox.join("1000-1.json")), Some(inbox.join("1000-1.taken")));
        // The window's Undo finds nothing to remove, so the verdict is the cycle's.
        let undo = std::fs::remove_file(inbox.join("1000-1.json")).unwrap_err();
        assert_eq!(undo.kind(), std::io::ErrorKind::NotFound);

        assert_eq!(apply_inbox(&store, &inbox, 2).unwrap(), applied(2));
        assert_eq!(ids(&store, PropositionStatus::Rejected), vec![id], "in the order given, the later verdict wins");
        assert!(store.confirmed_proposition_ids().unwrap().is_empty());
        assert_eq!(std::fs::read_dir(&inbox).unwrap().count(), 0);
    }

    #[test]
    fn a_verdict_that_cannot_be_taken_waits_for_the_next_cycle() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let (store, e) = memory(dir.path());
        let id = store.insert_proposition(&new("Amy writes Rust in the mornings"), &[e], 1).unwrap();
        let inbox = inbox(dir.path());
        give(&inbox, "1", id, "reject");
        let lock = |mode| std::fs::set_permissions(&inbox, std::fs::Permissions::from_mode(mode)).unwrap();
        lock(0o500);
        if std::fs::write(inbox.join("probe"), "").is_ok() {
            // Permissions are not enforced here (run as root): nothing to check.
            lock(0o700);
            return;
        }
        let outcome = apply_inbox(&store, &inbox, 2);
        lock(0o700);

        // Applying it untaken would let the window withdraw a verdict already applied.
        assert_eq!(outcome.unwrap(), InboxOutcome::default());
        assert!(ids(&store, PropositionStatus::Rejected).is_empty());
        assert!(inbox.join("1.json").exists(), "still the window's to withdraw");
        assert_eq!(apply_inbox(&store, &inbox, 3).unwrap(), applied(1));
        assert_eq!(ids(&store, PropositionStatus::Rejected), vec![id]);
    }

    #[test]
    fn a_development_memory_is_given_no_inbox() {
        assert_eq!(inbox_for_memory(true), None);
        assert_eq!(inbox_for_memory(false), inbox_dir());
    }

    #[test]
    fn only_the_daemon_names_the_owner_inbox() {
        // Every other caller, tests included, hands `Understanding::new` a
        // folder of its own or none, so running the tests cannot take the
        // owner's pending verdicts.
        fn sources(dir: &Path, out: &mut Vec<PathBuf>) {
            for entry in std::fs::read_dir(dir).unwrap().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    sources(&path, out);
                } else if path.extension().is_some_and(|ext| ext == "rs") {
                    out.push(path);
                }
            }
        }
        let root = Path::new(env!("CARGO_MANIFEST_DIR"));
        let mut files = Vec::new();
        sources(&root.join("src"), &mut files);
        sources(&root.join("tests"), &mut files);
        let mut naming: Vec<String> = files
            .iter()
            .filter(|path| {
                let source = std::fs::read_to_string(path).unwrap_or_default();
                source.contains("inbox_dir(") || source.contains("inbox_for_memory(")
            })
            .map(|path| path.strip_prefix(root).unwrap().to_string_lossy().into_owned())
            .collect();
        naming.sort();
        assert_eq!(naming, vec!["src/bin/mci_agent.rs", "src/understanding/feedback.rs"]);
        let daemon = std::fs::read_to_string(root.join("src/bin/mci_agent.rs")).unwrap();
        assert_eq!(daemon.matches("inbox_for_memory(read_dev_key_hex().is_some())").count(), 1);
        assert!(!daemon.contains("inbox_dir("));
    }
}
