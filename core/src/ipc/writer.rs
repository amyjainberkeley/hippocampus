//! Async frame writer over the wire format defined in [`super::wire`].
//!
//! PROTECTED-SET per `AGENT_PROTOCOL` §5. The mirror of
//! [`super::reader::FrameReader`] on the encode side: takes a
//! [`super::Message`] + a per-connection monotonic sequence counter,
//! emits the bytes through any `AsyncWrite + Unpin` transport.
//!
//! In Phase-1 cycle 3 the concrete transport is a
//! `tokio::net::UnixStream` connected to the macOS Swift helper's
//! `AF_UNIX` socket end. The core uses this writer to send the
//! `CaptureStart` + `CaptureStop` control messages and the
//! per-frame `SurfaceReleased` acks that close the ADR-0007 timing
//! contract (drop the surface within `interval × (queueDepth − 1)`
//! or the helper drops on its own clock).
//!
//! **Trust-boundary stance** (mirrors `reader`): every byte the writer
//! produces passes through [`super::wire::encode`], which is the
//! single point of truth for the wire layout. The writer's only job is
//! to push those bytes into the transport and surface I/O errors. It
//! does NOT inspect the message; it does NOT short-circuit framing;
//! it does NOT batch (one `write_all` per frame, so the connection's
//! framing remains observable for tcpdump-equivalent debugging).

use std::io;

use tokio::io::{AsyncWrite, AsyncWriteExt};

use super::wire::encode;
use super::Message;

/// Errors the writer surfaces.
#[derive(Debug)]
pub enum WriteError {
    /// Underlying transport returned an `io::Error`. Connection-level —
    /// the helper has disconnected, the FD was closed, etc.
    Io(io::Error),
}

impl std::fmt::Display for WriteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "ipc-write io: {e}"),
        }
    }
}

impl std::error::Error for WriteError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(e) => Some(e),
        }
    }
}

impl From<io::Error> for WriteError {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}

/// Per-connection frame writer.
///
/// Holds the monotonic sequence counter. Callers create one per
/// outbound connection and call [`send`](Self::send) per message.
/// Sequence numbers start at 0 and increment per `send`; the helper
/// uses them for late-ack detection (see
/// [`Message::SurfaceReleased::ack_seq`](super::Message::SurfaceReleased)).
pub struct FrameWriter {
    next_seq: u64,
}

impl FrameWriter {
    /// Construct a writer starting at sequence 0.
    #[must_use]
    pub const fn new() -> Self {
        Self { next_seq: 0 }
    }

    /// Construct a writer starting at a specific sequence — for
    /// reconnect / resume flows where the prior sequence is known.
    #[must_use]
    pub const fn starting_at(seq: u64) -> Self {
        Self { next_seq: seq }
    }

    /// Encode `msg` with the next sequence number and write it to
    /// `sink`. Returns the sequence number the message was assigned —
    /// useful for tests + for the core's `SurfaceReleased.ack_seq`
    /// bookkeeping.
    ///
    /// **Atomicity:** one `write_all` per frame, so the connection's
    /// framing is observable. If the transport flushes lazily, the
    /// caller is responsible for `.flush()` — the writer never calls
    /// it implicitly (lets callers batch writes with a single flush
    /// when desired, e.g. send `CaptureStart` + `CaptureStop` quickly
    /// in tests).
    ///
    /// # Errors
    /// See [`WriteError`].
    pub async fn send<W>(&mut self, sink: &mut W, msg: &Message) -> Result<u64, WriteError>
    where
        W: AsyncWrite + Unpin + ?Sized,
    {
        let seq = self.next_seq;
        let bytes = encode(seq, msg);
        sink.write_all(&bytes).await?;
        self.next_seq = self.next_seq.wrapping_add(1);
        Ok(seq)
    }

    /// The next sequence number a `send` would emit. Read-only.
    #[must_use]
    pub const fn next_seq(&self) -> u64 {
        self.next_seq
    }
}

impl Default for FrameWriter {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::reader::FrameReader;
    use crate::ipc::{Message, RedactionReason};
    use std::io::Cursor;
    use tokio::io::AsyncReadExt;

    /// Writer + reader round-trip: encode a message on one side,
    /// decode on the other, assert identity. This is the binding
    /// regression gate that the encode + decode paths agree.
    #[tokio::test]
    async fn writer_reader_round_trip() {
        let (mut a, mut b) = tokio::io::duplex(64);
        let mut writer = FrameWriter::new();

        let written_msg = Message::CaptureStart {
            interval_ms: 200,
            queue_depth: 3,
        };
        let writer_task = tokio::spawn({
            let m = written_msg.clone();
            async move {
                let seq = writer.send(&mut a, &m).await.unwrap();
                a.shutdown().await.unwrap();
                seq
            }
        });

        let mut reader = FrameReader::new();
        let frame = reader.read_frame(&mut b).await.unwrap().unwrap();
        let written_seq = writer_task.await.unwrap();

        assert_eq!(frame.seq, written_seq);
        assert_eq!(frame.message, written_msg);
    }

