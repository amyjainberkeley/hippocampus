use super::*;
use mci_brain::{Event, EventSource};
use serde_json::{json, Value};

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
        let path = CString::new(path.to_str().unwrap()).unwrap();
        let key = CString::new("2a".repeat(32)).unwrap();
        let handle = unsafe { mci_brain_ffi_open(path.as_ptr(), key.as_ptr()) };
        assert!(!handle.is_null());
        Self { handle, store, dir }
    }

    fn seed(&self, text: &str, title: &str, ts_us: u64) -> EventId {
        self.store
            .put_event_with_source(
                &Event {
                    id: EventId(0),
                    ts_us,
                    app_bundle_id: Some("test.snippets".into()),
                    window_title: Some(title.into()),
                    url: Some("https://example.test/notes".into()),
                    text: text.into(),
                    summary: None,
                    entities: None,
                    episode_id: None,
                    cascade_reason: 0,
                    keyframe_blob: Some("ab".repeat(32)),
                    tab_id: None,
                    embedding: None,
                },
                EventSource::ScreenOcr,
            )
            .unwrap()
    }

    fn search(&self, query: &Value) -> Vec<HitJson> {
        let query = CString::new(query.to_string()).unwrap();
        let result = unsafe { mci_brain_ffi_search(self.handle, query.as_ptr()) };
        Self::read_hits(result)
    }

    fn read_hits(result: *mut c_char) -> Vec<HitJson> {
        assert!(!result.is_null());
        let bytes = unsafe { CStr::from_ptr(result) }.to_bytes().to_vec();
        unsafe { mci_brain_ffi_string_free(result) };
        serde_json::from_slice(&bytes).unwrap()
    }
}

impl Drop for TestBrain {
    fn drop(&mut self) {
        unsafe { mci_brain_ffi_close(self.handle) };
    }
}

fn assert_excerpt(body: &str, excerpt: &str, expected: &str) {
    assert!(
        excerpt.contains(expected),
        "missing matching passage {expected:?}"
    );
    assert!(body.contains(excerpt), "excerpt must be verbatim body text");
    assert!(excerpt.chars().count() <= SNIPPET_CHAR_CAP);
}

#[test]
fn lexical_snippet_finds_deep_body_match_and_preserves_identity_and_ranking() {
    let brain = TestBrain::new();
    let body = format!(
        "{}needle launch decision. {}",
        "unrelated ".repeat(60),
        "tail ".repeat(80)
    );
    let id = brain.seed(&body, "Notes", 100);
    brain.seed("needle", "Other notes", 200);
    let ranked = brain.store.fts5_search("needle", 10).unwrap();
    let hits = brain.search(&json!({"text": "needle", "mode": "text", "limit": 10}));
    assert_eq!(
        hits.iter()
            .map(|hit| (EventId(hit.event_id), hit.score.unwrap()))
            .collect::<Vec<_>>(),
        ranked
    );
    let hit = hits.iter().find(|hit| hit.event_id == id.0).unwrap();
    assert_eq!(hit.ts_us, 100);
    assert_eq!(hit.source, "lexical");
    assert_eq!(hit.source_kind, "screen_ocr");
    assert_eq!(hit.app_bundle_id.as_deref(), Some("test.snippets"));
    assert_eq!(hit.window_title.as_deref(), Some("Notes"));
    assert_eq!(hit.url.as_deref(), Some("https://example.test/notes"));
    assert_eq!(
        hit.thumbnail_path.as_deref(),
        brain
            .dir
            .path()
            .join("blobs")
            .join(format!("{}.bin", "ab".repeat(32)))
            .to_str()
    );
    assert_excerpt(&body, &hit.ocr_text_snippet, "needle launch decision");
}

fn assert_visible_match(excerpt: &str, expected: &str) {
    // HitRow displays three lines. Source line breaks must not consume that
    // budget before the matching line, even for a body shorter than 280 chars.
    let visible = excerpt
        .split(['\n', '\r', '\u{85}', '\u{2028}', '\u{2029}'])
        .take(3)
        .collect::<Vec<_>>()
        .join("\n");
    assert!(
        visible.contains(expected),
        "matching passage absent from three-line visible prefix: {visible:?}"
    );
    let before = excerpt.split_once(expected).unwrap().0;
    assert!(
        before.chars().count() <= 32,
        "too much leading context before visible match: {} chars",
        before.chars().count()
    );
}

