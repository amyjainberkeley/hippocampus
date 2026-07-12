//! End-to-end OCREvent → chunker → encrypted event row wire test
//! (DOGFOOD v1 #5).
//!
//! Drives the **production** path from synthetic `OCREvent` wire frames
//! through `drain_to_log_with_brain` → `BrainPump` (real
//! `EventChunker` + deterministic `FixedDimEmbedder`) → real
//! `SqlCipherBrainStore` (SQLCipher + FTS5 + brute-force vector search)
//! and asserts:
//!
//! 1. **N synthetic OCREvent frames produce exactly N event rows** in
//!    the on-disk encrypted `mci.sqlite`.
//! 2. Every row carries the ADR-0010 §1.3 context header in
//!    `events.text` (the prepend the chunker wire installed).
//! 3. **`mci_recall`** (lexical FTS5 path via `LiveBrainReader`) returns
//!    every seeded event when queried against its OCR body — proves the
//!    `events_fts` trigger sync + recall round-trip works on real
//!    chunker-wired writes.
//! 4. **`vec_search`** (semantic side via `BrainStore`) returns the
//!    matching event when queried with the embedding of the chunker's
//!    first-chunk output — proves the embedding written at ingest is
//!    the same one the retriever queries against.
//! 5. **`mci_stats`** reports `event_count == N`, `oldest_ts_us ==
//!    first ts`, `newest_ts_us == last ts`.
//! 6. The content-free `events_ingested_count` counter equals N.
//!
//! # Hermetic
//!
//! Every brain lives in a `tempfile::TempDir`; nothing escapes the
//! test process. The `§4 capture-default-OFF` gate is unchanged — no
//! live capture is invoked; the test harness feeds synthetic wire
//! bytes through the same `drain_to_log_with_brain` path the
//! production agent uses.
//!
//! # CSO sign-off notes (matches PR body)
//!
//! - No store schema change — writes go through the existing
//!   `SqlCipherBrainStore.put_event` API.
//! - No key-wrap change — opens the store with the test
//!   `DbKey::from_bytes([0xCC; 32])`, same pattern as
//!   `mcp_e2e_real_brain.rs`.
//! - No new persisted PII fields beyond the existing event row — the
//!   §1.3 header is composed of the same `app_bundle_id` /
//!   `window_title` / `url` already stored in their own columns.
//! - ADR-0016 §4.2 cascade-twice preserved — the helper-side single
//!   `OCREvent` emission site is unchanged; this test exercises the
//!   consumer side only.

use std::sync::Arc;

use mci_agent::brain_ingest::{BrainIngestor, BrainPump};
use mci_agent::device_id::{load_or_generate, DeviceId};
use mci_agent::health_log::{HealthLog, HealthLogConfig};
use mci_agent::mcp::{BrainReader, JsonRpcId, JsonRpcRequest, LiveBrainReader, Server};
use mci_agent::runner::drain_to_log_with_brain;
use mci_agent::wall_clock::SystemWallClock;
use mci_brain::stubs::FixedDimEmbedder;
use mci_brain::{BrainStore, Embedder, SqlCipherBrainStore};
use mci_core::crypto::DbKey;
use mci_core::ipc::wire::encode;
use mci_core::ipc::Message;
use std::io::Cursor;

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------

fn open_temp_store() -> (
    tempfile::TempDir,
    std::path::PathBuf,
    DbKey,
    Arc<SqlCipherBrainStore>,
) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("dogfood5.sqlite");
    let key = DbKey::from_bytes([0xCC; 32]);
    let store = Arc::new(SqlCipherBrainStore::new(&path, &key).unwrap());
    (dir, path, key, store)
}

fn fresh_log(tmp_path: &std::path::Path) -> HealthLog {
    HealthLog::new(HealthLogConfig {
        path: tmp_path.join("h.jsonl"),
        max_bytes: 10 * 1024 * 1024,
    })
}

async fn device_id(dir: &std::path::Path) -> DeviceId {
    let (id, _src) = load_or_generate(dir.join("device-id")).await.unwrap();
    id
}

