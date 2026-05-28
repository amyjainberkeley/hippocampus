//! `HelperConnection` — pairs [`super::reader::FrameReader`] +
//! [`super::writer::FrameWriter`] on a single bidirectional transport
//! and routes inbound frames into the store-row materializers.
//!
//! PROTECTED-SET per `AGENT_PROTOCOL` §5. This is the core's side of
//! the helper IPC end-to-end: bytes-in → typed messages → store rows;
//! typed control + acks → bytes-out. Phase-1 cycle 3 wires a concrete
//! `tokio::net::UnixStream` here; this iteration's transport is
//! generic so the producer- and consumer-tasks are testable against a
//! `tokio::io::duplex` pair.
//!
//! The connection is intentionally NOT a tokio `task` itself — the
//! caller (the agent shell, Phase-1 cycle 3+) owns the spawn lifetime
//! so it can `select!` against shutdown signals + the inbound stream.
//! This module exposes building blocks (`recv_one`, `send_one`,
//! `route_tombstone`) so the cycle-3 PR composes them into the actual
//! supervisor loop.

use crate::ipc::reader::FrameReader;
use crate::ipc::writer::FrameWriter;
use crate::ipc::{Frame, Message, ReadError, WriteError};
use crate::store::EventRow;

use tokio::io::{AsyncRead, AsyncWrite};

/// Routing outcome for a single inbound frame.
///
/// The connection's caller decides what to do with each variant; this
/// module just classifies. Decoupling the routing from the side effects
/// (writing to the store, advancing a counter, logging) keeps the
/// trust-boundary logic at this layer auditable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Routed {
    /// Helper emitted a privacy tombstone. The caller writes the
    /// materialized [`EventRow`] to the store layer.
    Tombstone(EventRow),
    /// Helper emitted a state-transition event (a non-suppressed
    /// frame). The Phase-1 cycle 3+ pipeline takes over from here;
    /// for now the connection passes the raw frame back so callers
    /// can no-op or stub it.
    StateTransition(Frame),
    /// Helper emitted health counters. The CRS Telemetry-Gap analyst's
    /// `frames_delivered` / `frames_suppressed` / drop-counters live
    /// here; the caller forwards them to whatever sink the agent shell
    /// has wired (`tracing` + a rotating log file, per the
    /// `2026-05-19-telemetry-gap.md` recommendation).
    Health(Frame),
    /// Inbound `SurfaceReleased` ack arrived from the helper — this
    /// is core→helper-only by ADR-0007's design, so receiving it FROM
    /// the helper is a protocol bug. Treat as a hostile / malformed
    /// frame; close the connection.
    ProtocolMisuse(Frame),
    /// `CaptureStart` / `CaptureStop` originate at the core; receiving
    /// them FROM the helper is also a protocol bug.
    EchoedControl(Frame),
    /// Helper emitted a twice-cleared `OCREvent` (ADR-0016 P3.6). The
    /// brain-ingestor consumer lands at P3.7+; until then the
    /// connection passes the frame through for caller no-op or
    /// structural assertion. **CSO-protected**: this variant is the
    /// IPC-seam evidence that `OCREvent` and `PrivacyTombstone` are
    /// disjoint dispatch targets — an enum-match dispatcher cannot
    /// deliver a `PrivacyTombstone` to the brain by construction
    /// (ADR-0016 §4.3 invariant).
    OCREvent(Frame),
    /// Browser extension emitted a `PageContentEvent` (Phase 7
    /// pull-forward). Full page text from the DOM, delivered via native
    /// messaging host. The agent's brain-ingestor uses this as the
    /// preferred text source when a URL-matched OCREvent also exists.
    PageContent(Frame),
}

/// Errors `HelperConnection` surfaces. Distinguishes wire-level
/// failures (decode) from transport failures (Io) from contract
/// failures (`ProtocolViolation`).
#[derive(Debug)]
pub enum ConnectionError {
    /// Inbound read failed at the transport / decoder layer.
    Read(ReadError),
    /// Outbound write failed at the transport layer.
    Write(WriteError),
}

impl std::fmt::Display for ConnectionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Read(e) => write!(f, "helper-conn read: {e}"),
            Self::Write(e) => write!(f, "helper-conn write: {e}"),
        }
    }
}

impl std::error::Error for ConnectionError {}

impl From<ReadError> for ConnectionError {
    fn from(e: ReadError) -> Self {
        Self::Read(e)
    }
}

impl From<WriteError> for ConnectionError {
    fn from(e: WriteError) -> Self {
        Self::Write(e)
    }
}