#[test]
fn lexical_snippet_multiline_match_is_visible_without_changing_source_readback() {
    let brain = TestBrain::new();
    let body = format!(
        "{}needle launch decision.\n{}",
        "earlier\n".repeat(80),
        "later\n".repeat(80)
    );
    let text = format!("[app=test.snippets | title=Notes | url= | ts=100]\n{body}");
    let id = brain.seed(&text, "Notes", 100);
    let ranked = brain.store.fts5_search("needle", 10).unwrap();
    let hits = brain.search(&json!({"text": "needle", "mode": "text", "limit": 10}));
    assert_eq!(hits.len(), 1);
    let hit = &hits[0];
    assert_excerpt(&body, &hit.ocr_text_snippet, "needle launch decision");
    assert_visible_match(&hit.ocr_text_snippet, "needle launch decision");
    assert!(hit.ocr_text_snippet.starts_with("needle launch decision."));
    assert_eq!((EventId(hit.event_id), hit.score.unwrap()), ranked[0]);
    assert_eq!(hit.ts_us, 100);
    assert_eq!(hit.source, "lexical");
    assert_eq!(hit.source_kind, "screen_ocr");

    let raw = unsafe { mci_brain_ffi_event_text(brain.handle, id.0) };
    assert!(!raw.is_null());
    let full: Value = serde_json::from_slice(unsafe { CStr::from_ptr(raw) }.to_bytes()).unwrap();
    unsafe { mci_brain_ffi_string_free(raw) };
    assert_eq!(full["event_id"], id.0);
    assert_eq!(full["text"], text);
    assert_eq!(full["truncated"], false);
    let recent = TestBrain::read_hits(unsafe { mci_brain_ffi_recent_events(brain.handle, 10) });
    assert_eq!(
        recent[0].ocr_text_snippet,
        text.chars().take(280).collect::<String>()
    );
}

#[test]
fn search_snippet_short_multiline_and_unicode_separators_keep_match_visible() {
    let query = SearchSnippet::new(&[LexicalAlternative::Keywords("caf\u{e9}")]);
    for separator in ["\n", "\r\n", "\r", "\u{85}", "\u{2028}", "\u{2029}"] {
        let prefix = format!("earlier{separator}").repeat(10);
        let body = format!("{prefix}CAF\u{c9} launch decision");
        assert!(body.chars().count() < 280);
        let excerpt = query.excerpt(&body);
        assert_excerpt(&body, &excerpt, "CAF\u{c9} launch decision");
        assert_visible_match(&excerpt, "CAF\u{c9} launch decision");
    }
}

#[test]
fn search_snippet_limits_same_line_context_and_does_not_backfill_at_end() {
    let query = SearchSnippet::new(&[LexicalAlternative::Keywords("needle")]);
    for body in [
        format!(
            "{}needle launch decision. {}",
            "before ".repeat(80),
            "after ".repeat(80)
        ),
        format!("{}needle launch decision", "earlier\n".repeat(80)),
        format!(
            "{}\n{}needle launch decision\ncontinued evidence",
            "earlier\n".repeat(80),
            "\u{130}\u{1f642} ".repeat(50)
        ),
    ] {
        let excerpt = query.excerpt(&body);
        assert_excerpt(&body, &excerpt, "needle launch decision");
        assert_visible_match(&excerpt, "needle launch decision");
    }
}

#[test]
fn lexical_snippet_prefers_nearby_distinct_words_over_an_earlier_single_word() {
    let brain = TestBrain::new();
    let body = format!(
        "launch {}decision for the launch is recorded. {}",
        "filler ".repeat(100),
        "tail ".repeat(80)
    );
    brain.seed(&body, "Notes", 100);
    for query in [
        "launch decision",
        "decision launch",
        "launch launch decision",
    ] {
        let hits = brain.search(&json!({"text": query, "mode": "text", "limit": 10}));
        assert_eq!(hits.len(), 1);
        assert_excerpt(
            &body,
            &hits[0].ocr_text_snippet,
            "decision for the launch is recorded",
        );
    }
}

