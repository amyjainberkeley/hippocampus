//! Byte-explicit wire encode / decode for [`super::Message`].
//!
//! No `serde`. Each message variant has its own `encode_*` / `decode_*`
//! helper; the public [`encode`] and [`decode`] functions dispatch on
//! the discriminant. Every encode + decode pair is round-trip-tested.
//!
//! Strings are length-prefixed UTF-8 (`u16 LE` length + bytes). Vectors
//! of `DirtyRect` use a `u16 LE` count + the rects packed back-to-back.
//! All integers are little-endian. The header layout is documented in
//! [`super`].

use super::{DirtyRect, Message, RedactionReason};

/// Wire-format magic byte. Frames lacking this leading byte are rejected
/// as not-MCI-IPC.
pub const FRAME_MAGIC: u8 = 0x4D; // 'M'

/// Current wire-format version. Bumped on any breaking layout change.
pub const FRAME_VERSION: u8 = 0x01;

/// Header size in bytes: magic(1) + version(1) + `msg_type(2)` + seq(8) + len(4).
pub const MIN_FRAME_HEADER_BYTES: usize = 1 + 1 + 2 + 8 + 4;

/// Maximum payload bytes a single frame may carry.
///
/// Generous: covers a `StateTransitionEvent` with thousands of dirty rects.
/// Hard cap so a fuzzed / malicious helper cannot ask the core to allocate
/// gigabytes by sending a giant `len` header.
pub const MAX_FRAME_PAYLOAD_BYTES: u32 = 1 << 20; // 1 MiB

/// Wire-protocol message-type discriminant (the `msg_type` header field).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u16)]
pub enum MessageType {
    /// Core → helper start signal (see [`super::Message::CaptureStart`]).
    CaptureStart = 0x0001,
    /// Core → helper stop signal (see [`super::Message::CaptureStop`]).
    CaptureStop = 0x0002,
    /// Helper → core surviving-cascade frame
    /// (see [`super::Message::StateTransitionEvent`]).
    StateTransitionEvent = 0x0010,
    /// Helper → core suppression record
    /// (see [`super::Message::PrivacyTombstone`]).
    PrivacyTombstone = 0x0011,
    /// Core → helper surface-released ack
    /// (see [`super::Message::SurfaceReleased`]).
    SurfaceReleased = 0x0020,
    /// Helper → core periodic health counters
    /// (see [`super::Message::HelperHealth`]).
    HelperHealth = 0x0030,
}

impl MessageType {
    /// Decode a wire-byte discriminant.
    ///
    /// # Errors
    /// Returns [`DecodeError::InvalidEnum`] for unknown values.
    pub fn from_u16(v: u16) -> Result<Self, DecodeError> {
        Ok(match v {
            0x0001 => Self::CaptureStart,
            0x0002 => Self::CaptureStop,
            0x0010 => Self::StateTransitionEvent,
            0x0011 => Self::PrivacyTombstone,
            0x0020 => Self::SurfaceReleased,
            0x0030 => Self::HelperHealth,
            other => {
                return Err(DecodeError::InvalidEnum {
                    field: "MessageType",
                    value: u32::from(other),
                })
            }
        })
    }
}

/// A decoded frame with its sequence number and message payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    /// Monotonic sequence number assigned by the sender.
    pub seq: u64,
    /// Decoded message body.
    pub message: Message,
}

