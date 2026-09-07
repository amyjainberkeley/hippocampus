use std::ffi::{CStr, CString};

use mci_brain::fts_sanitizer::MAX_LEXICAL_ALTERNATIVE_BYTES;
use mci_brain::{BrainStore, Event, EventId, EventSource, SqlCipherBrainStore};
use mci_brain_ffi::{
    mci_brain_ffi_close, mci_brain_ffi_delete_event, mci_brain_ffi_last_error_message,
    mci_brain_ffi_open, mci_brain_ffi_search, mci_brain_ffi_string_free, Handle, HitJson,
    USER_ALIAS_GROUP_CAP, USER_ALIAS_PER_GROUP_CAP,
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
        assert!(!handle.is_null(), "{}", last_error());
        Self {
            handle,
            store,
            _dir: dir,
        }
    }

    fn seed(&self, text: &str, ts_us: u64, app: Option<&str>, source: EventSource) -> EventId {
        self.store
            .put_event_with_source(&event(text, ts_us, app), source)
            .unwrap()
    }

    fn search(&self, query: &Value) -> Vec<HitJson> {
        let query = CString::new(query.to_string()).unwrap();
        let result = unsafe { mci_brain_ffi_search(self.handle, query.as_ptr()) };
        assert!(!result.is_null(), "{}", last_error());
        let json = unsafe { CStr::from_ptr(result) }.to_bytes().to_owned();
        unsafe { mci_brain_ffi_string_free(result) };
        serde_json::from_slice(&json).unwrap()
    }
}

impl Drop for TestBrain {
    fn drop(&mut self) {
        unsafe { mci_brain_ffi_close(self.handle) };
    }
}

fn event(text: &str, ts_us: u64, app: Option<&str>) -> Event {
    Event {
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
    }
}

fn last_error() -> String {
    let error = unsafe { mci_brain_ffi_last_error_message() };
    if error.is_null() {
        return "no diagnostic".into();
    }
    unsafe { CStr::from_ptr(error) }
        .to_string_lossy()
        .into_owned()
}

fn ids(hits: &[HitJson]) -> Vec<u64> {
    let mut ids: Vec<_> = hits.iter().map(|hit| hit.event_id).collect();
    ids.sort_unstable();
    ids
}

#[test]
fn aliases_reach_sqlite_as_exact_phrases_and_preserve_source() {
    let brain = TestBrain::new();
    let canonical = brain.seed(
        "Review Amy Jain budget.",
        100,
        None,
        EventSource::TranscriptImport,
    );
    let short = brain.seed("AJ notes.", 101, None, EventSource::ScreenOcr);
    let sibling = brain.seed("A Jay check.", 102, None, EventSource::Unknown);
    brain.seed("Review Amy budget Jain.", 103, None, EventSource::ScreenOcr);
    brain.seed("Review Jain Amy budget.", 104, None, EventSource::ScreenOcr);
    brain.seed("A careful Jay check.", 105, None, EventSource::ScreenOcr);

    let hits = brain.search(&json!({
        "text": "aj email", "limit": 20,
        "user_aliases": {"Amy Jain": ["AJ", "A Jay"]},
    }));
    assert_eq!(ids(&hits), vec![canonical.0, short.0, sibling.0]);
    assert!(hits
        .iter()
        .all(|hit| hit.source == "lexical" && hit.score.is_some()));
    let imported = hits.iter().find(|hit| hit.event_id == canonical.0).unwrap();
    assert_eq!(imported.source_kind, "transcript_import");
    assert_eq!(imported.ocr_text_snippet, "Review Amy Jain budget.");
}

