//! A History row carries everything the window shows for a moment at once:
//! the screenshot its window kept (its path and when it was taken), what the
//! moment was about (its caption) and what was read, without the window's
//! tab strip. The two arrive from different parts of the store (the moment's
//! screenshot from the events around it, its caption and cleaned text from
//! `moment_readings`), so this reads them together through the C ABI, as the
//! window does, on every path a row comes by. Every moment here is made up.

use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::ptr;

use mci_brain::caption::{self, Moment};
use mci_brain::{
    BrainStore, Event, EventId, EventSource, MomentReading, SqlCipherBrainStore, READING_VERSION,
};
use mci_brain_ffi::{
    mci_brain_ffi_close, mci_brain_ffi_event_reading, mci_brain_ffi_events_by_ids,
    mci_brain_ffi_open, mci_brain_ffi_recent_events, mci_brain_ffi_search,
    mci_brain_ffi_string_free, Handle, HitJson,
};
use mci_core::crypto::DbKey;
use serde_json::{json, Value};

const SECOND: u64 = 1_000_000;
const MINUTE: u64 = 60 * SECOND;
/// A fixed afternoon, so the moments sit in one day.
const T0: u64 = 1_791_838_800_000_000;

const CHROME: &str = "com.google.Chrome";
const SLACK: &str = "com.tinyspeck.slackmacgap";
const ARTICLE: &str = "Rounding half to even \u{00B7} Dev Notes";
const ARTICLE_URL: &str = "https://devnotes.example/rounding";
/// Chrome's tabs as the reader before 0.3 read them: favicons as letters,
/// titles cut short, close marks and a check between them. Made up.
const TAB_STRIP: &str = "D Rounding half to even \u{00B7} Dev No \u{d7} 31 Northwind - Calen \u{d7} \u{2713} Q4 planning - Google Do\u{2026} \u{d7} +";
const ADDRESS_BAR: &str = "< > C devnotes.example/rounding \u{2606}";
const PAGE: &str = "Rounding half to even\nWhy banker\u{2019}s rounding keeps order totals from drifting by a cent";
const MODEL_CAPTION: &str = "Reading about rounding half to even";

fn digest(n: u8) -> String {
    format!("{n:02x}").repeat(32)
}

struct Brain {
    dir: tempfile::TempDir,
    handle: *mut Handle,
}

impl Brain {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        drop(
            SqlCipherBrainStore::new(&dir.path().join("mci.sqlite"), &DbKey::from_bytes([42; 32]))
                .unwrap(),
        );
        let path = CString::new(dir.path().join("mci.sqlite").to_str().unwrap()).unwrap();
        let key = CString::new("2a".repeat(32)).unwrap();
        let handle = unsafe { mci_brain_ffi_open(path.as_ptr(), key.as_ptr()) };
        assert!(!handle.is_null());
        Self { dir, handle }
    }

    fn writer(&self) -> SqlCipherBrainStore {
        SqlCipherBrainStore::new(
            &self.dir.path().join("mci.sqlite"),
            &DbKey::from_bytes([42; 32]),
        )
        .unwrap()
    }

    fn blob(&self, n: u8) -> String {
        PathBuf::from(self.dir.path())
            .join("blobs")
            .join(format!("{}.bin", digest(n)))
            .to_string_lossy()
            .into_owned()
    }

    /// History's own read: one day, newest first.
    fn history(&self) -> HashMap<u64, HitJson> {
        let query = CString::new(
            json!({
                "text": "", "mode": "text", "browse": true, "limit": 50,
                "time_from_us": T0 - 60 * MINUTE, "time_to_us": T0 + 60 * MINUTE,
            })
            .to_string(),
        )
        .unwrap();
        by_id(read(unsafe {
            mci_brain_ffi_search(self.handle, query.as_ptr())
        }))
    }

    fn recent(&self) -> HashMap<u64, HitJson> {
        by_id(read(unsafe {
            mci_brain_ffi_recent_events(self.handle, 50)
        }))
    }

    fn by_ids(&self, ids: &[u64]) -> HashMap<u64, HitJson> {
        let query = CString::new(json!({ "ids": ids }).to_string()).unwrap();
        by_id(read(unsafe {
            mci_brain_ffi_events_by_ids(self.handle, query.as_ptr())
        }))
    }

    fn detail(&self, id: u64) -> Value {
        let raw = unsafe { mci_brain_ffi_event_reading(self.handle, id, ptr::null()) };
        assert!(!raw.is_null());
        let value = serde_json::from_slice(unsafe { CStr::from_ptr(raw) }.to_bytes()).unwrap();
        unsafe { mci_brain_ffi_string_free(raw) };
        value
    }
}

impl Drop for Brain {
    fn drop(&mut self) {
        unsafe { mci_brain_ffi_close(self.handle) };
    }
}

fn read(raw: *mut c_char) -> Vec<HitJson> {
    assert!(!raw.is_null());
    let hits = serde_json::from_slice(unsafe { CStr::from_ptr(raw) }.to_bytes()).unwrap();
    unsafe { mci_brain_ffi_string_free(raw) };
    hits
}

fn by_id(hits: Vec<HitJson>) -> HashMap<u64, HitJson> {
    hits.into_iter().map(|hit| (hit.event_id, hit)).collect()
}

#[allow(clippy::too_many_arguments)]
fn put(
    store: &SqlCipherBrainStore,
    ts_us: u64,
    app: &str,
    title: &str,
    url: Option<&str>,
    body: &str,
    source: EventSource,
    keyframe: Option<u8>,
) -> u64 {
    store
        .put_event_with_source(
            &Event {
                id: EventId(0),
                ts_us,
                app_bundle_id: Some(app.into()),
                window_title: Some(title.into()),
                url: url.map(Into::into),
                text: format!(
                    "[app={app} | title={title} | url={} | ts=2026-10-12T14:00:00.000Z]\n{body}",
                    url.unwrap_or("?")
                ),
                summary: None,
                entities: None,
                episode_id: None,
                cascade_reason: 0,
                keyframe_blob: keyframe.map(digest),
                tab_id: None,
                embedding: None,
            },
            source,
        )
        .unwrap()
        .0
}

