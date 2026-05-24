//! Pin the **Swift↔Rust OCREvent wire contract** end-to-end with a
//! byte-exact v0x06 fixture.
//!
//! AGENT_QUESTIONS.md 2026-05-23 option C follow-on. The §4 capture-
//! to-brain spine is code-complete (5/5) and PR #174 already pins the
//! Rust **consumer** side (`drain_to_log_with_brain` → `BrainPump` →
//! `SqlCipherBrainStore` → `mci_recall`) using synthetic `OCREvent`
//! values constructed via the Rust `encode` helper. What this test
//! adds — and what was previously unproven — is that the **raw bytes
//! the Swift helper emits** decode cleanly through the same path.
//!
//! ## The cross-side byte-array contract
//!
//! `OCR_EVENT_V06_FIXTURE` below is **byte-for-byte identical** to the
//! `expected` array hand-rolled in:
//!
//! - Swift: `adapters/macos/MCICaptureHelper/Tests/MCICaptureHelperKitTests/WireTests.swift:188-235`
//!   (`WireFixturesTests.testOCREventCrossSideFixture`)
//! - Rust:  `core/src/ipc/wire.rs:1130-1213`
//!   (`wire::tests::ocr_event_cross_side_fixture`)
//!
//! Both of the above pin layout in isolation (encoder side / decoder
//! side). This test closes the loop by feeding the Swift-hand-rolled
//! bytes through the **production agent ingest path** and asserting an
//! `mci_recall` round-trip. A drift between either of the three
//! locations breaks one of these tests loudly.
//!
//! ## Hermetic
//!
//! The encrypted brain lives in a `tempfile::TempDir`; nothing escapes
//! the test process. The `§4 capture-default-OFF` gate is unchanged —
//! no live capture is invoked.
//!
//! ## CSO sign-off notes (matches PR body)
//!
//! - No production wire schema or emission-site change — this test
//!   only exercises the **consumer** side with bytes the encoder
//!   already produces.
//! - No store schema change — writes go through the existing
//!   `SqlCipherBrainStore.put_event` API.
//! - No key-wrap change — opens the store with the test
//!   `DbKey::from_bytes([0xCC; 32])`, same pattern as
//!   `chunker_event_wire.rs` and `mcp_e2e_real_brain.rs`.
//! - ADR-0016 §4.2 cascade-twice preserved — the helper-side single
//!   `OCREvent` emission site at `OCRPostAllowEmitter.swift:217` is
//!   unchanged.

use std::io::Cursor;
use std::sync::Arc;

use mci_agent::brain_ingest::{BrainIngestor, BrainPump};
use mci_agent::device_id::{load_or_generate, DeviceId};
use mci_agent::health_log::{HealthLog, HealthLogConfig};
use mci_agent::mcp::{BrainReader, LiveBrainReader};
use mci_agent::runner::{drain_to_log_with_brain, RunError};
use mci_agent::wall_clock::SystemWallClock;
use mci_brain::stubs::FixedDimEmbedder;
use mci_brain::{BrainStore, Embedder, SqlCipherBrainStore};
use mci_core::crypto::DbKey;
use mci_core::ipc::{DecodeError, ReadError};