/// Errors returned by [`decode`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    /// Buffer is shorter than the minimum frame header (16 bytes).
    ShortBuffer,
    /// Buffer is shorter than `MIN_FRAME_HEADER_BYTES + len`.
    Truncated {
        /// Total bytes the parser needed to make progress.
        needed: usize,
        /// Bytes actually available in the input buffer.
        have: usize,
    },
    /// First byte was not [`FRAME_MAGIC`].
    BadMagic {
        /// The actual magic byte received.
        got: u8,
    },
    /// `version` byte does not match [`FRAME_VERSION`].
    UnsupportedVersion {
        /// The version byte received.
        got: u8,
    },
    /// `len` header exceeds [`MAX_FRAME_PAYLOAD_BYTES`]. A misbehaving or
    /// malicious helper cannot `DoS` the core into a huge allocation.
    OversizedPayload {
        /// The declared payload length that was over the cap.
        len: u32,
    },
    /// Enum discriminant doesn't match any known variant.
    InvalidEnum {
        /// The enum being decoded (e.g. `"MessageType"`).
        field: &'static str,
        /// The unrecognized discriminant value.
        value: u32,
    },
    /// Payload bytes were consumed but the message decoder did not consume
    /// them all (or asked for more than the payload had).
    PayloadLengthMismatch {
        /// Wire-format `msg_type` discriminant.
        msg_type: u16,
        /// Bytes the message decoder actually consumed.
        expected: usize,
        /// Bytes the frame header declared.
        declared: u32,
    },
    /// A length-prefixed UTF-8 string failed `from_utf8`.
    InvalidUtf8,
}

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ShortBuffer => write!(f, "buffer shorter than frame header"),
            Self::Truncated { needed, have } => {
                write!(f, "truncated frame: needed {needed} bytes, have {have}")
            }
            Self::BadMagic { got } => write!(f, "bad magic byte: got 0x{got:02x}, expected 0x4D"),
            Self::UnsupportedVersion { got } => {
                write!(f, "unsupported wire version: got 0x{got:02x}")
            }
            Self::OversizedPayload { len } => {
                write!(f, "oversized payload: {len} bytes (max {MAX_FRAME_PAYLOAD_BYTES})")
            }
            Self::InvalidEnum { field, value } => {
                write!(f, "invalid {field} discriminant: 0x{value:x}")
            }
            Self::PayloadLengthMismatch { msg_type, expected, declared } => write!(
                f,
                "payload-length mismatch for msg_type 0x{msg_type:04x}: decoder used {expected} of {declared} bytes"
            ),
            Self::InvalidUtf8 => write!(f, "invalid utf-8 in length-prefixed string"),
        }
    }
}

impl std::error::Error for DecodeError {}

// ---------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------

/// Encode a [`Message`] with the given sequence number into the wire format.
///
/// The returned buffer is `MIN_FRAME_HEADER_BYTES + payload.len()` bytes.
/// The fd (if any) for [`Message::StateTransitionEvent`] is **not** in this
/// buffer — it travels out-of-band via `SCM_RIGHTS` on the socket.
#[must_use]
pub fn encode(seq: u64, msg: &Message) -> Vec<u8> {
    let mut payload = Vec::with_capacity(64);
    encode_payload(msg, &mut payload);
    debug_assert!(
        payload.len() <= MAX_FRAME_PAYLOAD_BYTES as usize,
        "encoded payload exceeds MAX_FRAME_PAYLOAD_BYTES"
    );

    let mut out = Vec::with_capacity(MIN_FRAME_HEADER_BYTES + payload.len());
    out.push(FRAME_MAGIC);
    out.push(FRAME_VERSION);
    out.extend_from_slice(&(msg.message_type() as u16).to_le_bytes());
    out.extend_from_slice(&seq.to_le_bytes());
    #[allow(clippy::cast_possible_truncation)]
    let payload_len = payload.len() as u32;
    out.extend_from_slice(&payload_len.to_le_bytes());
    out.extend_from_slice(&payload);
    out
}