/// An article in front: it kept its screenshot when it came to the front,
/// was read again six seconds later without one, and the re-clean job gave
/// the later moment a caption the on-device model wrote. Slack beside it
/// is text only.
struct Afternoon {
    brain: Brain,
    kept: u64,
    later: u64,
    beside: u64,
}

fn afternoon() -> Afternoon {
    let brain = Brain::new();
    let writer = brain.writer();
    let body = format!("{TAB_STRIP}\n{ADDRESS_BAR}\n{PAGE}");
    let kept = put(
        &writer,
        T0,
        CHROME,
        ARTICLE,
        Some(ARTICLE_URL),
        &body,
        EventSource::ScreenOcr,
        Some(7),
    );
    let later = put(
        &writer,
        T0 + 6 * SECOND,
        CHROME,
        ARTICLE,
        Some(ARTICLE_URL),
        &body,
        EventSource::ScreenOcr,
        None,
    );
    let beside = put(
        &writer,
        T0 + 8 * SECOND,
        SLACK,
        "launch (Channel) - Northwind Studio - Slack",
        None,
        "Jordan Lee 2:14 PM\nstaging is green, shipping the rounding fix at 4\nMessage #launch",
        EventSource::ScreenContext,
        None,
    );
    let read = writer.stored_moment(EventId(later)).unwrap().unwrap();
    assert!(writer
        .put_moment_reading(
            &MomentReading {
                event_id: EventId(later),
                version: READING_VERSION,
                reading: None,
                caption: Some(MODEL_CAPTION.into()),
                caption_by: Some("apple-foundation-models".into()),
                model_tried: true,
                updated_us: T0 + MINUTE,
            },
            &read
        )
        .unwrap());
    Afternoon {
        brain,
        kept,
        later,
        beside,
    }
}

fn title_caption(app: &str, title: &str, url: Option<&str>) -> Option<String> {
    caption::fallback(&Moment {
        app: Some(app),
        title: Some(title),
        url,
        text: "",
        beside: false,
    })
}

/// The page leads, and no part of the tab strip or the address bar is left.
fn assert_reads_the_page(hit: &HitJson) {
    assert!(
        hit.ocr_text_snippet
            .starts_with("Rounding half to even\nWhy banker"),
        "{:?}",
        hit.ocr_text_snippet
    );
    for chrome in [
        "Calen",
        "\u{d7}",
        "\u{2713}",
        "devnotes.example/rounding",
        "Launch plan",
    ] {
        assert!(
            !hit.ocr_text_snippet.contains(chrome),
            "{chrome:?} in {:?}",
            hit.ocr_text_snippet
        );
    }
}

#[test]
fn a_history_row_carries_its_windows_screenshot_its_caption_and_clean_text() {
    let day = afternoon();
    let rows = day.brain.history();

    let later = &rows[&day.later];
    assert_eq!(
        later.thumbnail_path.as_deref(),
        Some(day.brain.blob(7).as_str())
    );
    assert_eq!(
        later.thumbnail_ts_us,
        Some(T0),
        "taken when the window came to the front"
    );
    assert_eq!(later.caption.as_deref(), Some(MODEL_CAPTION));
    assert_reads_the_page(later);

    let kept = &rows[&day.kept];
    assert_eq!(
        kept.thumbnail_path.as_deref(),
        Some(day.brain.blob(7).as_str())
    );
    assert_eq!(kept.thumbnail_ts_us, Some(T0));
    assert_eq!(
        kept.caption,
        title_caption(CHROME, ARTICLE, Some(ARTICLE_URL))
    );
    assert!(kept.caption.is_some());
    assert_reads_the_page(kept);

    let beside = &rows[&day.beside];
    assert_eq!(
        beside.thumbnail_path, None,
        "a window beside the front one is text only"
    );
    assert_eq!(beside.thumbnail_ts_us, None);
    // Where it was open, never what was done in it.
    assert_eq!(beside.caption.as_deref(), Some("#launch, open in Slack"));
    assert!(
        !beside.ocr_text_snippet.contains("Message #launch"),
        "{:?}",
        beside.ocr_text_snippet
    );
}

#[test]
fn every_way_a_row_arrives_carries_the_same_screenshot_and_meaning() {
    let day = afternoon();
    let from_history = day.brain.history();
    for rows in [
        day.brain.recent(),
        day.brain.by_ids(&[day.later, day.kept, day.beside]),
    ] {
        for id in [day.later, day.kept, day.beside] {
            let (row, want) = (&rows[&id], &from_history[&id]);
            assert_eq!(row.thumbnail_path, want.thumbnail_path, "{id}");
            assert_eq!(row.thumbnail_ts_us, want.thumbnail_ts_us, "{id}");
            assert_eq!(row.caption, want.caption, "{id}");
            assert_eq!(row.ocr_text_snippet, want.ocr_text_snippet, "{id}");
        }
    }
}

#[test]
fn the_moment_opens_with_its_caption_and_the_page_with_the_tabs_set_apart() {
    let day = afternoon();
    let detail = day.brain.detail(day.later);
    assert_eq!(detail["caption"], MODEL_CAPTION);
    assert_eq!(detail["main"], PAGE);
    let rest = detail["rest"].as_str().unwrap();
    assert!(rest.contains(TAB_STRIP), "{rest}");
    assert!(rest.contains(ADDRESS_BAR), "{rest}");
}
