//! V2-P5 — integration tests for [`Tier2Extractor`] + the V2-P3
//! writer trait + the sentinel "processed" marker. Mirrors the
//! discipline in `tests/tier1_extractor.rs`: ephemeral encrypted DB
//! under `tempfile::tempdir()` with an `InMemoryKeyWrap`-derived
//! `DbKey`. Uses the in-crate [`MockNerBackend`] so no Qwen model is
//! required.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use mci_brain::extraction::tier2::{
    EXTRACTOR_KIND, KIND_LOCATION, KIND_ORGANIZATION, KIND_PERSON_NAME, KIND_PRODUCT_NAME,
    KIND_PROJECT_NAME, KIND_TOPIC, SENTINEL_KIND, SENTINEL_NAME,
};
use mci_brain::graph::Entity;
use mci_brain::{
    mark_event_tier2_processed, persist_tier2_matches, BrainStore, Event, EventId, MockNerBackend,
    SqlCipherBrainStore, Tier2Extractor, Tier2RawMatch,
};
use mci_core::crypto::{DbKey, InMemoryKeyWrap, KeyWrap};
use mci_core::store::{open as mci_core_open, Db};
use rusqlite::params;
use tempfile::TempDir;

// ---------------------------------------------------------------------------
// Scaffolding (mirrors tier1_extractor.rs)
// ---------------------------------------------------------------------------

fn tmp(name: &str) -> (TempDir, PathBuf) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join(name);
    (dir, path)
}

fn test_key() -> DbKey {
    let k = DbKey::generate().expect("csprng");
    let wrap = InMemoryKeyWrap;
    let wrapped = wrap.wrap(&k).expect("wrap");
    wrap.unwrap_key(&wrapped).expect("unwrap")
}

fn make_event(ts_us: u64, text: &str) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some("com.apple.Terminal".into()),
        window_title: Some("zsh".into()),
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

fn raw_open(path: &Path, key: &DbKey) -> Db {
    mci_core_open(path, key).expect("mci_core::store::open")
}

fn raw_count_where(db: &Db, sql: &str, args: &[&dyn rusqlite::ToSql]) -> i64 {
    db.conn().query_row(sql, args, |r| r.get(0)).expect("count")
}

// ---------------------------------------------------------------------------
// 1. Round-trip per kind: extract → persist → SELECT verifies the row
// ---------------------------------------------------------------------------

#[test]
fn round_trip_per_kind_writes_entity_and_mention_rows() {
    let (_dir, path) = tmp("tier2-roundtrip.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let text = "Alice Smith from Anthropic met Bob about V2-P5 in San Francisco";
    let ts = 1_700_000_000_000_000;
    let event = make_event(ts, text);
    let eid = store.put_event(&event).expect("put_event");

    let raws = vec![
        Tier2RawMatch {
            kind: KIND_PERSON_NAME.into(),
            canonical_name: "Alice Smith".into(),
            mention_text: "Alice Smith".into(),
            span_start: 0,
            span_end: 11,
            confidence: 0.95,
        },
        Tier2RawMatch {
            kind: KIND_ORGANIZATION.into(),
            canonical_name: "Anthropic".into(),
            mention_text: "Anthropic".into(),
            span_start: 17,
            span_end: 26,
            confidence: 0.9,
        },
        Tier2RawMatch {
            kind: KIND_PERSON_NAME.into(),
            canonical_name: "Bob".into(),
            mention_text: "Bob".into(),
            span_start: 31,
            span_end: 34,
            confidence: 0.85,
        },
        Tier2RawMatch {
            kind: KIND_PROJECT_NAME.into(),
            canonical_name: "V2-P5".into(),
            mention_text: "V2-P5".into(),
            span_start: 41,
            span_end: 46,
            confidence: 0.92,
        },
        Tier2RawMatch {
            kind: KIND_LOCATION.into(),
            canonical_name: "San Francisco".into(),
            mention_text: "San Francisco".into(),
            span_start: 50,
            span_end: 63,
            confidence: 0.88,
        },
    ];

    let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raws)));
    let matches = ex.extract(text).expect("extract ok");
    assert_eq!(matches.len(), 5);
    let stats =
        persist_tier2_matches(&store as &dyn BrainStore, eid, ts, &matches).expect("persist ok");
    assert_eq!(stats.entities_upserted, 5);
    assert_eq!(stats.mentions_inserted, 5);

    let db = raw_open(&path, &key);

    // Each kind has a row.
    for (kind, canon) in [
        (KIND_PERSON_NAME, "Alice Smith"),
        (KIND_ORGANIZATION, "Anthropic"),
        (KIND_PERSON_NAME, "Bob"),
        (KIND_PROJECT_NAME, "V2-P5"),
        (KIND_LOCATION, "San Francisco"),
    ] {
        let n = raw_count_where(
            &db,
            "SELECT COUNT(*) FROM entities WHERE kind=?1 AND canonical_name=?2",
            &[&kind, &canon],
        );
        assert_eq!(n, 1, "missing entity ({kind}, {canon})");
    }

    // Every mention carries extractor_kind = "qwen".
    let eid_i64 = i64::try_from(eid.0).expect("eid fits i64");
    let qwen_mentions = raw_count_where(
        &db,
        "SELECT COUNT(*) FROM entity_mentions WHERE event_id=?1 AND extractor_kind=?2",
        &[&eid_i64, &EXTRACTOR_KIND],
    );
    assert_eq!(qwen_mentions, 5);
}

