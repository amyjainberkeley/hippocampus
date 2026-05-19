//! Async frame reader over the wire format defined in [`super::wire`].
//!
//! PROTECTED-SET per `AGENT_PROTOCOL` §5. This module reads bytes that
//! cross the helper → core process boundary. It MUST never panic on
//! hostile input — the trust boundary is here. Every error path
//! returns a [`ReadError`] the caller can decide whether to log + drop
//! or escalate.
//!
//! The reader is transport-generic. In Phase-1 cycle 2 the concrete
//! transport is a `tokio::net::UnixStream` connected to the macOS Swift
//! helper's `AF_UNIX` socket end (with `SCM_RIGHTS` carrying surface
//! fds out-of-band — those are handled by the caller, not this module,
//! because Rust stdlib's `UnixStream` exposes the ancillary-data API on
//! a different surface). In tests the transport is a `tokio::io::DuplexStream`
//! or a `Cursor<Vec<u8>>` adapter.
//!
//! Buffering strategy: read into a growing per-connection buffer; try to
//! decode one frame; if the buffer is short of the declared frame length,
//! read more; if the magic byte is wrong or the payload exceeds
//! [`super::wire::MAX_FRAME_PAYLOAD_BYTES`], abort the connection.

use std::io;

use tokio::io::{AsyncRead, AsyncReadExt};

use super::wire::{decode, DecodeError, Frame, MAX_FRAME_PAYLOAD_BYTES, MIN_FRAME_HEADER_BYTES};

/// Errors the reader surfaces.
#[derive(Debug)]
pub enum ReadError {
    /// Underlying transport returned an `io::Error`. Connection-level —
    /// the helper has disconnected, the FD was closed, etc.
    Io(io::Error),
    /// EOF before a full frame could be assembled. Not necessarily an
    /// error during shutdown; the caller decides.
    UnexpectedEof,
    /// The wire decoder rejected the bytes. Per `AGENT_PROTOCOL` §5 this
    /// is a trust-boundary event: the helper sent something invalid.
    /// The reader does NOT continue after this — it returns and the
    /// caller MUST close the connection (otherwise a hostile helper
    /// could spam decode errors forever).
    Decode(DecodeError),
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "ipc-read io: {e}"),
            Self::UnexpectedEof => write!(f, "ipc-read eof before full frame"),
            Self::Decode(e) => write!(f, "ipc-read decode: {e}"),
        }
    }
}

impl std::error::Error for ReadError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(e) => Some(e),
            Self::UnexpectedEof => None,
            Self::Decode(e) => Some(e),
        }
    }
}

impl From<io::Error> for ReadError {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}

impl From<DecodeError> for ReadError {
    fn from(e: DecodeError) -> Self {
        Self::Decode(e)
    }
}

/// Reusable per-connection state for the frame reader.
///
/// Owns a growing scratch buffer and a `read_into_buffer_chunk` size.
/// Callers create one per accepted connection and call [`read_frame`]
/// in a loop.
pub struct FrameReader {
    buf: Vec<u8>,
    chunk: usize,
}

impl FrameReader {
    /// Construct a reader with the default chunk size (8 KiB).
    #[must_use]
    pub fn new() -> Self {
        Self::with_chunk_size(8 * 1024)
    }

    /// Construct a reader with a custom chunk size. Useful in tests to
    /// force partial reads.
    #[must_use]
    pub fn with_chunk_size(chunk: usize) -> Self {
        assert!(chunk > 0, "chunk size must be > 0");
        Self {
            buf: Vec::with_capacity(chunk),
            chunk,
        }
    }

