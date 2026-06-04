//! V2-P5+ P4 — **construction-graph wiring proof** for the SYNC BERT NER
//! tier (`[[project-v2p1-unit-tests-passed-but-never-wired]]` gate).
//!
//! Unlike the Qwen tier (driven externally by `tier2_worker`), the BERT
//! tier runs **inline inside `BrainPump::ingest_ocr_event`**. So this test
//! drives the REAL production code path: build a pump with
//! `with_ner_sync(<backend>)` over a real `SqlCipherBrainStore`, push one
//! `OCREvent` through `ingest_ocr_event`, and assert the brain ends up with:
//!
//! 1. `extractor_kind = "ner"` mentions for the legitimate Person / Org /
//!    Location the backend surfaced (the wire is live, not dead code).
//! 2. The `(extractor_status, ner_sync_processed)` sentinel mention — the
//!    second, distinct watermark (the Qwen `qwen_tier2_processed` sentinel
//!    is NOT written, proving two-sentinel independence).
//! 3. **No** `ner` mention on the JWT span (V2-P4 `redacted_token`
//!    downstream SKIP survives the new tier) and **no** `ner` mention on
//!    the cascade-marker span (cascade-marker SKIP) — and no JWT bytes
//!    anywhere in `entities.canonical_name` / `entity_mentions.mention_text`.
//! 4. The pump's content-free `ner_sync_mentions_persisted_count()` counter
//!    reflects exactly the legitimate mentions.
//!
//! The production wiring in `apps/agent/src/bin/mci_agent.rs`
//! (`load_ner_sync_backend` → `BrainPump::with_ner_sync`) installs the real
//! `NerTier2Backend` (Core ML, `cpu_only`); this test installs a
//! deterministic substring backend so the wire is provable in CI without a
//! `.mlmodelc`. `git grep NerTier2Backend -- apps/agent/src/bin/mci_agent.rs`
//! returns the production caller.

use std::sync::Arc;

use mci_agent::brain_ingest::{BrainIngestor, BrainPump, IngestOutcome};
use mci_brain::extraction::tier2::{
    EXTRACTOR_KIND_NER, KIND_LOCATION, KIND_ORGANIZATION, KIND_PERSON_NAME, SENTINEL_KIND,
    SENTINEL_NAME, SENTINEL_NAME_NER,
};
use mci_brain::{BrainStore, NerBackend, NerError, SqlCipherBrainStore, Tier2RawMatch};
use mci_core::crypto::DbKey;
use mci_core::ipc::Message;
use mci_core::store::open as mci_core_open;
use rusqlite::params;

/// Deterministic test backend that locates a fixed set of entities by
/// substring in whatever (headered) text the pump passes it — mirroring how
/// a real NER backend surfaces entities regardless of the context header
/// `BrainPump` prepends. Avoids hard-coding header-dependent byte offsets.
#[derive(Debug)]
struct SubstringNerBackend {
    /// `(kind, canonical_name, needle, confidence)`
    specs: Vec<(&'static str, &'static str, String, f32)>,
}

impl NerBackend for SubstringNerBackend {
    fn extract_entities(&self, text: &str) -> Result<Vec<Tier2RawMatch>, NerError> {
        if text.trim().is_empty() {
            return Err(NerError::InvalidInput("empty".into()));
        }
        let mut out = Vec::new();
        for (kind, canonical, needle, conf) in &self.specs {
            if let Some(pos) = text.find(needle.as_str()) {
                out.push(Tier2RawMatch {
                    kind: (*kind).to_string(),
                    canonical_name: (*canonical).to_string(),
                    mention_text: needle.clone(),
                    span_start: pos,
                    span_end: pos + needle.len(),
                    confidence: *conf,
                });
            }
        }
        Ok(out)
    }
}

fn make_event(seq: u64, ts_us: u64, body: &str) -> Message {
    let mut bundle = [0u8; 64];
    let app = "com.apple.Terminal";
    bundle[..app.len()].copy_from_slice(app.as_bytes());
    Message::OCREvent {
        seq,
        ts_us,
        app_bundle_id: bundle,
        window_title: "iTerm — v2p5+ sync-ner wiring".into(),
        url: String::new(),
        ocr_text: body.into(),
        keyframe_hash: [0u8; 32],
    }
}