fn encode_payload(msg: &Message, out: &mut Vec<u8>) {
    match msg {
        Message::CaptureStart {
            interval_ms,
            queue_depth,
        } => {
            out.extend_from_slice(&interval_ms.to_le_bytes());
            out.push(*queue_depth);
        }
        Message::CaptureStop => {
            // No payload.
        }
        Message::StateTransitionEvent {
            ts_us,
            fd_index,
            width_px,
            height_px,
            status_flags,
            dirty_rects,
        } => {
            out.extend_from_slice(&ts_us.to_le_bytes());
            out.push(*fd_index);
            out.extend_from_slice(&width_px.to_le_bytes());
            out.extend_from_slice(&height_px.to_le_bytes());
            out.push(*status_flags);
            #[allow(clippy::cast_possible_truncation)]
            let n = dirty_rects.len() as u16;
            out.extend_from_slice(&n.to_le_bytes());
            for r in dirty_rects {
                out.extend_from_slice(&r.x.to_le_bytes());
                out.extend_from_slice(&r.y.to_le_bytes());
                out.extend_from_slice(&r.width.to_le_bytes());
                out.extend_from_slice(&r.height.to_le_bytes());
            }
        }
        Message::PrivacyTombstone {
            ts_us,
            app_bundle,
            reason,
        } => {
            out.extend_from_slice(&ts_us.to_le_bytes());
            encode_string(app_bundle, out);
            out.push(reason.as_u8());
        }
        Message::SurfaceReleased { fd_index, ack_seq } => {
            out.push(*fd_index);
            out.extend_from_slice(&ack_seq.to_le_bytes());
        }
        Message::HelperHealth {
            uptime_ms,
            frames_delivered,
            frames_suppressed,
            frames_dropped_backpressure,
            frames_dropped_late_ack,
        } => {
            out.extend_from_slice(&uptime_ms.to_le_bytes());
            out.extend_from_slice(&frames_delivered.to_le_bytes());
            out.extend_from_slice(&frames_suppressed.to_le_bytes());
            out.extend_from_slice(&frames_dropped_backpressure.to_le_bytes());
            out.extend_from_slice(&frames_dropped_late_ack.to_le_bytes());
        }
    }
}

fn encode_string(s: &str, out: &mut Vec<u8>) {
    let bytes = s.as_bytes();
    debug_assert!(
        u16::try_from(bytes.len()).is_ok(),
        "string too long for u16 length prefix"
    );
    #[allow(clippy::cast_possible_truncation)]
    let n = bytes.len() as u16;
    out.extend_from_slice(&n.to_le_bytes());
    out.extend_from_slice(bytes);
}

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

/// Decode a single frame from `buf`.
///
/// Returns the decoded [`Frame`] **and** the number of input bytes
/// consumed, so callers parsing a stream can advance their read cursor.
///
/// # Errors
/// Returns a [`DecodeError`] for any malformed, truncated, oversized,
/// unsupported-version, or enum-discriminant-invalid input. The decoder
/// is the trust boundary: it never panics on hostile input.
pub fn decode(buf: &[u8]) -> Result<(Frame, usize), DecodeError> {
    if buf.len() < MIN_FRAME_HEADER_BYTES {
        return Err(DecodeError::ShortBuffer);
    }
    let magic = buf[0];
    if magic != FRAME_MAGIC {
        return Err(DecodeError::BadMagic { got: magic });
    }
    let version = buf[1];
    if version != FRAME_VERSION {
        return Err(DecodeError::UnsupportedVersion { got: version });
    }
    let msg_type_raw = u16::from_le_bytes([buf[2], buf[3]]);
    let msg_type = MessageType::from_u16(msg_type_raw)?;
    let seq = u64::from_le_bytes(buf[4..12].try_into().expect("8 bytes from header"));
    let declared_len = u32::from_le_bytes(buf[12..16].try_into().expect("4 bytes from header"));
    if declared_len > MAX_FRAME_PAYLOAD_BYTES {
        return Err(DecodeError::OversizedPayload { len: declared_len });
    }
    let total = MIN_FRAME_HEADER_BYTES + declared_len as usize;
    if buf.len() < total {
        return Err(DecodeError::Truncated {
            needed: total,
            have: buf.len(),
        });
    }
    let payload = &buf[MIN_FRAME_HEADER_BYTES..total];

    let (message, used) = decode_payload(msg_type, payload)?;
    if used != payload.len() {
        return Err(DecodeError::PayloadLengthMismatch {
            msg_type: msg_type_raw,
            expected: used,
            declared: declared_len,
        });
    }
    Ok((Frame { seq, message }, total))
}

