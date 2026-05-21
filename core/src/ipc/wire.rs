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
///
/// `0x01 → 0x02` (2026-05-19): `HelperHealth` gained the
/// `frames_redacted_by_failsafe` counter (a §7 fail-safe privacy-
/// regression sentinel for the CRS Telemetry-Gap analyst).
///
/// `0x02 → 0x03` (2026-05-20): `HelperHealth` gained the
/// `cascade_forced_count` counter — monotonically-increasing total of
/// cascade evaluations that ran because the cascade-floor heartbeat
/// elapsed (filter returned `.drop*` but the wall-clock since the last
/// cascade run reached `cascadeFloorIntervalMs`), strictly disjoint
/// from the existing filter-passed cascade calls. STEP-2-FINDING-004's
/// in-process counter (`HelperHealthCounters.cascadeForced`) is now
/// surfaced on the wire so the Telemetry-Gap analyst can observe
/// floor-forced evaluations on static secure surfaces.
///
/// `0x03 → 0x04` (2026-05-20, ADR-0016 P3.6): new
/// [`MessageType::OCREvent`] variant added — the FIRST message variant
/// carrying user content (OCR'd text) across the IPC seam. The variant
/// is gated by the ADR-0013 cascade running TWICE — once on pixels at
/// frame time (§1–§5 + §7), once on OCR'd text (§6 OCR-time secret/PII
/// regex). [`RedactionReason::OcrTimeSecret`] (= 6) is added so the
/// twice-fired path emits a [`Message::PrivacyTombstone`] with the
/// distinct reason instead of an `OCREvent`. The wire-frame-version
/// bump is lock-step with `adapters/macos/.../IPC/Wire.swift` and
/// `tools/wire_decode.py` per the PR #44 precedent. ADR-0016 §1.6
/// proposed `OCR_EVENT_MSG_TYPE = 0x0020` but that slot is occupied by
/// [`MessageType::SurfaceReleased`] (assigned in PR #15); this PR
/// assigns `0x0040`. ADR-0016 §1.6 owes a follow-up doc PR to align.
///
/// The decoder rejects any other version: helper and core ship
/// **version-locked** in the same signed bundle and capture is
/// default-OFF, so there are no persisted or in-flight `0x01` / `0x02`
/// / `0x03` frames to remain compatible with — a hard version break is
/// the correct, auditable choice over a silently mis-parsed payload.
pub const FRAME_VERSION: u8 = 0x04;

/// Header size in bytes: magic(1) + version(1) + `msg_type(2)` + seq(8) + len(4).
pub const MIN_FRAME_HEADER_BYTES: usize = 1 + 1 + 2 + 8 + 4;

/// Maximum payload bytes a single frame may carry.
///
/// Generous: covers a `StateTransitionEvent` with thousands of dirty rects.
/// Hard cap so a fuzzed / malicious helper cannot ask the core to allocate
/// gigabytes by sending a giant `len` header.
pub const MAX_FRAME_PAYLOAD_BYTES: u32 = 1 << 20; // 1 MiB

/// Maximum bytes of OCR'd text the helper is permitted to emit in a
/// single [`super::Message::OCREvent`] payload (ADR-0016 §4.9). Over-cap
/// OCR results fail closed: the helper emits a
/// [`super::Message::PrivacyTombstone`] with reason
/// [`super::RedactionReason::FailsafeUnknown`] instead. Defense-in-depth
/// against an OCR run that pathologically produces megabytes of text
/// from one frame (ADR-0013 §7 fail-closed default).
pub const MAX_OCR_TEXT_BYTES: u32 = 64 * 1024;

/// Fixed app-bundle-id field length in [`super::Message::OCREvent`]
/// (null-padded). ADR-0016 §1.6.
pub const OCR_EVENT_APP_BUNDLE_ID_LEN: usize = 64;

/// Fixed keyframe-hash field length in [`super::Message::OCREvent`]
/// (blake3 of the keyframe blob; all-zero bytes signals "no blob yet"
/// in P3.6 — the blob writer lands at P3.6.5). ADR-0016 §1.6.
pub const OCR_EVENT_KEYFRAME_HASH_LEN: usize = 32;

