//! The window's rows and detail view show a moment's caption and cleaned
//! text: the ones the re-clean job stored when there are some, else the live
//! reading and a caption made from the title. Forgetting a moment in the
//! window takes its stored reading with it. Every moment here is made up.

use std::ffi::{c_char, CStr, CString};
use std::ptr;

use mci_brain::moment_readings::CAPTION_RULES_SINCE;
use mci_brain::reading::Reading;
use mci_brain::{
    BrainStore, Event, EventId, EventSource, MomentReading, SqlCipherBrainStore, READING_VERSION,
};
use mci_brain_ffi::{
    mci_brain_ffi_close, mci_brain_ffi_delete_event, mci_brain_ffi_event_reading,
    mci_brain_ffi_open, mci_brain_ffi_reading, mci_brain_ffi_recent_events, mci_brain_ffi_search,
    mci_brain_ffi_string_free, Handle,
};
use mci_core::crypto::DbKey;
use serde_json::{json, Value};

const CHROME: &str = "com.google.Chrome";
const TAB_STRIP: &str =
    "T N 27 Trailhead - Sched \u{d7} \u{2713} Q4 planning - Goo # launch-plan (Chan\u{2026}";
const PAGE: &str =
    "How to type accents on a Mac\nPress and hold a letter key, then choose an accent.";

fn take_json(raw: *mut c_char) -> Value {
    assert!(!raw.is_null(), "the call returned an error");
    let bytes = unsafe { CStr::from_ptr(raw) }.to_bytes().to_vec();
    unsafe { mci_brain_ffi_string_free(raw) };
    serde_json::from_slice(&bytes).unwrap()
}

struct Brain {
    dir: tempfile::TempDir,
    handle: *mut Handle,
}

impl Brain {
    fn path(&self) -> std::path::PathBuf {
        self.dir.path().join("brain.sqlite")
    }

    fn writer(&self) -> SqlCipherBrainStore {
        SqlCipherBrainStore::new(&self.path(), &DbKey::from_bytes([42; 32])).unwrap()
    }

    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("brain.sqlite");
        drop(SqlCipherBrainStore::new(&path, &DbKey::from_bytes([42; 32])).unwrap());
        let path_c = CString::new(path.to_str().unwrap()).unwrap();
        let key = CString::new("2a".repeat(32)).unwrap();
        let handle = unsafe { mci_brain_ffi_open(path_c.as_ptr(), key.as_ptr()) };
        assert!(!handle.is_null());
        Self { dir, handle }
    }

    fn history(&self) -> Vec<Value> {
        let query = CString::new(
            json!({"text": "", "mode": "text", "browse": true, "limit": 50}).to_string(),
        )
        .unwrap();
        take_json(unsafe { mci_brain_ffi_search(self.handle, query.as_ptr()) })
            .as_array()
            .unwrap()
            .clone()
    }

    fn reading(&self, id: u64) -> Value {
        take_json(unsafe { mci_brain_ffi_event_reading(self.handle, id, ptr::null()) })
    }
}

impl Drop for Brain {
    fn drop(&mut self) {
        unsafe { mci_brain_ffi_close(self.handle) };
    }
}

