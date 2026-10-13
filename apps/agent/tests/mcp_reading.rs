//! What an AI tool reads through MCP is each event's reading: never the
//! stored header or U+001E (RULINGS T8, T14). The store keeps its text as
//! it arrived, header included.

use std::sync::Arc;

use mci_agent::mcp::{BrainReader, JsonRpcId, JsonRpcRequest, LiveBrainReader, Server};
use mci_brain::{BrainStore, Event, EventId, EventSource, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

const NOTES: &str = "com.apple.Notes";

fn open_temp_store() -> (tempfile::TempDir, Arc<SqlCipherBrainStore>) {
    let dir = tempfile::tempdir().unwrap();
    let key = DbKey::from_bytes([0xC3; 32]);
    let store =
        Arc::new(SqlCipherBrainStore::new(&dir.path().join("reading.sqlite"), &key).unwrap());
    (dir, store)
}

fn seed(
    store: &SqlCipherBrainStore,
    text: &str,
    ts_us: u64,
    app: &str,
    source: EventSource,
) -> EventId {
    store
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

fn call(server: &Server, tool: &str, arguments: serde_json::Value) -> serde_json::Value {
    let response = server
        .dispatch(JsonRpcRequest {
            jsonrpc: "2.0".into(),
            method: "tools/call".into(),
            params: Some(serde_json::json!({ "name": tool, "arguments": arguments })),
            id: Some(JsonRpcId::Number(1)),
        })
        .expect("a response");
    assert!(response.error.is_none(), "{tool}: {:?}", response.error);
    response.result.expect("a result")
}

fn strings(value: &serde_json::Value, out: &mut Vec<String>) {
    match value {
        serde_json::Value::String(text) => out.push(text.clone()),
        serde_json::Value::Array(items) => items.iter().for_each(|item| strings(item, out)),
        serde_json::Value::Object(map) => map.values().for_each(|item| strings(item, out)),
        _ => {}
    }
}

#[test]
fn no_text_an_ai_tool_reads_holds_the_separator_or_a_header() {
    let (_dir, store) = open_temp_store();
    let revision = format!("[MCP_RESOURCE revision_sha256={}]\n", "ab".repeat(32));
    seed(
        &store,
        &classified_notes(),
        1_000_000,
        NOTES,
        EventSource::ScreenOcr,
    );
    seed(
        &store,
        &format!("{}Background launch window\n\n\u{1e}\nTabs", header(NOTES)),
        2_000_000,
        NOTES,
        EventSource::ScreenContext,
    );
    seed(
        &store,
        "[app=claude-code | title=demo · user | url=/x/demo#main | session=s1 | src=/t.jsonl:2]\nlaunch the beta",
        3_000_000,
        "com.anthropic.claude-code",
        EventSource::TranscriptImport,
    );
    seed(
        &store,
        &format!("{revision}[app=mcp:docs | title=Spec | url=docs://1 | ts=1]\nlaunch spec"),
        4_000_000,
        "mcp:docs",
        EventSource::McpResource,
    );
    seed(
        &store,
        &format!(
            "{}Launch page\u{1e}\n\n[VISIBLE-OCR]\nLaunch\n\n\u{1e}\nTabs",
            header("com.google.Chrome")
        ),
        5_000_000,
        "com.google.Chrome",
        EventSource::BrowserPageWithOcr,
    );
    seed(
        &store,
        &format!("{}launch notes\u{1e}", header(NOTES)),
        6_000_000,
        NOTES,
        EventSource::Unknown,
    );
    let server = Server::new(Arc::new(LiveBrainReader::from_store_with_embedder(
        Arc::clone(&store),
        None,
    )));

    let mut seen = Vec::new();
    for query in ["launch", "tabs", "roadmap"] {
        strings(
            &call(&server, "mci_recall", serde_json::json!({ "query": query })),
            &mut seen,
        );
    }
    strings(
        &call(
            &server,
            "mci_events_since",
            serde_json::json!({ "ts_us": 0 }),
        ),
        &mut seen,
    );
    for app in [
        NOTES,
        "com.google.Chrome",
        "mcp:docs",
        "com.anthropic.claude-code",
    ] {
        strings(
            &call(
                &server,
                "mci_events_by_app",
                serde_json::json!({ "app_bundle_id": app }),
            ),
            &mut seen,
        );
    }
    strings(
        &call(
            &server,
            "mci_context",
            serde_json::json!({ "focus": "launch" }),
        ),
        &mut seen,
    );
    strings(
        &call(&server, "mci_context", serde_json::json!({})),
        &mut seen,
    );
    assert!(seen
        .iter()
        .any(|text| text.contains("The beta opens on October 21.")));
    for text in seen {
        assert!(!text.contains('\u{1e}'), "{text:?}");
        assert!(!text.contains("[app="), "{text:?}");
    }
}

#[test]
fn a_recalled_window_shows_the_passage_with_the_query_words() {
    let (_dir, store) = open_temp_store();
    seed(
        &store,
        &classified_notes(),
        1_000_000,
        NOTES,
        EventSource::ScreenOcr,
    );
    let server = Server::new(Arc::new(LiveBrainReader::from_store_with_embedder(
        Arc::clone(&store),
        None,
    )));
    let result = call(
        &server,
        "mci_recall",
        serde_json::json!({ "query": "When does the beta open?" }),
    );
    let snippet = result["hits"][0]["text_snippet"].as_str().unwrap();
    assert!(
        snippet.starts_with("The beta opens on October 21."),
        "{snippet:?}"
    );
    assert!(
        !snippet.contains("Roadmap"),
        "chrome is not shown when the words are in main"
    );
    let result = call(
        &server,
        "mci_recall",
        serde_json::json!({ "query": "roadmap" }),
    );
    assert_eq!(
        result["hits"][0]["text_snippet"], "Roadmap\nRecently Deleted 3",
        "the words are only in the chrome"
    );
}

#[test]
fn a_recalled_terminal_shows_its_last_lines() {
    let (_dir, store) = open_temp_store();
    let lines: Vec<String> = (1..=120)
        .map(|n| format!("compile step {n} done"))
        .collect();
    let text = format!(
        "{}{}\nerror: the release build failed\n\n\u{1e}\nzsh",
        header("com.apple.Terminal"),
        lines.join("\n")
    );
    seed(
        &store,
        &text,
        1_000_000,
        "com.apple.Terminal",
        EventSource::ScreenOcr,
    );
    let server = Server::new(Arc::new(LiveBrainReader::from_store_with_embedder(
        Arc::clone(&store),
        None,
    )));
    // "builds" finds "build" through the index's stemming, but is not in the
    // text word for word, so the passage is the terminal's end.
    let result = call(
        &server,
        "mci_recall",
        serde_json::json!({ "query": "builds" }),
    );
    let snippet = result["hits"][0]["text_snippet"].as_str().unwrap();
    assert!(
        snippet.ends_with("error: the release build failed"),
        "{snippet:?}"
    );
    assert!(!snippet.contains("compile step 1 done"));
    assert!(snippet.len() <= mci_brain::EventRecord::SNIPPET_MAX_CHARS);
}

#[test]
fn listed_rows_start_with_the_window_text_while_the_store_keeps_its_header() {
    let (_dir, store) = open_temp_store();
    seed(
        &store,
        &classified_notes(),
        1_000_000,
        NOTES,
        EventSource::ScreenOcr,
    );
    let reader = LiveBrainReader::from_store_with_embedder(Arc::clone(&store), None);
    let stored = reader.events_since(0, 10).unwrap();
    assert!(
        stored[0]
            .text_snippet
            .starts_with("[app=com.apple.Notes | title="),
        "the store is unchanged"
    );
    let server = Server::new(Arc::new(reader));
    for result in [
        call(
            &server,
            "mci_events_since",
            serde_json::json!({ "ts_us": 0 }),
        ),
        call(
            &server,
            "mci_events_by_app",
            serde_json::json!({ "app_bundle_id": NOTES }),
        ),
    ] {
        let row = &result["events"][0];
        assert_eq!(row["source_kind"], "screen_ocr");
        assert!(
            row["text_snippet"]
                .as_str()
                .unwrap()
                .starts_with("Launch plan\nThe beta opens"),
            "{row}"
        );
    }
}