/// Fixed-portion byte length of an `OCREvent` payload, before the
/// variable-length `window_title` / url / `ocr_text` bytes. ADR-0016 §1.6:
///   `seq(8)` + `ts_us(8)` + `app_bundle_id(64)` + `window_title_len(2)`
///   + `url_len(2)` + `ocr_text_len(4)` + `keyframe_hash(32)` = 120 bytes.
pub const OCR_EVENT_FIXED_HEADER_BYTES: usize =
    8 + 8 + OCR_EVENT_APP_BUNDLE_ID_LEN + 2 + 2 + 4 + OCR_EVENT_KEYFRAME_HASH_LEN;

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
    /// Helper → core twice-cleared OCR event with user content
    /// (see [`super::Message::OCREvent`]). ADR-0016 P3.6.
    OCREvent = 0x0040,
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
            0x0040 => Self::OCREvent,
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

#[allow(clippy::too_many_lines)]
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
            frames_redacted_by_failsafe,
            cascade_forced_count,
            frames_dropped_backpressure,
            frames_dropped_late_ack,
        } => {
            out.extend_from_slice(&uptime_ms.to_le_bytes());
            out.extend_from_slice(&frames_delivered.to_le_bytes());
            out.extend_from_slice(&frames_suppressed.to_le_bytes());
            out.extend_from_slice(&frames_redacted_by_failsafe.to_le_bytes());
            // wire 0x03: cascade_forced_count immediately follows
            // frames_redacted_by_failsafe (the PR #24 precedent: a new
            // u64 inserts in the natural "what does the cascade see"
            // cluster, before the drop-side counters).
            out.extend_from_slice(&cascade_forced_count.to_le_bytes());
            out.extend_from_slice(&frames_dropped_backpressure.to_le_bytes());
            out.extend_from_slice(&frames_dropped_late_ack.to_le_bytes());
        }
        Message::OCREvent {
            seq,
            ts_us,
            app_bundle_id,
            window_title,
            url,
            ocr_text,
            keyframe_hash,
        } => {
            out.extend_from_slice(&seq.to_le_bytes());
            out.extend_from_slice(&ts_us.to_le_bytes());
            out.extend_from_slice(app_bundle_id);
            debug_assert!(
                u16::try_from(window_title.len()).is_ok(),
                "OCREvent window_title too long for u16 length prefix"
            );
            debug_assert!(
                u16::try_from(url.len()).is_ok(),
                "OCREvent url too long for u16 length prefix"
            );
            debug_assert!(
                u32::try_from(ocr_text.len()).is_ok(),
                "OCREvent ocr_text too long for u32 length prefix"
            );
            debug_assert!(
                ocr_text.len() as u64 <= u64::from(MAX_OCR_TEXT_BYTES),
                "OCREvent ocr_text exceeds MAX_OCR_TEXT_BYTES (ADR-0016 §4.9)"
            );
            #[allow(clippy::cast_possible_truncation)]
            let window_title_len = window_title.len() as u16;
            #[allow(clippy::cast_possible_truncation)]
            let url_len = url.len() as u16;
            #[allow(clippy::cast_possible_truncation)]
            let ocr_text_len = ocr_text.len() as u32;
            out.extend_from_slice(&window_title_len.to_le_bytes());
            out.extend_from_slice(&url_len.to_le_bytes());
            out.extend_from_slice(&ocr_text_len.to_le_bytes());
            out.extend_from_slice(keyframe_hash);
            out.extend_from_slice(window_title.as_bytes());
            out.extend_from_slice(url.as_bytes());
            out.extend_from_slice(ocr_text.as_bytes());
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

#[allow(clippy::too_many_lines)]
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
            let frames_redacted_by_failsafe = p.u64_le()?;
            let cascade_forced_count = p.u64_le()?;
            let frames_dropped_backpressure = p.u64_le()?;
            let frames_dropped_late_ack = p.u64_le()?;
            Message::HelperHealth {
                uptime_ms,
                frames_delivered,
                frames_suppressed,
                frames_redacted_by_failsafe,
                cascade_forced_count,
                frames_dropped_backpressure,
                frames_dropped_late_ack,
            }
        }
        MessageType::OCREvent => {
            let seq = p.u64_le()?;
            let ts_us = p.u64_le()?;
            let app_bundle_id = p.fixed_64()?;
            let window_title_len = p.u16_le()? as usize;
            let url_len = p.u16_le()? as usize;
            let ocr_text_len_raw = p.u32_le()?;
            if ocr_text_len_raw > MAX_OCR_TEXT_BYTES {
                return Err(DecodeError::OversizedPayload {
                    len: ocr_text_len_raw,
                });
            }
            let ocr_text_len = ocr_text_len_raw as usize;
            let keyframe_hash = p.fixed_32()?;
            let window_title = p.string_bytes(window_title_len)?;
            let url = p.string_bytes(url_len)?;
            let ocr_text = p.string_bytes(ocr_text_len)?;
            Message::OCREvent {
                seq,
                ts_us,
                app_bundle_id,
                window_title,
                url,
                ocr_text,
                keyframe_hash,
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
    fn string_bytes(&mut self, n: usize) -> Result<String, DecodeError> {
        let bytes = self.take(n)?;
        std::str::from_utf8(bytes)
            .map(ToOwned::to_owned)
            .map_err(|_| DecodeError::InvalidUtf8)
    }
    fn fixed_32(&mut self) -> Result<[u8; 32], DecodeError> {
        let bytes = self.take(32)?;
        let mut out = [0u8; 32];
        out.copy_from_slice(bytes);
        Ok(out)
    }
    fn fixed_64(&mut self) -> Result<[u8; 64], DecodeError> {
        let bytes = self.take(64)?;
        let mut out = [0u8; 64];
        out.copy_from_slice(bytes);
        Ok(out)
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
            frames_redacted_by_failsafe: 13,
            cascade_forced_count: 5,
            frames_dropped_backpressure: 7,
            frames_dropped_late_ack: 0,
        });
    }

    #[test]
    fn helper_health_cross_side_fixture() {
        // Byte-exact mirror of the Swift
        // `WireFixturesTests.testHelperHealthCrossSideFixture` and the
        // layout parsed by `tools/wire_decode.py`. If any of those
        // three drift, the IPC contract is broken silently. This
        // fixture is the observable trip-wire. Wire 0x04 (P3.6) bumps
        // only the version byte for the new OCREvent variant;
        // HelperHealth's payload layout is unchanged.
        let buf = encode(
            42,
            &Message::HelperHealth {
                uptime_ms: 1,
                frames_delivered: 2,
                frames_suppressed: 3,
                frames_redacted_by_failsafe: 4,
                cascade_forced_count: 5,
                frames_dropped_backpressure: 6,
                frames_dropped_late_ack: 7,
            },
        );
        let expected: [u8; 72] = [
            0x4D, 0x04, 0x30, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x38, 0x00,
            0x00, 0x00, // u64 LE × 7
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ];
        assert_eq!(
            buf,
            expected.to_vec(),
            "HelperHealth v0x04 cross-side fixture"
        );

        // And the round-trip decoder reads exactly back what the
        // encoder produced — proves the v0x04 layout is self-consistent.
        let (frame, used) = decode(&buf).expect("decode v0x04 fixture");
        assert_eq!(used, buf.len());
        assert_eq!(frame.seq, 42);
        assert_eq!(
            frame.message,
            Message::HelperHealth {
                uptime_ms: 1,
                frames_delivered: 2,
                frames_suppressed: 3,
                frames_redacted_by_failsafe: 4,
                cascade_forced_count: 5,
                frames_dropped_backpressure: 6,
                frames_dropped_late_ack: 7,
            }
        );
    }

    #[test]
    fn helper_health_v0x03_payload_is_seven_u64s() {
        // Trip-wire: the wire 0x03 bump added one u64
        // (`cascade_forced_count`). The frame is now header(16) + 7 ×
        // u64(56) = 72 bytes. The Swift mirror's `testHelperHealthFixture`
        // asserts the same length. Drift here = silent IPC break.
        let buf = encode(
            1,
            &Message::HelperHealth {
                uptime_ms: 1000,
                frames_delivered: 100,
                frames_suppressed: 5,
                frames_redacted_by_failsafe: 3,
                cascade_forced_count: 11,
                frames_dropped_backpressure: 2,
                frames_dropped_late_ack: 0,
            },
        );
        assert_eq!(buf.len(), MIN_FRAME_HEADER_BYTES + 7 * 8);
        // cascade_forced_count is the 5th u64 of the payload.
        // Offset = header(16) + 4 × u64(32) = 48.
        let off = MIN_FRAME_HEADER_BYTES + 4 * 8;
        let cfc = u64::from_le_bytes(buf[off..off + 8].try_into().unwrap());
        assert_eq!(cfc, 11);
    }

    #[test]
    fn frame_version_is_0x04() {
        // Trip-wire: the wire bump for OCREvent moved the version
        // 0x03 → 0x04 (ADR-0016 P3.6). The Swift `Wire.swift` mirror
        // and the byte fixtures in `WireTests.swift` MUST match.
        assert_eq!(FRAME_VERSION, 0x04);
        let buf = encode(0, &Message::CaptureStop);
        assert_eq!(buf[1], 0x04, "version byte in the framed header");
    }

    #[test]
    fn decode_rejects_old_0x03_frame_at_v0x04_layout() {
        // Lock-step cross-version regression guard (PR #44 precedent
        // for 0x02→0x03; this is the 0x03→0x04 analog). A stale signed
        // helper from a prior bundle pumping 0x03 bytes into a 0x04
        // core MUST be rejected at the trust boundary before the
        // payload decoder runs — otherwise an OCREvent emitted as a
        // 0x03 frame could be silently mis-parsed.
        let mut buf = encode(0, &Message::CaptureStop);
        buf[1] = 0x03;
        let err = decode(&buf).unwrap_err();
        assert!(matches!(err, DecodeError::UnsupportedVersion { got: 0x03 }));
    }

    #[test]
    fn decode_rejects_old_0x02_frame() {
        // Helper + core ship version-locked; an 0x02 frame is a stale
        // peer, not a compatible one. The decoder rejects it loudly
        // rather than mis-parsing a `HelperHealth` whose layout moved.
        let mut buf = encode(0, &Message::CaptureStop);
        buf[1] = 0x02;
        let err = decode(&buf).unwrap_err();
        assert!(matches!(err, DecodeError::UnsupportedVersion { got: 0x02 }));
    }

    #[test]
    fn decode_rejects_old_0x01_frame_at_v0x04_layout() {
        // Cross-version regression guard. The decoder MUST refuse to
        // read a 0x01 (or any non-FRAME_VERSION) frame at the v0x04
        // payload layout. Without this, a stale signed helper from a
        // prior bundle could pump 0x01 bytes into a 0x04 core and the
        // strict payload-length consumption tripwire downstream would
        // not catch it (the version check fails first, which is the
        // whole point — fail loud at the trust boundary).
        let mut buf = encode(0, &Message::CaptureStop);
        buf[1] = 0x01;
        let err = decode(&buf).unwrap_err();
        assert!(matches!(err, DecodeError::UnsupportedVersion { got: 0x01 }));
    }

    #[test]
    fn decode_rejects_old_v0x02_helper_health_payload() {
        // A v0x02 HelperHealth payload was 6 × u64 = 48 bytes; the
        // v0x03 decoder expects 7 × u64 = 56 bytes. Hand-craft a
        // header that claims v0x03 but carries a v0x02-shaped payload
        // — strict payload-length consumption (PayloadLengthMismatch)
        // is what guards against silent cross-version reads after the
        // version byte alone would not (e.g. a misconfigured proxy).
        // This is the "payload-strict-consumption tripwire" called out
        // in the PR body.
        let mut payload = Vec::with_capacity(48);
        for v in 0u64..6 {
            payload.extend_from_slice(&v.to_le_bytes());
        }
        let mut buf = vec![FRAME_MAGIC, FRAME_VERSION];
        buf.extend_from_slice(&(MessageType::HelperHealth as u16).to_le_bytes());
        buf.extend_from_slice(&0_u64.to_le_bytes());
        #[allow(clippy::cast_possible_truncation)]
        let payload_len = payload.len() as u32;
        buf.extend_from_slice(&payload_len.to_le_bytes());
        buf.extend_from_slice(&payload);

        let err = decode(&buf).unwrap_err();
        // The decoder runs out of payload bytes trying to read the
        // 7th u64 — surfaces as a Truncated parser error.
        assert!(
            matches!(err, DecodeError::Truncated { .. }),
            "expected Truncated on a 48-byte v0x02-shaped payload at v0x03, got {err:?}"
        );
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
    fn roundtrip_ocr_event_minimal() {
        roundtrip(&Message::OCREvent {
            seq: 0,
            ts_us: 0,
            app_bundle_id: [0u8; 64],
            window_title: String::new(),
            url: String::new(),
            ocr_text: String::new(),
            keyframe_hash: [0u8; 32],
        });
    }

    #[test]
    fn roundtrip_ocr_event_populated() {
        let mut bundle = [0u8; 64];
        let id = b"com.apple.Safari";
        bundle[..id.len()].copy_from_slice(id);
        roundtrip(&Message::OCREvent {
            seq: 42,
            ts_us: 1_234_567_890,
            app_bundle_id: bundle,
            window_title: "Login — example.com".to_string(),
            url: "https://example.com/login".to_string(),
            ocr_text: "username: alice\nthis is OCR'd UI text\n".to_string(),
            keyframe_hash: [0xAB; 32],
        });
    }

    #[test]
    fn ocr_event_cross_side_fixture() {
        // Byte-exact mirror of the Swift
        // `WireFixturesTests.testOCREventCrossSideFixture` and the
        // layout parsed by `tools/wire_decode.py`. Pins the v0x04
        // OCREvent layout across all three sides; any drift = silent
        // IPC contract break. ADR-0016 §1.6 byte order.
        let mut bundle = [0u8; 64];
        let id = b"com.apple.Safari";
        bundle[..id.len()].copy_from_slice(id);
        let hash: [u8; 32] = [0xAB; 32];
        let buf = encode(
            42,
            &Message::OCREvent {
                seq: 42,
                ts_us: 0x0102_0304_0506_0708,
                app_bundle_id: bundle,
                window_title: "T".to_string(), // 1 byte
                url: "U".to_string(),          // 1 byte
                ocr_text: "Hi".to_string(),    // 2 bytes
                keyframe_hash: hash,
            },
        );
        // Fixed payload = 8 (seq) + 8 (ts_us) + 64 (app_bundle_id)
        //                + 2 + 2 + 4 (lens) + 32 (keyframe_hash) = 120
        // Variable    = 1 + 1 + 2 = 4
        // Total payload = 124. Frame total = 16 (header) + 124 = 140.
        assert_eq!(
            buf.len(),
            MIN_FRAME_HEADER_BYTES + OCR_EVENT_FIXED_HEADER_BYTES + 4
        );
        assert_eq!(buf.len(), 140);

        // Header: magic 4D, version 04, msg_type 0040 LE, seq 42 LE,
        //         len 124 LE.
        assert_eq!(&buf[0..4], &[0x4D, 0x04, 0x40, 0x00]);
        assert_eq!(&buf[4..12], &42u64.to_le_bytes());
        assert_eq!(&buf[12..16], &124u32.to_le_bytes());

        // Payload starts at offset 16. seq u64 = 42.
        assert_eq!(&buf[16..24], &42u64.to_le_bytes());
        // ts_us u64.
        assert_eq!(&buf[24..32], &0x0102_0304_0506_0708u64.to_le_bytes());
        // app_bundle_id 64 bytes — null-padded "com.apple.Safari".
        assert_eq!(&buf[32..32 + 16], id);
        for &b in &buf[32 + 16..32 + 64] {
            assert_eq!(b, 0, "app_bundle_id must be null-padded");
        }
        // window_title_len u16 = 1.
        assert_eq!(&buf[96..98], &1u16.to_le_bytes());
        // url_len u16 = 1.
        assert_eq!(&buf[98..100], &1u16.to_le_bytes());
        // ocr_text_len u32 = 2.
        assert_eq!(&buf[100..104], &2u32.to_le_bytes());
        // keyframe_hash 32 bytes.
        assert_eq!(&buf[104..136], &hash);
        // Variable: window_title (1) + url (1) + ocr_text (2).
        assert_eq!(&buf[136..137], b"T");
        assert_eq!(&buf[137..138], b"U");
        assert_eq!(&buf[138..140], b"Hi");

        // Round-trip decode confirms the layout is self-consistent.
        let (frame, used) = decode(&buf).expect("decode OCREvent fixture");
        assert_eq!(used, buf.len());
        assert_eq!(frame.seq, 42);
        match frame.message {
            Message::OCREvent {
                seq,
                ts_us,
                app_bundle_id,
                window_title,
                url,
                ocr_text,
                keyframe_hash,
            } => {
                assert_eq!(seq, 42);
                assert_eq!(ts_us, 0x0102_0304_0506_0708);
                assert_eq!(app_bundle_id, bundle);
                assert_eq!(window_title, "T");
                assert_eq!(url, "U");
                assert_eq!(ocr_text, "Hi");
                assert_eq!(keyframe_hash, hash);
            }
            other => panic!("expected OCREvent, got {other:?}"),
        }
    }

    #[test]
    fn decode_rejects_truncated_ocr_event_payload() {
        // Build a valid OCREvent and lop off the last byte of the
        // variable trailer — strict consumption MUST surface as
        // Truncated. This is the payload-strict-consumption tripwire
        // for the v0x04 layout, mirroring PR #44's discipline.
        let mut bundle = [0u8; 64];
        let id = b"com.apple.Safari";
        bundle[..id.len()].copy_from_slice(id);
        let buf = encode(
            7,
            &Message::OCREvent {
                seq: 7,
                ts_us: 0,
                app_bundle_id: bundle,
                window_title: "x".to_string(),
                url: "y".to_string(),
                ocr_text: "z".to_string(),
                keyframe_hash: [0u8; 32],
            },
        );
        // Crafted full frame; now truncate the LAST byte of the
        // payload while preserving the declared `len` field so the
        // decoder slices on declared, then runs out reading the
        // trailer.
        let mut bad = buf.clone();
        bad.pop();
        let err = decode(&bad).unwrap_err();
        assert!(
            matches!(err, DecodeError::Truncated { .. }),
            "expected Truncated on a 1-byte-short OCREvent payload, got {err:?}"
        );
    }

    #[test]
    fn decode_rejects_oversized_ocr_text_len() {
        // ADR-0016 §4.9: OCR text per-event capped at 64 KB on the
        // helper side. The CORE-side decoder enforces the same cap as
        // a belt-and-suspenders trust-boundary check: a misbehaving
        // helper claiming `ocr_text_len > 64 KB` is rejected before any
        // allocation. Test by hand-crafting a payload-length header
        // that declares a larger ocr_text_len than the cap allows.
        let mut payload = Vec::new();
        payload.extend_from_slice(&0u64.to_le_bytes()); // seq
        payload.extend_from_slice(&0u64.to_le_bytes()); // ts_us
        payload.extend_from_slice(&[0u8; 64]); // app_bundle_id
        payload.extend_from_slice(&0u16.to_le_bytes()); // window_title_len
        payload.extend_from_slice(&0u16.to_le_bytes()); // url_len
                                                        // ocr_text_len > MAX_OCR_TEXT_BYTES — strictly above cap.
        payload.extend_from_slice(&(MAX_OCR_TEXT_BYTES + 1).to_le_bytes());
        payload.extend_from_slice(&[0u8; 32]); // keyframe_hash

        let mut buf = vec![FRAME_MAGIC, FRAME_VERSION];
        buf.extend_from_slice(&(MessageType::OCREvent as u16).to_le_bytes());
        buf.extend_from_slice(&0u64.to_le_bytes());
        #[allow(clippy::cast_possible_truncation)]
        let payload_len = payload.len() as u32;
        buf.extend_from_slice(&payload_len.to_le_bytes());
        buf.extend_from_slice(&payload);

        let err = decode(&buf).unwrap_err();
        assert!(
            matches!(err, DecodeError::OversizedPayload { .. }),
            "expected OversizedPayload on over-cap ocr_text_len, got {err:?}"
        );
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