fn put(store: &SqlCipherBrainStore, ts_us: u64, title: &str, body: &str) -> EventId {
    store
        .put_event_with_source(
            &Event {
                id: EventId(0),
                ts_us,
                app_bundle_id: Some(CHROME.into()),
                window_title: Some(title.into()),
                url: Some("https://support.example/type-accents".into()),
                text: format!(
                    "[app={CHROME} | title={title} | url=https://support.example/type-accents | ts=2026-10-12T09:00:00.000Z]\n{body}"
                ),
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

#[test]
fn before_the_job_a_row_reads_the_page_first_with_a_caption_from_its_title() {
    let brain = Brain::new();
    let id = put(
        &brain.writer(),
        100,
        "How to type accents on a Mac - Apple Support",
        &format!("{TAB_STRIP}\n{PAGE}"),
    );
    let rows = brain.history();
    assert_eq!(rows.len(), 1);
    let snippet = rows[0]["ocr_text_snippet"].as_str().unwrap();
    assert!(
        snippet.starts_with("How to type accents on a Mac"),
        "{snippet}"
    );
    assert!(!snippet.contains("Sched"), "{snippet}");
    assert_eq!(rows[0]["caption"], "Reading how to type accents on a Mac");
    let detail = brain.reading(id.0);
    assert_eq!(detail["main"], PAGE);
    assert_eq!(detail["rest"], TAB_STRIP);
    assert_eq!(detail["caption"], "Reading how to type accents on a Mac");
    // Recent rows carry the same caption.
    let recent = take_json(unsafe { mci_brain_ffi_recent_events(brain.handle, 5) });
    assert_eq!(recent[0]["caption"], "Reading how to type accents on a Mac");
}

#[test]
fn after_the_job_rows_and_the_detail_show_what_it_stored() {
    let brain = Brain::new();
    let writer = brain.writer();
    let id = put(
        &writer,
        100,
        "Accent menu",
        &format!("Today\nPinned\n{PAGE}"),
    );
    let stored = Reading {
        main: PAGE.into(),
        rest: "Today\nPinned".into(),
    };
    let read = writer.stored_moment(id).unwrap().unwrap();
    assert!(writer
        .put_moment_reading(
            &MomentReading {
                event_id: id,
                version: READING_VERSION,
                reading: Some(stored.clone()),
                caption: Some("Looking up how to type accents".into()),
                caption_by: Some("apple-foundation-models".into()),
                model_tried: true,
                updated_us: 200,
            },
            &read
        )
        .unwrap());
    let rows = brain.history();
    assert_eq!(rows[0]["caption"], "Looking up how to type accents");
    assert!(rows[0]["ocr_text_snippet"]
        .as_str()
        .unwrap()
        .starts_with("How to type accents"));
    let detail = brain.reading(id.0);
    assert_eq!(detail["main"], stored.main);
    assert_eq!(detail["rest"], stored.rest);
    assert_eq!(detail["caption"], "Looking up how to type accents");
}

/// A model's line about the accent page that `caption::accept` takes for it
/// as it reads now: grounded in the page, and naming more than its title.
const GROUNDED_LINE: &str = "Reading how to press and hold a letter key";

fn put_older_reading(writer: &SqlCipherBrainStore, id: EventId, version: u32, caption: &str) {
    let read = writer.stored_moment(id).unwrap().unwrap();
    writer
        .put_moment_reading(
            &MomentReading {
                event_id: id,
                version,
                reading: Some(Reading {
                    main: "made by rules this build does not know".into(),
                    rest: String::new(),
                }),
                caption: Some(caption.into()),
                caption_by: Some("apple-foundation-models".into()),
                model_tried: true,
                updated_us: 200,
            },
            &read,
        )
        .unwrap();
}

#[test]
fn text_and_caption_stored_by_other_rules_are_not_shown() {
    // A row made by rules this build does not know or no longer keeps (a
    // newer build's, before a downgrade: its caption rules may not be these;
    // one from before the caption rules last changed; a model line that no
    // longer holds for the moment as it reads now): the live reading and a
    // caption made from the title now, never the two mixed.
    let brain = Brain::new();
    let writer = brain.writer();
    for (n, (version, line)) in [
        (READING_VERSION + 1, GROUNDED_LINE),
        (CAPTION_RULES_SINCE - 1, GROUNDED_LINE),
        (READING_VERSION - 1, "Looking up the accent menu"),
    ]
    .into_iter()
    .enumerate()
    {
        let id = put(&writer, 100 + n as u64, "Accent menu", PAGE);
        put_older_reading(&writer, id, version, line);
        let detail = brain.reading(id.0);
        assert_eq!(detail["main"], PAGE, "the live reading");
        assert_eq!(
            detail["caption"], "Reading \u{201c}Accent menu\u{201d}",
            "version {version}"
        );
        let row = brain
            .history()
            .into_iter()
            .find(|row| row["event_id"] == id.0)
            .unwrap();
        assert_eq!(
            row["caption"], "Reading \u{201c}Accent menu\u{201d}",
            "version {version}"
        );
    }
}

#[test]
fn a_model_caption_kept_through_a_reading_change_shows_at_once_beside_the_live_text() {
    // Only the reading's rules changed since the row was made (the caption
    // rules are the same): the model's line shows while it still holds for
    // the moment as it reads now, before the idle-only re-clean reaches the
    // row. The text is still the live reading.
    let brain = Brain::new();
    let writer = brain.writer();
    for (n, version) in (CAPTION_RULES_SINCE..READING_VERSION).enumerate() {
        let id = put(&writer, 100 + n as u64, "Accent menu", PAGE);
        put_older_reading(&writer, id, version, GROUNDED_LINE);
        let detail = brain.reading(id.0);
        assert_eq!(detail["main"], PAGE, "the live reading, not the stored one");
        assert_eq!(detail["caption"], GROUNDED_LINE, "version {version}");
        let row = brain
            .history()
            .into_iter()
            .find(|row| row["event_id"] == id.0)
            .unwrap();
        assert_eq!(row["caption"], GROUNDED_LINE, "version {version}");
        assert!(row["ocr_text_snippet"]
            .as_str()
            .unwrap()
            .starts_with("How to type accents"));
        let recent = take_json(unsafe { mci_brain_ffi_recent_events(brain.handle, 5) });
        let recent = recent
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["event_id"] == id.0)
            .unwrap()
            .clone();
        assert_eq!(recent["caption"], GROUNDED_LINE, "version {version}");
    }
}

#[test]
fn forgetting_a_moment_in_the_window_takes_its_reading_and_caption() {
    let brain = Brain::new();
    let id = {
        let writer = brain.writer();
        let id = put(&writer, 100, "Accent menu", PAGE);
        let read = writer.stored_moment(id).unwrap().unwrap();
        writer
            .put_moment_reading(
                &MomentReading {
                    event_id: id,
                    version: READING_VERSION,
                    reading: None,
                    caption: Some("Reading Accent menu".into()),
                    caption_by: Some("title".into()),
                    model_tried: false,
                    updated_us: 200,
                },
                &read,
            )
            .unwrap();
        id
    };
    let request = CString::new(format!(r#"{{"event_id":{}}}"#, id.0)).unwrap();
    let result = take_json(unsafe { mci_brain_ffi_delete_event(brain.handle, request.as_ptr()) });
    assert_eq!(result["events_deleted"], 1);
    assert_eq!(brain.writer().moment_reading(id).unwrap(), None);
    assert!(brain.history().is_empty());
}

#[test]
fn a_screenshot_read_again_gets_a_caption_from_its_title() {
    let input = CString::new(
        json!({
            "stored": format!("[app={CHROME} | title=How to type accents on a Mac | url=? | ts=x]\n{TAB_STRIP}\n{PAGE}"),
            "source": "screen_ocr",
            "app": CHROME,
            "title": "How to type accents on a Mac",
        })
        .to_string(),
    )
    .unwrap();
    let value = take_json(unsafe { mci_brain_ffi_reading(input.as_ptr()) });
    assert_eq!(value["main"], PAGE);
    assert_eq!(value["rest"], TAB_STRIP);
    assert_eq!(value["caption"], "Reading how to type accents on a Mac");
}
