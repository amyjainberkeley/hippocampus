//! V2-P? — **Messages "who" dot-connect** construction-graph WIRING PROOF +
//! end-to-end gate.
//!
//! Proves the whole chain the "make Messages store the WHO" change builds,
//! driving the SAME production entry points `bin/mci_agent.rs` spawns
//! (`MessagesPluginPump`, `BrainPump`, and the three idle workers) against a
//! real `SqlCipherBrainStore`:
//!
//! ```text
//!   Messages event (friend texts from a number with NO saved contact name)
//!        │  MessagesPluginPump.ingest_row
//!        │     → window_title = "from <handle>"   (the WHO, displayable)
//!        │     → Tier-1 extract               → phone entity + entity_mention
//!        │
//!   Safari event 30 s later mentioning the SAME number
//!        │  BrainPump.ingest_ocr_event        → SAME phone entity + mention
//!        │
//!        │  episode_worker        → two episodes (one per app)
//!        │  alias_resolver_worker → ONE handle-anchored Person identity
//!        │                          (Phase C: rule = "handle_anchor")
//!        │  consolidator_worker   → ONE shared_identity episode_edge
//!        ▼
//!   episode_edges_for_identity(handle identity) → events_in_episode
//!        ⇒ BOTH the Messages event AND the Safari event come back as a
//!          single connected hit ← the Messages dot-connect gate, on a bare
//!          handle with no contact name.
//! ```
//!
//! # Why a SECOND, cross-app event
//!
//! A `shared_identity` edge connects two events in *different* episodes
//! within 60 s. Two Messages events in the same app land in ONE episode
//! (the segmenter breaks on app-change / >10 min gap), so the canonical
//! Messages dot-connect is Messages ⇄ another app sharing the same handle —
//! exactly the "I texted them, then looked them up in Safari" path.
//!
//! # CSO sign-off notes
//!
//! (a) Every brain lives in a `tempfile::TempDir`; no real chat.db is read.
//! (b) The persisted handle is the user's own contact id, written ONLY into
//!     the local `SQLCipher` brain (`window_title` + `events.text` + the
//!     entity graph). No new schema, no capture-scope change, no IPC, no
//!     network — the zero-knowledge invariant is preserved by construction.

#![cfg(target_os = "macos")]
// The module-doc ASCII pipeline diagram intentionally uses bare code-like
// tokens (window_title, entity_mention, …) for readability; backticking
// every token would wreck the diagram.
#![allow(clippy::doc_markdown)]

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use mci_agent::brain_ingest::{BrainIngestor, BrainPump};
use mci_agent::messages_ingest::{MessagesIngestOutcome, MessagesPluginPump};
use mci_agent::{alias_resolver_worker, consolidator_worker, episode_worker};
use mci_brain::episode_segmenter::HeuristicEpisodeSegmenter;
use mci_brain::graph::Entity;
use mci_brain::redaction::messages_plugin::MessagesPluginConfig;
use mci_brain::{BrainStore, EventId, SqlCipherBrainStore};
use mci_core::crypto::DbKey;
use mci_core::ipc::Message;
use mci_messages_reader::{ChatService, MessageRow};

const MESSAGES: &str = "com.apple.MobileSMS";
const SAFARI: &str = "com.apple.Safari";
/// The friend's number — never saved as a contact, so no NAME ever enters
/// the brain for them. Tier-1 canonicalizes it to the digit string.
const HANDLE: &str = "+15551234567";
const HANDLE_DIGITS: &str = "15551234567";
const S: u64 = 1_000_000; // one second, microseconds
/// Wall-clock base in unix seconds — the Messages pump multiplies
/// `date_unix` by 1e6 to get `ts_us`.
const BASE_UNIX_S: i64 = 1_900_000_000;