// -----------------------------------------------------------------------
// The byte-exact v0x06 OCREvent frame — pinned across THREE sides.
//
// Cross-references (any drift in any of the three MUST be a flagged
// review item — this fixture is the IPC contract for the FIRST
// message variant carrying USER CONTENT across the seam):
//   - Swift encoder: adapters/macos/MCICaptureHelper/Tests/
//                    MCICaptureHelperKitTests/WireTests.swift:188-235
//   - Rust  decoder: core/src/ipc/wire.rs:1130-1213
//
// Layout (ADR-0016 §1.6, little-endian throughout):
//   header (16): magic 0x4D | version 0x06 | msg_type 0x0040 (OCREvent)
//                | seq u64 = 42 | len u32 = 124
//   payload (124):
//     seq u64 = 42
//     ts_us u64 = 0x0102_0304_0506_0708
//     app_bundle_id [u8; 64] = "com.apple.Safari" null-padded
//     window_title_len u16 = 1
//     url_len u16 = 1
//     ocr_text_len u32 = 2
//     keyframe_hash [u8; 32] = all 0xAB
//     window_title = "T"
//     url          = "U"
//     ocr_text     = "Hi"
// -----------------------------------------------------------------------
#[rustfmt::skip]
const OCR_EVENT_V06_FIXTURE: &[u8] = &[
    // ── Frame header (16 bytes) ─────────────────────────────────────
    0x4D, 0x06, 0x40, 0x00, // magic 'M', version 0x06, msg_type 0x0040 LE
    0x2A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // seq u64 LE = 42
    0x7C, 0x00, 0x00, 0x00, // len u32 LE = 124

    // ── Payload (124 bytes) ─────────────────────────────────────────
    // payload.seq u64 LE = 42
    0x2A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // ts_us u64 LE = 0x0102_0304_0506_0708
    0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
    // app_bundle_id [u8; 64] — "com.apple.Safari" + 48 null bytes
    b'c', b'o', b'm', b'.', b'a', b'p', b'p', b'l',
    b'e', b'.', b'S', b'a', b'f', b'a', b'r', b'i',
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    // window_title_len u16 LE = 1
    0x01, 0x00,
    // url_len u16 LE = 1
    0x01, 0x00,
    // ocr_text_len u32 LE = 2
    0x02, 0x00, 0x00, 0x00,
    // keyframe_hash [u8; 32] — all 0xAB
    0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB,
    0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB,
    0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB,
    0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB, 0xAB,
    // window_title "T", url "U", ocr_text "Hi"
    b'T',
    b'U',
    b'H', b'i',
];

/// `ts_us` value encoded in the fixture (mirrors the Swift literal).
const FIXTURE_TS_US: u64 = 0x0102_0304_0506_0708;

/// `app_bundle_id` value encoded in the fixture.
const FIXTURE_APP_BUNDLE_ID: &str = "com.apple.Safari";

/// OCR body the recall test queries against. Unique within this test's
/// brain because exactly one event is ingested.
const FIXTURE_OCR_TOKEN: &str = "Hi";

// -----------------------------------------------------------------------
// Helpers — same shape as chunker_event_wire.rs so the two stay in lockstep.
// -----------------------------------------------------------------------

fn open_temp_store() -> (
    tempfile::TempDir,
    std::path::PathBuf,
    DbKey,
    Arc<SqlCipherBrainStore>,
) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("wire_e2e_fixture.sqlite");
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

// -----------------------------------------------------------------------
// (1) Positive: the byte-exact fixture decodes, ingests, and is recalled.
// -----------------------------------------------------------------------