#[test]
#[allow(clippy::too_many_lines)]
fn sync_ner_wired_into_ingest_writes_ner_mentions_and_sentinel() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("v2p5p4-sync-ner.sqlite");
    let key = DbKey::from_bytes([0xCE; 32]);
    let store = Arc::new(SqlCipherBrainStore::new(&path, &key).expect("open store"));

    let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
    let body = format!(
        "Alice from the Brain team flagged a footprint regression in San Francisco. \
         Auth: Bearer {jwt} \
         Code: [REDACTED:SMS_OTP] please confirm."
    );

    // The injected backend surfaces 3 legitimate entities + 2 that the
    // Tier2Extractor filter chain MUST drop (a hallucinated org on the JWT
    // bytes → token-REDACT downstream SKIP; a hallucinated location on the
    // cascade marker → cascade-marker SKIP).
    let backend = SubstringNerBackend {
        specs: vec![
            (KIND_PERSON_NAME, "Alice", "Alice".to_string(), 0.95),
            (
                KIND_ORGANIZATION,
                "the Brain team",
                "the Brain team".to_string(),
                0.9,
            ),
            (
                KIND_LOCATION,
                "San Francisco",
                "San Francisco".to_string(),
                0.9,
            ),
            // dropped: JWT-as-org (redacted_token overlap)
            (KIND_ORGANIZATION, "AuthCorp", jwt.to_string(), 0.9),
            // dropped: cascade-marker-as-location
            (
                KIND_LOCATION,
                "SecretPlace",
                "[REDACTED:SMS_OTP]".to_string(),
                0.9,
            ),
        ],
    };

    let pump = BrainPump::new(Arc::clone(&store) as Arc<dyn BrainStore>, None)
        .with_ner_sync(Arc::new(backend));
    assert!(pump.ner_sync_enabled(), "sync NER must be installed");

    let frame = make_event(1, 1_700_000_000_000_000, &body);
    let id = match pump.ingest_ocr_event(&frame).expect("ingest ok") {
        IngestOutcome::Stored { id, .. } => id,
        IngestOutcome::NotOcrEvent => panic!("expected Stored"),
    };
    assert!(id.0 > 0);

    // The wire ran inline during ingest: 3 legitimate 'ner' mentions.
    assert_eq!(
        pump.ner_sync_mentions_persisted_count(),
        3,
        "sync NER should have persisted exactly the 3 legitimate mentions"
    );

    let db = mci_core_open(&path, &key).expect("raw open");
    let conn = db.conn();
    let id_i64 = i64::try_from(id.0).expect("id fits i64");

    let count_entity = |kind: &str, canon: &str| -> i64 {
        conn.query_row(
            "SELECT COUNT(*) FROM entities WHERE kind=?1 AND canonical_name=?2",
            params![kind, canon],
            |r| r.get(0),
        )
        .expect("count entity")
    };

    // 'ner' mentions on the event: 3 legitimate + 1 sentinel = 4.
    let ner_mentions: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM entity_mentions WHERE event_id=?1 AND extractor_kind=?2",
            params![id_i64, EXTRACTOR_KIND_NER],
            |r| r.get(0),
        )
        .expect("count ner mentions");
    assert_eq!(
        ner_mentions, 4,
        "expected 3 legit 'ner' mentions + 1 sentinel mention"
    );

    // Legitimate entities landed with the right kinds.
    assert_eq!(count_entity(KIND_PERSON_NAME, "Alice"), 1);
    assert_eq!(count_entity(KIND_ORGANIZATION, "the Brain team"), 1);
    assert_eq!(count_entity(KIND_LOCATION, "San Francisco"), 1);

    // The sync-NER sentinel exists; the Qwen sentinel does NOT (two-sentinel
    // independence — the async tier has not run on this event).
    assert_eq!(count_entity(SENTINEL_KIND, SENTINEL_NAME_NER), 1);
    assert_eq!(
        count_entity(SENTINEL_KIND, SENTINEL_NAME),
        0,
        "Qwen sentinel must NOT be written by the sync BERT tier"
    );

    // Hallucinated org on the JWT was dropped (no AuthCorp entity).
    assert_eq!(
        count_entity(KIND_ORGANIZATION, "AuthCorp"),
        0,
        "JWT-as-org hallucination must be dropped by token-REDACT downstream SKIP"
    );
    // Hallucinated location on the cascade marker was dropped.
    assert_eq!(
        count_entity(KIND_LOCATION, "SecretPlace"),
        0,
        "cascade-marker hallucination must be dropped by cascade-marker SKIP"
    );

    // No JWT bytes leaked anywhere via the NER tier.
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
            "JWT bytes leaked into entities.canonical_name: {c}"
        );
    }
    let mut stmt2 = conn
        .prepare("SELECT mention_text FROM entity_mentions WHERE extractor_kind=?1")
        .expect("prepare");
    let texts: Vec<String> = stmt2
        .query_map(params![EXTRACTOR_KIND_NER], |r| {
            r.get::<_, Option<String>>(0)
        })
        .expect("query")
        .filter_map(|r| r.ok().flatten())
        .collect();
    for t in &texts {
        assert!(
            !t.contains("eyJ"),
            "JWT bytes leaked into ner mention_text: {t}"
        );
        assert!(
            !t.contains("REDACTED:SMS_OTP"),
            "cascade-marker bytes leaked into ner mention_text: {t}"
        );
    }

    // The event remains in the Qwen pending set (the sync tier's sentinel is
    // independent of the Qwen watermark) — proves the two tiers coexist.
    let qwen_pending = store.events_pending_tier2(10).expect("pending");
    assert!(
        qwen_pending.iter().any(|e| e.id == id),
        "event must still be pending the async Qwen tier (independent sentinel)"
    );
}

/// A pump WITHOUT `with_ner_sync` ingests normally and writes zero 'ner'
/// mentions — proves the tier is opt-in (model-absent path stays Tier-1-only).
#[test]
fn no_ner_backend_means_no_ner_mentions() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("v2p5p4-no-ner.sqlite");
    let key = DbKey::from_bytes([0xC1; 32]);
    let store = Arc::new(SqlCipherBrainStore::new(&path, &key).expect("open"));

    let pump = BrainPump::new(Arc::clone(&store) as Arc<dyn BrainStore>, None);
    assert!(!pump.ner_sync_enabled());

    let frame = make_event(1, 1_700_000_000_000_000, "Alice met Bob in Seattle");
    let id = match pump.ingest_ocr_event(&frame).expect("ingest") {
        IngestOutcome::Stored { id, .. } => id,
        IngestOutcome::NotOcrEvent => panic!("expected Stored"),
    };
    assert_eq!(pump.ner_sync_mentions_persisted_count(), 0);

    let db = mci_core_open(&path, &key).expect("raw open");
    let conn = db.conn();
    let id_i64 = i64::try_from(id.0).expect("id fits");
    let ner_mentions: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM entity_mentions WHERE event_id=?1 AND extractor_kind=?2",
            params![id_i64, EXTRACTOR_KIND_NER],
            |r| r.get(0),
        )
        .expect("count");
    assert_eq!(ner_mentions, 0, "no NER backend → no 'ner' mentions");
}
