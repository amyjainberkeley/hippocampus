//! Agent runner — the in-process pipeline that turns a `FrameReader`
//! over an `AsyncRead` transport into JSONL health records on disk.
//!
//! Phase-1 cycle 3 wires the production transport (a `tokio::net::
//! UnixStream` half from the helper child process). This iter (11)
//! provides the runner so the binary scaffold can drive it from a
//! synthetic stdin in `--demo` mode, end-to-end.
//!
//! PROTECTED-SET per `AGENT_PROTOCOL` §5 (agent shell logging). The
//! runner only ever produces typed `HealthLogRecord` values via
//! [`health_pump::pump_one`]; it does NOT have a path that surfaces
//! Tombstone / `StateTransition` / `ProtocolMisuse` / `EchoedControl` as
//! log records. Those variants are silently counted via tracing
//! (Phase-1 cycle 3+) but never reach the `HealthLog` JSONL file
//! (content-free invariant).

use mci_core::ipc::connection::Routed;
use mci_core::ipc::reader::FrameReader;
use mci_core::ipc::Message;
use tokio::io::AsyncRead;

use crate::brain_ingest::{BrainIngestor, IngestError, IngestOutcome};
use crate::device_id::DeviceId;
use crate::health_log::HealthLog;
use crate::health_pump::{pump_one, PumpError};
use crate::wall_clock::WallClock;

/// Per-run outcome counters. Caller (the binary's main) prints these.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct RunStats {
    /// Frames decoded off the input transport.
    pub frames_seen: u64,
    /// Frames that routed to `Routed::Health` and pumped into the
    /// `HealthLog` JSONL successfully.
    pub frames_logged: u64,
    /// Frames that routed to a non-`Health` variant — counted, never
    /// logged. Phase-1 cycle 3+ surfaces them through a separate
    /// tracing channel.
    pub frames_non_health: u64,
    /// `OCREvent` frames that the brain ingestor successfully wrote to
    /// the store. Populated by [`drain_to_log_with_brain`] only; the
    /// brain-less [`drain_to_log`] leaves this at `0` and counts
    /// `OCREvent` frames under `frames_non_health` (the variant it
    /// does not route).
    pub frames_to_brain: u64,
}