fn open_temp_store() -> (tempfile::TempDir, Arc<SqlCipherBrainStore>, PathBuf, DbKey) {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("messages_who.sqlite");
    let key = DbKey::from_bytes([0xAB; 32]);
    let store = Arc::new(SqlCipherBrainStore::new(&db_path, &key).unwrap());
    (dir, store, db_path, key)
}

fn enabled_cfg() -> MessagesPluginConfig {
    MessagesPluginConfig {
        plugin_enabled: true,
        ..MessagesPluginConfig::DEFAULT
    }
}

/// An incoming Messages row from `HANDLE` (no saved contact name).
fn incoming_row(rowid: i64, body: &str) -> MessageRow {
    MessageRow {
        rowid,
        guid: format!("M-{rowid}"),
        date_unix: BASE_UNIX_S + rowid,
        is_from_me: false,
        service: ChatService::IMessage,
        body: Some(body.to_owned()),
        handle_rowid: 1,
        sender_handle: Some(HANDLE.to_owned()),
        has_attachments: false,
        recipient_handles: Vec::new(),
    }
}

/// An outgoing Messages row the user SENT to `HANDLE` — `is_from_me = true`,
/// `handle_id = 0` (no sender row), the recipient resolved by the reader
/// from the message's chat into `recipient_handles` (no saved contact name).
fn outgoing_row(rowid: i64, body: &str) -> MessageRow {
    MessageRow {
        rowid,
        guid: format!("M-{rowid}"),
        date_unix: BASE_UNIX_S + rowid,
        is_from_me: true,
        service: ChatService::IMessage,
        body: Some(body.to_owned()),
        handle_rowid: 0,
        sender_handle: None,
        has_attachments: false,
        recipient_handles: vec![HANDLE.to_owned()],
    }
}

/// A Safari page-content event whose text mentions the same number.
fn safari_page(ts_us: u64, full_text: &str) -> Message {
    Message::PageContentEvent {
        seq: 1,
        ts_us,
        url: "https://contacts.example.com/jamie".to_owned(),
        title: "Jamie".to_owned(),
        full_text: full_text.to_owned(),
        source_browser: "safari".to_owned(),
        tab_id: 7,
    }
}

/// Spawn a worker future for one cycle, then signal shutdown and join.
async fn one_cycle<F, Fut, T>(make: F) -> T
where
    F: FnOnce(tokio::sync::watch::Receiver<bool>) -> Fut,
    Fut: std::future::Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    let (tx, rx) = tokio::sync::watch::channel(false);
    let handle = tokio::spawn(make(rx));
    tokio::time::sleep(Duration::from_millis(250)).await;
    let _ = tx.send(true);
    handle.await.unwrap()
}