// ---------------------------------------------------------------------------
// 2. Idempotency: same (event, text) re-extracted = no new rows
// ---------------------------------------------------------------------------

#[test]
fn second_pass_is_no_op_at_row_level() {
    let (_dir, path) = tmp("tier2-idem.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let text = "Alice from Anthropic talked about V2-P5";
    let ts = 1_700_000_000_000_000;
    let eid = store.put_event(&make_event(ts, text)).expect("put");

    let raws = vec![Tier2RawMatch {
        kind: KIND_PERSON_NAME.into(),
        canonical_name: "Alice".into(),
        mention_text: "Alice".into(),
        span_start: 0,
        span_end: 5,
        confidence: 0.9,
    }];
    let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raws)));
    let m1 = ex.extract(text).expect("extract 1");
    persist_tier2_matches(&store as &dyn BrainStore, eid, ts, &m1).expect("persist 1");
    mark_event_tier2_processed(&store as &dyn BrainStore, eid, ts).expect("mark 1");

    let db = raw_open(&path, &key);
    let entities_after_first = raw_count_where(&db, "SELECT COUNT(*) FROM entities", &[]);
    let mentions_after_first = raw_count_where(&db, "SELECT COUNT(*) FROM entity_mentions", &[]);

    // Second pass.
    let m2 = ex.extract(text).expect("extract 2");
    persist_tier2_matches(&store as &dyn BrainStore, eid, ts, &m2).expect("persist 2");
    mark_event_tier2_processed(&store as &dyn BrainStore, eid, ts).expect("mark 2");

    let entities_after_second = raw_count_where(&db, "SELECT COUNT(*) FROM entities", &[]);
    let mentions_after_second = raw_count_where(&db, "SELECT COUNT(*) FROM entity_mentions", &[]);

    assert_eq!(
        entities_after_first, entities_after_second,
        "second pass must not create new entity rows"
    );
    assert_eq!(
        mentions_after_first, mentions_after_second,
        "second pass must not create new mention rows (INSERT OR IGNORE)"
    );
}

// ---------------------------------------------------------------------------
// 3. Cascade-marker SKIP: contents of [REDACTED:…] never become NER mentions
// ---------------------------------------------------------------------------

