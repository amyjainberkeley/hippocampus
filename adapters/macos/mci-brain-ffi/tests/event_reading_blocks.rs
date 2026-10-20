//! The FFI's reading of a moment carries its text as blocks too
//! (`blocks`, SPEC 4.2), additive beside `main`: what the formatted reading
//! view draws. Every block holds only text that was read, and a moment with
//! nothing to read has no blocks.

use std::ffi::{c_char, CStr, CString};
use std::ptr;

use mci_brain::reading_blocks::{blocks, plain_text, Block, Window, MAX_STRUCTURE_BYTES};
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
    for block in made {
        assert!(block["kind"].is_string(), "each block names its kind");
    }
    let made: Vec<Block> = serde_json::from_value(value["blocks"].clone()).unwrap();
    assert_eq!(
        words(&plain_text(&made)),
        words(&main),
        "the blocks hold main's words, in order"
    );
}

#[test]
fn an_older_article_arrives_formatted() {
    let brain = TestBrain::new();
    let title = "Rounding half to even";
    let stored = format!(
        "{}MONEY & ROUNDING\nRounding half to even\nPriya Raman \u{b7} Oct 12, 2026 \u{b7} 6 min read\nRound half to even sends each tie to the even neighbour instead, so half the\nties go down and\nhalf go up. The errors cancel out:\nround_half_even(2.5)   // 2.0\nround_half_even(3.5)   // 4.0",
        header(title)
    );
    let id = brain.seed(&stored, title);
    let value = brain.reading(id.0);
    let made: Vec<Block> = serde_json::from_value(value["blocks"].clone()).unwrap();
    assert_eq!(
        made,
        [
            Block::Label {
                text: "MONEY & ROUNDING".into()
            },
            Block::Heading {
                level: 1,
                text: "Rounding half to even".into()
            },
            Block::Byline {
                text: "Priya Raman \u{b7} Oct 12, 2026 \u{b7} 6 min read".into()
            },
            Block::Paragraph {
                text: "Round half to even sends each tie to the even neighbour instead, so half the ties go down and half go up. The errors cancel out:".into()
            },
            Block::Code {
                text: "round_half_even(2.5)   // 2.0\nround_half_even(3.5)   // 4.0".into()
            },
        ]
    );
}

#[test]
fn the_reading_with_its_blocks_stays_within_the_windows_bound() {
    // A window of many short list items: the most structure a reading's
    // blocks can add (EventReading.maxJSONBytes in ReadableText.swift).
    let brain = TestBrain::new();
    let mut body = String::new();
    while body.len() < 120 * 1024 {
        body.push_str("\u{2022} a\n");
    }
    let id = brain.seed(&format!("{}{body}", header("Items")), "Items");
    let raw = unsafe { mci_brain_ffi_event_reading(brain.handle, id.0, ptr::null()) };
    assert!(!raw.is_null());
    let bytes = unsafe { CStr::from_ptr(raw) }.to_bytes().len();
    unsafe { mci_brain_ffi_string_free(raw) };
    let text_cap = (128 * 1024 + 1024) * 6;
    assert!(
        bytes <= text_cap * 2 + MAX_STRUCTURE_BYTES + 512 + 2048,
        "{bytes} bytes"
    );
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