/// Construct an `OCREvent` wire frame whose payload looks like a real
/// twice-cleared helper emission (ADR-0016 §1.6).
fn make_ocr_frame(
    seq: u64,
    ts_us: u64,
    app_id: &str,
    title: &str,
    url: &str,
    body: &str,
) -> Vec<u8> {
    let mut bundle = [0u8; 64];
    let copy_len = app_id.len().min(64);
    bundle[..copy_len].copy_from_slice(&app_id.as_bytes()[..copy_len]);
    encode(
        seq,
        &Message::OCREvent {
            seq,
            ts_us,
            app_bundle_id: bundle,
            window_title: title.to_owned(),
            url: url.to_owned(),
            ocr_text: body.to_owned(),
            keyframe_hash: [0u8; 32],
        },
    )
}

fn req_call(name: &str, args: serde_json::Value) -> JsonRpcRequest {
    JsonRpcRequest {
        jsonrpc: "2.0".into(),
        method: "tools/call".into(),
        params: Some(serde_json::json!({"name": name, "arguments": args})),
        id: Some(JsonRpcId::Number(1)),
    }
}

// -----------------------------------------------------------------------
// The wire test — N synthetic OCREvents end up as N rows + N hits
// -----------------------------------------------------------------------

#[tokio::test]
async fn n_synthetic_ocr_events_become_n_rows_and_recall_hits() {
    let (dir, db_path, key, store) = open_temp_store();
    let log = fresh_log(dir.path());
    let clock = SystemWallClock;
    let id = device_id(dir.path()).await;

    let embedder: Arc<dyn Embedder> = Arc::new(FixedDimEmbedder::default());
    // Production wire: BrainPump::new installs the default EventChunker.
    let pump = BrainPump::new(
        Arc::clone(&store) as Arc<dyn BrainStore>,
        Some(Arc::clone(&embedder)),
    );

    // Five distinct synthetic events. Each body carries a unique
    // distinguishing token so FTS5 recall can be asserted per-event.
    let fixtures: Vec<(u64, u64, &str, &str, &str, &str)> = vec![
        (
            0,
            1_000_000,
            "com.apple.Safari",
            "Login — bank",
            "https://bank.example.com/login",
            "alpha onetime balance",
        ),
        (
            1,
            2_000_000,
            "com.google.Chrome",
            "Pricing — example",
            "https://example.com/pricing",
            "bravo annual subscription",
        ),
        (
            2,
            3_000_000,
            "com.apple.Notes",
            "Meeting notes",
            "",
            "charlie standup mci roadmap",
        ),
        (
            3,
            4_000_000,
            "com.tinyspeck.slackmacgap",
            "general — Slack",
            "",
            "delta deploy postmortem",
        ),
        (
            4,
            5_000_000,
            "com.apple.Safari",
            "Issue #42",
            "https://github.com/test/repo/issues/42",
            "echo regression fixed",
        ),
    ];

    let mut bytes = Vec::new();
    for (seq, ts_us, app, title, url, body) in &fixtures {
        bytes.extend(make_ocr_frame(*seq, *ts_us, app, title, url, body));
    }

    let mut cursor = Cursor::new(bytes);
    let stats = drain_to_log_with_brain(&mut cursor, &log, &clock, &id, &pump)
        .await
        .expect("drain ok");

    // (1) Counters — N seen, N to brain, content-free counter == N.
    assert_eq!(stats.frames_seen, fixtures.len() as u64);
    assert_eq!(stats.frames_to_brain, fixtures.len() as u64);
    assert_eq!(stats.frames_logged, 0);
    assert_eq!(stats.frames_non_health, 0);
    assert_eq!(pump.events_ingested_count(), fixtures.len() as u64);

    // (2) Store-side row count + header presence in events.text. Open a
    // read-only handle off the same encrypted file the writer wrote to.
    let reader = LiveBrainReader::open(&db_path, &key).expect("open reader");
    let s = reader.stats().expect("stats");
    assert_eq!(s.event_count, fixtures.len() as u64);
    assert_eq!(s.oldest_ts_us, Some(1_000_000));
    assert_eq!(s.newest_ts_us, Some(5_000_000));

    // (3) `mci_events_since(0)` returns every event with the ADR-0010
    // §1.3 header in the text snippet — proves the chunker-wired
    // headered_text reached events.text.
    let rows = reader.events_since(0, 100).expect("events_since");
    assert_eq!(rows.len(), fixtures.len());
    for r in &rows {
        assert!(
            r.text_snippet.starts_with("[app="),
            "events.text must carry ADR-0010 §1.3 header; got: {}",
            r.text_snippet
        );
        assert!(
            r.text_snippet.contains(" | title="),
            "header must include the title-separator: {}",
            r.text_snippet
        );
    }

    // (4) `mci_recall` on each unique body token hits exactly that
    // event. The FTS5 trigger sync on put_event must have indexed every
    // row; if any was dropped we'd see zero hits.
    for (_, ts_us, _, _, _, body) in &fixtures {
        let token = body.split_whitespace().next().expect("body has a token");
        let hits = reader.recall(token, 10).expect("recall");
        assert!(
            !hits.is_empty(),
            "FTS5 recall for token '{token}' returned zero hits"
        );
        let matched = hits.iter().any(|h| h.record.ts_us == *ts_us);
        assert!(
            matched,
            "expected at least one hit at ts_us={ts_us} for token '{token}'"
        );
    }

    // (5) Semantic side: embed one of the seeded bodies (with the same
    // headered shape the pump used) and check vec_search returns the
    // matching event id. We re-derive the headered_text the same way
    // BrainPump did — chunker-first-chunk over `[app=…]\n<body>` — and
    // ask the store for top-1 nearest neighbour.
    let (target_ts, target_body) = (fixtures[2].1, fixtures[2].5);
    let header = format!(
        "[app=com.apple.Notes | title=Meeting notes | url=? | ts={}]\n",
        mci_agent::wall_clock::format_unix_ms(u128::from(target_ts / 1000))
    );
    let headered_query = format!("{header}{target_body}");
    let q_emb = embedder.embed_one(&headered_query).expect("embed query");
    let vec_hits = store.vec_search(&q_emb, 1).expect("vec_search");
    assert_eq!(vec_hits.len(), 1, "expected exactly one nearest neighbour");
    let top_event = store
        .get_event(vec_hits[0].0)
        .expect("get_event")
        .expect("event row present");
    assert_eq!(
        top_event.ts_us, target_ts,
        "nearest neighbour must be the event we embedded against"
    );

    // (6) MCP `tools/call mci_stats` round-trip via the dispatcher —
    // last line of defence that the user-visible surface sees the
    // populated brain.
    let server = Server::new(Arc::new(LiveBrainReader::from_store_with_embedder(
        Arc::clone(&store),
        None,
    )));
    let resp = server
        .dispatch(req_call("mci_stats", serde_json::json!({})))
        .expect("response");
    assert!(resp.error.is_none(), "unexpected error: {:?}", resp.error);
    let result = resp.result.expect("result");
    let stats_obj = result.get("stats").expect("stats");
    assert_eq!(
        stats_obj.get("event_count").and_then(|v| v.as_u64()),
        Some(fixtures.len() as u64)
    );
}

