//! Store surfaces added for the handoff layer (contract 2026-09-26):
//! project evidence by url prefix, source-filtered range reads, and the
//! `handoff_deliveries` ledger from migration 0012.

use mci_brain::{BrainStore, Event, EventId, EventSource, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

fn event(ts_us: u64, url: Option<&str>, text: &str) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some("com.anthropic.claude-code".into()),
        window_title: Some("proj · user".into()),
        url: url.map(str::to_owned),
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

fn fresh_store(dir: &tempfile::TempDir) -> SqlCipherBrainStore {
    let key = DbKey::from_bytes([7; 32]);
    SqlCipherBrainStore::new(&dir.path().join("brain.sqlite"), &key).expect("open store")
}

#[test]
fn url_prefix_matches_root_and_children_but_not_siblings() {
    let dir = tempfile::tempdir().unwrap();
    let store = fresh_store(&dir);
    let rows = [
        (10, Some("/x/onekit"), "root"),
        (20, Some("/x/onekit/sub"), "child"),
        (
            30,
            Some("/x/onekit-bench"),
            "sibling with shared characters",
        ),
        (40, Some("/x/other"), "unrelated"),
        (50, None, "no url"),
        (60, Some("/x/onekit"), "root again, newest"),
    ];
    for (ts, url, text) in rows {
        store
            .put_event_with_source(&event(ts, url, text), EventSource::TranscriptImport)
            .unwrap();
    }

    let hits = store.events_by_url_prefix("/x/onekit", 100).unwrap();
    let texts: Vec<&str> = hits.iter().map(|e| e.text.as_str()).collect();
    assert_eq!(
        texts,
        ["root again, newest", "child", "root"],
        "newest first"
    );

    // A trailing slash on the prefix means the same project.
    let slashed = store.events_by_url_prefix("/x/onekit/", 100).unwrap();
    assert_eq!(slashed.len(), 3);

    // The limit keeps the newest rows.
    let limited = store.events_by_url_prefix("/x/onekit", 1).unwrap();
    assert_eq!(limited[0].text, "root again, newest");

    assert!(store.events_by_url_prefix("", 10).is_err());
    assert!(store
        .events_by_url_prefix("/x/onekit", 0)
        .unwrap()
        .is_empty());
}

#[test]
fn source_filtered_range_reads_only_that_source() {
    let dir = tempfile::tempdir().unwrap();
    let store = fresh_store(&dir);
    store
        .put_event_with_source(&event(100, None, "screen a"), EventSource::ScreenOcr)
        .unwrap();
    store
        .put_event_with_source(
            &event(200, None, "transcript"),
            EventSource::TranscriptImport,
        )
        .unwrap();
    store
        .put_event_with_source(&event(300, None, "screen b"), EventSource::ScreenOcr)
        .unwrap();
    store
        .put_event(&event(400, None, "legacy, no source"))
        .unwrap();

    let screen = store
        .events_by_source_in_range(EventSource::ScreenOcr, 0, u64::MAX, 10)
        .unwrap();
    let texts: Vec<&str> = screen.iter().map(|e| e.text.as_str()).collect();
    assert_eq!(texts, ["screen b", "screen a"]);

    let windowed = store
        .events_by_source_in_range(EventSource::ScreenOcr, 150, 350, 10)
        .unwrap();
    assert_eq!(windowed.len(), 1);
    assert_eq!(windowed[0].text, "screen b");

    assert!(store
        .events_by_source_in_range(EventSource::ScreenOcr, 10, 5, 10)
        .is_err());
    let transcript = store
        .events_by_source_in_range(EventSource::TranscriptImport, 0, u64::MAX, 10)
        .unwrap();
    assert_eq!(transcript.len(), 1);
    assert_eq!(transcript[0].text, "transcript");
}

#[test]
fn deliveries_are_recorded_and_read_back_newest_first() {
    let dir = tempfile::tempdir().unwrap();
    let store = fresh_store(&dir);
    assert!(store.recent_handoff_deliveries(5).unwrap().is_empty());

    let first = store
        .record_handoff_delivery(
            1_000,
            "cli",
            "/x/onekit",
            "ab".repeat(32).as_str(),
            512,
            "[1,2]",
        )
        .unwrap();
    let second = store
        .record_handoff_delivery(
            2_000,
            "claude-code",
            "/x/onekit",
            "cd".repeat(32).as_str(),
            600,
            "[]",
        )
        .unwrap();
    assert!(second > first);

    let rows = store.recent_handoff_deliveries(5).unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].client, "claude-code");
    assert_eq!(rows[0].ts_us, 2_000);
    assert_eq!(rows[0].token_estimate, 600);
    assert_eq!(rows[0].event_ids_json, "[]");
    assert_eq!(rows[1].client, "cli");
    assert_eq!(rows[1].event_ids_json, "[1,2]");
    assert_eq!(rows[1].project_root, "/x/onekit");
    assert_eq!(store.recent_handoff_deliveries(1).unwrap().len(), 1);

    assert!(store
        .record_handoff_delivery(3_000, "", "/x", "0", 1, "[]")
        .is_err());
    assert!(store
        .record_handoff_delivery(3_000, "cli", "/x", "0", 1, "not json")
        .is_err());
}

#[test]
fn migration_0012_is_idempotent_and_readonly_handles_read_the_ledger() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("brain.sqlite");
    let key = DbKey::from_bytes([9; 32]);
    {
        let store = SqlCipherBrainStore::new(&path, &key).unwrap();
        store
            .record_handoff_delivery(5, "codex", "/p", "00", 10, "[3]")
            .unwrap();
    }
    // Re-opening a writer re-applies the migration batch without error.
    let again = SqlCipherBrainStore::new(&path, &key).unwrap();
    assert_eq!(again.recent_handoff_deliveries(10).unwrap().len(), 1);
    drop(again);

    let reader = SqlCipherBrainStore::open_readonly(&path, &key).unwrap();
    let rows = reader.recent_handoff_deliveries(10).unwrap();
    assert_eq!(rows[0].client, "codex");
    assert!(
        reader
            .record_handoff_delivery(6, "cli", "/p", "00", 1, "[]")
            .is_err(),
        "a read-only handle must not be able to write the ledger"
    );
}
