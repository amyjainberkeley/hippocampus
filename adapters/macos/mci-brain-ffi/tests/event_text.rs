use std::ffi::{CStr, CString};

use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore};
use mci_brain_ffi::{
    mci_brain_ffi_close, mci_brain_ffi_event_text, mci_brain_ffi_last_error_message,
    mci_brain_ffi_open, mci_brain_ffi_recent_events, mci_brain_ffi_string_free, Handle, HitJson,
};
use mci_core::crypto::DbKey;
use serde_json::Value;

const CAP: usize = 128 * 1024;

struct TestBrain {
    handle: *mut Handle,
    store: SqlCipherBrainStore,
    dir: tempfile::TempDir,
}

impl TestBrain {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("brain.sqlite");
        let store = SqlCipherBrainStore::new(&path, &DbKey::from_bytes([42; 32])).unwrap();
        let path_c = CString::new(path.to_str().unwrap()).unwrap();
        let key = CString::new("2a".repeat(32)).unwrap();
        let handle = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key.as_ptr()) };
        assert!(!handle.is_null());
        Self { handle, store, dir }
    }

    fn seed(&self, text: &str) -> EventId {
        self.seed_with_identity(text, 100, None)
    }

    fn seed_with_identity(&self, text: &str, ts_us: u64, app: Option<&str>) -> EventId {
        self.store
            .put_event(&Event {
                id: EventId(0),
                ts_us,
                app_bundle_id: app.map(str::to_owned),
                window_title: None,
                url: None,
                text: text.into(),
                summary: None,
                entities: None,
                episode_id: None,
                cascade_reason: 0,
                keyframe_blob: None,
                tab_id: None,
                embedding: None,
            })
            .unwrap()
    }

    fn read(&self, id: u64) -> Value {
        let raw = unsafe { mci_brain_ffi_event_text(self.handle, id) };
        assert!(
            !raw.is_null(),
            "a missing event is JSON null, not an FFI error"
        );
        let bytes = unsafe { CStr::from_ptr(raw) }.to_bytes().to_owned();
        unsafe { mci_brain_ffi_string_free(raw) };
        assert!(
            bytes.len() <= (CAP + 1024) * 6 + 256,
            "JSON escaping must remain bounded"
        );
        serde_json::from_slice(&bytes).unwrap()
    }
}

impl Drop for TestBrain {
    fn drop(&mut self) {
        unsafe { mci_brain_ffi_close(self.handle) };
    }
}

#[test]
fn selected_event_exposes_stored_text_beyond_unchanged_list_snippets() {
    let brain = TestBrain::new();
    let text = format!("{}\nThe final stored line.", "a".repeat(350));
    let selected = brain.seed(&text);
    brain.seed("Unselected evidence.");
    let value = brain.read(selected.0);
    assert_eq!(value["event_id"], selected.0);
    assert_eq!(value["text"], text);
    assert_eq!(value["truncated"], false);

    let raw = unsafe { mci_brain_ffi_recent_events(brain.handle, 10) };
    assert!(!raw.is_null());
    let hits: Vec<HitJson> =
        serde_json::from_slice(unsafe { CStr::from_ptr(raw) }.to_bytes()).unwrap();
    unsafe { mci_brain_ffi_string_free(raw) };
    let hit = hits.iter().find(|hit| hit.event_id == selected.0).unwrap();
    assert_eq!(hit.ocr_text_snippet.chars().count(), 280);
    assert!(!hit.ocr_text_snippet.contains("The final stored line."));
    assert_eq!(brain.store.stats().unwrap().event_count, 2);
}

#[test]
fn text_cap_distinguishes_complete_boundary_from_truncated_prefix() {
    let brain = TestBrain::new();
    for (length, expected_length, truncated) in [
        (CAP - 1, CAP - 1, false),
        (CAP, CAP, false),
        (CAP + 1, CAP, true),
    ] {
        let id = brain.seed(&"a".repeat(length));
        let value = brain.read(id.0);
        assert_eq!(value["text"].as_str().unwrap().len(), expected_length);
        assert_eq!(value["truncated"], truncated);
    }
}

#[test]
fn cap_never_splits_a_multibyte_scalar_or_invents_replacement_text() {
    let brain = TestBrain::new();
    for scalar in ['\u{e9}', '\u{20ac}', '\u{1f642}'] {
        let prefix = "a".repeat(CAP - 1);
        let id = brain.seed(&format!("{prefix}{scalar}tail"));
        let value = brain.read(id.0);
        assert_eq!(value["text"].as_str().unwrap(), prefix);
        assert_eq!(value["truncated"], true);
    }
}

#[test]
fn complete_unicode_and_control_characters_round_trip_without_rewriting() {
    let brain = TestBrain::new();
    let text = "\u{4f60}\u{597d} e\u{301}\nquote: \"slash: \\ nul: \0 end";
    let id = brain.seed(text);
    let value = brain.read(id.0);
    assert_eq!(value["text"], text);
    assert_eq!(value["truncated"], false);
}

