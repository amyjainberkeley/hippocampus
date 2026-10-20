//! Each `recall` hit carries the caption History's row shows for its moment
//! (`caption`, additive), so the Ask panel can title a hit "Working on tax.rs
//! in trailhead-shop" rather than its raw window title, and say the same
//! thing History says about the same moment.
//!
//! History's rows (mci-brain-ffi `row_text`) show the caption stored for a
//! moment when the current rules made it, and otherwise one made from the
//! moment's own window now ([`mci_brain::caption::fallback`]). These tests
//! hold `recall` to both.
//!
//! Hermetic: a temporary encrypted brain with made-up moments, driven through
//! `Server::dispatch`. No subprocess, no network, nothing of the person's.

use std::sync::Arc;

use mci_agent::mcp::{JsonRpcId, JsonRpcRequest, JsonRpcResponse, LiveBrainReader, Server};
use mci_brain::caption::{self, Moment};
use mci_brain::{
    BrainStore, Event, EventId, EventSource, MomentReading, SqlCipherBrainStore, READING_VERSION,
};
use mci_core::crypto::DbKey;

const VSCODE: &str = "com.microsoft.VSCode";
const SLACK: &str = "com.tinyspeck.slackmacgap";
const SAFARI: &str = "com.apple.Safari";

fn open_temp_store() -> (tempfile::TempDir, Arc<SqlCipherBrainStore>) {
    let dir = tempfile::tempdir().unwrap();
    let key = DbKey::from_bytes([0x5A; 32]);
    let store = Arc::new(SqlCipherBrainStore::new(&dir.path().join("mci.sqlite"), &key).unwrap());
    (dir, store)
}

/// A moment read off the screen, stored as the helper stores one: the
/// header line, then what the window said.
fn put_moment(
    store: &SqlCipherBrainStore,
    ts_us: u64,
    app: &str,
    title: &str,
    url: Option<&str>,
    said: &str,
) -> EventId {
    let event = Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some(app.into()),
        window_title: Some(title.into()),
        url: url.map(str::to_owned),
        text: format!("[app={app} | title={title}]\n{said}"),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob: None,
        tab_id: None,
        embedding: None,
    };
    store
        .put_event_with_source(&event, EventSource::ScreenOcr)
        .unwrap()
}

/// The re-clean job's row for a moment, with `caption`, made by `version`.
fn put_caption(store: &SqlCipherBrainStore, id: EventId, caption: &str, version: u32) {
    let read = store
        .stored_moment(id)
        .unwrap()
        .expect("the moment is stored");
    let row = MomentReading {
        event_id: id,
        version,
        reading: None,
        caption: Some(caption.into()),
        caption_by: Some("apple-foundation-models".into()),
        model_tried: true,
        updated_us: read.ts_us + 1,
    };
    assert!(store.put_moment_reading(&row, &read).unwrap());
}

fn recall(store: Arc<SqlCipherBrainStore>, query: &str) -> serde_json::Value {
    let server = Server::new(Arc::new(LiveBrainReader::from_store_with_embedder(
        store, None,
    )));
    let response: JsonRpcResponse = server
        .dispatch(JsonRpcRequest {
            jsonrpc: "2.0".into(),
            method: "tools/call".into(),
            params: Some(serde_json::json!({
                "name": "recall",
                "arguments": {"query": query, "limit": 16}
            })),
            id: Some(JsonRpcId::Number(1)),
        })
        .expect("a response");
    assert!(response.error.is_none(), "{:?}", response.error);
    response.result.expect("a result")
}