    /// Read exactly one frame from the transport.
    ///
    /// Buffers as needed across multiple reads. Returns `Ok(Some(frame))`
    /// when a full frame is decoded, `Ok(None)` on clean EOF before any
    /// bytes have been read, or `Err(_)` on any error.
    ///
    /// **Trust boundary semantics:** on a decode error the caller MUST
    /// close the connection. The reader leaves any remaining buffered
    /// bytes in `self.buf` (intentionally — they may be useful for
    /// diagnostic dumps under `tracing`), but does NOT advance past
    /// them; calling `read_frame` again after an error returns the
    /// same error.
    ///
    /// # Errors
    /// See [`ReadError`].
    pub async fn read_frame<R>(&mut self, reader: &mut R) -> Result<Option<Frame>, ReadError>
    where
        R: AsyncRead + Unpin + ?Sized,
    {
        loop {
            // Try to decode whatever we have first — handles the common
            // case where the prior read returned a multi-frame chunk
            // and we're catching up on the buffer.
            match decode(&self.buf) {
                Ok((frame, used)) => {
                    // Successful decode — drain the consumed bytes and
                    // return.
                    self.buf.drain(..used);
                    return Ok(Some(frame));
                }
                Err(DecodeError::ShortBuffer | DecodeError::Truncated { .. }) => {
                    // Need more bytes. Fall through to the read below.
                }
                Err(DecodeError::OversizedPayload { len }) => {
                    // Hard trust-boundary failure: a hostile / fuzzed
                    // sender declared a payload bigger than our cap.
                    // Abort BEFORE reading more bytes (the cap is the
                    // whole point — keep memory bounded).
                    return Err(ReadError::Decode(DecodeError::OversizedPayload { len }));
                }
                Err(other) => {
                    // Any other decoder error is also a trust-boundary
                    // failure: bad magic, unsupported version, invalid
                    // enum, payload-length mismatch, invalid UTF-8.
                    return Err(ReadError::Decode(other));
                }
            }

            // Read more bytes into the scratch buffer. Use a temporary
            // stack-style chunk to avoid growing `buf` past what we
            // actually need.
            let prev_len = self.buf.len();
            self.buf.resize(prev_len + self.chunk, 0);
            let n = match reader.read(&mut self.buf[prev_len..]).await {
                Ok(n) => n,
                Err(e) => {
                    self.buf.truncate(prev_len);
                    return Err(ReadError::Io(e));
                }
            };
            self.buf.truncate(prev_len + n);

            if n == 0 {
                // Clean EOF.
                return if self.buf.is_empty() {
                    Ok(None)
                } else {
                    Err(ReadError::UnexpectedEof)
                };
            }
        }
    }

    /// Bytes currently buffered (test/diagnostic accessor).
    #[must_use]
    pub fn buffered_len(&self) -> usize {
        self.buf.len()
    }
}

impl Default for FrameReader {
    fn default() -> Self {
        Self::new()
    }
}