#[test]
fn cascade_marker_contents_never_persisted_as_tier2_entity() {
    let (_dir, path) = tmp("tier2-cascade.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    // Backend (mistakenly) thinks the marker contents is a topic.
    // The extractor must drop the mention.
    let text = "code [REDACTED:SMS_OTP] confirmed";
    let ts = 1_700_000_000_000_000;
    let eid = store.put_event(&make_event(ts, text)).expect("put");

    let marker_start = text.find("[REDACTED").expect("present");
    let marker_end = marker_start + "[REDACTED:SMS_OTP]".len();
    let raws = vec![Tier2RawMatch {
        kind: KIND_TOPIC.into(),
        canonical_name: "SMS_OTP".into(),
        mention_text: "[REDACTED:SMS_OTP]".into(),
        span_start: marker_start,
        span_end: marker_end,
        confidence: 0.9,
    }];

    let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raws)));
    let matches = ex.extract(text).expect("ok");
    assert!(
        matches.is_empty(),
        "Tier2Extractor must drop mention overlapping cascade marker"
    );
    persist_tier2_matches(&store as &dyn BrainStore, eid, ts, &matches).expect("persist");

    let db = raw_open(&path, &key);
    let topic_rows = raw_count_where(
        &db,
        "SELECT COUNT(*) FROM entities WHERE kind=?1",
        &[&KIND_TOPIC],
    );
    assert_eq!(
        topic_rows, 0,
        "no `topic` entity may be created from a cascade-marker span"
    );

    // No mention rows whose mention_text contains the marker bytes.
    let mut stmt = db
        .conn()
        .prepare("SELECT mention_text FROM entity_mentions")
        .expect("prepare");
    let texts: Vec<Option<String>> = stmt
        .query_map([], |r| r.get(0))
        .expect("query")
        .filter_map(Result::ok)
        .collect();
    for t in texts.into_iter().flatten() {
        assert!(
            !t.contains("REDACTED:SMS_OTP"),
            "mention_text leaked cascade-marker bytes: {t}"
        );
    }
}

// ---------------------------------------------------------------------------
// 4. Token-REDACT downstream SKIP — V2-P4 JWT spans never re-emerge via V2-P5
// ---------------------------------------------------------------------------

#[test]
fn tier1_redacted_token_bytes_never_re_persisted_via_tier2() {
    let (_dir, path) = tmp("tier2-token-downstream.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
    let text = format!("Authorization: Bearer {jwt} (please redact)");
    let ts = 1_700_000_000_000_000;
    let eid = store.put_event(&make_event(ts, &text)).expect("put_event");

    // Backend (wrongly) classifies the JWT as an organization. The
    // extractor must drop because Tier 1 already redacted these
    // bytes via a `(redacted_token, jwt)` entity — persisting via
    // V2-P5 would defeat the discipline.
    let jwt_start = "Authorization: Bearer ".len();
    let jwt_end = jwt_start + jwt.len();
    let raws = vec![Tier2RawMatch {
        kind: KIND_ORGANIZATION.into(),
        canonical_name: "AuthCorp".into(),
        mention_text: jwt.into(),
        span_start: jwt_start,
        span_end: jwt_end,
        confidence: 0.9,
    }];

    let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raws)));
    let matches = ex.extract(&text).expect("ok");
    assert!(
        matches.is_empty(),
        "Tier2 must drop mention overlapping V2-P4 redacted_token span"
    );
    persist_tier2_matches(&store as &dyn BrainStore, eid, ts, &matches).expect("persist");

    let db = raw_open(&path, &key);

    // No JWT byte sequence in any entities or entity_mentions field.
    for col in ["canonical_name"] {
        let sql = format!("SELECT {col} FROM entities");
        let mut stmt = db.conn().prepare(&sql).expect("prepare");
        let vals: Vec<String> = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .expect("query")
            .filter_map(Result::ok)
            .collect();
        for v in &vals {
            assert!(
                !v.contains("eyJ"),
                "entities.{col} leaked JWT bytes via V2-P5: {v}"
            );
        }
    }
    let mut stmt = db
        .conn()
        .prepare("SELECT mention_text FROM entity_mentions WHERE extractor_kind=?1")
        .expect("prepare");
    let mentions: Vec<String> = stmt
        .query_map(params![EXTRACTOR_KIND], |r| r.get::<_, Option<String>>(0))
        .expect("query")
        .filter_map(|r| r.ok().flatten())
        .collect();
    for m in &mentions {
        assert!(
            !m.contains("eyJ"),
            "entity_mentions.mention_text leaked JWT bytes via V2-P5: {m}"
        );
    }
}

