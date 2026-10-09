//! Whole-screen capture: text from a visible window the user was not focused
//! on arrives as `ContextOCREvent` and is stored under that window's own app
//! and title, as `screen_context`, never as the focused app.

use std::sync::Arc;

use mci_agent::brain_ingest::{BrainIngestor, BrainPump, IngestOutcome};
use mci_brain::{BrainStore, EventSource, SqlCipherBrainStore};
use mci_core::crypto::DbKey;
use mci_core::ipc::Message;

fn bundle(app: &str) -> [u8; 64] {
    let mut out = [0u8; 64];
    out[..app.len()].copy_from_slice(app.as_bytes());
    out
}

#[test]
fn context_text_is_stored_under_its_own_window_as_screen_context() {
    let dir = tempfile::tempdir().expect("tempdir");
    let key = DbKey::from_bytes([0xCD; 32]);
    let store = Arc::new(SqlCipherBrainStore::new(&dir.path().join("ctx.sqlite"), &key).expect("open"));
    let pump = BrainPump::new(Arc::clone(&store) as Arc<dyn BrainStore>, None);

    let outcome = pump
        .ingest_ocr_event(&Message::ContextOCREvent {
            seq: 1,
            ts_us: 1_700_000_000_000_000,
            app_bundle_id: bundle("com.apple.TextEdit"),
            window_title: "Quarterly notes".into(),
            url: String::new(),
            ocr_text: "Budget review moved to Thursday".into(),
            keyframe_hash: [0u8; 32],
        })
        .expect("ingest");
    let IngestOutcome::Stored { id, .. } = outcome else {
        panic!("context text must be stored");
    };

    assert_eq!(store.event_source(id).expect("source"), EventSource::ScreenContext);
    let event = store.get_event(id).expect("read").expect("present");
    assert_eq!(event.app_bundle_id.as_deref(), Some("com.apple.TextEdit"));
    assert_eq!(event.window_title.as_deref(), Some("Quarterly notes"));
    assert_eq!(event.url, None);
    assert_eq!(event.keyframe_blob, None, "no screenshot is kept for background windows");
    assert!(event.text.contains("Budget review moved to Thursday"));
    assert_eq!(store.capture_storage_stats().expect("stats").stored_frame_count, 1);
}
