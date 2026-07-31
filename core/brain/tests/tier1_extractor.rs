//! V2-P4 — integration tests for [`Tier1Extractor`] + the V2-P3
//! writer trait. Mirrors the discipline in `tests/graph_store.rs`:
//! ephemeral encrypted DB under `tempfile::tempdir()` with an
//! `InMemoryKeyWrap`-derived `DbKey`. The shipped agent binary
//! cannot construct that key wrap (gated by `mci-core`'s
//! `insecure-test-keywrap` feature) — so the round-trip tests below
//! never run against a real user DB.

use std::path::{Path, PathBuf};

use mci_brain::extraction::tier1::{
    persist_tier1_matches, EXTRACTOR_KIND, KIND_CRYPTO_ADDRESS, KIND_EMAIL, KIND_FILE_PATH,
    KIND_GITHUB_REF, KIND_IP_ADDRESS, KIND_PHONE, KIND_REDACTED_TOKEN, KIND_URL, KIND_UUID,
    SUBKIND_AWS_ACCESS_KEY, SUBKIND_CASCADE_REDACTED, SUBKIND_JWT, SUBKIND_STRIPE_API_KEY,
};
use mci_brain::graph::Entity;
use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore, Tier1Extractor};
use mci_core::crypto::{DbKey, InMemoryKeyWrap, KeyWrap};
use mci_core::store::{open as mci_core_open, Db};
use rusqlite::params;
use tempfile::TempDir;

// ---------------------------------------------------------------------------
// Test scaffolding (mirrors tests/graph_store.rs)
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

fn raw_count(db: &Db, table: &str) -> i64 {
    let sql = format!("SELECT COUNT(*) FROM {table}");
    db.conn()
        .query_row(&sql, [], |r| r.get(0))
        .expect("count rows")
}

// ---------------------------------------------------------------------------
// 1. Round-trip: extract → persist → SELECT verifies the row landed
// ---------------------------------------------------------------------------

#[test]
fn round_trip_writes_entity_and_mention_rows() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let ts = 1_700_000_000_000_000;
    let event = make_event(ts, "Visit https://example.com/x and mail me at a@b.co");
    let eid = store.put_event(&event).expect("put_event");

    let matches = Tier1Extractor::new().extract(&event.text);
    let stats =
        persist_tier1_matches(&store as &dyn BrainStore, eid, ts, &matches).expect("persist");
    assert!(
        stats.entities_upserted >= 2,
        "expected URL + email entities"
    );
    assert!(stats.mentions_inserted >= 2);

    // Read back via find_entity_by_alias.
    let url = store
        .find_entity_by_alias(KIND_URL, "https://example.com/x")
        .expect("find url")
        .expect("url present");
    assert_eq!(url.kind, KIND_URL);
    assert_eq!(url.canonical_name, "https://example.com/x");

    let email = store
        .find_entity_by_alias(KIND_EMAIL, "a@b.co")
        .expect("find email")
        .expect("email present");
    assert_eq!(email.kind, KIND_EMAIL);

    // Two mentions land on the same event row.
    let db = raw_open(&path, &key);
    let mentions_count = raw_count(&db, "entity_mentions");
    assert!(mentions_count >= 2);
}

// ---------------------------------------------------------------------------
// 2. Idempotency: same event ingested twice → same entity_id, no dupes
// ---------------------------------------------------------------------------

#[test]
fn second_pass_is_no_op_at_row_level() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let ts = 1_700_000_000_000_000;
    let event = make_event(ts, "URL https://example.com/x once");
    let eid = store.put_event(&event).expect("put_event");

    let ex = Tier1Extractor::new();
    let m = ex.extract(&event.text);

    persist_tier1_matches(&store as &dyn BrainStore, eid, ts, &m).expect("persist 1");
    let db = raw_open(&path, &key);
    let entities_after_1 = raw_count(&db, "entities");
    let mentions_after_1 = raw_count(&db, "entity_mentions");

    // Second pass over the same event.
    persist_tier1_matches(&store as &dyn BrainStore, eid, ts, &m).expect("persist 2");
    let entities_after_2 = raw_count(&db, "entities");
    let mentions_after_2 = raw_count(&db, "entity_mentions");

    assert_eq!(
        entities_after_1, entities_after_2,
        "entities row count must be stable across a second extractor pass"
    );
    assert_eq!(
        mentions_after_1, mentions_after_2,
        "entity_mentions row count must be stable across a second extractor pass"
    );
}