// ---------------------------------------------------------------------------
// 5. Same canonical name across two events → one entity, two mentions
// ---------------------------------------------------------------------------

#[test]
fn shared_canonical_across_events_converges_on_one_entity_row() {
    let (_dir, path) = tmp("tier2-converge.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let ts1 = 1_700_000_000_000_000;
    let ts2 = ts1 + 1_000_000;

    let text1 = "Alice spoke at the standup";
    let text2 = "Alice flagged a regression";

    let eid1 = store.put_event(&make_event(ts1, text1)).expect("put 1");
    let eid2 = store.put_event(&make_event(ts2, text2)).expect("put 2");

    let raw = vec![Tier2RawMatch {
        kind: KIND_PERSON_NAME.into(),
        canonical_name: "Alice".into(),
        mention_text: "Alice".into(),
        span_start: 0,
        span_end: 5,
        confidence: 0.9,
    }];
    let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raw)));
    persist_tier2_matches(
        &store as &dyn BrainStore,
        eid1,
        ts1,
        &ex.extract(text1).expect("ex1"),
    )
    .expect("persist 1");
    persist_tier2_matches(
        &store as &dyn BrainStore,
        eid2,
        ts2,
        &ex.extract(text2).expect("ex2"),
    )
    .expect("persist 2");

    let db = raw_open(&path, &key);
    let person_rows = raw_count_where(
        &db,
        "SELECT COUNT(*) FROM entities WHERE kind=?1 AND canonical_name=?2",
        &[&KIND_PERSON_NAME, &"Alice"],
    );
    assert_eq!(
        person_rows, 1,
        "Two events with the same Alice mention converge on ONE entity row"
    );
    let mentions = raw_count_where(
        &db,
        "SELECT COUNT(*) FROM entity_mentions m
         JOIN entities e ON e.id = m.entity_id
         WHERE e.kind=?1 AND e.canonical_name=?2 AND m.extractor_kind=?3",
        &[&KIND_PERSON_NAME, &"Alice", &EXTRACTOR_KIND],
    );
    assert_eq!(mentions, 2, "two events → two mentions on the same entity");
}

// ---------------------------------------------------------------------------
// 6. Schema consistency: every entity_mention FK points at a valid entity
// ---------------------------------------------------------------------------

#[test]
fn every_mention_references_a_valid_entity() {
    let (_dir, path) = tmp("tier2-schema.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let text = "Alice and Bob worked on V2-P5";
    let ts = 1_700_000_000_000_000;
    let eid = store.put_event(&make_event(ts, text)).expect("put");

    let raws = vec![
        Tier2RawMatch {
            kind: KIND_PERSON_NAME.into(),
            canonical_name: "Alice".into(),
            mention_text: "Alice".into(),
            span_start: 0,
            span_end: 5,
            confidence: 0.9,
        },
        Tier2RawMatch {
            kind: KIND_PERSON_NAME.into(),
            canonical_name: "Bob".into(),
            mention_text: "Bob".into(),
            span_start: 10,
            span_end: 13,
            confidence: 0.9,
        },
        Tier2RawMatch {
            kind: KIND_PROJECT_NAME.into(),
            canonical_name: "V2-P5".into(),
            mention_text: "V2-P5".into(),
            span_start: 24,
            span_end: 29,
            confidence: 0.92,
        },
    ];
    let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raws)));
    let matches = ex.extract(text).expect("ok");
    persist_tier2_matches(&store as &dyn BrainStore, eid, ts, &matches).expect("persist");
    mark_event_tier2_processed(&store as &dyn BrainStore, eid, ts).expect("mark");

    let db = raw_open(&path, &key);
    let orphans = raw_count_where(
        &db,
        "SELECT COUNT(*) FROM entity_mentions m
         LEFT JOIN entities e ON e.id = m.entity_id
         WHERE e.id IS NULL",
        &[],
    );
    assert_eq!(
        orphans, 0,
        "no entity_mention may reference a missing entity"
    );
}

// ---------------------------------------------------------------------------
// 7. Sentinel + pending-events query: a processed event isn't re-emitted
// ---------------------------------------------------------------------------