#[tokio::test]
#[allow(clippy::too_many_lines)] // one cohesive end-to-end gate: ingest → resolve → consolidate → query
async fn messages_handle_dot_connects_cross_app_end_to_end() {
    let (_dir, store, _path, _key) = open_temp_store();

    // 1) Friend texts from a number with NO saved contact name — ingested
    //    through the PRODUCTION Messages pump.
    let pump = MessagesPluginPump::with_watermark(
        Arc::clone(&store) as Arc<dyn BrainStore>,
        None,
        enabled_cfg(),
        0,
    );
    let outcome = pump
        .ingest_row(&incoming_row(1, "dinner at 7?"))
        .expect("ingest");
    let MessagesIngestOutcome::Stored { id: msg_id, .. } = outcome else {
        panic!("expected the allowed Messages event to be Stored");
    };

    // The WHO is persisted (display) AND the handle was extracted (graph).
    let msg_ev = store.get_event(msg_id).unwrap().unwrap();
    assert_eq!(
        msg_ev.window_title.as_deref(),
        Some("from +15551234567"),
        "the sender handle is the window 'who' title"
    );
    assert!(
        pump.tier1_mentions_persisted_count() >= 1,
        "the handle was extracted into entity_mentions"
    );

    // The phone entity exists (content-stable on the DIGIT canonical form)
    // and is mentioned ON the Messages event.
    let phone_id = Entity::derive_id("phone", HANDLE_DIGITS);
    let entities = store.list_resolvable_entities().unwrap();
    assert!(
        entities
            .iter()
            .any(|e| e.id == phone_id && e.kind == "phone"),
        "a phone entity was extracted for the handle ({entities:?})"
    );
    let cooccurrences = store.entity_cooccurrences().unwrap();
    assert!(
        cooccurrences
            .iter()
            .any(|(eid, members)| *eid == msg_id && members.contains(&phone_id)),
        "the handle is mentioned on the Messages event ({cooccurrences:?})"
    );

    // 2) ~30 s later the SAME number appears in a Safari page — ingested
    //    through the production screen/page pump. SAME phone entity (the
    //    content-stable id converges across both pumps).
    let brain = BrainPump::new(Arc::clone(&store) as Arc<dyn BrainStore>, None);
    let page_ts = (BASE_UNIX_S as u64 + 1) * S + 30 * S; // 30 s after the text
    brain
        .ingest_ocr_event(&safari_page(page_ts, "Call Jamie back at +15551234567"))
        .expect("ingest safari page");

    // 3) Segment → resolve → consolidate, via the production workers.
    let seg_store = Arc::clone(&store);
    one_cycle(move |rx| async move {
        episode_worker::run_episode_worker(
            seg_store,
            Arc::new(HeuristicEpisodeSegmenter::new()),
            64,
            Duration::from_millis(50),
            rx,
        )
        .await
        .unwrap()
    })
    .await;

    let alias_store = Arc::clone(&store);
    one_cycle(move |rx| async move {
        alias_resolver_worker::run_alias_resolver_worker(alias_store, Duration::from_millis(50), rx)
            .await
            .unwrap()
    })
    .await;

    // The bare handle anchored its OWN Person identity (Phase C).
    let memberships = store.identity_of_entity(&phone_id).unwrap();
    assert_eq!(
        memberships.len(),
        1,
        "the recurring handle resolves to exactly one identity"
    );
    let membership = &memberships[0];
    assert_eq!(
        membership.identity_kind, "person",
        "handle → Person identity"
    );
    assert_eq!(
        membership.rule, "handle_anchor",
        "anchored purely by the handle (no contact name)"
    );
    let identity = membership.identity_id.clone();

    let cons_store = Arc::clone(&store);
    let stats = one_cycle(move |rx| async move {
        consolidator_worker::run_consolidator_worker(cons_store, Duration::from_millis(50), rx)
            .await
            .unwrap()
    })
    .await;
    assert!(stats.cycles_run >= 1);
    assert_eq!(stats.store_errors, 0);
    assert!(
        stats.edges_written >= 1,
        "wrote ≥1 cross-app dot-connect edge"
    );

    // 4) THE DOT-CONNECT QUERY: handle identity → edges → linked events.
    let edges = store.episode_edges_for_identity(&identity).unwrap();
    assert_eq!(edges.len(), 1, "exactly one cross-app link for this handle");
    assert_eq!(
        edges[0].edge_kind,
        mci_brain::EpisodeEdge::KIND_SHARED_IDENTITY
    );

    // The handle (phone entity) is cited as the linking evidence.
    let evidence: Vec<String> =
        serde_json::from_str(edges[0].evidence_entity_ids.as_deref().unwrap()).unwrap();
    assert!(
        evidence.contains(&phone_id.0),
        "the handle entity is the edge evidence ({evidence:?})"
    );

    // Walk both endpoints back to their events — the connected hit must hold
    // ONE Messages event AND ONE Safari event (the cross-app dot-connect).
    let mut apps: Vec<String> = Vec::new();
    for ep in [edges[0].src_episode_id, edges[0].dst_episode_id] {
        for ev in store.events_in_episode(ep, 10).unwrap() {
            apps.push(ev.app_bundle_id.unwrap_or_default());
        }
    }
    assert!(
        apps.iter().any(|a| a == MESSAGES),
        "the connected hit includes the Messages event ({apps:?})"
    );
    assert!(
        apps.iter().any(|a| a == SAFARI),
        "the connected hit includes the Safari event ({apps:?})"
    );
}

