use mci_brain::{BrainStore, Event, EventId, EventSource, SqlCipherBrainStore};
use mci_brain_ffi::{
    mci_brain_ffi_close, mci_brain_ffi_events_by_ids, mci_brain_ffi_open,
    mci_brain_ffi_string_free, mci_brain_ffi_timeline_events, HitJson, TimelineEventJson,
};
use mci_core::crypto::DbKey;
use std::ffi::{CStr, CString};

#[test]
fn ffi_preserves_acquisition_source_and_finds_old_dates_beyond_recent_cap() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("brain.sqlite");
    let key = DbKey::from_bytes([42; 32]);
    let store = SqlCipherBrainStore::new(&path, &key).unwrap();
    let event = Event {
        id: EventId(0),
        ts_us: 100,
        app_bundle_id: Some("com.anthropic.claude-code".into()),
        window_title: None,
        url: None,
        text: "Exact imported transcript".into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: None,
    };
    let id = store
        .put_event_with_source(&event, EventSource::TranscriptImport)
        .unwrap();
    let mut db = mci_core::store::open(&path, &key).unwrap();
    let tx = db.conn_mut().transaction().unwrap();
    tx.execute_batch(
        "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10001)
        INSERT INTO events(ts_us,text,cascade_reason) SELECT 1000+x,'newer event',0 FROM n;",
    )
    .unwrap();
    tx.commit().unwrap();
    drop(db);
    drop(store);
    let path_c = CString::new(path.to_str().unwrap()).unwrap();
    let key_c = CString::new("2a".repeat(32)).unwrap();
    let handle = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key_c.as_ptr()) };
    assert!(!handle.is_null());
    let query =
        CString::new(r#"{"start_ts_us":100,"end_ts_us":100,"resolution":"event"}"#).unwrap();
    let result = unsafe { mci_brain_ffi_timeline_events(handle, query.as_ptr()) };
    assert!(!result.is_null());
    let rows: Vec<TimelineEventJson> =
        serde_json::from_slice(unsafe { CStr::from_ptr(result) }.to_bytes()).unwrap();
    unsafe {
        mci_brain_ffi_string_free(result);
    }
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].event_id, id.0);
    assert_eq!(rows[0].source_kind, "transcript_import");
    let query = CString::new(format!("{{\"ids\":[{}]}}", id.0)).unwrap();
    let result = unsafe { mci_brain_ffi_events_by_ids(handle, query.as_ptr()) };
    assert!(!result.is_null());
    let hits: Vec<HitJson> =
        serde_json::from_slice(unsafe { CStr::from_ptr(result) }.to_bytes()).unwrap();
    unsafe {
        mci_brain_ffi_string_free(result);
        mci_brain_ffi_close(handle);
    }
    assert_eq!(hits[0].source_kind, "transcript_import");
    assert_eq!(hits[0].source, "linked");
    assert_eq!(hits[0].ocr_text_snippet, "Exact imported transcript");
}

#[test]
fn old_json_without_acquisition_source_decodes_unknown() {
    let hit: HitJson = serde_json::from_value(serde_json::json!({
        "event_id": 1, "ts_us": 100, "app_bundle_id": null, "window_title": null,
        "url": null, "ocr_text_snippet": "legacy", "source": "timeline", "score": null,
    }))
    .unwrap();
    assert_eq!(hit.source_kind, "unknown");
    assert_eq!(hit.source, "timeline");
}