#[test]
fn lexical_snippet_preserves_unicode_offsets_and_original_case() {
    let brain = TestBrain::new();
    let body = format!(
        "{}CAF\u{c9} \u{6771}\u{4eac} launch decision. {}",
        "\u{130}\u{1f642} ".repeat(220),
        "\u{754c} ".repeat(180)
    );
    brain.seed(&body, "Notes", 100);
    let hits =
        brain.search(&json!({"text": "caf\u{e9} \u{6771}\u{4eac}", "mode": "text", "limit": 10}));
    assert_eq!(hits.len(), 1);
    assert_excerpt(
        &body,
        &hits[0].ocr_text_snippet,
        "CAF\u{c9} \u{6771}\u{4eac} launch decision",
    );
}

#[test]
fn lexical_snippet_uses_literal_punctuation_and_whole_words() {
    let brain = TestBrain::new();
    let body = format!(
        "launchpad decisionary {}launch-decision: approved; OR confirmed. {}",
        "filler ".repeat(100),
        "tail ".repeat(80)
    );
    brain.seed(&body, "Notes", 100);
    for query in [
        "launch-decision?",
        "(launch) decision*",
        "OR",
        "launch decision",
    ] {
        let hits = brain.search(&json!({"text": query, "mode": "text", "limit": 10}));
        assert_eq!(hits.len(), 1);
        assert_excerpt(
            &body,
            &hits[0].ocr_text_snippet,
            "launch-decision: approved; OR confirmed",
        );
    }
}

#[test]
fn lexical_snippet_skips_complete_context_header_even_when_header_matches() {
    let brain = TestBrain::new();
    let body = format!(
        "{}needle launch decision. {}",
        "filler ".repeat(100),
        "tail ".repeat(80)
    );
    let text = format!("[app=test.snippets | title=needle | url= | ts=100]\n{body}");
    brain.seed(&text, "needle", 100);
    let hits = brain.search(&json!({"text": "needle", "mode": "text", "limit": 10}));
    assert_eq!(hits.len(), 1);
    assert_excerpt(&body, &hits[0].ocr_text_snippet, "needle launch decision");
}

#[test]
fn lexical_snippet_metadata_only_hits_do_not_invent_a_body_match() {
    let brain = TestBrain::new();
    brain.seed(
        "[app=test.snippets | title=needle | url= | ts=100]\nOrdinary body without the keyword.",
        "Notes",
        100,
    );
    brain.seed("Another body without the keyword.", "needle", 200);
    brain.seed("", "needle", 300);
    let hits = brain.search(&json!({"text": "needle", "mode": "text", "limit": 10}));
    assert_eq!(hits.len(), 3);
    for hit in hits {
        assert!(!hit.ocr_text_snippet.contains("needle"));
        assert_eq!(
            hit.ocr_text_snippet,
            match hit.ts_us {
                100 => "Ordinary body without the keyword.",
                200 => "Another body without the keyword.",
                300 => "",
                _ => unreachable!(),
            }
        );
    }
}

#[test]
fn snippet_search_preserves_empty_queries_and_recent_history_formatting() {
    let brain = TestBrain::new();
    let text = format!(
        "[app=test.snippets | title=needle | url= | ts=100]\n{}needle launch decision",
        "filler ".repeat(100)
    );
    brain.seed(&text, "Notes", 100);
    for query in ["", "   ", "?! () *"] {
        assert!(brain
            .search(&json!({"text": query, "mode": "text", "limit": 10}))
            .is_empty());
    }
    let recent = TestBrain::read_hits(unsafe { mci_brain_ffi_recent_events(brain.handle, 10) });
    let browse = brain.search(&json!({"text": "", "browse": true, "limit": 10}));
    let prefix: String = text.chars().take(280).collect();
    assert_eq!(recent[0].ocr_text_snippet, prefix);
    assert_eq!(browse[0].ocr_text_snippet, prefix);
    assert_eq!(
        timeline_snippet(&text),
        "filler ".repeat(12).chars().take(80).collect::<String>()
    );
}

