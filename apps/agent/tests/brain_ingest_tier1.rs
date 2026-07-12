//! V2-P4 — proves the `BrainPump` → Tier 1 extractor wiring.
//!
//! Drives a synthetic `OCREvent` through `BrainPump::ingest_ocr_event`
//! against a real `SqlCipherBrainStore` and asserts the Tier 1
//! extractor wrote the expected `entities` / `entity_mentions` rows
//! after `put_event` returned.
//!
//! This is the **construction-graph wiring proof** for the CSO
//! mini-audit row #3: the extractor is INVOKED by the Allow-arm
//! dispatch site, not just defined in the library.

use std::sync::Arc;

use mci_agent::brain_ingest::{BrainIngestor, BrainPump, IngestOutcome};
use mci_brain::extraction::tier1::{
    KIND_EMAIL, KIND_PHONE, KIND_REDACTED_TOKEN, KIND_URL, SUBKIND_CASCADE_REDACTED, SUBKIND_JWT,
};
use mci_brain::{BrainStore, SqlCipherBrainStore};
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
        window_title: "iTerm — extraction test".into(),
        url: String::new(),
        ocr_text: body.into(),
        keyframe_hash: [0u8; 32],
    }
}

#[test]
fn brain_pump_runs_tier1_after_put_event() {
    // Hermetic tempdir + test key (same pattern as chunker_event_wire.rs).
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("v2p4.sqlite");
    let key = DbKey::from_bytes([0xCC; 32]);
    let store = Arc::new(SqlCipherBrainStore::new(&path, &key).expect("open store"));

    let pump = BrainPump::new(Arc::clone(&store) as Arc<dyn BrainStore>, None);

    // The OCR text includes the literal cascade marker (post-§6
    // redaction shape), a URL, an email, and a JWT shape. The
    // extractor must:
    // - emit URL + email entities normally
    // - emit a `cascade_redacted` placeholder for the marker
    // - emit a `jwt` placeholder WITHOUT the JWT bytes
    // - emit NO `phone` entity (the digits were already redacted
    //   upstream by the cascade)
    let text = "Visit https://example.com/x, mail me at user@example.com, \
                code [REDACTED:SMS_OTP] auth eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
    let frame = make_event(1, 1_700_000_000_000_000, text);

    let outcome = pump.ingest_ocr_event(&frame).expect("ingest ok");
    let id = match outcome {
        IngestOutcome::Stored { id, .. } => id,
        IngestOutcome::NotOcrEvent => panic!("expected Stored"),
    };
    assert!(id.0 > 0, "event_id should be assigned by put_event");

    // The counter should have ticked at least once (we wrote multiple
    // mentions).
    assert!(pump.tier1_mentions_persisted_count() >= 3);

    // Read back via a fresh raw connection (graph_store.rs pattern).
    let db = mci_core_open(&path, &key).expect("raw_open");
    let conn = db.conn();

    // URL entity present.
    let url_rows: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM entities WHERE kind=?1 AND canonical_name=?2",
            params![KIND_URL, "https://example.com/x"],
            |r| r.get(0),
        )
        .expect("count url");
    assert_eq!(url_rows, 1);

    // Email entity present.
    let email_rows: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM entities WHERE kind=?1 AND canonical_name=?2",
            params![KIND_EMAIL, "user@example.com"],
            |r| r.get(0),
        )
        .expect("count email");
    assert_eq!(email_rows, 1);

    // cascade_redacted entity present (the marker itself).
    let cascade_rows: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM entities WHERE kind=?1 AND canonical_name=?2",
            params![KIND_REDACTED_TOKEN, SUBKIND_CASCADE_REDACTED],
            |r| r.get(0),
        )
        .expect("count cascade");
    assert_eq!(cascade_rows, 1);

    // jwt entity present BUT no JWT bytes anywhere in `entities` /
    // `entity_mentions`.
    let jwt_rows: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM entities WHERE kind=?1 AND canonical_name=?2",
            params![KIND_REDACTED_TOKEN, SUBKIND_JWT],
            |r| r.get(0),
        )
        .expect("count jwt");
    assert_eq!(jwt_rows, 1);

    // NO phone entity (cascade marker doesn't expose digits).
    let phone_rows: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM entities WHERE kind=?1",
            params![KIND_PHONE],
            |r| r.get(0),
        )
        .expect("count phone");
    assert_eq!(phone_rows, 0);

    // Defence-in-depth: no JWT byte sequence in any entity field.
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
            "entities.canonical_name leaked JWT bytes: {c}"
        );
    }
    let mut stmt2 = conn
        .prepare("SELECT mention_text FROM entity_mentions")
        .expect("prepare2");
    let mentions: Vec<String> = stmt2
        .query_map([], |r| r.get::<_, Option<String>>(0))
        .expect("query")
        .filter_map(|r| r.ok().flatten())
        .collect();
    for m in &mentions {
        assert!(
            !m.contains("eyJ"),
            "entity_mentions.mention_text leaked JWT bytes: {m}"
        );
    }
}

#[test]
fn brain_pump_two_ingests_same_url_yields_one_entity_two_mentions() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("v2p4-idem.sqlite");
    let key = DbKey::from_bytes([0xCD; 32]);
    let store = Arc::new(SqlCipherBrainStore::new(&path, &key).expect("open"));
    let pump = BrainPump::new(Arc::clone(&store) as Arc<dyn BrainStore>, None);

    let url = "https://example.com/dup";
    pump.ingest_ocr_event(&make_event(
        1,
        1_700_000_000_000_000,
        &format!("first {url}"),
    ))
    .expect("ingest 1");
    pump.ingest_ocr_event(&make_event(
        2,
        1_700_000_001_000_000,
        &format!("again {url}"),
    ))
    .expect("ingest 2");

    let db = mci_core_open(&path, &key).expect("raw_open");
    let conn = db.conn();

    let url_entities: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM entities WHERE kind=?1 AND canonical_name=?2",
            params![KIND_URL, url],
            |r| r.get(0),
        )
        .expect("count url entities");
    assert_eq!(
        url_entities, 1,
        "the same URL across two events must converge on ONE entity row"
    );

    let url_mentions: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM entity_mentions m
             JOIN entities e ON e.id = m.entity_id
             WHERE e.kind=?1 AND e.canonical_name=?2",
            params![KIND_URL, url],
            |r| r.get(0),
        )
        .expect("count url mentions");
    assert_eq!(
        url_mentions, 2,
        "two events must produce two mentions of the same URL entity"
    );
}
