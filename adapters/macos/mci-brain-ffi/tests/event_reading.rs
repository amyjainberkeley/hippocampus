//! The FFI hands the window readable text: a reading for the detail view,
//! readable list rows, and the raw stored text only through the audit path.

use std::ffi::{c_char, CStr, CString};
use std::ptr;

use mci_brain::{BrainStore, Event, EventId, EventSource, SqlCipherBrainStore};
use mci_brain_ffi::{
    mci_brain_ffi_close, mci_brain_ffi_event_reading, mci_brain_ffi_event_text,
    mci_brain_ffi_events_by_ids, mci_brain_ffi_open, mci_brain_ffi_reading,
    mci_brain_ffi_recent_events, mci_brain_ffi_search, mci_brain_ffi_string_free,
    mci_brain_ffi_timeline_events, Handle,
};
use mci_core::crypto::DbKey;
use serde_json::{json, Value};

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

    fn seed(&self, text: &str, ts_us: u64, app: &str, source: EventSource) -> EventId {
        self.store
            .put_event_with_source(
                &Event {
                    id: EventId(0),
                    ts_us,
                    app_bundle_id: Some(app.into()),
                    window_title: Some("Launch plan".into()),
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
                source,
            )
            .unwrap()
    }

    fn reading(&self, id: u64, query: Option<&str>) -> Value {
        let query = query.map(|q| CString::new(q).unwrap());
        let raw = unsafe {
            mci_brain_ffi_event_reading(
                self.handle,
                id,
                query.as_ref().map_or(ptr::null(), |q| q.as_ptr()),
            )
        };
        take_json(raw)
    }

    fn call(
        &self,
        f: unsafe extern "C" fn(*mut Handle, *const c_char) -> *mut c_char,
        arg: &Value,
    ) -> Value {
        let arg = CString::new(arg.to_string()).unwrap();
        take_json(unsafe { f(self.handle, arg.as_ptr()) })
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

fn header(app: &str) -> String {
    format!("[app={app} | title=Launch plan | url=? | ts=2026-10-12T14:02:00.000Z]\n")
}

/// A classified Notes window: content, the separator, then chrome.
fn classified_notes() -> String {
    format!(
        "{}\u{4e09} Launch plan\nThe beta opens on October 21. Everything below has to be true by then, and nothing else is in\nscope.\n\n\u{1e}\n\u{53e3} Search\nRoadmap\nRecently Deleted 3",
        header(NOTES)
    )
}

#[test]
fn the_detail_view_reads_main_then_rest_and_the_audit_path_stays_raw() {
    let brain = TestBrain::new();
    let stored = classified_notes();
    let id = brain.seed(&stored, 100, NOTES, EventSource::ScreenOcr);

    let value = brain.reading(id.0, None);
    assert_eq!(value["event_id"], id.0);
    assert_eq!(value["ts_us"], 100);
    assert_eq!(value["app_bundle_id"], NOTES);
    assert_eq!(value["source_kind"], "screen_ocr");
    assert_eq!(
        value["main"],
        "Launch plan\nThe beta opens on October 21. Everything below has to be true by then, and nothing else is in scope."
    );
    assert_eq!(value["rest"], "Search\nRoadmap\nRecently Deleted 3");
    assert_eq!(value["match_in"], Value::Null);
    assert_eq!(value["truncated"], false);

    let raw = take_json(unsafe { mci_brain_ffi_event_text(brain.handle, id.0) });
    assert_eq!(
        raw["text"], stored,
        "the raw path returns exactly what is stored"
    );
}

#[test]
fn match_in_says_where_a_searchs_words_are() {
    let brain = TestBrain::new();
    let id = brain.seed(&classified_notes(), 100, NOTES, EventSource::ScreenOcr);
    assert_eq!(brain.reading(id.0, Some("beta"))["match_in"], "main");
    assert_eq!(brain.reading(id.0, Some("roadmap"))["match_in"], "rest");
    assert_eq!(
        brain.reading(id.0, Some("quantum"))["match_in"],
        Value::Null
    );
    assert_eq!(brain.reading(id.0, Some(""))["match_in"], Value::Null);
}

#[test]
fn a_missing_event_reads_as_null() {
    let brain = TestBrain::new();
    assert_eq!(brain.reading(999, None), Value::Null);
    assert!(unsafe { mci_brain_ffi_event_reading(ptr::null_mut(), 1, ptr::null()) }.is_null());
}

#[test]
fn a_browser_page_read_both_ways_shows_the_page_first() {
    let brain = TestBrain::new();
    let stored = format!(
        "{}Pricing guide\nPer-seat pricing grows with the customer.\n\n[VISIBLE-OCR]\nPer-seat pricing\n\n\u{1e}\nStripe Docs",
        header("com.google.Chrome")
    );
    let id = brain.seed(
        &stored,
        100,
        "com.google.Chrome",
        EventSource::BrowserPageWithOcr,
    );
    let value = brain.reading(id.0, None);
    assert_eq!(
        value["main"],
        "Pricing guide\nPer-seat pricing grows with the customer."
    );
    assert_eq!(value["rest"], "Per-seat pricing\n\nStripe Docs");
    assert_eq!(value["source_kind"], "browser_page_with_ocr");
}

#[test]
fn text_never_stored_reads_by_the_same_rules() {
    let input = CString::new(
        json!({"stored": classified_notes(), "source": "screen_ocr", "app": NOTES, "title": null})
            .to_string(),
    )
    .unwrap();
    let value = take_json(unsafe { mci_brain_ffi_reading(input.as_ptr()) });
    let expected = mci_brain::reading::reading(
        &classified_notes(),
        EventSource::ScreenOcr,
        Some(NOTES),
        None,
    );
    assert_eq!(value, json!({"main": expected.main, "rest": expected.rest}));

    let plain = CString::new(json!({"stored": "Re-read text \u{25cf}"}).to_string()).unwrap();
    assert_eq!(
        take_json(unsafe { mci_brain_ffi_reading(plain.as_ptr()) }),
        json!({"main": "Re-read text \u{25cf}", "rest": ""}),
        "with no source the text is shown as given"
    );
    let bad = CString::new("not json").unwrap();
    assert!(unsafe { mci_brain_ffi_reading(bad.as_ptr()) }.is_null());
    assert!(unsafe { mci_brain_ffi_reading(ptr::null()) }.is_null());
}

/// Every string in a JSON value.
fn strings(value: &Value, out: &mut Vec<String>) {
    match value {
        Value::String(text) => out.push(text.clone()),
        Value::Array(items) => items.iter().for_each(|item| strings(item, out)),
        Value::Object(map) => map.values().for_each(|item| strings(item, out)),
        _ => {}
    }
}

#[test]
fn no_text_the_window_reads_holds_the_separator_or_a_header() {
    let brain = TestBrain::new();
    let revision = format!("[MCP_RESOURCE revision_sha256={}]\n", "ab".repeat(32));
    let ids = [
        brain.seed(&classified_notes(), 100, NOTES, EventSource::ScreenOcr),
        brain.seed(
            &format!("{}Background window launch\n\n\u{1e}\nTabs", header(NOTES)),
            101,
            NOTES,
            EventSource::ScreenContext,
        ),
        brain.seed(
            "[app=claude-code | title=demo · user | url=/x/demo#main | session=s1 | src=/t.jsonl:2]\nlaunch the beta",
            102,
            "com.anthropic.claude-code",
            EventSource::TranscriptImport,
        ),
        brain.seed(
            &format!("{revision}[app=mcp:docs | title=Spec | url=docs://1 | ts=1]\nlaunch spec"),
            103,
            "mcp:docs",
            EventSource::McpResource,
        ),
        brain.seed(
            &format!("{}Launch page{}\n\n[VISIBLE-OCR]\nLaunch\n\n\u{1e}\nTabs", header("com.google.Chrome"), "\u{1e}"),
            104,
            "com.google.Chrome",
            EventSource::BrowserPageWithOcr,
        ),
        brain.seed(&format!("{}launch notes\u{1e}", header(NOTES)), 105, NOTES, EventSource::Unknown),
    ];
    let mut seen = Vec::new();
    for query in ["launch", "tabs", "beta"] {
        strings(
            &brain.call(
                mci_brain_ffi_search,
                &json!({"text": query, "mode": "text", "limit": 20}),
            ),
            &mut seen,
        );
    }
    strings(
        &brain.call(
            mci_brain_ffi_search,
            &json!({"text": "", "browse": true, "limit": 20}),
        ),
        &mut seen,
    );
    strings(
        &take_json(unsafe { mci_brain_ffi_recent_events(brain.handle, 20) }),
        &mut seen,
    );
    strings(
        &brain.call(
            mci_brain_ffi_events_by_ids,
            &json!({"ids": ids.iter().map(|id| id.0).collect::<Vec<_>>()}),
        ),
        &mut seen,
    );
    strings(
        &brain.call(
            mci_brain_ffi_timeline_events,
            &json!({"start_ts_us": 0, "end_ts_us": 1_000}),
        ),
        &mut seen,
    );
    for id in ids {
        strings(&brain.reading(id.0, Some("launch")), &mut seen);
    }
    assert!(seen.len() > 30);
    for text in seen {
        assert!(!text.contains('\u{1e}'), "{text:?}");
        assert!(!text.contains("[app="), "{text:?}");
    }
}

#[test]
fn list_rows_show_the_reading_not_the_stored_text() {
    let brain = TestBrain::new();
    let id = brain.seed(&classified_notes(), 100, NOTES, EventSource::ScreenOcr);
    let recent = take_json(unsafe { mci_brain_ffi_recent_events(brain.handle, 10) });
    let row = &recent[0];
    assert_eq!(row["event_id"], id.0);
    let snippet = row["ocr_text_snippet"].as_str().unwrap();
    assert!(
        snippet.starts_with("Launch plan\nThe beta opens on October 21."),
        "{snippet:?}"
    );
    assert!(
        !snippet.contains("Roadmap"),
        "chrome stays out of list rows"
    );
    let main = brain.reading(id.0, None)["main"]
        .as_str()
        .unwrap()
        .to_owned();
    let timeline = brain.call(
        mci_brain_ffi_timeline_events,
        &json!({"start_ts_us": 0, "end_ts_us": 1_000}),
    );
    assert_eq!(
        timeline[0]["snippet"],
        main.chars().take(80).collect::<String>()
    );
}