/// Bidirectional helper connection.
///
/// Generic over independent `AsyncRead` + `AsyncWrite` halves so the
/// concrete transport can be anything — a duplex pair (tests), a
/// `tokio::net::UnixStream` split (cycle 3), or a future TLS-wrapped
/// channel.
///
/// Holds the agent's per-device identifier so `Routed::Tombstone`
/// rows know what `events.device_id` to bind. The identifier is
/// supplied by the agent shell, not by the helper (per ADR-0008 +
/// ADR-0012).
pub struct HelperConnection<R, W>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    reader: FrameReader,
    writer: FrameWriter,
    rx: R,
    tx: W,
    device_id: String,
}

impl<R, W> HelperConnection<R, W>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    /// Construct a fresh connection.
    pub fn new(rx: R, tx: W, device_id: impl Into<String>) -> Self {
        Self {
            reader: FrameReader::new(),
            writer: FrameWriter::new(),
            rx,
            tx,
            device_id: device_id.into(),
        }
    }

    /// Read one frame and route it. Returns `Ok(None)` on clean EOF.
    ///
    /// # Errors
    /// See [`ConnectionError`].
    pub async fn recv_one(&mut self) -> Result<Option<Routed>, ConnectionError> {
        let Some(frame) = self.reader.read_frame(&mut self.rx).await? else {
            return Ok(None);
        };
        Ok(Some(self.route(frame)))
    }

    /// Send one outbound message — `CaptureStart`, `CaptureStop`,
    /// `SurfaceReleased`. Returns the sequence number the message
    /// was assigned.
    ///
    /// # Errors
    /// See [`ConnectionError`].
    pub async fn send_one(&mut self, msg: &Message) -> Result<u64, ConnectionError> {
        Ok(self.writer.send(&mut self.tx, msg).await?)
    }

    /// The next outbound sequence number a `send_one` would emit.
    #[must_use]
    pub fn next_seq(&self) -> u64 {
        self.writer.next_seq()
    }

    /// Classify an inbound frame into a [`Routed`] outcome.
    fn route(&self, frame: Frame) -> Routed {
        match &frame.message {
            Message::PrivacyTombstone { .. } => {
                // The materializer cannot return None here because we
                // just matched on PrivacyTombstone. The assert
                // documents the invariant.
                let row = EventRow::from_tombstone(&frame, &self.device_id)
                    .expect("matched PrivacyTombstone variant; from_tombstone yields Some");
                Routed::Tombstone(row)
            }
            Message::StateTransitionEvent { .. } => Routed::StateTransition(frame),
            Message::HelperHealth { .. } => Routed::Health(frame),
            Message::SurfaceReleased { .. } => Routed::ProtocolMisuse(frame),
            Message::OCREvent { .. } => Routed::OCREvent(frame),
            Message::PageContentEvent { .. } => Routed::PageContent(frame),
            Message::CaptureStart { .. } | Message::CaptureStop => Routed::EchoedControl(frame),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::wire::encode;
    use crate::ipc::RedactionReason;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    fn make_pair() -> (
        tokio::io::DuplexStream,
        tokio::io::DuplexStream,
        tokio::io::DuplexStream,
        tokio::io::DuplexStream,
    ) {
        // Two duplex pairs: one each direction. The "helper" side
        // writes to its own tx → the "core" side reads from its rx.
        let (helper_tx, core_rx) = tokio::io::duplex(256);
        let (core_tx, helper_rx) = tokio::io::duplex(256);
        (core_rx, core_tx, helper_tx, helper_rx)
    }

    #[tokio::test]
    async fn routes_privacy_tombstone_to_event_row() {
        let (core_rx, core_tx, mut helper_tx, _helper_rx) = make_pair();

        let frame_bytes = encode(
            0,
            &Message::PrivacyTombstone {
                ts_us: 1_500_000,
                app_bundle: "com.apple.Safari".to_string(),
                reason: RedactionReason::AxSecureSubrole,
            },
        );
        let helper_task = tokio::spawn(async move {
            helper_tx.write_all(&frame_bytes).await.unwrap();
            helper_tx.shutdown().await.unwrap();
        });

        let mut conn = HelperConnection::new(core_rx, core_tx, "device-A");
        let routed = conn.recv_one().await.unwrap().unwrap();
        helper_task.await.unwrap();

        match routed {
            Routed::Tombstone(row) => {
                assert_eq!(row.ts_ms, 1500);
                assert_eq!(row.device_id, "device-A");
                assert_eq!(row.app_bundle, "com.apple.Safari");
                assert_eq!(row.source_type, "redacted");
                assert_eq!(row.redaction_reason, "ax-secure-subrole");
            }
            other => panic!("expected Tombstone, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn routes_state_transition_passthrough() {
        let (core_rx, core_tx, mut helper_tx, _helper_rx) = make_pair();

        let frame_bytes = encode(
            7,
            &Message::StateTransitionEvent {
                ts_us: 0,
                fd_index: 0,
                width_px: 1920,
                height_px: 1080,
                status_flags: 0,
                dirty_rects: vec![],
            },
        );
        let helper_task = tokio::spawn(async move {
            helper_tx.write_all(&frame_bytes).await.unwrap();
            helper_tx.shutdown().await.unwrap();
        });

        let mut conn = HelperConnection::new(core_rx, core_tx, "d");
        let routed = conn.recv_one().await.unwrap().unwrap();
        helper_task.await.unwrap();
        assert!(matches!(routed, Routed::StateTransition(_)));
    }

    #[tokio::test]
    async fn routes_helper_health_to_dedicated_variant() {
        let (core_rx, core_tx, mut helper_tx, _helper_rx) = make_pair();

        let frame_bytes = encode(
            1,
            &Message::HelperHealth {
                uptime_ms: 1000,
                frames_delivered: 5,
                frames_suppressed: 1,
                frames_redacted_by_failsafe: 0,
                cascade_forced_count: 0,
                frames_dropped_backpressure: 0,
                frames_dropped_late_ack: 0,
                frames_encode_failed: 0,
            },
        );
        let helper_task = tokio::spawn(async move {
            helper_tx.write_all(&frame_bytes).await.unwrap();
            helper_tx.shutdown().await.unwrap();
        });

        let mut conn = HelperConnection::new(core_rx, core_tx, "d");
        let routed = conn.recv_one().await.unwrap().unwrap();
        helper_task.await.unwrap();
        assert!(matches!(routed, Routed::Health(_)));
    }

    /// Receiving a `SurfaceReleased` FROM the helper is a protocol bug —
    /// it's a core→helper-only message per ADR-0007. Caller closes
    /// the connection on this.
    #[tokio::test]
    async fn routes_surface_released_from_helper_as_protocol_misuse() {
        let (core_rx, core_tx, mut helper_tx, _helper_rx) = make_pair();

        let frame_bytes = encode(
            0,
            &Message::SurfaceReleased {
                fd_index: 0,
                ack_seq: 42,
            },
        );
        let helper_task = tokio::spawn(async move {
            helper_tx.write_all(&frame_bytes).await.unwrap();
            helper_tx.shutdown().await.unwrap();
        });

        let mut conn = HelperConnection::new(core_rx, core_tx, "d");
        let routed = conn.recv_one().await.unwrap().unwrap();
        helper_task.await.unwrap();
        assert!(matches!(routed, Routed::ProtocolMisuse(_)));
    }

    /// `CaptureStart` / `CaptureStop` from helper-side is also misuse —
    /// those are core→helper.
    #[tokio::test]
    async fn routes_echoed_control_as_misuse() {
        let (core_rx, core_tx, mut helper_tx, _helper_rx) = make_pair();

        let frame_bytes = encode(
            0,
            &Message::CaptureStart {
                interval_ms: 200,
                queue_depth: 3,
            },
        );
        let helper_task = tokio::spawn(async move {
            helper_tx.write_all(&frame_bytes).await.unwrap();
            helper_tx.shutdown().await.unwrap();
        });

        let mut conn = HelperConnection::new(core_rx, core_tx, "d");
        let routed = conn.recv_one().await.unwrap().unwrap();
        helper_task.await.unwrap();
        assert!(matches!(routed, Routed::EchoedControl(_)));
    }

    /// `send_one` writes a `CaptureStart` and the test reads the bytes
    /// off the other side of the pair. Confirms the outbound path
    /// produces wire-format bytes and increments the sequence.
    #[tokio::test]
    async fn send_one_emits_wire_bytes_and_advances_seq() {
        let (core_rx, core_tx, _helper_tx, mut helper_rx) = make_pair();
        let mut conn = HelperConnection::new(core_rx, core_tx, "d");
        let seq = conn
            .send_one(&Message::CaptureStart {
                interval_ms: 200,
                queue_depth: 3,
            })
            .await
            .unwrap();
        assert_eq!(seq, 0);
        assert_eq!(conn.next_seq(), 1);

        // Drop the connection's tx half so the helper's rx sees EOF.
        drop(conn);

        let mut buf = Vec::<u8>::new();
        helper_rx.read_to_end(&mut buf).await.unwrap();
        assert!(!buf.is_empty(), "wrote wire bytes");
        assert_eq!(buf[0], 0x4D, "magic");
        assert_eq!(buf[2], 0x01, "CaptureStart msg_type low byte");
    }

    /// Clean EOF (helper closed cleanly with no data buffered) returns
    /// `Ok(None)` so the caller's supervisor loop can break gracefully.
    #[tokio::test]
    async fn clean_eof_returns_none() {
        let (core_rx, core_tx, mut helper_tx, _helper_rx) = make_pair();
        let helper_task = tokio::spawn(async move {
            helper_tx.shutdown().await.unwrap();
        });
        let mut conn = HelperConnection::new(core_rx, core_tx, "d");
        let routed = conn.recv_one().await.unwrap();
        helper_task.await.unwrap();
        assert!(routed.is_none());
    }
}