/// Errors the runner surfaces. Distinguishes transport / decode /
/// log-write paths so the binary's main can choose an exit code.
#[derive(Debug, thiserror::Error)]
pub enum RunError {
    /// Inbound transport read or decode failed. Hostile / malformed
    /// helper input lands here.
    #[error("runner read: {0}")]
    Read(#[from] mci_core::ipc::ReadError),
    /// JSONL log write failed. File-system error.
    #[error("runner log: {0}")]
    Log(#[from] crate::health_log::HealthLogError),
    /// Brain ingest failed — embedder / store. Closes the connection;
    /// the supervisor relaunches the helper.
    #[error("runner brain: {0}")]
    Brain(#[from] IngestError),
}

impl From<PumpError> for RunError {
    fn from(_: PumpError) -> Self {
        // The pump only returns `NotHealth`, which the runner handles
        // by counting + continuing, never by returning. Keeping the
        // From impl for symmetry; callers won't construct this branch.
        Self::Read(mci_core::ipc::ReadError::UnexpectedEof)
    }
}

/// Drive one connection-to-disk drain.
///
/// Reads frames from `rx` until clean EOF or a fatal error. For each
/// frame:
///
/// 1. Classify as `Health` / `Tombstone` / `StateTransition` /
///    `ProtocolMisuse` / `EchoedControl` (same logic
///    `HelperConnection::route` uses; duplicated here so the runner
///    is transport-symmetric — the helper-side `HelperConnection`
///    requires both `AsyncRead` + `AsyncWrite`, but in `--demo`
///    mode the agent only reads).
/// 2. If `Health`: pump → `HealthLogRecord` → append to JSONL.
/// 3. Else: increment counter, continue (NEVER log).
///
/// **Decode errors close the connection** per ADR-0007 trust-boundary
/// rules (caller may surface to a higher-level shutdown path).
pub async fn drain_to_log<R>(
    rx: &mut R,
    log: &HealthLog,
    clock: &dyn WallClock,
    device_id: &DeviceId,
) -> Result<RunStats, RunError>
where
    R: AsyncRead + Unpin,
{
    let mut reader = FrameReader::new();
    let mut stats = RunStats::default();

    while let Some(frame) = reader.read_frame(rx).await? {
        stats.frames_seen += 1;
        if matches!(frame.message, Message::HelperHealth { .. }) {
            let routed = Routed::Health(frame);
            match pump_one(&routed, clock, device_id) {
                Ok(rec) => {
                    log.record(&rec).await?;
                    stats.frames_logged += 1;
                }
                Err(PumpError::NotHealth) => {
                    // Can't happen: we just matched HelperHealth.
                    // Defensive non-fatal counter bump.
                    stats.frames_non_health += 1;
                }
            }
        } else {
            // Tombstone, StateTransition, SurfaceReleased,
            // CaptureStart/Stop, OCREvent — all counted, NEVER logged.
            // Cycle 3+ routes them to their proper destinations
            // (`drain_to_log_with_brain` is the variant that delivers
            // OCREvent into the brain store; this brain-less drain
            // simply does not consume them).
            stats.frames_non_health += 1;
        }
    }
    Ok(stats)
}

/// Drive one connection-to-disk + connection-to-brain drain.
///
/// Same shape as [`drain_to_log`] PLUS the wire-to-brain ingest pump
/// (ADR-0016 P3.6.6). For each frame:
///
/// 1. `HelperHealth` → JSONL log (identical to [`drain_to_log`]).
/// 2. `OCREvent` → `brain.ingest_ocr_event(&frame.message)`; on
///    `IngestOutcome::Stored` increments `frames_to_brain`. The
///    `BrainIngestor` handles the store + embedder + counter internally.
/// 3. Every other variant (`PrivacyTombstone`, `StateTransitionEvent`,
///    `SurfaceReleased`, `CaptureStart`, `CaptureStop`) → counted as
///    `frames_non_health`, NEVER routed to the brain. The dispatch
///    is `match`-exhaustive on `&Message`; **adding a new variant
///    breaks compilation here** (test
///    `brain_dispatch_is_exhaustive_on_message` pins this) — the
///    structural §4.3 guarantee.
///
/// **§4.3 LOAD-BEARING**: `Message::PrivacyTombstone { .. }` falls into
/// the catch-all arm with the same `frames_non_health` counter as
/// every other non-health/non-OCR variant — `brain.ingest_ocr_event`
/// is NEVER called for it. CSO-sign-off block on the PR body asserts
/// this in the diff.
///
/// # Errors
/// [`RunError::Read`] for hostile / malformed input;
/// [`RunError::Log`] for log-file failures;
/// [`RunError::Brain`] for embedder / store failures (the connection
/// closes; the supervisor relaunches).
#[allow(clippy::too_many_lines)]
pub async fn drain_to_log_with_brain<R>(
    rx: &mut R,
    log: &HealthLog,
    clock: &dyn WallClock,
    device_id: &DeviceId,
    brain: &dyn BrainIngestor,
) -> Result<RunStats, RunError>
where
    R: AsyncRead + Unpin,
{
    let mut reader = FrameReader::new();
    let mut stats = RunStats::default();

    while let Some(frame) = reader.read_frame(rx).await? {
        stats.frames_seen += 1;
        match &frame.message {
            Message::HelperHealth { .. } => {
                let routed = Routed::Health(frame);
                match pump_one(&routed, clock, device_id) {
                    Ok(rec) => {
                        log.record(&rec).await?;
                        stats.frames_logged += 1;
                    }
                    Err(PumpError::NotHealth) => {
                        // Cannot happen — we matched HelperHealth above.
                        stats.frames_non_health += 1;
                    }
                }
            }
            Message::OCREvent { .. } | Message::PageContentEvent { .. } => {
                match brain.ingest_ocr_event(&frame.message)? {
                    IngestOutcome::Stored { .. } => {
                        stats.frames_to_brain += 1;
                    }
                    IngestOutcome::NotOcrEvent => {
                        stats.frames_non_health += 1;
                    }
                }
            }
            Message::PrivacyTombstone { .. }
            | Message::StateTransitionEvent { .. }
            | Message::SurfaceReleased { .. }
            | Message::CaptureStart { .. }
            | Message::CaptureStop => {
                stats.frames_non_health += 1;
            }
        }
    }
    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::health_log::HealthLogConfig;
    use crate::wall_clock::test_support::FixedClock;
    use mci_core::ipc::wire::encode;
    use mci_core::ipc::RedactionReason;
    use std::io::Cursor;

    fn id() -> DeviceId {
        DeviceId::from_hex_for_test("0123456789abcdef0123456789abcdef")
    }

    #[tokio::test]
    async fn drains_three_health_frames_to_jsonl() {
        let tmp = tempfile::tempdir().unwrap();
        let log_path = tmp.path().join("h.jsonl");
        let log = HealthLog::new(HealthLogConfig {
            path: log_path.clone(),
            max_bytes: 10 * 1024 * 1024,
        });
        let clock = FixedClock::at_unix_ms(1_779_163_200_000);
        let id = id();

        let mut bytes = Vec::new();
        for seq in 0..3 {
            let f = encode(
                seq,
                &Message::HelperHealth {
                    uptime_ms: 1000 + seq * 10,
                    frames_delivered: seq * 5,
                    frames_suppressed: 0,
                    frames_redacted_by_failsafe: 0,
                    cascade_forced_count: 0,
                    frames_dropped_backpressure: 0,
                    frames_dropped_late_ack: 0,
                    frames_encode_failed: 0,
                    frames_focus_race_dropped: 0,
                    failsafe_by_app: vec![],
                    cpu_pct_micro: 0,
                    rss_bytes: 0,
                    tracker_alive_at_us: 0,
                },
            );
            bytes.extend(f);
        }
        let mut cursor = Cursor::new(bytes);
        let stats = drain_to_log(&mut cursor, &log, &clock, &id).await.unwrap();

        assert_eq!(stats.frames_seen, 3);
        assert_eq!(stats.frames_logged, 3);
        assert_eq!(stats.frames_non_health, 0);

        let body = tokio::fs::read_to_string(&log_path).await.unwrap();
        let lines: Vec<&str> = body.lines().collect();
        assert_eq!(lines.len(), 3);
        for line in lines {
            assert!(line.contains("\"device_id\":\"0123456789abcdef0123456789abcdef\""));
            assert!(line.contains("\"wall_ts\":\"2026-05-19T04:00:00.000Z\""));
        }
    }

    #[tokio::test]
    async fn non_health_frames_counted_not_logged() {
        let tmp = tempfile::tempdir().unwrap();
        let log_path = tmp.path().join("h.jsonl");
        let log = HealthLog::new(HealthLogConfig {
            path: log_path.clone(),
            max_bytes: 10 * 1024 * 1024,
        });
        let clock = FixedClock::at_unix_ms(0);
        let id = id();

        let mut bytes = Vec::new();
        bytes.extend(encode(
            0,
            &Message::PrivacyTombstone {
                ts_us: 1,
                app_bundle: "com.apple.Safari".to_string(),
                reason: RedactionReason::AxSecureSubrole,
            },
        ));
        bytes.extend(encode(
            1,
            &Message::HelperHealth {
                uptime_ms: 0,
                frames_delivered: 0,
                frames_suppressed: 0,
                frames_redacted_by_failsafe: 0,
                cascade_forced_count: 0,
                frames_dropped_backpressure: 0,
                frames_dropped_late_ack: 0,
                frames_encode_failed: 0,
                frames_focus_race_dropped: 0,
                failsafe_by_app: vec![],
                cpu_pct_micro: 0,
                rss_bytes: 0,
                tracker_alive_at_us: 0,
            },
        ));
        bytes.extend(encode(2, &Message::CaptureStop));
        bytes.extend(encode(
            3,
            &Message::SurfaceReleased {
                fd_index: 0,
                ack_seq: 1,
            },
        ));

        let mut cursor = Cursor::new(bytes);
        let stats = drain_to_log(&mut cursor, &log, &clock, &id).await.unwrap();
        assert_eq!(stats.frames_seen, 4);
        assert_eq!(stats.frames_logged, 1);
        assert_eq!(stats.frames_non_health, 3);

        // Log contains exactly one line (the Health).
        let body = tokio::fs::read_to_string(&log_path).await.unwrap();
        let lines: Vec<&str> = body.lines().collect();
        assert_eq!(lines.len(), 1);
        // And the line carries NONE of the forbidden field names.
        for forbidden in [
            "\"app_bundle\":",
            "\"window_title\":",
            "\"url\":",
            "\"text\":",
            "\"summary\":",
            "\"entities\":",
        ] {
            assert!(
                !lines[0].contains(forbidden),
                "log contains forbidden {forbidden}"
            );
        }
    }

    #[tokio::test]
    async fn empty_input_yields_zero_stats() {
        let tmp = tempfile::tempdir().unwrap();
        let log = HealthLog::new(HealthLogConfig {
            path: tmp.path().join("h.jsonl"),
            max_bytes: 1024 * 1024,
        });
        let clock = FixedClock::at_unix_ms(0);
        let id = id();
        let mut empty = Cursor::new(Vec::<u8>::new());
        let stats = drain_to_log(&mut empty, &log, &clock, &id).await.unwrap();
        assert_eq!(stats, RunStats::default());
    }

    #[tokio::test]
    async fn malformed_input_returns_read_error() {
        let tmp = tempfile::tempdir().unwrap();
        let log = HealthLog::new(HealthLogConfig {
            path: tmp.path().join("h.jsonl"),
            max_bytes: 1024 * 1024,
        });
        let clock = FixedClock::at_unix_ms(0);
        let id = id();
        // Bad magic byte.
        let mut bytes = encode(0, &Message::CaptureStop);
        bytes[0] = 0xFF;
        let mut cursor = Cursor::new(bytes);
        let err = drain_to_log(&mut cursor, &log, &clock, &id)
            .await
            .unwrap_err();
        assert!(matches!(err, RunError::Read(_)));
    }

    // ---------------------------------------------------------------
    // P3.6.6 wire-to-brain ingest pump — tests
    //
    // These exercise `drain_to_log_with_brain` (the variant that
    // routes OCREvent frames to a `BrainIngestor`) and the structural
    // §4.3 invariant that `PrivacyTombstone` NEVER reaches
    // `BrainStore::put_event`.
    // ---------------------------------------------------------------

    use crate::brain_ingest::{BrainIngestor, BrainPump};
    use mci_brain::stubs::{FixedDimEmbedder, InMemoryBrainStore};
    use mci_brain::{BrainStore, EmbedError, Embedder, EventId, StoreError};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, Mutex};

    /// A recording wrapper around `InMemoryBrainStore` that counts
    /// `put_event` calls and snapshots every event submitted. Lets
    /// tests assert on exact-call-count + matching field shape.
    #[derive(Default)]
    struct RecordingStore {
        inner: InMemoryBrainStore,
        put_calls: AtomicU64,
        last_event: Mutex<Option<mci_brain::Event>>,
    }

    impl RecordingStore {
        fn new() -> Self {
            Self::default()
        }
        fn put_call_count(&self) -> u64 {
            self.put_calls.load(Ordering::Relaxed)
        }
        fn last(&self) -> Option<mci_brain::Event> {
            self.last_event.lock().unwrap().clone()
        }
    }

    impl BrainStore for RecordingStore {
        fn put_event(&self, event: &mci_brain::Event) -> Result<EventId, StoreError> {
            self.put_calls.fetch_add(1, Ordering::Relaxed);
            *self.last_event.lock().unwrap() = Some(event.clone());
            // Mirror the production `SqlCipherBrainStore.put_event`
            // dim-check (ADR-0009 pin at 384) so tests that exercise
            // the mis-dim path see the same StoreError::InvalidInput
            // a production store would raise.
            if let Some(emb) = &event.embedding {
                if emb.len() != 384 {
                    return Err(StoreError::InvalidInput(format!(
                        "embedding dimension must be 384 (ADR-0009), got {}",
                        emb.len()
                    )));
                }
            }
            self.inner.put_event(event)
        }
        fn get_event(&self, id: EventId) -> Result<Option<mci_brain::Event>, StoreError> {
            self.inner.get_event(id)
        }
        fn fts5_search(
            &self,
            query: &str,
            limit: usize,
        ) -> Result<Vec<(EventId, f32)>, StoreError> {
            self.inner.fts5_search(query, limit)
        }
        fn vec_search(
            &self,
            query_embedding: &[f32],
            limit: usize,
        ) -> Result<Vec<(EventId, f32)>, StoreError> {
            self.inner.vec_search(query_embedding, limit)
        }
    }

    /// Embedder that returns a wrong-dim vector — exercises the
    /// `mci_brain` wrapper / store dim-rejection paths.
    struct MisDimEmbedder;
    impl Embedder for MisDimEmbedder {
        fn dimension(&self) -> usize {
            128
        }
        fn embed_one(&self, _text: &str) -> Result<Vec<f32>, EmbedError> {
            Ok(vec![0.1; 128])
        }
    }

    fn make_ocr_frame_bytes(seq: u64, ts_us: u64, text: &str) -> Vec<u8> {
        let mut bundle = [0u8; 64];
        let id = b"com.apple.Safari";
        bundle[..id.len()].copy_from_slice(id);
        encode(
            seq,
            &Message::OCREvent {
                seq,
                ts_us,
                app_bundle_id: bundle,
                window_title: "MyTitle".to_string(),
                url: "https://example.com/page".to_string(),
                ocr_text: text.to_string(),
                keyframe_hash: [0u8; 32],
            },
        )
    }

    fn make_pump(store: Arc<RecordingStore>, embedder: Option<Arc<dyn Embedder>>) -> BrainPump {
        BrainPump::new(store as Arc<dyn BrainStore>, embedder)
    }

    fn fresh_log(tmp_path: &std::path::Path) -> HealthLog {
        HealthLog::new(HealthLogConfig {
            path: tmp_path.join("h.jsonl"),
            max_bytes: 10 * 1024 * 1024,
        })
    }

    #[tokio::test]
    async fn brain_one_ocr_event_yields_one_put_event_with_matching_fields() {
        let tmp = tempfile::tempdir().unwrap();
        let log = fresh_log(tmp.path());
        let clock = FixedClock::at_unix_ms(0);
        let id = id();
        let store = Arc::new(RecordingStore::new());
        let embedder: Arc<dyn Embedder> = Arc::new(FixedDimEmbedder::default());
        let pump = make_pump(store.clone(), Some(embedder));

        let bytes = make_ocr_frame_bytes(0, 1_234_567, "the quick brown fox");
        let mut cursor = Cursor::new(bytes);
        let stats = drain_to_log_with_brain(&mut cursor, &log, &clock, &id, &pump)
            .await
            .expect("drain ok");

        assert_eq!(stats.frames_seen, 1);
        assert_eq!(stats.frames_to_brain, 1);
        assert_eq!(stats.frames_logged, 0);
        assert_eq!(stats.frames_non_health, 0);
        assert_eq!(store.put_call_count(), 1);
        assert_eq!(pump.events_ingested_count(), 1);

        let ev = store.last().expect("event recorded");
        assert_eq!(ev.ts_us, 1_234_567);
        // ADR-0010 §1.3 — events.text now carries the prepended context
        // header. The OCR body is preserved at the tail.
        assert!(
            ev.text.starts_with("[app=com.apple.Safari | title=MyTitle | url=https://example.com/page | ts="),
            "expected ADR-0010 §1.3 header, got: {}",
            &ev.text[..ev.text.len().min(160)]
        );
        assert!(ev.text.ends_with("the quick brown fox"));
        assert_eq!(ev.app_bundle_id.as_deref(), Some("com.apple.Safari"));
        assert_eq!(ev.window_title.as_deref(), Some("MyTitle"));
        assert_eq!(ev.url.as_deref(), Some("https://example.com/page"));
        assert_eq!(ev.cascade_reason, 0);
        // Embedding attached: 384-d L2-normalized vector.
        let emb = ev.embedding.as_ref().expect("embedding attached");
        assert_eq!(emb.len(), 384);
    }

    #[tokio::test]
    async fn brain_privacy_tombstone_yields_zero_put_event_calls() {
        // §4.3 LOAD-BEARING — the structural wall the PR body asserts.
        // A PrivacyTombstone frame on the wire MUST NOT reach the
        // BrainStore.put_event method. The match arm in
        // drain_to_log_with_brain routes Tombstone to the non-health
        // counter, not to brain.ingest_ocr_event.
        let tmp = tempfile::tempdir().unwrap();
        let log = fresh_log(tmp.path());
        let clock = FixedClock::at_unix_ms(0);
        let id = id();
        let store = Arc::new(RecordingStore::new());
        let pump = make_pump(store.clone(), None);

        let mut bytes = Vec::new();
        bytes.extend(encode(
            0,
            &Message::PrivacyTombstone {
                ts_us: 1,
                app_bundle: "com.1password.app".to_string(),
                reason: RedactionReason::AxSecureSubrole,
            },
        ));
        bytes.extend(encode(
            1,
            &Message::PrivacyTombstone {
                ts_us: 2,
                app_bundle: "com.apple.Safari".to_string(),
                reason: RedactionReason::OcrTimeSecret,
            },
        ));

        let mut cursor = Cursor::new(bytes);
        let stats = drain_to_log_with_brain(&mut cursor, &log, &clock, &id, &pump)
            .await
            .expect("drain ok");

        assert_eq!(stats.frames_seen, 2);
        assert_eq!(stats.frames_to_brain, 0, "tombstones MUST NOT reach brain");
        assert_eq!(stats.frames_non_health, 2);
        assert_eq!(store.put_call_count(), 0);
        assert_eq!(pump.events_ingested_count(), 0);
    }

    #[tokio::test]
    async fn brain_canned_embedding_is_attached_to_stored_event() {
        // Embedder returns deterministic 384-d L2-normalized vector.
        // Stored event MUST carry it.
        let tmp = tempfile::tempdir().unwrap();
        let log = fresh_log(tmp.path());
        let clock = FixedClock::at_unix_ms(0);
        let id = id();
        let store = Arc::new(RecordingStore::new());
        let embedder: Arc<dyn Embedder> = Arc::new(FixedDimEmbedder::default());
        let pump = make_pump(store.clone(), Some(embedder));

        let bytes = make_ocr_frame_bytes(0, 9_000_000, "indemnification clause");
        let mut cursor = Cursor::new(bytes);
        let _stats = drain_to_log_with_brain(&mut cursor, &log, &clock, &id, &pump)
            .await
            .expect("drain ok");

        let ev = store.last().expect("event recorded");
        let emb = ev.embedding.as_ref().expect("embedding attached");
        assert_eq!(emb.len(), 384);
        // L2-norm: sum of squares ≈ 1.0 (FixedDimEmbedder normalizes).
        let mag_sq: f32 = emb.iter().map(|x| x * x).sum();
        assert!(
            (mag_sq - 1.0).abs() < 1e-4,
            "vector must be L2-normalized; got mag^2={mag_sq}"
        );
    }

    #[tokio::test]
    async fn brain_mis_dim_embedding_rejected_by_store_invalid_input() {
        // Mis-dim embedding surfaces as RunError::Brain wrapping
        // IngestError::Embed (the arctic-embed-s wrapper / the brain
        // store both reject mis-dim per ADR-0009; here the wrapper-less
        // raw MisDimEmbedder is wired direct, so it's the store that
        // rejects with StoreError::InvalidInput).
        let tmp = tempfile::tempdir().unwrap();
        let log = fresh_log(tmp.path());
        let clock = FixedClock::at_unix_ms(0);
        let id = id();
        let store = Arc::new(RecordingStore::new());
        let embedder: Arc<dyn Embedder> = Arc::new(MisDimEmbedder);
        let pump = make_pump(store.clone(), Some(embedder));

        let bytes = make_ocr_frame_bytes(0, 1, "hello");
        let mut cursor = Cursor::new(bytes);
        let err = drain_to_log_with_brain(&mut cursor, &log, &clock, &id, &pump)
            .await
            .unwrap_err();
        assert!(
            matches!(
                err,
                RunError::Brain(crate::brain_ingest::IngestError::Store(_))
            ),
            "expected RunError::Brain(IngestError::Store), got {err:?}"
        );
        // No event reached the inner store because the dim check ran
        // before the transaction opened.
        assert_eq!(store.put_call_count(), 1, "store call attempted");
        // The InMemoryBrainStore would have accepted the call; the
        // record happened in RecordingStore::put_event before the inner
        // store rejected. The point of the test is that the error
        // propagates as RunError::Brain — pinned above.
    }

    #[tokio::test]
    async fn brain_mixed_stream_routes_each_variant_correctly() {
        // Interleaved: Tombstone, OCREvent, Health, CaptureStop,
        // OCREvent. Expect: brain=2, log=1, non_health=2 (Tombstone +
        // CaptureStop), seen=5, no store calls for tombstone.
        let tmp = tempfile::tempdir().unwrap();
        let log_path = tmp.path().join("h.jsonl");
        let log = HealthLog::new(HealthLogConfig {
            path: log_path.clone(),
            max_bytes: 10 * 1024 * 1024,
        });
        let clock = FixedClock::at_unix_ms(1_779_163_200_000);
        let id = id();
        let store = Arc::new(RecordingStore::new());
        let embedder: Arc<dyn Embedder> = Arc::new(FixedDimEmbedder::default());
        let pump = make_pump(store.clone(), Some(embedder));

        let mut bytes = Vec::new();
        bytes.extend(encode(
            0,
            &Message::PrivacyTombstone {
                ts_us: 1,
                app_bundle: "com.apple.Safari".to_string(),
                reason: RedactionReason::AxSecureSubrole,
            },
        ));
        bytes.extend(make_ocr_frame_bytes(1, 100, "first ocr"));
        bytes.extend(encode(
            2,
            &Message::HelperHealth {
                uptime_ms: 1000,
                frames_delivered: 10,
                frames_suppressed: 1,
                frames_redacted_by_failsafe: 0,
                cascade_forced_count: 0,
                frames_dropped_backpressure: 0,
                frames_dropped_late_ack: 0,
                frames_encode_failed: 0,
                frames_focus_race_dropped: 0,
                failsafe_by_app: vec![],
                cpu_pct_micro: 0,
                rss_bytes: 0,
                tracker_alive_at_us: 0,
            },
        ));
        bytes.extend(encode(3, &Message::CaptureStop));
        bytes.extend(make_ocr_frame_bytes(4, 200, "second ocr"));

        let mut cursor = Cursor::new(bytes);
        let stats = drain_to_log_with_brain(&mut cursor, &log, &clock, &id, &pump)
            .await
            .expect("drain ok");

        assert_eq!(stats.frames_seen, 5);
        assert_eq!(stats.frames_to_brain, 2);
        assert_eq!(stats.frames_logged, 1);
        assert_eq!(stats.frames_non_health, 2);
        assert_eq!(store.put_call_count(), 2);
        assert_eq!(pump.events_ingested_count(), 2);

        // The health JSONL line MUST contain only the typed shape — no
        // OCR text or app bundle leaked. Mirrors the existing
        // non_health_frames_counted_not_logged invariant.
        let body = tokio::fs::read_to_string(&log_path).await.unwrap();
        let lines: Vec<&str> = body.lines().collect();
        assert_eq!(lines.len(), 1);
        for forbidden in [
            "\"ocr_text\":",
            "first ocr",
            "second ocr",
            "com.apple.Safari",
            "MyTitle",
        ] {
            assert!(
                !lines[0].contains(forbidden),
                "log contains forbidden {forbidden}"
            );
        }
    }

    #[tokio::test]
    async fn brain_ocr_without_embedder_ingests_with_none_embedding() {
        // ADR-0016 §1.4: events.embedding is nullable. When the
        // arctic-embed-s mlpackage isn't bundled yet, BrainPump is
        // constructed with embedder=None; events still flow into the
        // store with embedding=None and recall falls back to FTS5.
        let tmp = tempfile::tempdir().unwrap();
        let log = fresh_log(tmp.path());
        let clock = FixedClock::at_unix_ms(0);
        let id = id();
        let store = Arc::new(RecordingStore::new());
        let pump = make_pump(store.clone(), None);

        let bytes = make_ocr_frame_bytes(0, 42, "no model bundled");
        let mut cursor = Cursor::new(bytes);
        let stats = drain_to_log_with_brain(&mut cursor, &log, &clock, &id, &pump)
            .await
            .expect("drain ok");

        assert_eq!(stats.frames_to_brain, 1);
        let ev = store.last().unwrap();
        assert!(ev.text.ends_with("no model bundled"));
        assert!(ev.text.starts_with("[app=com.apple.Safari"));
        assert!(ev.embedding.is_none());
    }

    #[tokio::test]
    async fn brain_dispatch_match_is_exhaustive_on_message() {
        // Compile-time-style proof: the match in
        // drain_to_log_with_brain enumerates every Message variant.
        // If a new variant is added without an explicit arm here, the
        // match fails to compile. This test exercises every variant
        // through the drain so the count + routing is observable, and
        // the assertion is on the structural outcomes (only OCREvent
        // reaches brain; only HelperHealth reaches log).
        let tmp = tempfile::tempdir().unwrap();
        let log = fresh_log(tmp.path());
        let clock = FixedClock::at_unix_ms(0);
        let id = id();
        let store = Arc::new(RecordingStore::new());
        let pump = make_pump(store.clone(), None);

        let mut bytes = Vec::new();
        bytes.extend(encode(
            0,
            &Message::CaptureStart {
                interval_ms: 200,
                queue_depth: 3,
            },
        ));
        bytes.extend(encode(1, &Message::CaptureStop));
        bytes.extend(encode(
            2,
            &Message::StateTransitionEvent {
                ts_us: 1,
                fd_index: 0,
                width_px: 100,
                height_px: 100,
                status_flags: 0,
                dirty_rects: vec![],
            },
        ));
        bytes.extend(encode(
            3,
            &Message::PrivacyTombstone {
                ts_us: 2,
                app_bundle: "x".to_string(),
                reason: RedactionReason::FailsafeUnknown,
            },
        ));
        bytes.extend(encode(
            4,
            &Message::SurfaceReleased {
                fd_index: 0,
                ack_seq: 0,
            },
        ));
        bytes.extend(encode(
            5,
            &Message::HelperHealth {
                uptime_ms: 0,
                frames_delivered: 0,
                frames_suppressed: 0,
                frames_redacted_by_failsafe: 0,
                cascade_forced_count: 0,
                frames_dropped_backpressure: 0,
                frames_dropped_late_ack: 0,
                frames_encode_failed: 0,
                frames_focus_race_dropped: 0,
                failsafe_by_app: vec![],
                cpu_pct_micro: 0,
                rss_bytes: 0,
                tracker_alive_at_us: 0,
            },
        ));
        bytes.extend(make_ocr_frame_bytes(6, 1, "hello"));

        let mut cursor = Cursor::new(bytes);
        let stats = drain_to_log_with_brain(&mut cursor, &log, &clock, &id, &pump)
            .await
            .expect("drain ok");

        assert_eq!(stats.frames_seen, 7);
        // Brain receives ONLY OCREvent.
        assert_eq!(stats.frames_to_brain, 1);
        // Log receives ONLY HelperHealth.
        assert_eq!(stats.frames_logged, 1);
        // Non-health = CaptureStart + CaptureStop + StateTransition +
        // PrivacyTombstone + SurfaceReleased = 5.
        assert_eq!(stats.frames_non_health, 5);
        // Tombstone NEVER reached brain.
        assert_eq!(store.put_call_count(), 1);
    }

    #[tokio::test]
    async fn brain_counter_is_monotonic_across_n_ocr_events() {
        let tmp = tempfile::tempdir().unwrap();
        let log = fresh_log(tmp.path());
        let clock = FixedClock::at_unix_ms(0);
        let id = id();
        let store = Arc::new(RecordingStore::new());
        let pump = make_pump(store.clone(), None);

        let mut bytes = Vec::new();
        for seq in 0..5_u64 {
            bytes.extend(make_ocr_frame_bytes(
                seq,
                u64::from(u32::try_from(seq).unwrap()) * 1_000_000,
                "tick",
            ));
        }

        let mut cursor = Cursor::new(bytes);
        let stats = drain_to_log_with_brain(&mut cursor, &log, &clock, &id, &pump)
            .await
            .expect("drain ok");

        assert_eq!(stats.frames_to_brain, 5);
        assert_eq!(pump.events_ingested_count(), 5);
        assert_eq!(store.put_call_count(), 5);
    }

    #[tokio::test]
    async fn brain_empty_ocr_text_skips_embedder_call() {
        // Empty OCR text → no embedder call (the FixedDimEmbedder
        // rejects empty input with EmbedError::InvalidInput per
        // ArcticEmbedSEmbedder semantics; BrainPump short-circuits
        // empty text before calling embed_one so the event still
        // ingests with embedding=None).
        let tmp = tempfile::tempdir().unwrap();
        let log = fresh_log(tmp.path());
        let clock = FixedClock::at_unix_ms(0);
        let id = id();
        let store = Arc::new(RecordingStore::new());
        let embedder: Arc<dyn Embedder> = Arc::new(FixedDimEmbedder::default());
        let pump = make_pump(store.clone(), Some(embedder));

        let bytes = make_ocr_frame_bytes(0, 1, "");
        let mut cursor = Cursor::new(bytes);
        let stats = drain_to_log_with_brain(&mut cursor, &log, &clock, &id, &pump)
            .await
            .expect("drain ok");

        assert_eq!(stats.frames_to_brain, 1);
        let ev = store.last().unwrap();
        assert!(
            ev.embedding.is_none(),
            "empty ocr_text MUST NOT invoke embedder"
        );
    }
}