/// The SENT-direction twin of the gate above: the user TEXTS a number with
/// no saved contact name, then looks it up in Safari. The outgoing
/// recipient — resolved by the reader from the message's chat — must become
/// the "who", get extracted as the SAME phone entity, anchor a Person
/// identity, and dot-connect cross-app. This is the gate that proves "what
/// did I send my friend" is answerable.
#[tokio::test]
#[allow(clippy::too_many_lines)] // one cohesive end-to-end gate: ingest → resolve → consolidate → query
async fn outgoing_message_handle_dot_connects_cross_app_end_to_end() {
    let (_dir, store, _path, _key) = open_temp_store();

    // 1) The user texts a number with NO saved contact name — ingested
    //    through the PRODUCTION Messages pump as an OUTGOING row.
    let pump = MessagesPluginPump::with_watermark(
        Arc::clone(&store) as Arc<dyn BrainStore>,
        None,
        enabled_cfg(),
        0,
    );
    let outcome = pump
        .ingest_row(&outgoing_row(1, "dinner at 7?"))
        .expect("ingest");
    let MessagesIngestOutcome::Stored { id: msg_id, .. } = outcome else {
        panic!("expected the allowed outgoing Messages event to be Stored");
    };

    // The SENT "who" is persisted (display) AND the recipient handle was
    // extracted (graph) — the direction word is `to`, not `from`.
    let msg_ev = store.get_event(msg_id).unwrap().unwrap();
    assert_eq!(
        msg_ev.window_title.as_deref(),
        Some("to +15551234567"),
        "the resolved recipient handle is the window 'who' title"
    );
    assert!(
        pump.tier1_mentions_persisted_count() >= 1,
        "the recipient handle was extracted into entity_mentions"
    );

    // The phone entity exists (content-stable DIGIT canonical form) and is
    // mentioned ON the outgoing Messages event.
    let phone_id = Entity::derive_id("phone", HANDLE_DIGITS);
    let entities = store.list_resolvable_entities().unwrap();
    assert!(
        entities
            .iter()
            .any(|e| e.id == phone_id && e.kind == "phone"),
        "a phone entity was extracted for the recipient handle ({entities:?})"
    );
    let cooccurrences = store.entity_cooccurrences().unwrap();
    assert!(
        cooccurrences
            .iter()
            .any(|(eid, members)| *eid == msg_id && members.contains(&phone_id)),
        "the recipient handle is mentioned on the outgoing event ({cooccurrences:?})"
    );

    // 2) ~30 s later the SAME number appears in a Safari page — production
    //    screen/page pump, SAME content-stable phone entity.
    let brain = BrainPump::new(Arc::clone(&store) as Arc<dyn BrainStore>, None);
    let page_ts = (BASE_UNIX_S as u64 + 1) * S + 30 * S; // 30 s after the text
    brain
        .ingest_ocr_event(&safari_page(page_ts, "Call Jamie back at +15551234567"))
        .expect("ingest safari page");

    // 3) Segment → resolve → consolidate, via the production workers.
    let seg_store = Arc::clone(&store);
    one_cycle(move |rx| async move {
        episode_worker::run_episode_worker(
            seg_store,
            Arc::new(HeuristicEpisodeSegmenter::new()),
            64,
            Duration::from_millis(50),
            rx,
        )
        .await
        .unwrap()
    })
    .await;

    let alias_store = Arc::clone(&store);
    one_cycle(move |rx| async move {
        alias_resolver_worker::run_alias_resolver_worker(alias_store, Duration::from_millis(50), rx)
            .await
            .unwrap()
    })
    .await;

    // The bare recipient handle anchored its OWN Person identity (Phase C).
    let memberships = store.identity_of_entity(&phone_id).unwrap();
    assert_eq!(
        memberships.len(),
        1,
        "the recipient handle resolves to exactly one identity"
    );
    let membership = &memberships[0];
    assert_eq!(
        membership.identity_kind, "person",
        "handle → Person identity"
    );
    assert_eq!(
        membership.rule, "handle_anchor",
        "anchored purely by the handle (no contact name)"
    );
    let identity = membership.identity_id.clone();

    let cons_store = Arc::clone(&store);
    let stats = one_cycle(move |rx| async move {
        consolidator_worker::run_consolidator_worker(cons_store, Duration::from_millis(50), rx)
            .await
            .unwrap()
    })
    .await;
    assert!(stats.cycles_run >= 1);
    assert_eq!(stats.store_errors, 0);
    assert!(
        stats.edges_written >= 1,
        "wrote ≥1 cross-app dot-connect edge"
    );

    // 4) THE DOT-CONNECT QUERY: recipient identity → edges → linked events.
    let edges = store.episode_edges_for_identity(&identity).unwrap();
    assert_eq!(edges.len(), 1, "exactly one cross-app link for this handle");
    assert_eq!(
        edges[0].edge_kind,
        mci_brain::EpisodeEdge::KIND_SHARED_IDENTITY
    );
    let evidence: Vec<String> =
        serde_json::from_str(edges[0].evidence_entity_ids.as_deref().unwrap()).unwrap();
    assert!(
        evidence.contains(&phone_id.0),
        "the recipient handle entity is the edge evidence ({evidence:?})"
    );

    // The connected hit holds the OUTGOING Messages event AND the Safari
    // event — "I texted them, then looked them up".
    let mut apps: Vec<String> = Vec::new();
    for ep in [edges[0].src_episode_id, edges[0].dst_episode_id] {
        for ev in store.events_in_episode(ep, 10).unwrap() {
            apps.push(ev.app_bundle_id.unwrap_or_default());
        }
    }
    assert!(
        apps.iter().any(|a| a == MESSAGES),
        "the connected hit includes the outgoing Messages event ({apps:?})"
    );
    assert!(
        apps.iter().any(|a| a == SAFARI),
        "the connected hit includes the Safari event ({apps:?})"
    );
}

