//! IPC framing for the macOS Swift capture helper (ADR-0007).
//!
//! Phase 1 introduces a separate signed Swift helper process that owns the
//! `SCStream` lifecycle. This module defines the **wire-protocol message
//! types** the helper and the Rust core exchange over `AF_UNIX` with
//! `SCM_RIGHTS` for surface-handle file descriptors.
//!
//! Binding ADRs:
//! - `docs/decisions/0007-macos-capture-separate-signed-helper-process.md`
//!   — process model, IPC mechanism class (`AF_UNIX`), per-frame ack
//!   discipline that preserves the §5.1 surface-release timing across the
//!   process boundary.
//! - `docs/decisions/0006-capturesource-trait-shape-async-push.md`
//!   — the in-process trait this IPC channel materializes across processes.
//! - `docs/decisions/0013-native-grade-sensitive-surface-suppression.md`
//!   — **the cascade runs in the helper, before any frame or metadata
//!   crosses this IPC**. Suppressed events emit a [`PrivacyTombstone`]
//!   instead of a [`StateTransitionEvent`]; pixels and event-level text
//!   never traverse this module.
//!
//! **Protected-set scope (`AGENT_PROTOCOL` §5).** This module defines the
//! exact bytes that cross a process boundary carrying capture-derived
//! payloads. Any change to a message variant, a field's byte layout, or
//! the framing envelope requires a fresh CSO review.
//!
//! Wire format (binary, little-endian):
//!
//! ```text
//! +-----------+--------+------------------+
//! | magic     | u8     | 0x4D = 'M'       |
//! | version   | u8     | currently 0x01   |
//! | msg_type  | u16 LE | discriminant     |
//! | seq       | u64 LE | monotonic seq id |
//! | len       | u32 LE | payload bytes    |
//! | payload   | len B  | message-specific |
//! +-----------+--------+------------------+
//! ```
//!
//! Surface file descriptors are passed out-of-band via `SCM_RIGHTS` in the
//! socket control message. The payload references them by ordinal index
//! into the control-message fd array — never by raw fd integer (which would
//! be meaningless across processes).
//!
//! No `serde` / `bincode` / other heavyweight dep — keep the IPC surface
//! deliberately small and audit-friendly. Encoders and decoders are
//! byte-explicit and round-trip-tested.

pub mod connection;
pub mod fdpass;
pub mod reader;
pub mod wire;
pub mod writer;

pub use connection::{ConnectionError, HelperConnection, Routed};
pub use fdpass::{recv_with_fds, send_with_fds, socket_pair, FdPassError, RecvOutcome, MAX_SCM_FDS};
pub use reader::{FrameReader, ReadError, READER_BUFFER_CAP};
pub use wire::{
    decode, encode, DecodeError, Frame, MessageType, FRAME_MAGIC, FRAME_VERSION,
    MIN_FRAME_HEADER_BYTES,
};
pub use writer::{FrameWriter, WriteError};

use std::time::Duration;

/// A single message exchanged between the macOS Swift helper and the Rust
/// core.
///
/// Each variant maps to a `[MessageType]` discriminant on the wire.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Message {
    /// Core → helper. Start the underlying `SCStream` with these parameters.
    CaptureStart {
        /// Target capture interval in milliseconds. The helper translates
        /// this to `SCStreamConfiguration.minimumFrameInterval`.
        interval_ms: u32,
        /// Maximum in-flight frames in the helper's bounded queue. The
        /// helper drops on overflow per ADR-0006 backpressure rules.
        queue_depth: u8,
    },

    /// Core → helper. Stop the underlying `SCStream`.
    CaptureStop,

    /// Helper → core. A state-transition event survived the ADR-0013
    /// suppression cascade and is being delivered to the pipeline.
    ///
    /// The surface fd is **not** in this payload — it is the i-th file
    /// descriptor in the accompanying `SCM_RIGHTS` control message.
    StateTransitionEvent {
        /// Monotonic helper-side capture timestamp, microseconds since boot.
        ts_us: u64,
        /// Ordinal index into the accompanying `SCM_RIGHTS` fd array.
        /// `u8::MAX` means "no fd attached" (metadata-only event).
        fd_index: u8,
        /// Logical width of the surface in pixels, before any scaling.
        width_px: u32,
        /// Logical height of the surface in pixels, before any scaling.
        height_px: u32,
        /// Bitfield of [`FrameStatusFlags`] reported by the OS frame
        /// callback.
        status_flags: u8,
        /// Dirty rectangles (changed since prior delivered frame).
        dirty_rects: Vec<DirtyRect>,
    },

    /// Helper → core. ADR-0013 cascade fired for an event. **No pixels, no
    /// event-level text, no window title, no URL.** Only the bare minimum
    /// metadata needed for the user-visible privacy moment in the recall UI.
    ///
    /// This is the *demonstrable-redaction* surface F-STRAT-001b's audit
    /// will validate.
    PrivacyTombstone {
        /// Monotonic helper-side timestamp, microseconds since boot.
        ts_us: u64,
        /// Bundle identifier of the foreground app at the time of
        /// suppression. Maps to `events.app_bundle` in the store.
        app_bundle: String,
        /// Which cascade rule fired. Maps to the `events.redaction_reason`
        /// column added in the Phase-1 schema migration (ADR-0013 §4).
        reason: RedactionReason,
    },

    /// Core → helper. The core has dropped its borrow of the surface
    /// referenced by `fd_index`. The helper returns the surface to the OS
    /// pool.
    ///
    /// **Hard timeout enforced on the helper side** per ADR-0007: if this
    /// ack does not arrive within `interval × (queueDepth − 1)`, the
    /// helper drops the surface unilaterally and emits a counter. The
    /// channel never blocks waiting for the ack.
    SurfaceReleased {
        /// Ordinal index from the original `StateTransitionEvent`.
        fd_index: u8,
        /// Sequence number of the `StateTransitionEvent` being acked,
        /// for late-ack detection.
        ack_seq: u64,
    },

    /// Helper → core. Periodic counters for the CRS Telemetry-Gap analyst.
    /// Content-free (`AGENT_PROTOCOL` §9.3 / ADR-0001 NG3).
    HelperHealth {
        /// Helper uptime since `SCStream` start, milliseconds.
        uptime_ms: u64,
        /// Frames the OS delivered since start.
        frames_delivered: u64,
        /// Frames suppressed by the ADR-0013 cascade.
        frames_suppressed: u64,
        /// Frames dropped on backpressure (queue full).
        frames_dropped_backpressure: u64,
        /// Frames dropped on late ack (core held the surface past the
        /// timing bound — a bug indicator).
        frames_dropped_late_ack: u64,
    },
}

