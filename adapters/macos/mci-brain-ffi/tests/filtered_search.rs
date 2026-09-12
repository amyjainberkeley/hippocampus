use std::ffi::{CStr, CString};

use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore};
use mci_brain_ffi::{
    mci_brain_ffi_close, mci_brain_ffi_last_error_message, mci_brain_ffi_open,
    mci_brain_ffi_search, mci_brain_ffi_string_free, Handle, HitJson,
};
use mci_core::crypto::DbKey;
use serde_json::{json, Value};

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
        let path = CString::new(path.to_str().unwrap()).unwrap();
        let key = CString::new("2a".repeat(32)).unwrap();
        let handle = unsafe { mci_brain_ffi_open(path.as_ptr(), key.as_ptr()) };
        assert!(!handle.is_null());
        Self {
            handle,
            store,
            _dir: dir,
        }
    }

    fn seed(&self, text: &str, ts_us: u64, app: &str, url: Option<&str>) -> u64 {
        self.store
            .put_event(&Event {
                id: EventId(0),
                ts_us,
                app_bundle_id: Some(app.into()),
                window_title: None,
                url: url.map(str::to_owned),
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
            .0
    }

    fn search(&self, query: &Value) -> Result<Vec<HitJson>, String> {
        let query = CString::new(query.to_string()).unwrap();
        let result = unsafe { mci_brain_ffi_search(self.handle, query.as_ptr()) };
        if result.is_null() {
            let error = unsafe { mci_brain_ffi_last_error_message() };
            assert!(!error.is_null());
            return Err(unsafe { CStr::from_ptr(error) }
                .to_string_lossy()
                .into_owned());
        }
        let json = unsafe { CStr::from_ptr(result) }.to_bytes().to_owned();
        unsafe { mci_brain_ffi_string_free(result) };
        Ok(serde_json::from_slice(&json).unwrap())
    }
}

impl Drop for TestBrain {
    fn drop(&mut self) {
        unsafe { mci_brain_ffi_close(self.handle) };
    }
}

fn ids(hits: &[HitJson]) -> Vec<u64> {
    hits.iter().map(|hit| hit.event_id).collect()
}

#[test]
fn browse_filters_before_limit_beyond_recent_500_and_orders_ties() {
    let brain = TestBrain::new();
    let first = brain.seed("old", 100, "test.a", Some("https://example.test"));
    let second = brain.seed("old", 200, "test.b", Some("https://example.test"));
    let third = brain.seed("old", 200, "test.a", Some("https://example.test"));
    for i in 0..501 {
        let (app, url, ts) = match i % 4 {
            0 => ("test.other", Some("https://example.test"), 200),
            1 => ("test.a", None, 200),
            2 => ("test.b", Some(""), 200),
            _ => ("test.a", Some("https://example.test"), 201),
        };
        brain.seed("distractor", ts, app, url);
    }
    assert!(brain
        .store
        .recent_events(500)
        .unwrap()
        .iter()
        .all(|event| ![first, second, third].contains(&event.id.0)));
    let mut query = json!({"text":"", "browse":true, "limit":2,
        "app_filters":["test.a","test.b"], "has_url":true,
        "time_from_us":100, "time_to_us":200});
    let hits = brain.search(&query).unwrap();
    assert_eq!(ids(&hits), vec![third, second]);
    assert!(hits
        .iter()
        .all(|hit| hit.source == "recent" && hit.score.is_none()));
    query["limit"] = json!(3);
    assert_eq!(
        ids(&brain.search(&query).unwrap()),
        vec![third, second, first]
    );
    query["app_filter"] = json!("test.b");
    assert_eq!(ids(&brain.search(&query).unwrap()), vec![second]);
    query["time_from_us"] = json!(201);
    assert!(brain.search(&query).unwrap().is_empty());
    query["time_from_us"] = json!(u64::MAX);
    query["time_to_us"] = json!(u64::MAX);
    assert!(brain.search(&query).unwrap().is_empty());
}

#[test]
fn text_filters_before_ranked_50_for_plain_and_alias_queries() {
    let brain = TestBrain::new();
    for _ in 0..51 {
        for (app, url, ts) in [
            ("test.other", Some("https://example.test"), 150),
            ("test.a", None, 150),
            ("test.b", Some(""), 150),
            ("test.a", Some("https://example.test"), 201),
        ] {
            brain.seed("Alpha Project", ts, app, url);
        }
    }
    let first = brain.seed("Alpha Project", 100, "test.a", Some("https://example.test"));
    let second = brain.seed("Alpha Project", 200, "test.b", Some("https://example.test"));
    for (text, aliases) in [
        ("Alpha Project", json!({})),
        ("AP", json!({"Alpha Project":["AP"]})),
    ] {
        let mut query = json!({"text":text, "mode":"text", "limit":2,
            "user_aliases":aliases, "app_filters":["test.a","test.b","test.a"],
            "has_url":true, "time_from_us":100, "time_to_us":200});
        let hits = brain.search(&query).unwrap();
        assert_eq!(ids(&hits), vec![first, second]);
        assert!(hits
            .iter()
            .all(|hit| hit.source == "lexical" && hit.score.is_some()));
        query["app_filter"] = json!("test.b");
        assert_eq!(ids(&brain.search(&query).unwrap()), vec![second]);
        query["time_from_us"] = json!(200);
        assert_eq!(ids(&brain.search(&query).unwrap()), vec![second]);
    }
}

#[test]
fn explicit_browse_preserves_legacy_empty_text_and_rejects_nonempty_text() {
    let brain = TestBrain::new();
    let id = brain.seed("needle", 10, "test.a", None);
    assert!(brain
        .search(&json!({"text":"", "limit":50}))
        .unwrap()
        .is_empty());
    assert_eq!(
        ids(&brain
            .search(&json!({"text":"", "browse":true, "limit":50}))
            .unwrap()),
        vec![id]
    );
    assert!(brain
        .search(&json!({"text":"needle", "browse":true, "limit":50}))
        .is_err());
    assert_eq!(
        ids(&brain.search(&json!({"text":"needle", "limit":50})).unwrap()),
        vec![id]
    );
}

#[test]
fn new_app_id_list_is_bounded_and_validated_without_widening() {
    let brain = TestBrain::new();
    brain.seed("needle", 10, "test.a", None);
    for apps in [
        json!([""]),
        json!(["test.\u{0}a"]),
        json!(["test.\ta"]),
        json!(["test.\na"]),
        json!(["test.\u{7f}a"]),
        json!(["test.\u{85}a"]),
        json!(["a".repeat(256)]),
        json!(["\u{e9}".repeat(128)]),
        json!(vec!["test.a"; 33]),
    ] {
        let query = json!({"text":"needle", "mode":"text", "limit":1, "app_filters":apps});
        assert!(brain.search(&query).is_err(), "accepted {query}");
    }
    for apps in [json!([]), json!(["test.a"]), json!(vec!["test.a"; 32])] {
        assert_eq!(
            brain
                .search(&json!({"text":"needle", "mode":"text", "limit":1,
            "app_filters":apps}))
                .unwrap()
                .len(),
            1
        );
    }
}

#[test]
fn source_ids_match_mcp_unicode_and_sql_looking_values_exactly() {
    let brain = TestBrain::new();
    let source_ids = [
        "mcp:slack-personal".to_owned(),
        "mcp:\u{65e5}\u{672c}_notes".to_owned(),
        "mcp:caf\u{e9}".to_owned(),
        "mcp:cafe\u{301}".to_owned(),
        "mcp:O'Brien".to_owned(),
        "mcp:x') OR 1=1 --".to_owned(),
        "mcp:x'); DROP TABLE events; --".to_owned(),
        format!("{}x", "\u{e9}".repeat(127)),
    ];
    let expected: Vec<_> = source_ids
        .iter()
        .map(|source| brain.seed("needle", 100, source, Some("https://example.test")))
        .collect();
    brain.seed("needle", 100, "mcp:slack-personal.other", None);
    for (source, id) in source_ids.iter().zip(&expected) {
        for mut query in [
            json!({"text":"", "browse":true, "limit":50}),
            json!({"text":"needle", "mode":"text", "limit":50}),
            json!({"text":"alias", "mode":"text", "limit":50,
                "user_aliases":{"needle":["alias"]}}),
        ] {
            query["app_filters"] = json!([source]);
            assert_eq!(ids(&brain.search(&query).unwrap()), vec![*id], "{source}");
        }
    }
    // A bound source value cannot execute SQL, widen results, or normalize identity.
    assert_eq!(
        brain
            .search(&json!({"text":"needle", "mode":"text", "limit":50}))
            .unwrap()
            .len(),
        expected.len() + 1
    );
}

#[test]
fn related_rejects_unsupported_filters_without_changing_engine_meaning() {
    let brain = TestBrain::new();
    let id = brain.seed("needle", 10, "test.a", Some("https://example.test"));
    for extra in [
        json!({"app_filters":["test.a","test.b"]}),
        json!({"has_url":true}),
    ] {
        let mut query = json!({"text":"needle", "mode":"related", "limit":50});
        query
            .as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        let error = brain
            .search(&query)
            .expect_err("unsupported Related filters must fail");
        assert!(error.contains("Related"));
    }
    assert_eq!(
        ids(&brain
            .search(&json!({"text":"needle", "mode":"related", "limit":50,
        "app_filters":["test.a"]}))
            .unwrap()),
        vec![id]
    );
    assert!(brain
        .search(&json!({"text":"needle", "mode":"related", "limit":50,
        "app_filter":"test.b", "app_filters":["test.a"]}))
        .unwrap()
        .is_empty());
}
