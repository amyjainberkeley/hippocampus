//! Storage-security review S3: after a deletion or a retention purge, the
//! write-ahead log is folded into the database and truncated to zero bytes.
//! `VACUUM` in WAL mode writes the rewritten database through `-wal`, and
//! without a truncating checkpoint the log keeps frames that still hold the
//! deleted rows (encrypted, but under the same key) until they are reused.

use std::path::{Path, PathBuf};

use mci_brain::retention_purger::purge_once;
use mci_brain::{BrainStore, Event, EventId, RetentionConfig, SqlCipherBrainStore};
use mci_core::crypto::{DbKey, InMemoryKeyWrap, KeyWrap};

const DAY_US: u64 = 86_400_000_000;

fn test_key() -> DbKey {
    let key = DbKey::generate().expect("csprng");
    let wrap = InMemoryKeyWrap;
    let wrapped = wrap.wrap(&key).expect("wrap");
    wrap.unwrap_key(&wrapped).expect("unwrap")
}

fn event(ts_us: u64, text: &str) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some("com.example.Notes".into()),
        window_title: Some("Synthetic notes".into()),
        url: None,
        text: text.into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: None,
    }
}

fn wal_path(db: &Path) -> PathBuf {
    let mut name = db.as_os_str().to_owned();
    name.push("-wal");
    PathBuf::from(name)
}

fn wal_len(db: &Path) -> u64 {
    std::fs::metadata(wal_path(db)).map_or(0, |metadata| metadata.len())
}

/// A store holding `count` made-up moments a day apart, ending at `now_us`,
/// with enough text that the log grows well past a page.
fn filled_store(count: u64, now_us: u64) -> (tempfile::TempDir, PathBuf, SqlCipherBrainStore) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("mci.sqlite");
    let store = SqlCipherBrainStore::new(&path, &test_key()).expect("open store");
    let filler = "Quillfeather draft paragraph about synthetic marigold planning. ".repeat(40);
    for index in 0..count {
        let ts = now_us - (count - index) * DAY_US;
        store
            .put_event(&event(ts, &format!("moment {index} {filler}")))
            .expect("put event");
    }
    (dir, path, store)
}

#[test]
fn deleting_a_range_leaves_an_empty_write_ahead_log() {
    let now = 1_800_000_000_000_000;
    let (_dir, path, store) = filled_store(60, now);
    let outcome = store
        .delete_events_in_range_with_outcome(now - 30 * DAY_US, now)
        .expect("delete range");
    assert!(outcome.events_deleted > 0);
    assert!(outcome.vacuum_ok(), "{:?}", outcome.cleanup_warnings);
    assert_eq!(
        wal_len(&path),
        0,
        "the log still holds frames after the deletion"
    );
}

#[test]
fn deleting_one_moment_leaves_an_empty_write_ahead_log() {
    let now = 1_800_000_000_000_000;
    let (_dir, path, store) = filled_store(40, now);
    let outcome = store.delete_event_with_outcome(EventId(7)).expect("delete");
    assert_eq!(outcome.events_deleted, 1);
    assert_eq!(wal_len(&path), 0);
}

#[test]
fn deleting_everything_leaves_an_empty_write_ahead_log() {
    let now = 1_800_000_000_000_000;
    let (_dir, path, store) = filled_store(40, now);
    let outcome = store.wipe_all_with_outcome().expect("wipe");
    assert_eq!(outcome.events_deleted, 40);
    assert_eq!(wal_len(&path), 0);
}

#[test]
fn a_retention_purge_leaves_an_empty_write_ahead_log() {
    let now = 1_800_000_000_000_000;
    let (_dir, path, store) = filled_store(60, now);
    let stats = purge_once(&store, &RetentionConfig::Days(7), now).expect("purge");
    assert!(stats.events_deleted > 40, "{stats:?}");
    assert_eq!(wal_len(&path), 0);
}
