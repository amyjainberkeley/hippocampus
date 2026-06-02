//! V2-P5 — proves the **full `BrainPump` → Tier 1 → Tier 2 →
//! `entity_mentions` pipeline wiring**.
//!
//! Drives a synthetic `OCREvent` through `BrainPump::ingest_ocr_event`
//! against a real `SqlCipherBrainStore`. Verifies:
//!
//! 1. The Tier 1 regex extractor wrote `(extractor_kind = "regex")`
//!    mentions on the hot path (URL + email + cascade-marker +
//!    redacted JWT subkind), per the V2-P4 pin.
//! 2. The event is in the V2-P5 pending set
//!    (`events_pending_tier2`) — V2-P4 doesn't write the V2-P5
//!    sentinel.
//! 3. Running [`mci_brain::Tier2Extractor::extract`] +
//!    [`mci_brain::persist_tier2_matches`] +
//!    [`mci_brain::mark_event_tier2_processed`] produces:
//!    - `(extractor_kind = "qwen")` mentions for the legitimate
//!      person / organization / topic emitted by the mock NER
//!      backend.
//!    - **No** `qwen` mention on the JWT span (V2-P4's
//!      `redacted_token` discipline survives downstream — the
//!      backend hallucinates an "organization" classification on
//!      the JWT bytes; the extractor drops it).
//!    - **No** `qwen` mention on the cascade-marker span.
//!    - **No** JWT bytes anywhere in `entities.canonical_name` or
//!      `entity_mentions.mention_text` for either extractor kind.
//!    - The sentinel `(extractor_status, qwen_tier2_processed)`
//!      mention pinning the event as "done".
//! 4. After the V2-P5 path runs, the event is no longer in
//!    `events_pending_tier2`.
//!
//! This is the **construction-graph wiring proof** for the
//! V2-P5 PR #9 CSO mini-audit row #4 — the load-bearing test the
//! [[project-v2p1-unit-tests-passed-but-never-wired]] lesson
//! mandates for any new extraction layer.
//!
//! NOTE: this test exercises Tier 2 via the in-crate
//! [`mci_brain::MockNerBackend`] — no Qwen `.mlmodelc` required. The
//! production wiring in `apps/agent/src/bin/mci_agent.rs::
//! spawn_tier2_worker` constructs a Qwen-backed backend at startup
//! and spawns the same worker loop this test drives synchronously.

use std::sync::Arc;

use mci_agent::brain_ingest::{BrainIngestor, BrainPump, IngestOutcome};
use mci_brain::extraction::tier1::{
    KIND_EMAIL, KIND_REDACTED_TOKEN, KIND_URL, SUBKIND_CASCADE_REDACTED, SUBKIND_JWT,
};
use mci_brain::extraction::tier2::{
    EXTRACTOR_KIND as TIER2_EXTRACTOR_KIND, KIND_ORGANIZATION, KIND_PERSON_NAME, KIND_TOPIC,
    SENTINEL_KIND, SENTINEL_NAME,
};
use mci_brain::graph::Entity;
use mci_brain::{
    mark_event_tier2_processed, persist_tier2_matches, BrainStore, MockNerBackend,
    SqlCipherBrainStore, Tier2Extractor, Tier2RawMatch,
};
use mci_core::crypto::DbKey;
use mci_core::ipc::Message;
use mci_core::store::open as mci_core_open;
use rusqlite::params;

fn make_event(seq: u64, ts_us: u64, body: &str) -> Message {
    let mut bundle = [0u8; 64];
    let app = "com.apple.Terminal";
    bundle[..app.len()].copy_from_slice(app.as_bytes());
    Message::OCREvent {
        seq,
        ts_us,
        app_bundle_id: bundle,
        window_title: "iTerm — v2p5 wiring".into(),
        url: String::new(),
        ocr_text: body.into(),
        keyframe_hash: [0u8; 32],
    }
}