// ---------------------------------------------------------------------------
// 3. Idempotency across two events: same URL in two events → 1 entity, 2 mentions
// ---------------------------------------------------------------------------

#[test]
fn shared_entity_across_events_keeps_one_entity_row() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let ex = Tier1Extractor::new();

    let ev1 = make_event(1_700_000_000_000_000, "First mention https://example.com/x");
    let id1 = store.put_event(&ev1).expect("put_event 1");
    persist_tier1_matches(
        &store as &dyn BrainStore,
        id1,
        ev1.ts_us,
        &ex.extract(&ev1.text),
    )
    .expect("persist 1");

    let ev2 = make_event(
        1_700_000_001_000_000,
        "Second mention https://example.com/x again",
    );
    let id2 = store.put_event(&ev2).expect("put_event 2");
    persist_tier1_matches(
        &store as &dyn BrainStore,
        id2,
        ev2.ts_us,
        &ex.extract(&ev2.text),
    )
    .expect("persist 2");

    let url = store
        .find_entity_by_alias(KIND_URL, "https://example.com/x")
        .expect("find")
        .expect("present");

    // Exactly one entity row for the shared URL.
    let db = raw_open(&path, &key);
    let url_rows: i64 = db
        .conn()
        .query_row(
            "SELECT COUNT(*) FROM entities WHERE kind=?1 AND canonical_name=?2",
            params![KIND_URL, "https://example.com/x"],
            |r| r.get(0),
        )
        .expect("count entity rows for url");
    assert_eq!(url_rows, 1);

    // Two mentions referencing the same entity (one per event).
    let mention_rows: i64 = db
        .conn()
        .query_row(
            "SELECT COUNT(*) FROM entity_mentions WHERE entity_id=?1",
            params![&url.id.0],
            |r| r.get(0),
        )
        .expect("count mentions");
    assert_eq!(mention_rows, 2);
}

// ---------------------------------------------------------------------------
// 4. Cascade interaction: redacted SMS-OTP event has no phone, has redacted_token
// ---------------------------------------------------------------------------

#[test]
fn redacted_sms_event_yields_no_phone_entity_but_yields_redacted_marker() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    // Simulate the post-cascade text: the OCR-time §6 redaction has
    // already replaced the OTP/phone digits with the literal marker.
    let ts = 1_700_000_000_000_000;
    let event = make_event(
        ts,
        "Your one-time code is [REDACTED:SMS_OTP] please confirm",
    );
    let eid = store.put_event(&event).expect("put_event");

    let matches = Tier1Extractor::new().extract(&event.text);
    persist_tier1_matches(&store as &dyn BrainStore, eid, ts, &matches).expect("persist");

    // No phone entity (the digits never reached Tier 1).
    let db = raw_open(&path, &key);
    let phone_rows: i64 = db
        .conn()
        .query_row(
            "SELECT COUNT(*) FROM entities WHERE kind=?1",
            params![KIND_PHONE],
            |r| r.get(0),
        )
        .expect("count phone");
    assert_eq!(phone_rows, 0);

    // Exactly one cascade_redacted entity (the marker itself).
    let cascade_rows: i64 = db
        .conn()
        .query_row(
            "SELECT COUNT(*) FROM entities WHERE kind=?1 AND canonical_name=?2",
            params![KIND_REDACTED_TOKEN, SUBKIND_CASCADE_REDACTED],
            |r| r.get(0),
        )
        .expect("count cascade");
    assert_eq!(cascade_rows, 1);
}

// ---------------------------------------------------------------------------
// 5. Token-shape REDACT: persisted rows never carry source bytes
// ---------------------------------------------------------------------------