#[test]
fn json_escaping_of_a_large_control_character_prefix_is_bounded() {
    let brain = TestBrain::new();
    let id = brain.seed(&"\u{1}".repeat(CAP + 50));
    let value = brain.read(id.0);
    assert_eq!(value["text"].as_str().unwrap().len(), CAP);
    assert_eq!(value["truncated"], true);
}

#[test]
fn empty_text_is_a_present_event() {
    let brain = TestBrain::new();
    let id = brain.seed("");
    let value = brain.read(id.0);
    assert_eq!(value["event_id"], id.0);
    assert_eq!(value["text"], "");
    assert_eq!(value["truncated"], false);
}

#[test]
fn deleted_and_out_of_range_ids_resolve_to_no_text() {
    let brain = TestBrain::new();
    let id = brain.seed("Temporary synthetic evidence.");
    assert!(!brain.read(id.0).is_null());
    brain.store.delete_event(id).unwrap();
    for missing in [id.0, 0, u64::MAX, i64::MAX as u64 + 1] {
        assert!(brain.read(missing).is_null());
    }
}

#[test]
fn reused_id_returns_replacement_identity_with_its_text_not_the_deleted_identity() {
    let brain = TestBrain::new();
    let original = brain.seed_with_identity("old text", 100, Some("test.original"));
    let original_text = brain.read(original.0);
    assert_eq!(original_text["ts_us"], 100);
    assert_eq!(original_text["app_bundle_id"], "test.original");
    brain.store.delete_event(original).unwrap();
    assert!(brain.read(original.0).is_null());
    let replacement = brain.seed_with_identity("replacement text", 200, Some("test.replacement"));
    assert_eq!(
        replacement, original,
        "fixture must actually exercise row-id reuse"
    );
    let value = brain.read(original.0);
    assert_eq!(value["event_id"], original.0);
    assert_eq!(value["text"], "replacement text");
    assert_eq!(value["ts_us"], 200);
    assert_eq!(value["app_bundle_id"], "test.replacement");
    assert_ne!(value["ts_us"], original_text["ts_us"]);
    assert_ne!(value["app_bundle_id"], original_text["app_bundle_id"]);
}

#[test]
fn identity_is_exact_nullable_and_bounded_without_truncation() {
    let brain = TestBrain::new();
    for app in [None, Some(""), Some("mcp:fixture"), Some("test.\0exact")] {
        let id = brain.seed_with_identity("text", 100, app);
        let value = brain.read(id.0);
        assert_eq!(value["app_bundle_id"], serde_json::to_value(app).unwrap());
        assert_eq!(value["ts_us"], 100);
    }
    let maximum = "\u{1}".repeat(1024);
    let id = brain.seed_with_identity(&"\u{1}".repeat(CAP), 100, Some(&maximum));
    let value = brain.read(id.0);
    assert_eq!(value["app_bundle_id"], maximum);
    assert_eq!(value["text"].as_str().unwrap().len(), CAP);
    let id = brain.seed_with_identity("hidden", 100, Some(&"x".repeat(1025)));
    assert!(
        brain.read(id.0).is_null(),
        "oversized identity must not be truncated or replaced with null app"
    );
}

#[test]
fn rows_marked_suppressed_are_not_exposed() {
    let brain = TestBrain::new();
    let id = brain.seed("Synthetic withheld row.");
    let db = mci_core::store::open(
        &brain.dir.path().join("brain.sqlite"),
        &DbKey::from_bytes([42; 32]),
    )
    .unwrap();
    db.conn()
        .execute(
            "UPDATE events SET cascade_reason = 1 WHERE id = ?1",
            [i64::try_from(id.0).unwrap()],
        )
        .unwrap();
    assert!(brain.read(id.0).is_null());
}

#[test]
fn null_handle_is_rejected() {
    assert!(unsafe { mci_brain_ffi_event_text(std::ptr::null_mut(), 1) }.is_null());
}

#[test]
fn malformed_stored_utf8_fails_without_replacement_or_content_in_error() {
    let brain = TestBrain::new();
    let id = brain.seed("synthetic text");
    let db = mci_core::store::open(
        &brain.dir.path().join("brain.sqlite"),
        &DbKey::from_bytes([42; 32]),
    )
    .unwrap();
    let invalid = [b"private-fixture-marker".as_slice(), &[0xff]].concat();
    db.conn()
        .execute(
            "UPDATE events SET text = ?1 WHERE id = ?2",
            rusqlite::params![invalid, i64::try_from(id.0).unwrap()],
        )
        .unwrap();
    assert!(unsafe { mci_brain_ffi_event_text(brain.handle, id.0) }.is_null());
    let error = unsafe { CStr::from_ptr(mci_brain_ffi_last_error_message()) }
        .to_str()
        .unwrap();
    assert_eq!(error, "mci_brain_ffi_event_text: stored text unavailable");
}