fn decode_payload(msg_type: MessageType, payload: &[u8]) -> Result<(Message, usize), DecodeError> {
    let mut p = Parser::new(payload);
    let msg = match msg_type {
        MessageType::CaptureStart => {
            let interval_ms = p.u32_le()?;
            let queue_depth = p.u8_le()?;
            Message::CaptureStart {
                interval_ms,
                queue_depth,
            }
        }
        MessageType::CaptureStop => Message::CaptureStop,
        MessageType::StateTransitionEvent => {
            let ts_us = p.u64_le()?;
            let fd_index = p.u8_le()?;
            let width_px = p.u32_le()?;
            let height_px = p.u32_le()?;
            let status_flags = p.u8_le()?;
            let n = p.u16_le()?;
            let mut dirty_rects = Vec::with_capacity(n as usize);
            for _ in 0..n {
                let x = p.u32_le()?;
                let y = p.u32_le()?;
                let width = p.u32_le()?;
                let height = p.u32_le()?;
                dirty_rects.push(DirtyRect {
                    x,
                    y,
                    width,
                    height,
                });
            }
            Message::StateTransitionEvent {
                ts_us,
                fd_index,
                width_px,
                height_px,
                status_flags,
                dirty_rects,
            }
        }
        MessageType::PrivacyTombstone => {
            let ts_us = p.u64_le()?;
            let app_bundle = p.string()?;
            let reason = RedactionReason::from_u8(p.u8_le()?)?;
            Message::PrivacyTombstone {
                ts_us,
                app_bundle,
                reason,
            }
        }
        MessageType::SurfaceReleased => {
            let fd_index = p.u8_le()?;
            let ack_seq = p.u64_le()?;
            Message::SurfaceReleased { fd_index, ack_seq }
        }
        MessageType::HelperHealth => {
            let uptime_ms = p.u64_le()?;
            let frames_delivered = p.u64_le()?;
            let frames_suppressed = p.u64_le()?;
            let frames_dropped_backpressure = p.u64_le()?;
            let frames_dropped_late_ack = p.u64_le()?;
            Message::HelperHealth {
                uptime_ms,
                frames_delivered,
                frames_suppressed,
                frames_dropped_backpressure,
                frames_dropped_late_ack,
            }
        }
    };
    Ok((msg, p.cursor()))
}

struct Parser<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    const fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }
    const fn cursor(&self) -> usize {
        self.pos
    }
    fn take(&mut self, n: usize) -> Result<&'a [u8], DecodeError> {
        if self.pos + n > self.buf.len() {
            return Err(DecodeError::Truncated {
                needed: self.pos + n,
                have: self.buf.len(),
            });
        }
        let s = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }
    fn u8_le(&mut self) -> Result<u8, DecodeError> {
        Ok(self.take(1)?[0])
    }
    fn u16_le(&mut self) -> Result<u16, DecodeError> {
        let s = self.take(2)?;
        Ok(u16::from_le_bytes([s[0], s[1]]))
    }
    fn u32_le(&mut self) -> Result<u32, DecodeError> {
        let s = self.take(4)?;
        Ok(u32::from_le_bytes(s.try_into().expect("4 bytes")))
    }
    fn u64_le(&mut self) -> Result<u64, DecodeError> {
        let s = self.take(8)?;
        Ok(u64::from_le_bytes(s.try_into().expect("8 bytes")))
    }
    fn string(&mut self) -> Result<String, DecodeError> {
        let n = self.u16_le()? as usize;
        let bytes = self.take(n)?;
        std::str::from_utf8(bytes)
            .map(ToOwned::to_owned)
            .map_err(|_| DecodeError::InvalidUtf8)
    }
}