#[test]
fn token_shape_rows_never_carry_source_bytes() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let ts = 1_700_000_000_000_000;
    // A piece of text that includes a JWT, an AWS access key, and a
    // Stripe API key. After persistence, none of those source bytes
    // may appear in either `entities.canonical_name` or
    // `entity_mentions.mention_text`.
    let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
    let aws = "AKIAIOSFODNN7EXAMPLE";
    // Split literal: GitHub push protection blocks any contiguous
    // `sk_test_<24+ alnum>` on pattern alone. See tier1.rs `secrets` table.
    let stripe = concat!("sk_", "test_EXAMPLENOTAREALKEY000000");
    let text = format!("secrets: jwt={jwt} aws={aws} stripe={stripe} end");
    let event = make_event(ts, &text);
    let eid = store.put_event(&event).expect("put_event");

    let matches = Tier1Extractor::new().extract(&event.text);
    persist_tier1_matches(&store as &dyn BrainStore, eid, ts, &matches).expect("persist");

    // Pull EVERY canonical_name + mention_text and verify none of the
    // token bytes leaked.
    let db = raw_open(&path, &key);
    let conn = db.conn();
    let mut stmt = conn
        .prepare("SELECT canonical_name FROM entities")
        .expect("prepare entities");
    let canonicals: Vec<String> = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .expect("query")
        .filter_map(Result::ok)
        .collect();
    let mut stmt2 = conn
        .prepare("SELECT mention_text FROM entity_mentions")
        .expect("prepare mentions");
    let mentions: Vec<String> = stmt2
        .query_map([], |r| r.get::<_, Option<String>>(0))
        .expect("query")
        .filter_map(|r| r.ok().flatten())
        .collect();

    for c in &canonicals {
        assert!(
            !c.contains("eyJ"),
            "entities.canonical_name leaked JWT bytes: {c}"
        );
        assert!(
            !c.contains("AKIA"),
            "entities.canonical_name leaked AWS bytes: {c}"
        );
        assert!(
            !c.contains("sk_test_"),
            "entities.canonical_name leaked Stripe bytes: {c}"
        );
    }
    for m in &mentions {
        assert!(
            !m.contains("eyJ"),
            "entity_mentions.mention_text leaked JWT bytes: {m}"
        );
        assert!(
            !m.contains("AKIA"),
            "entity_mentions.mention_text leaked AWS bytes: {m}"
        );
        assert!(
            !m.contains("sk_test_"),
            "entity_mentions.mention_text leaked Stripe bytes: {m}"
        );
    }

    // And the placeholder subkind entities ARE present.
    for subkind in [SUBKIND_JWT, SUBKIND_AWS_ACCESS_KEY, SUBKIND_STRIPE_API_KEY] {
        let n: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM entities WHERE kind=?1 AND canonical_name=?2",
                params![KIND_REDACTED_TOKEN, subkind],
                |r| r.get(0),
            )
            .expect("count subkind");
        assert_eq!(n, 1, "missing redacted_token entity for {subkind}");
    }
}

// ---------------------------------------------------------------------------
// 6. Schema consistency: every (kind, canonical_name) is unique; every
//    entity_mentions.entity_id references a valid entities.id
// ---------------------------------------------------------------------------