/// A denylisted participant drops the WHOLE event — nothing (no handle, no
/// body, no mention) is persisted. Pins the protected-set contract that the
/// new "who" persistence rides ENTIRELY behind the cascade's drop gate.
#[tokio::test]
async fn denylisted_handle_persists_nothing() {
    let (_dir, store, _path, _key) = open_temp_store();
    let cfg = MessagesPluginConfig {
        plugin_enabled: true,
        allow_all_participants: true,
        participant_allowlist: vec![],
        participant_denylist: vec![HANDLE.to_owned()],
    };
    let pump =
        MessagesPluginPump::with_watermark(Arc::clone(&store) as Arc<dyn BrainStore>, None, cfg, 0);

    let outcome = pump
        .ingest_row(&incoming_row(1, "dinner at 7?"))
        .expect("ingest");
    assert!(
        matches!(outcome, MessagesIngestOutcome::Dropped { .. }),
        "denylisted participant ⇒ whole event dropped"
    );
    // No event, no entity, no mention for the denylisted handle.
    assert!(store.get_event(EventId(1)).unwrap().is_none());
    assert_eq!(pump.tier1_mentions_persisted_count(), 0);
    let phone_id = Entity::derive_id("phone", HANDLE_DIGITS);
    assert!(
        store.list_resolvable_entities().unwrap().is_empty(),
        "no entity persisted for a denylisted handle"
    );
    assert!(store.identity_of_entity(&phone_id).unwrap().is_empty());
}