// ---------------------------------------------------------------------------
// Tests — round trip + boundary + hostile-input
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn roundtrip(msg: &Message) {
        let buf = encode(42, msg);
        let (frame, used) = decode(&buf).expect("decode");
        assert_eq!(used, buf.len(), "decoder consumed full buffer");
        assert_eq!(frame.seq, 42);
        assert_eq!(&frame.message, msg);
    }

    #[test]
    fn roundtrip_capture_start() {
        roundtrip(&Message::CaptureStart {
            interval_ms: 200,
            queue_depth: 3,
        });
    }

    #[test]
    fn roundtrip_capture_stop() {
        roundtrip(&Message::CaptureStop);
    }

    #[test]
    fn roundtrip_state_transition_no_rects() {
        roundtrip(&Message::StateTransitionEvent {
            ts_us: 1_234_567_890,
            fd_index: 0,
            width_px: 3024,
            height_px: 1964,
            status_flags: super::super::FrameStatusFlags::COMPLETE,
            dirty_rects: vec![],
        });
    }

    #[test]
    fn roundtrip_state_transition_many_rects() {
        let rects = (0..1024_u32)
            .map(|i| DirtyRect {
                x: i,
                y: i * 2,
                width: 16,
                height: 16,
            })
            .collect::<Vec<_>>();
        roundtrip(&Message::StateTransitionEvent {
            ts_us: 999,
            fd_index: 2,
            width_px: 1920,
            height_px: 1080,
            status_flags: super::super::FrameStatusFlags::COMPLETE
                | super::super::FrameStatusFlags::IDLE,
            dirty_rects: rects,
        });
    }

    #[test]
    fn roundtrip_privacy_tombstone() {
        for reason in [
            RedactionReason::DenylistSource,
            RedactionReason::OsBlackedRegion,
            RedactionReason::SecureEventInput,
            RedactionReason::AxSecureSubrole,
            RedactionReason::DenylistPostCapture,
            RedactionReason::FailsafeUnknown,
        ] {
            roundtrip(&Message::PrivacyTombstone {
                ts_us: 7,
                app_bundle: "com.apple.Safari".to_string(),
                reason,
            });
        }
    }

    #[test]
    fn roundtrip_privacy_tombstone_unicode_bundle() {
        // Strings are length-prefixed UTF-8; multi-byte should round-trip.
        roundtrip(&Message::PrivacyTombstone {
            ts_us: 7,
            app_bundle: "com.example.密码管理器".to_string(),
            reason: RedactionReason::AxSecureSubrole,
        });
    }

    #[test]
    fn roundtrip_surface_released() {
        roundtrip(&Message::SurfaceReleased {
            fd_index: 1,
            ack_seq: 12345,
        });
    }

    #[test]
    fn roundtrip_helper_health() {
        roundtrip(&Message::HelperHealth {
            uptime_ms: u64::MAX / 2,
            frames_delivered: 1_000_000,
            frames_suppressed: 42,
            frames_dropped_backpressure: 7,
            frames_dropped_late_ack: 0,
        });
    }

    #[test]
    fn decode_rejects_short_buffer() {
        let err = decode(&[0; 5]).unwrap_err();
        assert!(matches!(err, DecodeError::ShortBuffer));
    }

    #[test]
    fn decode_rejects_bad_magic() {
        let mut buf = encode(0, &Message::CaptureStop);
        buf[0] = 0xFF;
        let err = decode(&buf).unwrap_err();
        assert!(matches!(err, DecodeError::BadMagic { got: 0xFF }));
    }

    #[test]
    fn decode_rejects_unsupported_version() {
        let mut buf = encode(0, &Message::CaptureStop);
        buf[1] = 0xEE;
        let err = decode(&buf).unwrap_err();
        assert!(matches!(err, DecodeError::UnsupportedVersion { got: 0xEE }));
    }

    #[test]
    fn decode_rejects_oversized_payload_header_alone() {
        // Construct a header that claims an enormous payload length.
        // Decoder must reject before allocating / before slicing.
        let mut buf = vec![FRAME_MAGIC, FRAME_VERSION];
        buf.extend_from_slice(&(MessageType::CaptureStop as u16).to_le_bytes());
        buf.extend_from_slice(&0_u64.to_le_bytes());
        // Declare a 2 MiB payload — over the 1 MiB cap.
        buf.extend_from_slice(&(2_u32 * 1024 * 1024).to_le_bytes());
        let err = decode(&buf).unwrap_err();
        assert!(matches!(err, DecodeError::OversizedPayload { .. }));
    }

    #[test]
    fn decode_rejects_truncated_payload() {
        let buf = encode(
            0,
            &Message::CaptureStart {
                interval_ms: 100,
                queue_depth: 3,
            },
        );
        // Lop off the last byte.
        let truncated = &buf[..buf.len() - 1];
        let err = decode(truncated).unwrap_err();
        assert!(matches!(err, DecodeError::Truncated { .. }));
    }

    #[test]
    fn decode_rejects_invalid_message_type() {
        let mut buf = vec![FRAME_MAGIC, FRAME_VERSION];
        buf.extend_from_slice(&0xBEEF_u16.to_le_bytes()); // unknown msg type
        buf.extend_from_slice(&0_u64.to_le_bytes());
        buf.extend_from_slice(&0_u32.to_le_bytes());
        let err = decode(&buf).unwrap_err();
        assert!(matches!(
            err,
            DecodeError::InvalidEnum {
                field: "MessageType",
                ..
            }
        ));
    }

    #[test]
    fn decode_rejects_invalid_redaction_reason() {
        // Hand-craft a PrivacyTombstone with reason byte = 99.
        let mut payload = Vec::new();
        payload.extend_from_slice(&0_u64.to_le_bytes());
        encode_string("com.example.app", &mut payload);
        payload.push(99);

        let mut buf = vec![FRAME_MAGIC, FRAME_VERSION];
        buf.extend_from_slice(&(MessageType::PrivacyTombstone as u16).to_le_bytes());
        buf.extend_from_slice(&0_u64.to_le_bytes());
        #[allow(clippy::cast_possible_truncation)]
        let payload_len = payload.len() as u32;
        buf.extend_from_slice(&payload_len.to_le_bytes());
        buf.extend_from_slice(&payload);

        let err = decode(&buf).unwrap_err();
        assert!(matches!(
            err,
            DecodeError::InvalidEnum {
                field: "RedactionReason",
                ..
            }
        ));
    }

    #[test]
    fn decode_streaming_returns_used_byte_count() {
        // Concatenate three frames; decoder should report exactly each frame's length.
        let mut buf = encode(1, &Message::CaptureStop);
        buf.extend(encode(
            2,
            &Message::CaptureStart {
                interval_ms: 100,
                queue_depth: 3,
            },
        ));
        buf.extend(encode(3, &Message::CaptureStop));

        let mut cursor = 0;
        let (f1, n1) = decode(&buf[cursor..]).unwrap();
        cursor += n1;
        let (f2, n2) = decode(&buf[cursor..]).unwrap();
        cursor += n2;
        let (f3, n3) = decode(&buf[cursor..]).unwrap();
        cursor += n3;
        assert_eq!(cursor, buf.len(), "all bytes consumed across three frames");

        assert_eq!(f1.seq, 1);
        assert_eq!(f1.message, Message::CaptureStop);
        assert_eq!(f2.seq, 2);
        assert!(matches!(
            f2.message,
            Message::CaptureStart {
                interval_ms: 100,
                queue_depth: 3
            }
        ));
        assert_eq!(f3.seq, 3);
    }

    #[test]
    fn header_size_constant_matches_layout() {
        // Trip-wire test: if someone changes the header without
        // updating MIN_FRAME_HEADER_BYTES, this catches it.
        let buf = encode(0, &Message::CaptureStop);
        assert_eq!(
            buf.len(),
            MIN_FRAME_HEADER_BYTES,
            "CaptureStop has zero-byte payload"
        );
    }
}