    /// Sequence numbers monotonically increment across calls.
    #[tokio::test]
    async fn sequence_increments_per_send() {
        let mut buf = Vec::<u8>::new();
        let mut writer = FrameWriter::new();
        for expected in 0..5 {
            let seq = writer.send(&mut buf, &Message::CaptureStop).await.unwrap();
            assert_eq!(seq, expected);
        }
        assert_eq!(writer.next_seq(), 5);
    }

    /// `starting_at` honors the initial sequence (for reconnect /
    /// resume flows where the prior seq is known).
    #[tokio::test]
    async fn starting_at_offsets_initial_sequence() {
        let mut buf = Vec::<u8>::new();
        let mut writer = FrameWriter::starting_at(42);
        let seq = writer.send(&mut buf, &Message::CaptureStop).await.unwrap();
        assert_eq!(seq, 42);
        assert_eq!(writer.next_seq(), 43);
    }

    /// Multiple frames in one connection stream — the reader's
    /// streaming parser must decode all of them.
    #[tokio::test]
    async fn three_frames_in_one_stream() {
        let (mut a, mut b) = tokio::io::duplex(128);
        let mut writer = FrameWriter::new();

        let messages = [
            Message::CaptureStart {
                interval_ms: 200,
                queue_depth: 3,
            },
            Message::PrivacyTombstone {
                ts_us: 1_500_000,
                app_bundle: "com.apple.Safari".to_string(),
                reason: RedactionReason::AxSecureSubrole,
            },
            Message::CaptureStop,
        ];
        let messages_clone = messages.clone();

        let writer_task = tokio::spawn(async move {
            for m in &messages_clone {
                writer.send(&mut a, m).await.unwrap();
            }
            a.shutdown().await.unwrap();
        });

        let mut reader = FrameReader::new();
        for (i, expected) in messages.iter().enumerate() {
            let frame = reader.read_frame(&mut b).await.unwrap().unwrap();
            assert_eq!(frame.seq, i as u64);
            assert_eq!(&frame.message, expected);
        }
        // Clean EOF after the three frames.
        assert!(reader.read_frame(&mut b).await.unwrap().is_none());

        writer_task.await.unwrap();
    }

    /// I/O errors on the sink propagate as `WriteError::Io`.
    #[tokio::test]
    async fn io_error_propagates() {
        // A Cursor over a fixed-size, non-resizable slice fills up
        // quickly and returns `WriteZero` once the buffer is full.
        let mut backing = [0_u8; 4]; // shorter than any encoded frame
        let mut cursor = Cursor::new(&mut backing[..]);
        let mut writer = FrameWriter::new();
        let err = writer
            .send(&mut cursor, &Message::CaptureStop)
            .await
            .unwrap_err();
        assert!(matches!(err, WriteError::Io(_)));
    }

    /// Writer is `Default`-constructible and `default() == new()`.
    #[test]
    fn default_starts_at_seq_zero() {
        let w = FrameWriter::default();
        assert_eq!(w.next_seq(), 0);
    }

    /// Encoded bytes match the wire spec — explicit sanity check
    /// that the writer doesn't add any framing beyond what `encode`
    /// produces.
    #[tokio::test]
    async fn writer_bytes_equal_encode_output() {
        let mut buf = Vec::<u8>::new();
        let mut writer = FrameWriter::new();
        let msg = Message::CaptureStop;
        let seq = writer.send(&mut buf, &msg).await.unwrap();
        let expected = encode(seq, &msg);
        assert_eq!(buf, expected);
    }

    /// Read the written bytes back through a raw `read_to_end` and
    /// confirm length matches the encoder's output. Independent of
    /// the reader — covers the case where the reader has a bug that
    /// happens to compensate for a writer bug.
    #[tokio::test]
    async fn duplex_byte_count_matches_encoded_length() {
        let (mut a, mut b) = tokio::io::duplex(256);
        let mut writer = FrameWriter::new();
        let msg = Message::HelperHealth {
            uptime_ms: 1000,
            frames_delivered: 10,
            frames_suppressed: 1,
            frames_redacted_by_failsafe: 0,
            cascade_forced_count: 0,
            frames_dropped_backpressure: 0,
            frames_dropped_late_ack: 0,
            frames_encode_failed: 0,
        };
        let bytes = encode(0, &msg);
        let expected_len = bytes.len();

        let writer_task = tokio::spawn(async move {
            writer.send(&mut a, &msg).await.unwrap();
            a.shutdown().await.unwrap();
        });

        let mut buf = Vec::<u8>::new();
        b.read_to_end(&mut buf).await.unwrap();
        assert_eq!(buf.len(), expected_len);
        assert_eq!(buf, bytes);

        writer_task.await.unwrap();
    }
}