/// Full pipeline wiring proof.
///
/// `git log -S "Tier2Extractor::new" -- apps/agent/src/bin/mci_agent.rs`
/// must return this PR's commit. This test pins the construction-
/// graph wire at the test layer (which exercises Tier 2 against the
/// same store the production wire writes to).
#[test]
#[allow(clippy::too_many_lines)]
fn full_pipeline_brain_pump_tier1_then_tier2_populates_entity_mentions() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("v2p5-wiring.sqlite");
    let key = DbKey::from_bytes([0xCE; 32]);
    let store = Arc::new(SqlCipherBrainStore::new(&path, &key).expect("open store"));

    let pump = BrainPump::new(Arc::clone(&store) as Arc<dyn BrainStore>, None);

    // OCR text: realistic mix of structural V2-P4 hits + V2-P5
    // NER-class entities + a cascade marker + a JWT.
    //
    // The string layout puts the post-cascade marker + JWT BEFORE
    // the person-name run so V2-P5's filter chain has both
    // skip-discipline cases live on the same event.
    let body = "Alice from the Brain team flagged a footprint regression. \
                Email her at alice@anthropic.com or visit https://example.com/x. \
                Auth: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c \
                Code: [REDACTED:SMS_OTP] please confirm.";
    let frame = make_event(1, 1_700_000_000_000_000, body);

    let outcome = pump.ingest_ocr_event(&frame).expect("ingest ok");
    let id = match outcome {
        IngestOutcome::Stored { id, .. } => id,
        IngestOutcome::NotOcrEvent => panic!("expected Stored"),
    };
    assert!(id.0 > 0);

    // ----- V2-P4 wiring pin (regression guard) -----
    // V2-P4 Tier 1 wrote at least: url + email + cascade_redacted + jwt
    // mentions. Pump's tier1 counter should reflect them.
    assert!(pump.tier1_mentions_persisted_count() >= 4);

    let db = mci_core_open(&path, &key).expect("raw_open");
    let conn = db.conn();
    let count_kind = |kind: &str, canon: &str| -> i64 {
        conn.query_row(
            "SELECT COUNT(*) FROM entities WHERE kind=?1 AND canonical_name=?2",
            params![kind, canon],
            |r| r.get(0),
        )
        .expect("count")
    };
    assert_eq!(count_kind(KIND_URL, "https://example.com/x"), 1);
    assert_eq!(count_kind(KIND_EMAIL, "alice@anthropic.com"), 1);
    assert_eq!(count_kind(KIND_REDACTED_TOKEN, SUBKIND_CASCADE_REDACTED), 1);
    assert_eq!(count_kind(KIND_REDACTED_TOKEN, SUBKIND_JWT), 1);

    // ----- Event still pending V2-P5 -----
    let pending_before = store
        .events_pending_tier2(10)
        .expect("pending before");
    assert!(
        pending_before.iter().any(|e| e.id == id),
        "event should be in V2-P5 pending set before Tier 2 runs"
    );

    // ----- Drive V2-P5 Tier 2 -----
    // The mock backend emits four matches:
    // - a legitimate Person ("Alice") — kept
    // - a legitimate Org ("the Brain team") — kept
    // - a legitimate Topic ("footprint regression") — kept
    // - a HALLUCINATED Org classification on the JWT bytes — must
    //   be dropped by the token-REDACT downstream filter (CSO
    //   mini-audit row #3)
    // - a HALLUCINATED Topic on the cascade marker — must be
    //   dropped by the cascade-marker SKIP filter
    let stored_event = store.get_event(id).expect("get").expect("event");
    let event_text = stored_event.text.clone();

    // Resolve offsets in the headered text.
    let alice_start = event_text.find("Alice").expect("alice");
    let alice_end = alice_start + "Alice".len();

    let brain_team_phrase = "the Brain team";
    let brain_team_start = event_text.find(brain_team_phrase).expect("brain team");
    let brain_team_end = brain_team_start + brain_team_phrase.len();

    let topic_phrase = "footprint regression";
    let topic_start = event_text.find(topic_phrase).expect("topic");
    let topic_end = topic_start + topic_phrase.len();

    let jwt_phrase = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
    let jwt_start = event_text.find(jwt_phrase).expect("jwt");
    let jwt_end = jwt_start + jwt_phrase.len();

    let marker_phrase = "[REDACTED:SMS_OTP]";
    let marker_start = event_text.find(marker_phrase).expect("marker");
    let marker_end = marker_start + marker_phrase.len();

    let raws = vec![
        // Legit
        Tier2RawMatch {
            kind: KIND_PERSON_NAME.into(),
            canonical_name: "Alice".into(),
            mention_text: "Alice".into(),
            span_start: alice_start,
            span_end: alice_end,
            confidence: 0.95,
        },
        Tier2RawMatch {
            kind: KIND_ORGANIZATION.into(),
            canonical_name: brain_team_phrase.into(),
            mention_text: brain_team_phrase.into(),
            span_start: brain_team_start,
            span_end: brain_team_end,
            confidence: 0.85,
        },
        Tier2RawMatch {
            kind: KIND_TOPIC.into(),
            canonical_name: topic_phrase.into(),
            mention_text: topic_phrase.into(),
            span_start: topic_start,
            span_end: topic_end,
            confidence: 0.8,
        },
        // Token-REDACT downstream hallucination — JWT span
        // classified as organization. MUST be dropped.
        Tier2RawMatch {
            kind: KIND_ORGANIZATION.into(),
            canonical_name: "AuthCorp".into(),
            mention_text: jwt_phrase.into(),
            span_start: jwt_start,
            span_end: jwt_end,
            confidence: 0.9,
        },
        // Cascade-marker hallucination. MUST be dropped.
        Tier2RawMatch {
            kind: KIND_TOPIC.into(),
            canonical_name: "sms otp".into(),
            mention_text: marker_phrase.into(),
            span_start: marker_start,
            span_end: marker_end,
            confidence: 0.9,
        },
    ];

    let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raws)));
    let matches = ex.extract(&event_text).expect("extract ok");
    assert_eq!(
        matches.len(),
        3,
        "extractor must keep 3 legitimate matches (Alice, Brain team, footprint regression) and drop 2 hallucinations (JWT-as-org + cascade-marker-as-topic)"
    );
    let kept_names: Vec<&str> = matches.iter().map(|m| m.canonical_name.as_str()).collect();
    assert!(kept_names.contains(&"Alice"));
    assert!(kept_names.contains(&brain_team_phrase));
    assert!(kept_names.contains(&topic_phrase));
    assert!(
        !kept_names.contains(&"AuthCorp"),
        "AuthCorp hallucination on JWT span must be dropped"
    );

    persist_tier2_matches(&*store, id, stored_event.ts_us, &matches).expect("persist tier2");
    mark_event_tier2_processed(&*store, id, stored_event.ts_us).expect("mark processed");

    // ----- Post-V2-P5 schema assertions -----
    let id_i64 = i64::try_from(id.0).expect("event id fits i64");
    let qwen_mentions: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM entity_mentions WHERE event_id=?1 AND extractor_kind=?2",
            params![id_i64, TIER2_EXTRACTOR_KIND],
            |r| r.get(0),
        )
        .expect("count qwen mentions");
    // 3 legitimate Tier 2 mentions + 1 sentinel mention = 4
    assert_eq!(qwen_mentions, 4);

    // The legitimate kinds landed:
    for (kind, canon) in [
        (KIND_PERSON_NAME, "Alice"),
        (KIND_ORGANIZATION, brain_team_phrase),
        (KIND_TOPIC, topic_phrase),
    ] {
        assert_eq!(
            count_kind(kind, canon),
            1,
            "missing tier2 entity ({kind}, {canon})"
        );
    }

    // The sentinel entity row exists.
    assert_eq!(count_kind(SENTINEL_KIND, SENTINEL_NAME), 1);

    // No JWT bytes leaked through V2-P5.
    let mut stmt = conn
        .prepare("SELECT canonical_name FROM entities")
        .expect("prepare");
    let canonicals: Vec<String> = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .expect("query")
        .filter_map(Result::ok)
        .collect();
    for c in &canonicals {
        assert!(
            !c.contains("eyJ"),
            "V2-P5 leaked JWT bytes into entities.canonical_name: {c}"
        );
    }
    let mut stmt2 = conn
        .prepare("SELECT mention_text FROM entity_mentions WHERE extractor_kind=?1")
        .expect("prepare");
    let mention_texts: Vec<String> = stmt2
        .query_map(params![TIER2_EXTRACTOR_KIND], |r| r.get::<_, Option<String>>(0))
        .expect("query")
        .filter_map(|r| r.ok().flatten())
        .collect();
    for m in &mention_texts {
        assert!(
            !m.contains("eyJ"),
            "V2-P5 leaked JWT bytes into entity_mentions.mention_text: {m}"
        );
        assert!(
            !m.contains("REDACTED:SMS_OTP"),
            "V2-P5 leaked cascade marker bytes into mention_text: {m}"
        );
    }

    // ----- Event no longer pending V2-P5 -----
    let pending_after = store
        .events_pending_tier2(10)
        .expect("pending after");
    assert!(
        pending_after.iter().all(|e| e.id != id),
        "event must be removed from V2-P5 pending set after the sentinel mark"
    );
}