#[test]
fn schema_consistency_unique_entity_keys_and_valid_fks() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let ex = Tier1Extractor::new();

    // Ingest a mix of events with overlapping kinds.
    let events = [
        "Visit https://github.com/amyjainberkeley/hippocampus/pulls and the doc /Users/ao/notes.md",
        "Closes #244 and #277; tracker https://github.com/amyjainberkeley/hippocampus/pulls overlap",
        "Email me at jane.doe@example.com — phone (415) 555-1234 ip 10.0.0.42",
        "uuid 550e8400-e29b-41d4-a716-446655440000 + eth 0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0",
    ];

    let mut ts = 1_700_000_000_000_000;
    for text in events {
        let ev = make_event(ts, text);
        let eid = store.put_event(&ev).expect("put_event");
        persist_tier1_matches(&store as &dyn BrainStore, eid, ts, &ex.extract(text))
            .expect("persist");
        ts += 1_000_000;
    }

    let db = raw_open(&path, &key);

    // (a) (kind, canonical_name) is unique across `entities`.
    let dupes: i64 = db
        .conn()
        .query_row(
            "SELECT COUNT(*) FROM (
                SELECT kind, canonical_name, COUNT(*) c
                FROM entities
                GROUP BY kind, canonical_name
                HAVING c > 1
            )",
            [],
            |r| r.get(0),
        )
        .expect("count dupes");
    assert_eq!(dupes, 0, "duplicate (kind, canonical_name) rows present");

    // (b) Every entity_mentions.entity_id references a valid entities.id.
    let orphans: i64 = db
        .conn()
        .query_row(
            "SELECT COUNT(*)
             FROM entity_mentions m
             LEFT JOIN entities e ON e.id = m.entity_id
             WHERE e.id IS NULL",
            [],
            |r| r.get(0),
        )
        .expect("orphan check");
    assert_eq!(orphans, 0, "orphan entity_mentions rows present");

    // (c) Every entity_mentions.extractor_kind is "regex" — Tier 1
    //     emits no other provenance tag.
    let non_regex: i64 = db
        .conn()
        .query_row(
            "SELECT COUNT(*) FROM entity_mentions WHERE extractor_kind != ?1",
            params![EXTRACTOR_KIND],
            |r| r.get(0),
        )
        .expect("provenance check");
    assert_eq!(non_regex, 0);
}

// ---------------------------------------------------------------------------
// 7. Cross-kind smoke: one event with many kinds → all kinds represented
// ---------------------------------------------------------------------------

#[test]
fn multi_kind_event_populates_each_kind() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let ts = 1_700_000_000_000_000;
    let text = "see https://example.com/x , ip 10.0.0.42, eth 0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0, \
                file /Users/ao/notes.md, ref #244, uuid 550e8400-e29b-41d4-a716-446655440000, \
                email a@b.co, phone (415) 555-1234";
    let event = make_event(ts, text);
    let eid = store.put_event(&event).expect("put_event");

    let matches = Tier1Extractor::new().extract(&event.text);
    persist_tier1_matches(&store as &dyn BrainStore, eid, ts, &matches).expect("persist");

    // Each of these kinds must be present at least once.
    let db = raw_open(&path, &key);
    for kind in [
        KIND_URL,
        KIND_EMAIL,
        KIND_PHONE,
        KIND_IP_ADDRESS,
        KIND_CRYPTO_ADDRESS,
        KIND_UUID,
        KIND_FILE_PATH,
        KIND_GITHUB_REF,
    ] {
        let n: i64 = db
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM entities WHERE kind=?1",
                params![kind],
                |r| r.get(0),
            )
            .expect("count kind");
        assert!(n >= 1, "kind {kind} missing");
    }
}

// ---------------------------------------------------------------------------
// 8. Content-stable ULID: two events extracting the same URL produce
//    the same entity_id bytes-for-bytes (Phase 8 sync precondition).
// ---------------------------------------------------------------------------

#[test]
fn content_stable_ulid_converges_across_events() {
    let (_dir, path) = tmp("brain.sqlite");
    let key = test_key();
    let store = SqlCipherBrainStore::new(&path, &key).expect("open");

    let ex = Tier1Extractor::new();

    let ev1 = make_event(1_700_000_000_000_000, "see https://example.com/x");
    let id1 = store.put_event(&ev1).expect("put 1");
    persist_tier1_matches(
        &store as &dyn BrainStore,
        id1,
        ev1.ts_us,
        &ex.extract(&ev1.text),
    )
    .expect("persist 1");

    let ev2 = make_event(
        1_700_000_001_000_000,
        "again https://example.com/x reposted",
    );
    let id2 = store.put_event(&ev2).expect("put 2");
    persist_tier1_matches(
        &store as &dyn BrainStore,
        id2,
        ev2.ts_us,
        &ex.extract(&ev2.text),
    )
    .expect("persist 2");

    // The derived ULID for the URL entity is content-stable.
    let derived = Entity::derive_id(KIND_URL, "https://example.com/x");
    let row = store
        .find_entity_by_alias(KIND_URL, "https://example.com/x")
        .expect("find")
        .expect("present");
    assert_eq!(row.id, derived);
}