/// Each hit's caption, by event id, from the structured hits and from the
/// text an AI tool reads: the two must agree.
fn captions(result: &serde_json::Value) -> Vec<(u64, Option<String>)> {
    let read = |hits: &serde_json::Value| -> Vec<(u64, Option<String>)> {
        hits.as_array()
            .expect("a hits array")
            .iter()
            .map(|hit| {
                let caption = hit
                    .get("caption")
                    .expect("every hit says its caption, null when it has none");
                (
                    hit["event_id"].as_u64().unwrap(),
                    caption.as_str().map(str::to_owned),
                )
            })
            .collect()
    };
    let structured = read(&result["hits"]);
    let text: serde_json::Value =
        serde_json::from_str(result["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(
        read(&text["hits"]),
        structured,
        "the text says what the hits say"
    );
    structured
}

fn caption_of(found: &[(u64, Option<String>)], id: EventId) -> Option<String> {
    found
        .iter()
        .find(|(event, _)| *event == id.0)
        .unwrap_or_else(|| panic!("moment {} was not found: {found:?}", id.0))
        .1
        .clone()
}

#[test]
fn a_hit_without_a_stored_caption_says_what_history_makes_from_its_window() {
    let (_dir, store) = open_temp_store();
    let code = put_moment(
        &store,
        1_791_828_400_000_000,
        VSCODE,
        "\u{25cf} tax.rs \u{2014} trailhead-shop",
        None,
        "fn total() -> Money { round_half_even(rounding) }",
    );
    let chat = put_moment(
        &store,
        1_791_828_500_000_000,
        SLACK,
        "launch-plan (Channel) - Northwind Studio - Slack",
        None,
        "10:02 AM the rounding fix is in, and its test",
    );
    let found = captions(&recall(Arc::clone(&store), "rounding"));
    assert_eq!(
        caption_of(&found, code).as_deref(),
        Some("Working on tax.rs in trailhead-shop")
    );
    assert_eq!(
        caption_of(&found, chat).as_deref(),
        Some("Chatting in #launch-plan")
    );
}

#[test]
fn a_stored_caption_is_the_one_a_hit_carries() {
    let (_dir, store) = open_temp_store();
    let page = put_moment(
        &store,
        1_791_828_960_000_000,
        SAFARI,
        "Rounding half to even \u{00b7} Dev Notes",
        Some("https://devnotes.example/rounding"),
        "Round half to even keeps order totals from drifting by a cent.",
    );
    put_caption(
        &store,
        page,
        "Reading about rounding order totals",
        READING_VERSION,
    );
    let found = captions(&recall(store, "rounding"));
    assert_eq!(
        caption_of(&found, page).as_deref(),
        Some("Reading about rounding order totals"),
        "the caption History shows for this moment"
    );
}

#[test]
fn a_caption_from_older_rules_gives_way_to_one_made_now() {
    let (_dir, store) = open_temp_store();
    let title = "\u{25cf} tax.rs \u{2014} trailhead-shop";
    let code = put_moment(
        &store,
        1_791_828_400_000_000,
        VSCODE,
        title,
        None,
        "fn total() -> Money { round_half_even(rounding) }",
    );
    put_caption(&store, code, "Old words for tax.rs", READING_VERSION - 1);
    let found = captions(&recall(store, "rounding"));
    let made_now = caption::fallback(&Moment {
        app: Some(VSCODE),
        title: Some(title),
        url: None,
        text: "fn total() -> Money { round_half_even(rounding) }",
        beside: false,
    });
    assert_eq!(caption_of(&found, code), made_now);
    assert_eq!(
        made_now.as_deref(),
        Some("Working on tax.rs in trailhead-shop")
    );
}

#[test]
fn a_hit_keeps_its_window_title_beside_its_caption() {
    // Additive: AI tools that read `window_title` still find it, unchanged.
    let (_dir, store) = open_temp_store();
    let title = "launch-plan (Channel) - Northwind Studio - Slack";
    let chat = put_moment(
        &store,
        1_791_828_500_000_000,
        SLACK,
        title,
        None,
        "the rounding fix is in",
    );
    let result = recall(store, "rounding");
    let hit = result["hits"]
        .as_array()
        .unwrap()
        .iter()
        .find(|hit| hit["event_id"] == chat.0)
        .expect("the moment is found");
    assert_eq!(hit["window_title"], title);
    assert_eq!(hit["caption"], "Chatting in #launch-plan");
}