impl Message {
    /// The wire-protocol discriminant for this variant.
    #[must_use]
    pub const fn message_type(&self) -> MessageType {
        match self {
            Self::CaptureStart { .. } => MessageType::CaptureStart,
            Self::CaptureStop => MessageType::CaptureStop,
            Self::StateTransitionEvent { .. } => MessageType::StateTransitionEvent,
            Self::PrivacyTombstone { .. } => MessageType::PrivacyTombstone,
            Self::SurfaceReleased { .. } => MessageType::SurfaceReleased,
            Self::HelperHealth { .. } => MessageType::HelperHealth,
        }
    }
}

/// A rectangle of pixels that changed since the prior delivered frame.
///
/// Mirrors the in-process [`crate::capture::DirtyRect`] but is repr-stable
/// for byte-explicit wire serialization.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DirtyRect {
    /// Top-left x in pixels.
    pub x: u32,
    /// Top-left y in pixels.
    pub y: u32,
    /// Width in pixels.
    pub width: u32,
    /// Height in pixels.
    pub height: u32,
}

/// Reason an event was suppressed by the ADR-0013 cascade.
///
/// Persisted in the new `events.redaction_reason` column after the Phase-1
/// schema migration (ADR-0013 §4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RedactionReason {
    /// Cascade §1 — source-level `SCContentFilter` denylist excluded the app
    /// or URL. Pixels never entered the pipeline; this tombstone records
    /// the suppression for the recall UI.
    DenylistSource,
    /// Cascade §2 — captured frame contained a known-black region from
    /// `NSWindowSharingType = .none` / DRM / source exclusion.
    OsBlackedRegion,
    /// Cascade §3 — `IsSecureEventInputEnabled()` returned true at frame
    /// time.
    SecureEventInput,
    /// Cascade §4 — focused AX element had `kAXSecureTextFieldSubrole`.
    AxSecureSubrole,
    /// Cascade §5 — `WorkflowContext` matched the post-capture denylist
    /// (belt-and-suspenders for §1).
    DenylistPostCapture,
    /// Cascade §7 — fail-safe default: helper could not positively classify
    /// the focused element with reasonable confidence.
    FailsafeUnknown,
}

impl RedactionReason {
    /// Discriminant byte used on the wire.
    #[must_use]
    pub const fn as_u8(self) -> u8 {
        match self {
            Self::DenylistSource => 1,
            Self::OsBlackedRegion => 2,
            Self::SecureEventInput => 3,
            Self::AxSecureSubrole => 4,
            Self::DenylistPostCapture => 5,
            Self::FailsafeUnknown => 7,
        }
    }

    /// Decode a wire-byte discriminant.
    ///
    /// # Errors
    /// Returns [`DecodeError::InvalidEnum`] for unrecognized discriminants.
    pub fn from_u8(b: u8) -> Result<Self, DecodeError> {
        Ok(match b {
            1 => Self::DenylistSource,
            2 => Self::OsBlackedRegion,
            3 => Self::SecureEventInput,
            4 => Self::AxSecureSubrole,
            5 => Self::DenylistPostCapture,
            7 => Self::FailsafeUnknown,
            other => {
                return Err(DecodeError::InvalidEnum {
                    field: "RedactionReason",
                    value: u32::from(other),
                })
            }
        })
    }