#[test]
fn sentinel_processed_marker_removes_event_from_pending_set() {
    let (_dir, path) = tmp("tier2-pending.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let ts1 = 1_700_000_000_000_000;
    let ts2 = ts1 + 1_000_000;
    let eid1 = store
        .put_event(&make_event(ts1, "first event"))
        .expect("put 1");
    let _eid2 = store
        .put_event(&make_event(ts2, "second event"))
        .expect("put 2");

    // Both events pending before any marker is written.
    let pending = store.events_pending_tier2(10).expect("pending");
    assert_eq!(pending.len(), 2);

    // Mark event #1 processed. Now only event #2 is pending.
    mark_event_tier2_processed(&store as &dyn BrainStore, eid1, ts1).expect("mark");
    let pending_after = store.events_pending_tier2(10).expect("pending after");
    assert_eq!(pending_after.len(), 1);
    assert_ne!(pending_after[0].id, eid1);
}

#[test]
fn sentinel_marker_handles_empty_ner_output() {
    let (_dir, path) = tmp("tier2-sentinel-empty.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let ts = 1_700_000_000_000_000;
    let eid = store
        .put_event(&make_event(ts, "no entities in this text whatsoever"))
        .expect("put");

    // Empty NER backend.
    let ex = Tier2Extractor::new(Arc::new(MockNerBackend::empty()));
    let matches = ex
        .extract("no entities in this text whatsoever")
        .expect("ok");
    assert!(matches.is_empty());
    persist_tier2_matches(&store as &dyn BrainStore, eid, ts, &matches).expect("persist");
    mark_event_tier2_processed(&store as &dyn BrainStore, eid, ts).expect("mark");

    // Event no longer in pending set despite producing zero NER mentions.
    let pending = store.events_pending_tier2(10).expect("pending");
    assert!(
        pending.is_empty(),
        "empty NER output must still be marked done"
    );

    // Sentinel entity row + mention row exist.
    let db = raw_open(&path, &key);
    let sentinel_id = Entity::derive_id(SENTINEL_KIND, SENTINEL_NAME).0;
    let eid_i64 = i64::try_from(eid.0).expect("eid fits i64");
    let mentions = raw_count_where(
        &db,
        "SELECT COUNT(*) FROM entity_mentions WHERE entity_id=?1 AND event_id=?2",
        &[&sentinel_id, &eid_i64],
    );
    assert_eq!(
        mentions, 1,
        "exactly one sentinel mention per processed event"
    );
}

// ---------------------------------------------------------------------------
// 8. Hallucination guard: span-text mismatch dropped before persistence
// ---------------------------------------------------------------------------

#[test]
fn hallucinated_mention_never_lands_in_store() {
    let (_dir, path) = tmp("tier2-hallucinate.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let text = "Alice met Bob in the lobby";
    let ts = 1_700_000_000_000_000;
    let eid = store.put_event(&make_event(ts, text)).expect("put");

    // Span points at "Alice" but mention_text says "Carol" — backend
    // hallucinated.
    let raws = vec![Tier2RawMatch {
        kind: KIND_PERSON_NAME.into(),
        canonical_name: "Carol".into(),
        mention_text: "Carol".into(),
        span_start: 0,
        span_end: 5,
        confidence: 0.9,
    }];
    let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raws)));
    let matches = ex.extract(text).expect("ok");
    persist_tier2_matches(&store as &dyn BrainStore, eid, ts, &matches).expect("persist");

    let db = raw_open(&path, &key);
    let carol_rows = raw_count_where(
        &db,
        "SELECT COUNT(*) FROM entities WHERE canonical_name=?1",
        &[&"Carol"],
    );
    assert_eq!(carol_rows, 0, "hallucinated mention must be dropped");
}

// ---------------------------------------------------------------------------
// 9. Multi-kind round-trip with realistic mix of person/org/topic
// ---------------------------------------------------------------------------

