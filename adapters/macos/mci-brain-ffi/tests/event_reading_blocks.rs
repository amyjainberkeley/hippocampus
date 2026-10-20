//! The FFI's reading of a moment carries its text as blocks too
//! (`blocks`, SPEC 4.2), additive beside `main`: what the formatted reading
//! view draws. Every block holds only text that was read, and a moment with
//! nothing to read has no blocks.

use std::ffi::{c_char, CStr, CString};
use std::ptr;

use mci_brain::reading_blocks::{blocks, Window};
use mci_brain::{BrainStore, Event, EventId, EventSource, SqlCipherBrainStore};
use mci_brain_ffi::{
    mci_brain_ffi_close, mci_brain_ffi_event_reading, mci_brain_ffi_open,
    mci_brain_ffi_string_free, Handle,
};
use mci_core::crypto::DbKey;
use serde_json::Value;

const NOTES: &str = "com.apple.Notes";

struct TestBrain {
    handle: *mut Handle,
    store: SqlCipherBrainStore,
    _dir: tempfile::TempDir,
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
        Self {
            handle,
            store,
            _dir: dir,
        }
    }

    fn seed(&self, text: &str, title: &str) -> EventId {
        self.store
            .put_event_with_source(
                &Event {
                    id: EventId(0),
                    ts_us: 100,
                    app_bundle_id: Some(NOTES.into()),
                    window_title: Some(title.into()),
                    url: None,
                    text: text.into(),
                    summary: None,
                    entities: None,
                    episode_id: None,
                    cascade_reason: 0,
                    keyframe_blob: None,
                    tab_id: None,
                    embedding: None,
                },
                EventSource::ScreenOcr,
            )
            .unwrap()
    }

    fn reading(&self, id: u64) -> Value {
        take_json(unsafe { mci_brain_ffi_event_reading(self.handle, id, ptr::null()) })
    }
}

impl Drop for TestBrain {
    fn drop(&mut self) {
        unsafe { mci_brain_ffi_close(self.handle) };
    }
}

fn take_json(raw: *mut c_char) -> Value {
    assert!(!raw.is_null(), "the call returned an error");
    let bytes = unsafe { CStr::from_ptr(raw) }.to_bytes().to_vec();
    unsafe { mci_brain_ffi_string_free(raw) };
    serde_json::from_slice(&bytes).unwrap()
}

fn header(title: &str) -> String {
    format!("[app={NOTES} | title={title} | url=? | ts=2026-10-12T14:02:00.000Z]\n")
}

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn the_reading_carries_main_as_blocks_of_what_was_read() {
    let brain = TestBrain::new();
    let stored = format!(
        "{}Launch checklist\nGift card copy is in the doc, ready for a last look.\n\nShip the rounding fix at 4.",
        header("Launch checklist")
    );
    let id = brain.seed(&stored, "Launch checklist");
    let value = brain.reading(id.0);

    let main = value["main"].as_str().unwrap().to_owned();
    let made = value["blocks"].as_array().expect("blocks is an array");
    assert!(!made.is_empty());
    let mut held = Vec::new();
    for block in made {
        assert!(block["kind"].is_string(), "each block names its kind");
        held.extend(words(block["text"].as_str().unwrap_or_default()));
    }
    assert_eq!(held, words(&main), "the blocks hold main's words, in order");
}

#[test]
fn the_ffi_makes_the_blocks_the_brain_makes() {
    let brain = TestBrain::new();
    let stored = format!(
        "{}Pricing page draft\nStart free, then $18 a seat.",
        header("Pricing page draft")
    );
    let id = brain.seed(&stored, "Pricing page draft");
    let value = brain.reading(id.0);
    let window = Window {
        app: Some(NOTES),
        title: Some("Pricing page draft"),
        url: None,
    };
    let expected = blocks(
        value["main"].as_str().unwrap(),
        &window,
        EventSource::ScreenOcr,
    );
    assert_eq!(value["blocks"], serde_json::to_value(expected).unwrap());
}

#[test]
fn a_moment_with_nothing_to_read_has_no_blocks() {
    let brain = TestBrain::new();
    let id = brain.seed(&header("Untitled"), "Untitled");
    let value = brain.reading(id.0);
    assert_eq!(value["main"], "");
    assert_eq!(value["blocks"], serde_json::json!([]));
}