#[test]
fn lexical_snippet_centers_expanded_alias_without_changing_ranking() {
    let brain = TestBrain::new();
    let body = format!(
        "{}Project Atlas launch decision. {}",
        "filler ".repeat(100),
        "tail ".repeat(80)
    );
    let id = brain.seed(&body, "Notes", 100);
    brain.seed("PA notes.", "Other notes", 200);
    let query = json!({
        "text": "PA", "mode": "text", "limit": 10,
        "user_aliases": {"Project Atlas": ["PA"]}
    });
    let parsed: QueryJson = serde_json::from_value(query.clone()).unwrap();
    let alternatives = expand_query_with_user_aliases(&parsed.text, &parsed.user_aliases);
    let ranked = brain
        .store
        .fts5_search_alternatives(&alternatives, 10)
        .unwrap();
    let hits = brain.search(&query);
    assert_eq!(
        hits.iter()
            .map(|hit| (EventId(hit.event_id), hit.score.unwrap()))
            .collect::<Vec<_>>(),
        ranked
    );
    let hit = hits.iter().find(|hit| hit.event_id == id.0).unwrap();
    assert_excerpt(
        &body,
        &hit.ocr_text_snippet,
        "Project Atlas launch decision",
    );
}

#[test]
fn search_snippet_fallback_and_boundary_cases_remain_verbatim() {
    let long = format!("{}needlework {}", "filler ".repeat(100), "tail ".repeat(80));
    for query in ["", "   ", "?! () *", "needle", "unmatched"] {
        let query = SearchSnippet::new(&[LexicalAlternative::Keywords(query)]);
        assert_eq!(
            query.excerpt(&long),
            long.chars().take(280).collect::<String>()
        );
    }
    let query = SearchSnippet::new(&[LexicalAlternative::Keywords("needle")]);
    for body in [
        "",
        "needle",
        "[app=needle]\nOrdinary text.",
        "[app=needle | title=x | url= | ts=100]",
    ] {
        assert_eq!(query.excerpt(body), body);
    }
    let header = "[app=needle | title=x | url= | ts=100]\n";
    assert_eq!(
        query.excerpt(&format!("{header}{header}body")),
        format!("{header}body")
    );
    for body in [
        format!("needle launch decision {}", "tail ".repeat(100)),
        format!("{}needle launch decision", "filler ".repeat(100)),
        format!(
            "{}needle launch decision {}",
            "\u{65}\u{301} ".repeat(100),
            "tail ".repeat(100)
        ),
    ] {
        assert_excerpt(&body, &query.excerpt(&body), "needle launch decision");
    }
    let long_word = "x".repeat(600);
    let long_query = SearchSnippet::new(&[LexicalAlternative::Keywords(&long_word)]);
    assert_eq!(
        long_query.excerpt(&format!("before {long_word} after")),
        "x".repeat(280)
    );
}

#[test]
fn related_snippet_without_literal_match_preserves_source_and_body_prefix() {
    let brain = TestBrain::new();
    let body = "Ordinary unrelated body. ".repeat(20);
    let id = brain.seed(&body, "Notes", 100);
    let query = SearchSnippet::new(&[LexicalAlternative::Keywords("needle")]);
    for source in [
        "hybrid",
        "hybrid-related",
        "hybrid-conflict",
        "semantic-related",
    ] {
        let event = brain.store.get_event(id).unwrap().unwrap();
        let handle = unsafe { &*brain.handle };
        let hit = hit_json(handle, id, event, source, Some(0.75), Some(&query));
        assert_eq!(hit.event_id, id.0);
        assert_eq!(hit.source, source);
        assert_eq!(hit.score, Some(0.75));
        assert_eq!(
            hit.ocr_text_snippet,
            body.chars().take(280).collect::<String>()
        );
    }
}
