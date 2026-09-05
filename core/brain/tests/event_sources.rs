use mci_brain::{BrainStore, Event, EventId, EventSource, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

fn event(ts_us: u64) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some("com.anthropic.claude-code".into()),
        window_title: None,
        url: None,
        text: "A source observation".into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: None,
    }
}

#[test]
fn source_round_trip_counts_and_deletion_are_grounded_in_retained_rows() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("brain.sqlite");
    let key = DbKey::from_bytes([42; 32]);
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();
    let sources = [
        EventSource::Unknown,
        EventSource::ScreenOcr,
        EventSource::BrowserPage,
        EventSource::BrowserPageWithOcr,
        EventSource::TranscriptImport,
        EventSource::StructuredApp,
        EventSource::McpResource,
    ];
    for (index, source) in sources.into_iter().enumerate() {
        let mut row = event(index as u64 + 1);
        if source == EventSource::ScreenOcr {
            row.keyframe_blob = Some("ab".repeat(32));
        }
        let id = store.put_event_with_source(&row, source).unwrap();
        assert_eq!(store.event_source(id).unwrap(), source);
    }
    let counts = store.capture_storage_stats().unwrap();
    assert_eq!(counts.stored_frame_count, 2);
    assert_eq!(counts.stored_screenshot_count, 1);
    assert_eq!(counts.last_stored_frame_ts_us, Some(4));
    drop(store);
    let reader = SqlCipherBrainStore::open_readonly(&path, &key).unwrap();
    assert_eq!(
        reader.event_source(EventId(5)).unwrap(),
        EventSource::TranscriptImport
    );
    drop(reader);
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();
    store.delete_events_in_range(2, 4).unwrap();
    assert_eq!(store.capture_storage_stats().unwrap().stored_frame_count, 0);
    assert_eq!(
        store.event_source(EventId(2)).unwrap(),
        EventSource::Unknown
    );
}

#[test]
fn legacy_readonly_and_migration_do_not_guess_provenance() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("brain.sqlite");
    let key = DbKey::from_bytes([43; 32]);
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();
    let id = store.put_event(&event(123)).unwrap();
    drop(store);
    let db = mci_core::store::open(&path, &key).unwrap();
    db.conn()
        .execute_batch(
            "DROP TABLE event_sources; UPDATE meta SET value='8' WHERE key='brain_schema_version';",
        )
        .unwrap();
    drop(db);
    let reader = SqlCipherBrainStore::open_readonly(&path, &key).unwrap();
    assert_eq!(reader.event_source(id).unwrap(), EventSource::Unknown);
    assert_eq!(
        reader.get_event(id).unwrap().unwrap().text,
        "A source observation"
    );
    drop(reader);
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();
    assert_eq!(store.event_source(id).unwrap(), EventSource::Unknown);
    assert_eq!(store.capture_storage_stats().unwrap().stored_frame_count, 0);
}

#[test]
fn attribution_failure_rolls_back_the_event_and_fts() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("brain.sqlite");
    let key = DbKey::from_bytes([44; 32]);
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();
    let db = mci_core::store::open(&path, &key).unwrap();
    db.conn().execute_batch("CREATE TRIGGER reject_source BEFORE INSERT ON event_sources BEGIN SELECT RAISE(ABORT, 'test failure'); END;").unwrap();
    assert!(store
        .put_event_with_source(&event(123), EventSource::ScreenOcr)
        .is_err());
    assert_eq!(store.stats().unwrap().event_count, 0);
    assert!(store.fts5_search("observation", 5).unwrap().is_empty());
}

#[test]
fn old_timeline_window_is_filtered_before_the_row_cap() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("brain.sqlite");
    let key = DbKey::from_bytes([45; 32]);
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();
    let first = store.put_event(&event(100)).unwrap();
    let last = store.put_event(&event(200)).unwrap();
    let mut db = mci_core::store::open(&path, &key).unwrap();
    let tx = db.conn_mut().transaction().unwrap();
    tx.execute_batch(
        "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10001)
        INSERT INTO events(ts_us,text,cascade_reason) SELECT 1000+x,'newer',0 FROM n;",
    )
    .unwrap();
    tx.commit().unwrap();
    assert_eq!(
        store
            .events_in_range(100, 200, 10000)
            .unwrap()
            .iter()
            .map(|e| e.id)
            .collect::<Vec<_>>(),
        vec![last, first]
    );
    assert_eq!(store.events_in_range(100, 200, 1).unwrap()[0].id, last);
    assert!(store.events_in_range(101, 199, 10).unwrap().is_empty());
    assert!(store.events_in_range(200, 100, 10).is_err());
}