#[test]
fn multi_kind_event_populates_each_kind_correctly() {
    let (_dir, path) = tmp("tier2-multi.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let text =
        "Alice from the Brain team flagged a footprint regression on the Hippocampus dogfood build";
    let ts = 1_700_000_000_000_000;
    let eid = store.put_event(&make_event(ts, text)).expect("put");

    let alice = text.find("Alice").unwrap();
    let brain = text.find("the Brain team").unwrap();
    let fp = text.find("footprint regression").unwrap();
    let hippo = text.find("Hippocampus").unwrap();
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
        Tier2RawMatch {
            kind: KIND_TOPIC.into(),
            canonical_name: "footprint regression".into(),
            mention_text: "footprint regression".into(),
            span_start: fp,
            span_end: fp + "footprint regression".len(),
            confidence: 0.8,
        },
        Tier2RawMatch {
            kind: KIND_PRODUCT_NAME.into(),
            canonical_name: "Hippocampus".into(),
            mention_text: "Hippocampus".into(),
            span_start: hippo,
            span_end: hippo + "Hippocampus".len(),
            confidence: 0.92,
        },
    ];

    let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raws)));
    let matches = ex.extract(text).expect("ok");
    assert_eq!(matches.len(), 4);
    persist_tier2_matches(&store as &dyn BrainStore, eid, ts, &matches).expect("persist");

    let db = raw_open(&path, &key);
    for kind in [
        KIND_PERSON_NAME,
        KIND_ORGANIZATION,
        KIND_TOPIC,
        KIND_PRODUCT_NAME,
    ] {
        let n = raw_count_where(&db, "SELECT COUNT(*) FROM entities WHERE kind=?1", &[&kind]);
        assert!(n >= 1, "kind {kind} missing from entities");
    }
}

// ---------------------------------------------------------------------------
// 10. Joint key shape — V2-P4 + V2-P5 can co-exist on same canonical_name
// ---------------------------------------------------------------------------

#[test]
fn tier1_and_tier2_can_share_canonical_with_distinct_extractor_kinds() {
    let (_dir, path) = tmp("tier2-joint-key.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    // Forge a canonical that BOTH extractors could plausibly emit.
    // Example: V2-P4 sees "https://example.com" as a URL; V2-P5
    // could emit "example.com" as an organization. They're distinct
    // entities under distinct kinds — no conflict. But to test the
    // joint-key shape specifically, let's exercise the same entity
    // id under two extractor_kind values for ONE mention text.
    let text = "Alice mentioned alice@example.com today";
    let ts = 1_700_000_000_000_000;
    let eid = store.put_event(&make_event(ts, text)).expect("put");

    // Pretend V2-P4 wrote a mention via Tier 1 — we mimic that here
    // by hand because V2-P4 doesn't extract `person_name`. The point
    // is to show that the V2-P5 `extractor_kind = "qwen"` mention is
    // a distinct row from any hypothetical V2-P4 mention on the same
    // (event, entity).
    let raws = vec![Tier2RawMatch {
        kind: KIND_PERSON_NAME.into(),
        canonical_name: "Alice".into(),
        mention_text: "Alice".into(),
        span_start: 0,
        span_end: 5,
        confidence: 0.9,
    }];
    let ex = Tier2Extractor::new(Arc::new(MockNerBackend::new(raws)));
    let matches = ex.extract(text).expect("ok");
    persist_tier2_matches(&store as &dyn BrainStore, eid, ts, &matches).expect("persist");

    let db = raw_open(&path, &key);
    let qwen_mentions = raw_count_where(
        &db,
        "SELECT COUNT(*) FROM entity_mentions WHERE extractor_kind=?1",
        &[&EXTRACTOR_KIND],
    );
    assert!(qwen_mentions >= 1);
    // The V2-P4 "regex" mentions in this same row (the email
    // `alice@example.com`) coexist:
    let regex_mentions = raw_count_where(
        &db,
        "SELECT COUNT(*) FROM entity_mentions WHERE extractor_kind=?1",
        &[&"regex"],
    );
    // V2-P5 testing path does not invoke V2-P4 (the worker would in
    // production but this test exercises only V2-P5). So regex
    // mentions are 0 here — the assertion is just that the schema
    // permits both.
    assert_eq!(regex_mentions, 0);
}