#[test]
fn operators_in_original_canonical_and_alias_text_are_literal() {
    let brain = TestBrain::new();
    let canonical_text = r#"Alpha" OR "Secret"#;
    let alias_text = "NEAR(needle, 10)";
    let canonical = brain.seed(canonical_text, 100, None, EventSource::ScreenOcr);
    let alias = brain.seed(alias_text, 101, None, EventSource::ScreenOcr);
    let original = brain.seed("tag OR leak", 102, None, EventSource::ScreenOcr);
    for text in [
        "Secret",
        "Alpha",
        "needle",
        "leak",
        "Alpha Secret",
        "needle 10",
    ] {
        brain.seed(text, 103, None, EventSource::ScreenOcr);
    }
    let hits = brain.search(&json!({
        "text": "tag OR leak", "limit": 20,
        "user_aliases": {canonical_text: ["tag", alias_text]},
    }));
    assert_eq!(ids(&hits), vec![canonical.0, alias.0, original.0]);
}

#[test]
fn alias_hits_obey_inclusive_time_bounds_and_exact_app_filter() {
    let brain = TestBrain::new();
    let mut expected = Vec::new();
    for ts in [99, 100, 200, 300, 301] {
        let id = brain.seed("Amy Jain", ts, Some("test.allowed"), EventSource::ScreenOcr);
        if (100..=300).contains(&ts) {
            expected.push(id.0);
        }
    }
    brain.seed(
        "Amy Jain",
        200,
        Some("test.allowed.other"),
        EventSource::ScreenOcr,
    );
    brain.seed("Amy Jain", 200, None, EventSource::ScreenOcr);
    let mut query = json!({
        "text": "AJ", "limit": 20, "user_aliases": {"Amy Jain": ["AJ"]},
        "time_from_us": 100, "time_to_us": 300, "app_filter": "test.allowed",
    });
    assert_eq!(ids(&brain.search(&query)), expected);
    query["time_from_us"] = json!(200);
    query["time_to_us"] = json!(200);
    assert_eq!(ids(&brain.search(&query)), vec![expected[1]]);
    query["time_to_us"] = json!(199);
    assert!(brain.search(&query).is_empty());
}

#[test]
fn no_alias_match_preserves_original_ranking_scores_and_empty_search() {
    let brain = TestBrain::new();
    brain.seed("vector database", 100, None, EventSource::ScreenOcr);
    brain.seed(
        "vector database design notes with extra detail",
        101,
        None,
        EventSource::ScreenOcr,
    );
    brain.seed("unrelated notes", 102, None, EventSource::ScreenOcr);
    let mut query = json!({"text": "vector database", "limit": 20});
    let baseline = brain.search(&query);
    assert_eq!(baseline.len(), 2);
    let ranked = brain.store.fts5_search("vector database", 20).unwrap();
    assert_eq!(
        baseline
            .iter()
            .map(|hit| (EventId(hit.event_id), hit.score.unwrap()))
            .collect::<Vec<_>>(),
        ranked,
    );
    for aliases in [json!({}), json!({"Amy Jain": ["AJ"]})] {
        query["user_aliases"] = aliases;
        assert_eq!(brain.search(&query), baseline);
    }
    query["text"] = json!("");
    assert!(brain.search(&query).is_empty());
}

#[test]
fn aliases_do_not_resurrect_deleted_or_suppressed_events() {
    let brain = TestBrain::new();
    let deleted = brain.seed("Amy Jain", 100, None, EventSource::ScreenOcr);
    let retained = brain.seed("AJ", 101, None, EventSource::ScreenOcr);
    let mut suppressed = event("Amy Jain private text", 102, None);
    suppressed.cascade_reason = 1;
    assert!(brain.store.put_event(&suppressed).is_err());
    let query = json!({"text": "AJ", "limit": 20, "user_aliases": {"Amy Jain": ["AJ"]}});
    assert_eq!(ids(&brain.search(&query)), vec![deleted.0, retained.0]);

    let delete_query = CString::new(json!({"event_id": deleted.0}).to_string()).unwrap();
    let result = unsafe { mci_brain_ffi_delete_event(brain.handle, delete_query.as_ptr()) };
    assert!(!result.is_null(), "{}", last_error());
    unsafe { mci_brain_ffi_string_free(result) };
    assert_eq!(ids(&brain.search(&query)), vec![retained.0]);
    assert!(brain.store.get_event(deleted).unwrap().is_none());
}