/// Hard cap on the per-connection scratch buffer — matches the wire
/// `MAX_FRAME_PAYLOAD_BYTES` envelope. The reader will never allocate
/// more than this for one connection; the decoder rejects oversized
/// frames before any allocation past the cap.
///
/// `MIN_FRAME_HEADER_BYTES` is a small compile-time integer (currently 16);
/// the `as u32` cast is sound by construction. A test below asserts the
/// invariant.
#[allow(clippy::cast_possible_truncation)]
pub const READER_BUFFER_CAP: u32 = MIN_FRAME_HEADER_BYTES as u32 + MAX_FRAME_PAYLOAD_BYTES;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::wire::encode;
    use crate::ipc::{Message, RedactionReason};
    use std::io::Cursor;
    use tokio::io::AsyncWriteExt;

    fn sample_tombstone(seq: u64) -> Vec<u8> {
        encode(
            seq,
            &Message::PrivacyTombstone {
                ts_us: seq * 1000,
                app_bundle: "com.apple.Safari".to_string(),
                reason: RedactionReason::AxSecureSubrole,
            },
        )
    }

    /// Read a single frame from a Cursor — happy path, all bytes
    /// available up-front.
    #[tokio::test]
    async fn reads_single_frame_in_one_shot() {
        let bytes = sample_tombstone(1);
        let mut cursor = Cursor::new(bytes);
        let mut reader = FrameReader::new();
        let frame = reader.read_frame(&mut cursor).await.unwrap().unwrap();
        assert_eq!(frame.seq, 1);
        assert!(matches!(frame.message, Message::PrivacyTombstone { .. }));
    }

    /// Read three concatenated frames sequentially.
    #[tokio::test]
    async fn reads_multiple_frames_streaming() {
        let mut stream = Vec::new();
        stream.extend(sample_tombstone(1));
        stream.extend(sample_tombstone(2));
        stream.extend(sample_tombstone(3));
        let mut cursor = Cursor::new(stream);
        let mut reader = FrameReader::new();

        for expected in 1..=3 {
            let f = reader.read_frame(&mut cursor).await.unwrap().unwrap();
            assert_eq!(f.seq, expected);
        }

        // After the last frame, the next read returns Ok(None) — clean
        // EOF with no leftover bytes.
        let next = reader.read_frame(&mut cursor).await.unwrap();
        assert!(next.is_none());
    }

    /// Read across multiple `.read()` calls (small chunk size) to
    /// confirm the reader correctly handles fragmented transport
    /// reads — this is the realistic Unix-socket case.
    #[tokio::test]
    async fn reads_frame_fragmented_across_chunks() {
        let bytes = sample_tombstone(42);
        let mut cursor = Cursor::new(bytes);
        let mut reader = FrameReader::with_chunk_size(4); // tiny chunks
        let frame = reader.read_frame(&mut cursor).await.unwrap().unwrap();
        assert_eq!(frame.seq, 42);
    }

    /// EOF before any byte has been read returns `Ok(None)`, not an
    /// error. Required so connection-close during shutdown is graceful.
    #[tokio::test]
    async fn clean_eof_with_empty_buffer_returns_none() {
        let mut cursor = Cursor::new(Vec::<u8>::new());
        let mut reader = FrameReader::new();
        let next = reader.read_frame(&mut cursor).await.unwrap();
        assert!(next.is_none());
    }

    /// EOF mid-frame returns `UnexpectedEof` — the helper closed the
    /// socket after sending a header but before the payload. Caller
    /// closes the connection.
    #[tokio::test]
    async fn truncated_frame_returns_unexpected_eof() {
        let bytes = sample_tombstone(7);
        // Send only the first 6 bytes of the header.
        let mut cursor = Cursor::new(bytes[..6].to_vec());
        let mut reader = FrameReader::new();
        let err = reader.read_frame(&mut cursor).await.unwrap_err();
        assert!(matches!(err, ReadError::UnexpectedEof), "got {err:?}");
    }

    /// Bad magic byte aborts immediately — does not block waiting for
    /// more bytes. Trust boundary.
    #[tokio::test]
    async fn bad_magic_returns_decode_error() {
        let mut bytes = sample_tombstone(0);
        bytes[0] = 0xFF;
        let mut cursor = Cursor::new(bytes);
        let mut reader = FrameReader::new();
        let err = reader.read_frame(&mut cursor).await.unwrap_err();
        assert!(matches!(
            err,
            ReadError::Decode(DecodeError::BadMagic { .. })
        ));
    }

    /// Oversized payload header (declares > 1 MiB) aborts BEFORE any
    /// further read. This is the `DoS` guard from PR #11; the reader
    /// honors it by never allocating past the cap.
    #[tokio::test]
    async fn oversized_payload_header_rejected_immediately() {
        // Hand-build a header that declares 2 MiB.
        let mut buf = vec![0x4D, 0x01]; // magic + version
        buf.extend_from_slice(&0x0002_u16.to_le_bytes()); // CaptureStop
        buf.extend_from_slice(&0_u64.to_le_bytes()); // seq
        buf.extend_from_slice(&(2_u32 * 1024 * 1024).to_le_bytes()); // len
                                                                     // No payload bytes — but the reader must reject from the header
                                                                     // alone.
        let mut cursor = Cursor::new(buf);
        let mut reader = FrameReader::new();
        let err = reader.read_frame(&mut cursor).await.unwrap_err();
        assert!(matches!(
            err,
            ReadError::Decode(DecodeError::OversizedPayload { .. })
        ));
    }

    /// A `tokio::io::DuplexStream` exercises the real `AsyncRead` impl —
    /// confirms the reader is generic over any `AsyncRead + Unpin`.
    #[tokio::test]
    async fn reads_over_duplex_stream() {
        let (mut tx, mut rx) = tokio::io::duplex(64);

        let bytes = sample_tombstone(99);
        let writer_task = tokio::spawn(async move {
            tx.write_all(&bytes).await.unwrap();
            tx.shutdown().await.unwrap();
        });

        let mut reader = FrameReader::new();
        let frame = reader.read_frame(&mut rx).await.unwrap().unwrap();
        assert_eq!(frame.seq, 99);

        writer_task.await.unwrap();
    }

    #[test]
    fn reader_buffer_cap_matches_wire_envelope() {
        // The reader's max allocation per connection MUST match what
        // the wire decoder accepts. Any drift makes the cap meaningless.
        assert_eq!(
            READER_BUFFER_CAP as usize,
            MIN_FRAME_HEADER_BYTES + MAX_FRAME_PAYLOAD_BYTES as usize
        );
    }
}