#[tokio::test]
async fn swift_v06_fixture_decodes_ingests_and_recalls_end_to_end() {
    // Belt-and-suspenders: pin the literal length so a future edit to the
    // const that doesn't match the Swift `expected` array fails LOUDLY
    // here, not via a confusing decode error downstream.
    assert_eq!(
        OCR_EVENT_V06_FIXTURE.len(),
        140,
        "fixture length must match WireTests.swift `frame.count` (140)"
    );

    let (dir, db_path, key, store) = open_temp_store();
    let log = fresh_log(dir.path());
    let clock = SystemWallClock;
    let id = device_id(dir.path()).await;

    let embedder: Arc<dyn Embedder> = Arc::new(FixedDimEmbedder::default());
    let pump = BrainPump::new(
        Arc::clone(&store) as Arc<dyn BrainStore>,
        Some(Arc::clone(&embedder)),
    );

    // Feed the Swift-hand-rolled bytes through the production drain.
    let mut cursor = Cursor::new(OCR_EVENT_V06_FIXTURE.to_vec());
    let stats = drain_to_log_with_brain(&mut cursor, &log, &clock, &id, &pump)
        .await
        .expect("drain must accept the v0x06 fixture");

    // Counters — exactly one frame seen, one routed to brain.
    assert_eq!(stats.frames_seen, 1);
    assert_eq!(stats.frames_to_brain, 1, "fixture must reach the brain");
    assert_eq!(stats.frames_logged, 0);
    assert_eq!(stats.frames_non_health, 0);
    assert_eq!(pump.events_ingested_count(), 1);

    // Store-side row + ts_us pinning.
    let reader = LiveBrainReader::open(&db_path, &key).expect("open reader");
    let s = reader.stats().expect("stats");
    assert_eq!(s.event_count, 1);
    assert_eq!(s.oldest_ts_us, Some(FIXTURE_TS_US));
    assert_eq!(s.newest_ts_us, Some(FIXTURE_TS_US));

    // `events.text` carries the ADR-0010 §1.3 context header AND the
    // app bundle id the Swift fixture encoded.
    let rows = reader.events_since(0, 10).expect("events_since");
    assert_eq!(rows.len(), 1);
    let row = &rows[0];
    assert!(
        row.text_snippet
            .starts_with(&format!("[app={FIXTURE_APP_BUNDLE_ID} | title=T | url=U | ts=")),
        "events.text must carry the ADR-0010 §1.3 header sourced from \
         the Swift fixture payload; got: {}",
        row.text_snippet
    );

    // `mci_recall` round-trip on the OCR body token — proves the FTS5
    // trigger sync indexed the headered text the chunker emitted.
    let hits = reader.recall(FIXTURE_OCR_TOKEN, 10).expect("recall");
    assert!(
        !hits.is_empty(),
        "mci_recall(\"{FIXTURE_OCR_TOKEN}\") must return at least one hit \
         for the v0x06 fixture"
    );
    assert!(
        hits.iter().any(|h| h.record.ts_us == FIXTURE_TS_US),
        "at least one hit must carry the fixture ts_us = {FIXTURE_TS_US}"
    );
}

// -----------------------------------------------------------------------
// (2) Negative: a single-byte version bump is REJECTED, not silently
// accepted. This is the strict-payload tripwire from PR #44 applied at
// the version-byte boundary — a misbehaving helper must not be able to
// smuggle bytes in by claiming a newer wire version the consumer
// hasn't agreed to.
// -----------------------------------------------------------------------

#[tokio::test]
async fn single_byte_version_flip_is_rejected_no_silent_accept() {
    // Flip byte 1 (the version byte) from 0x06 to 0x07. Every other byte
    // is unchanged — proves the decoder fails on the version mismatch
    // alone, not on some other downstream check.
    let mut corrupted: Vec<u8> = OCR_EVENT_V06_FIXTURE.to_vec();
    assert_eq!(corrupted[1], 0x06, "fixture sanity: byte 1 is FRAME_VERSION");
    corrupted[1] = 0x07;

    let (dir, _db_path, _key, store) = open_temp_store();
    let log = fresh_log(dir.path());
    let clock = SystemWallClock;
    let id = device_id(dir.path()).await;
    let embedder: Arc<dyn Embedder> = Arc::new(FixedDimEmbedder::default());
    let pump = BrainPump::new(
        Arc::clone(&store) as Arc<dyn BrainStore>,
        Some(embedder),
    );

    let mut cursor = Cursor::new(corrupted);
    let err = drain_to_log_with_brain(&mut cursor, &log, &clock, &id, &pump)
        .await
        .expect_err("drain MUST reject a frame with a version byte the consumer didn't agree to");

    match err {
        RunError::Read(ReadError::Decode(DecodeError::UnsupportedVersion { got })) => {
            assert_eq!(
                got, 0x07,
                "decoder must surface the actual rejected version byte"
            );
        }
        other => panic!(
            "expected RunError::Read(Decode(UnsupportedVersion {{ got: 7 }})), got: {other:?}"
        ),
    }

    // Belt-and-suspenders: the store and the pump counter MUST stay at
    // zero. Silent-accept of a bumped version byte would either ingest
    // the row (event_count == 1) or bump the counter without ingesting
    // (counter == 1, event_count == 0). Either is a critical regression.
    let s = store.stats().expect("stats");
    assert_eq!(s.event_count, 0, "no row may land from a rejected frame");
    assert_eq!(
        pump.events_ingested_count(),
        0,
        "the content-free counter must not advance on a rejected frame"
    );
}