#[test]
fn alias_caps_select_canonical_groups_deterministically() {
    let brain = TestBrain::new();
    let first = brain.seed("Group000", 100, None, EventSource::ScreenOcr);
    brain.seed("Group064", 101, None, EventSource::ScreenOcr);
    let mut aliases = serde_json::Map::new();
    for index in 0..=USER_ALIAS_GROUP_CAP {
        aliases.insert(format!("Group{index:03}"), json!(["needle"]));
    }
    let query = json!({"text": "needle", "limit": 20, "user_aliases": aliases});
    for _ in 0..8 {
        assert_eq!(ids(&brain.search(&query)), vec![first.0]);
    }
}

#[test]
fn aliases_beyond_the_per_group_cap_neither_expand_nor_trigger() {
    let brain = TestBrain::new();
    let canonical = brain.seed("Canonical", 100, None, EventSource::ScreenOcr);
    brain.seed("hiddenalias", 101, None, EventSource::ScreenOcr);
    let mut alternatives = vec!["needle"; USER_ALIAS_PER_GROUP_CAP];
    alternatives.push("hiddenalias");
    let query = json!({
        "text": "needle", "limit": 20, "user_aliases": {"Canonical": alternatives},
    });
    assert_eq!(ids(&brain.search(&query)), vec![canonical.0]);
    assert_eq!(
        brain.search(&json!({
            "text": "hiddenalias", "limit": 20, "user_aliases": {"Canonical": alternatives},
        })),
        brain.search(&json!({"text": "hiddenalias", "limit": 20}))
    );
}

#[test]
fn over_count_budget_retains_original_and_early_alias_hits() {
    let brain = TestBrain::new();
    let original = brain.seed("needle", 100, None, EventSource::ScreenOcr);
    let first = brain.seed("Group000", 101, None, EventSource::ScreenOcr);
    brain.seed("Group061", 102, None, EventSource::ScreenOcr);
    let mut many = serde_json::Map::new();
    for index in 0..USER_ALIAS_GROUP_CAP {
        many.insert(
            format!("Group{index:03}"),
            json!(vec!["needle"; USER_ALIAS_PER_GROUP_CAP]),
        );
    }
    let hits = brain.search(&json!({
        "text": "needle", "limit": 20, "user_aliases": many,
    }));
    assert_eq!(ids(&hits), vec![original.0, first.0]);
}

#[test]
fn over_byte_budget_skips_alias_and_keeps_original_and_later_phrases() {
    let brain = TestBrain::new();
    let original = brain.seed("needle", 100, None, EventSource::ScreenOcr);
    let later = brain.seed("valid phrase", 101, None, EventSource::ScreenOcr);
    let oversized = "x".repeat(MAX_LEXICAL_ALTERNATIVE_BYTES);
    let hits = brain.search(&json!({
        "text": "needle", "limit": 20,
        "user_aliases": {oversized: ["needle", "valid phrase"]},
    }));
    assert_eq!(ids(&hits), vec![original.0, later.0]);
}

#[test]
fn over_byte_budget_skips_whole_phrases_instead_of_truncating() {
    let brain = TestBrain::new();
    let original = brain.seed("needle", 100, None, EventSource::ScreenOcr);
    let fitting = brain.seed("end", 101, None, EventSource::ScreenOcr);
    brain.seed("One", 102, None, EventSource::ScreenOcr);
    // Leave three bytes: "One Two" cannot become an unrelated "One" match.
    let almost_full = "x".repeat(MAX_LEXICAL_ALTERNATIVE_BYTES - "needle".len() - 3);
    let hits = brain.search(&json!({
        "text": "needle", "limit": 20,
        "user_aliases": {almost_full: ["needle", "One Two", "end"]},
    }));
    assert_eq!(ids(&hits), vec![original.0, fitting.0]);
}