    /// The string the store layer writes to `events.redaction_reason`.
    /// Stable; do not change without a schema migration.
    #[must_use]
    pub const fn as_db_str(self) -> &'static str {
        match self {
            Self::DenylistSource => "denylist-source",
            Self::OsBlackedRegion => "os-blacked-region",
            Self::SecureEventInput => "secure-event-input",
            Self::AxSecureSubrole => "ax-secure-subrole",
            Self::DenylistPostCapture => "denylist-postcapture",
            Self::FailsafeUnknown => "failsafe-unknown",
        }
    }
}

/// Bitfield flags carried in `StateTransitionEvent.status_flags`.
///
/// Maps to the in-process [`crate::capture::FrameStatus`] enum but
/// preserves a bit-set shape so multiple statuses (e.g. `Idle` plus
/// `Complete`) can be reported in a single byte.
pub struct FrameStatusFlags;

impl FrameStatusFlags {
    /// New content was delivered (the common case).
    pub const COMPLETE: u8 = 0b0000_0001;
    /// The OS reported the screen as idle (untrustworthy on its own; see
    /// CRS scan + ADR-0013 cascade).
    pub const IDLE: u8 = 0b0000_0010;
    /// The OS suspended the stream (low-power / thermal / user pause).
    pub const SUSPENDED: u8 = 0b0000_0100;
    /// The OS dropped this frame (queue overflow on the OS side).
    pub const STOPPED: u8 = 0b0000_1000;
    /// All flags currently defined. Used by the decoder to reject unknown
    /// bits set by a misbehaving / fuzzed helper.
    pub const ALL_DEFINED: u8 = Self::COMPLETE | Self::IDLE | Self::SUSPENDED | Self::STOPPED;
}

/// Default per-frame ack timeout per ADR-0007.
///
/// The helper drops the surface unilaterally if [`Message::SurfaceReleased`]
/// has not arrived within this bound minus expected IPC RTT. The exact
/// value lands with the Phase-1 helper integration but the default here
/// matches the ADR-0006 timing-contract envelope: capture interval 200 ms
/// × `(queue_depth − 1)` = 400 ms with the default `queue_depth = 3`,
/// minus 100 ms slack for IPC RTT.
pub const DEFAULT_ACK_TIMEOUT: Duration = Duration::from_millis(300);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redaction_reasons_round_trip() {
        for &r in &[
            RedactionReason::DenylistSource,
            RedactionReason::OsBlackedRegion,
            RedactionReason::SecureEventInput,
            RedactionReason::AxSecureSubrole,
            RedactionReason::DenylistPostCapture,
            RedactionReason::FailsafeUnknown,
        ] {
            let b = r.as_u8();
            let r2 = RedactionReason::from_u8(b).unwrap();
            assert_eq!(r, r2);
            // db_str is stable + non-empty per ADR-0013 §4.
            assert!(!r.as_db_str().is_empty());
        }
    }

    #[test]
    fn redaction_reason_skips_six_to_match_cascade_numbering() {
        // The cascade has 7 rules (§1..§7); §6 is OCR-time regex which
        // runs in core/, not in the helper, so it never emits a tombstone
        // over IPC. The wire discriminant skips 6 deliberately to match
        // the cascade's numbering.
        assert!(RedactionReason::from_u8(6).is_err());
    }

    #[test]
    fn frame_status_flags_are_disjoint_bits() {
        let all = [
            FrameStatusFlags::COMPLETE,
            FrameStatusFlags::IDLE,
            FrameStatusFlags::SUSPENDED,
            FrameStatusFlags::STOPPED,
        ];
        let or = all.iter().fold(0u8, |a, b| a | b);
        let xor = all.iter().fold(0u8, |a, b| a ^ b);
        assert_eq!(or, xor, "FrameStatusFlags must be disjoint bits");
        assert_eq!(or, FrameStatusFlags::ALL_DEFINED);
    }

    #[test]
    fn message_type_matches_variant() {
        let msgs = [
            Message::CaptureStart {
                interval_ms: 200,
                queue_depth: 3,
            },
            Message::CaptureStop,
            Message::StateTransitionEvent {
                ts_us: 1,
                fd_index: 0,
                width_px: 1920,
                height_px: 1080,
                status_flags: FrameStatusFlags::COMPLETE,
                dirty_rects: vec![],
            },
            Message::PrivacyTombstone {
                ts_us: 2,
                app_bundle: "com.apple.Safari".to_string(),
                reason: RedactionReason::AxSecureSubrole,
            },
            Message::SurfaceReleased {
                fd_index: 0,
                ack_seq: 42,
            },
            Message::HelperHealth {
                uptime_ms: 0,
                frames_delivered: 0,
                frames_suppressed: 0,
                frames_dropped_backpressure: 0,
                frames_dropped_late_ack: 0,
            },
        ];
        for m in &msgs {
            // Trivial smoke test that each variant resolves a MessageType.
            let _t = m.message_type();
        }
    }
}