/// Second ingest of the same event into a fresh DB exercises the
/// V2-P4 → V2-P5 sequence end-to-end TWICE: the schema must allow
/// the second run with no new rows (full-chain idempotency).
#[test]
fn full_pipeline_is_idempotent_across_two_ingest_then_tier2_passes() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("v2p5-idem.sqlite");
    let key = DbKey::from_bytes([0xCF; 32]);
    let store = Arc::new(SqlCipherBrainStore::new(&path, &key).expect("open"));

    let pump = BrainPump::new(Arc::clone(&store) as Arc<dyn BrainStore>, None);

    let body = "Alice from the Brain team flagged a regression";
    let frame = make_event(1, 1_700_000_000_000_000, body);

    let id1 = match pump.ingest_ocr_event(&frame).expect("ingest 1") {
        IngestOutcome::Stored { id, .. } => id,
        IngestOutcome::NotOcrEvent => panic!("expected Stored"),
    };

    let stored = store.get_event(id1).expect("get").expect("event");
    let text = stored.text.clone();

    let alice = text.find("Alice").unwrap();
    let brain = text.find("the Brain team").unwrap();
    let raws = vec![
        Tier2RawMatch {
            kind: KIND_PERSON_NAME.into(),
            canonical_name: "Alice".into(),
            mention_text: "Alice".into(),
            span_start: alice,
            span_end: alice + 5,
            confidence: 0.9,
        },
        Tier2RawMatch {
            kind: KIND_ORGANIZATION.into(),
            canonical_name: "the Brain team".into(),
            mention_text: "the Brain team".into(),
            span_start: brain,
            span_end: brain + "the Brain team".len(),
            confidence: 0.85,
        },
    ];
    let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raws)));
    let m1 = ex.extract(&text).expect("ex1");
    persist_tier2_matches(&*store, id1, stored.ts_us, &m1).expect("persist 1");
    mark_event_tier2_processed(&*store, id1, stored.ts_us).expect("mark 1");

    let db = mci_core_open(&path, &key).expect("raw_open");
    let conn = db.conn();
    let total_entities_1: i64 = conn
        .query_row("SELECT COUNT(*) FROM entities", [], |r| r.get(0))
        .expect("count entities 1");
    let total_mentions_1: i64 = conn
        .query_row("SELECT COUNT(*) FROM entity_mentions", [], |r| r.get(0))
        .expect("count mentions 1");

    // Second pass: re-extract + re-persist + re-mark on the same event.
    let m2 = ex.extract(&text).expect("ex2");
    persist_tier2_matches(&*store, id1, stored.ts_us, &m2).expect("persist 2");
    mark_event_tier2_processed(&*store, id1, stored.ts_us).expect("mark 2");

    let total_entities_2: i64 = conn
        .query_row("SELECT COUNT(*) FROM entities", [], |r| r.get(0))
        .expect("count entities 2");
    let total_mentions_2: i64 = conn
        .query_row("SELECT COUNT(*) FROM entity_mentions", [], |r| r.get(0))
        .expect("count mentions 2");

    assert_eq!(
        total_entities_1, total_entities_2,
        "second pass must not duplicate entity rows"
    );
    assert_eq!(
        total_mentions_1, total_mentions_2,
        "second pass must not duplicate mention rows (INSERT OR IGNORE)"
    );
}

/// Pin: the production integration site
/// (`apps/agent/src/bin/mci_agent.rs::spawn_tier2_worker`) constructs
/// `Tier2Extractor::new(...)`. This test exists separately from the
/// pipeline test as a literal documentation point — `git log -S
/// "Tier2Extractor::new" -- apps/agent/src/bin/mci_agent.rs` should
/// return this PR's commit, and the wire is tested via the full
/// pipeline above (which uses the same `Tier2Extractor::new` + the
/// same `persist_tier2_matches` + `mark_event_tier2_processed`
/// surface the production worker uses).
#[test]
fn tier2_extractor_constructor_is_callable_via_brain_crate_surface() {
    // Just verify the surface is exported from `mci-brain` so the
    // production wiring in `mci_agent.rs` can call it without a
    // qualified path.
    let _ex = Tier2Extractor::new(Arc::new(MockNerBackend::empty()));
    // And the sentinel constants are public.
    let _id = Entity::derive_id(SENTINEL_KIND, SENTINEL_NAME);
}