// -----------------------------------------------------------------------
// Cascade-twice / privacy tripwire — PrivacyTombstone on the wire never
// reaches the brain even when interleaved with OCREvents.
// -----------------------------------------------------------------------

#[tokio::test]
async fn tombstones_interleaved_with_ocr_never_reach_real_store() {
    let (dir, _db_path, _key, store) = open_temp_store();
    let log = fresh_log(dir.path());
    let clock = SystemWallClock;
    let id = device_id(dir.path()).await;
    let embedder: Arc<dyn Embedder> = Arc::new(FixedDimEmbedder::default());
    let pump = BrainPump::new(Arc::clone(&store) as Arc<dyn BrainStore>, Some(embedder));

    let mut bytes = Vec::new();
    bytes.extend(encode(
        0,
        &Message::PrivacyTombstone {
            ts_us: 1,
            app_bundle: "com.1password.app".into(),
            reason: mci_core::ipc::RedactionReason::AxSecureSubrole,
        },
    ));
    bytes.extend(make_ocr_frame(
        1,
        2_000_000,
        "com.apple.Safari",
        "OK",
        "https://safe.example.com",
        "harmless content",
    ));
    bytes.extend(encode(
        2,
        &Message::PrivacyTombstone {
            ts_us: 3,
            app_bundle: "com.apple.Keychain Access".into(),
            reason: mci_core::ipc::RedactionReason::OcrTimeSecret,
        },
    ));

    let mut cursor = Cursor::new(bytes);
    let stats = drain_to_log_with_brain(&mut cursor, &log, &clock, &id, &pump)
        .await
        .expect("drain ok");

    assert_eq!(stats.frames_seen, 3);
    assert_eq!(stats.frames_to_brain, 1, "only the OCREvent reaches brain");
    assert_eq!(stats.frames_non_health, 2, "tombstones counted only");

    // Exactly one row landed; the tombstones did not.
    let s = store.stats().expect("stats");
    assert_eq!(s.event_count, 1);
}
