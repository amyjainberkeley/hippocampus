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
//! | version   | u8     | currently 0x04   |
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
pub use fdpass::{
    recv_with_fds, send_with_fds, socket_pair, FdPassError, RecvOutcome, MAX_SCM_FDS,
};
pub use reader::{FrameReader, ReadError, READER_BUFFER_CAP};
pub use wire::{
    decode, encode, DecodeError, Frame, MessageType, FRAME_MAGIC, FRAME_VERSION,
    MAX_OCR_TEXT_BYTES, MAX_PAGE_CONTENT_TEXT_BYTES, MIN_FRAME_HEADER_BYTES,
    OCR_EVENT_APP_BUNDLE_ID_LEN, OCR_EVENT_FIXED_HEADER_BYTES, OCR_EVENT_KEYFRAME_HASH_LEN,
    PAGE_CONTENT_EVENT_FIXED_HEADER_BYTES,
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

    /// Helper → core. An ADR-0016 P3.6 OCR'd-event payload — an event
    /// that cleared the ADR-0013 cascade TWICE: once on pixels at frame
    /// time (§1–§5 + §7) and once on OCR'd text (§6 OCR-time secret/PII
    /// regex). Only events that cleared BOTH cascades become `OCREvent`
    /// frames on the wire. Events that cleared pixels but failed §6 on
    /// text become [`PrivacyTombstone`] with reason
    /// [`RedactionReason::OcrTimeSecret`] instead — no OCR'd text bytes
    /// cross the seam.
    ///
    /// LOAD-BEARING (ADR-0016 §4): this is the first message variant
    /// carrying USER CONTENT (OCR'd text) across the IPC seam. Per-event
    /// OCR text is capped at 64 KB helper-side; over-cap triggers a
    /// fail-closed `PrivacyTombstone(reason=FailsafeUnknown)` instead.
    ///
    /// Keyframe blob writes are vacuous in this PR — the helper passes
    /// `keyframe_hash = [0u8; 32]` until P3.6.5 adds the blob writer.
    OCREvent {
        /// Event-level sequence number — distinct concept from the
        /// wire-frame `seq` in the envelope, though in production the
        /// helper sets both to the same allocated value (one frame per
        /// `OCREvent`). Carried in-payload so a future split of event
        /// sequencing from wire sequencing does not require a wire
        /// bump.
        seq: u64,
        /// Monotonic helper-side timestamp, microseconds since epoch.
        ts_us: u64,
        /// Bundle identifier of the foreground app, null-padded to
        /// 64 bytes (mirrors the bounded discipline used by
        /// `PrivacyTombstone.app_bundle`).
        app_bundle_id: [u8; 64],
        /// Window title at OCR time. UTF-8; helper-side enforcement
        /// caps the length so the variable trailer cannot balloon.
        window_title: String,
        /// Active browser tab URL at OCR time (post-ADR-0015 P2.5
        /// context join). Empty string when not a browser context.
        url: String,
        /// OCR'd text, capped at 64 KB helper-side per ADR-0016 §4.9.
        /// Always passes the cascade §6 regex re-run before reaching
        /// the wire — the trust boundary is enforced on the helper
        /// side, not the core.
        ocr_text: String,
        /// blake3 of the keyframe blob the event references. All-zero
        /// bytes signals "no blob yet" (vacuous in P3.6; blob writer
        /// lands at P3.6.5).
        keyframe_hash: [u8; 32],
    },

    /// Browser extension → agent (via native messaging host). Full page
    /// content extracted from the browser DOM — lossless text that
    /// pixel-OCR cannot match. ADR-0015 §6 Phase 7 pull-forward.
    ///
    /// The native messaging host runs the §6 secret-pattern filter on
    /// `full_text` BEFORE encoding this variant. Events that fail the
    /// filter become [`PrivacyTombstone`] with reason
    /// [`RedactionReason::OcrTimeSecret`] instead — same discipline as
    /// [`OCREvent`]'s cascade-twice path.
    ///
    /// Full text is capped at 200 KB; over-cap triggers sentence-boundary
    /// truncation in the native messaging host before encoding.
    PageContentEvent {
        /// Event-level sequence number.
        seq: u64,
        /// Timestamp microseconds since epoch.
        ts_us: u64,
        /// Active tab URL. UTF-8, length-prefixed on wire.
        url: String,
        /// Page title (`document.title`). UTF-8, length-prefixed on wire.
        title: String,
        /// Full page text (`document.body.innerText`, capped at 200 KB).
        full_text: String,
        /// Source browser identifier: `"safari"` | `"chrome"` | `"arc"`
        /// | `"edge"` | `"brave"` | `"firefox"`.
        source_browser: String,
        /// Browser-assigned tab id. 0 = not available.
        tab_id: u32,
    },

    /// Helper → core. Periodic counters for the CRS Telemetry-Gap analyst.
    /// Content-free (`AGENT_PROTOCOL` §9.3 / ADR-0001 NG3).
    HelperHealth {
        /// Helper uptime since `SCStream` start, milliseconds.
        uptime_ms: u64,
        /// Frames the OS delivered since start.
        frames_delivered: u64,
        /// Frames suppressed by the ADR-0013 cascade — the **total**
        /// across every cascade reason (denylist, blacked-region,
        /// secure-event-input, AX-secure, post-capture, fail-safe).
        frames_suppressed: u64,
        /// Frames suppressed specifically via the ADR-0013 **§7
        /// fail-safe** path (`RedactionReason::FailsafeUnknown`) — a
        /// **subset** of `frames_suppressed`, not subtracted from it.
        ///
        /// Split out as its own counter because it is a *privacy-
        /// regression sentinel* for the CRS Telemetry-Gap analyst: a
        /// spike means the cascade is failing to positively classify
        /// (AX broke / Electron AX silence / denylist-filter drift)
        /// and is bulk-redacting via fail-safe. That is privacy-*safe*
        /// (it fails closed) but signals an upstream classification
        /// regression that `frames_suppressed` alone would mask.
        frames_redacted_by_failsafe: u64,
        /// Cascade evaluations that ran because the cascade-floor
        /// heartbeat elapsed — the filter returned a `.drop*` decision
        /// but the wall-clock since the last cascade run reached
        /// `cascadeFloorIntervalMs`, so the helper pipeline forced the
        /// cascade anyway. Surfaced on the wire by the `0x02 → 0x03`
        /// bump (STEP-2-FINDING-004): under a static secure surface
        /// (`FairPlay`, sudo password entry, secure-field focus) the
        /// `SmartCaptureFilter` eats every frame; this counter is how
        /// the Telemetry-Gap analyst observes that the floor is doing
        /// what the filter cannot. **Strictly disjoint** from the
        /// existing filter-passed cascade calls (a single `process()`
        /// call increments exactly one of them whenever the cascade
        /// runs). NOT a subset of `frames_suppressed` — the floor-
        /// forced cascade can still emit a tombstone (`.suppress`),
        /// so the two streams can overlap, but it is observability-
        /// only and does not affect any fail-closed semantics.
        cascade_forced_count: u64,
        /// Frames dropped on backpressure (queue full).
        frames_dropped_backpressure: u64,
        /// Frames dropped on late ack (core held the surface past the
        /// timing bound — a bug indicator).
        frames_dropped_late_ack: u64,
        /// Cumulative count of cascade-`.allow` frames on which the
        /// VideoToolbox HEVC encoder threw on `encodeAllowedFrame(...)`.
        /// Promoted to the wire by the `0x06 → 0x07` bump (ocr-emit-
        /// silence fix — `docs/research/ocr-emit-silence-2026-05-28.md`).
        /// Content-free observability counter — same discipline as
        /// `frames_redacted_by_failsafe`. Was structurally invisible
        /// before this bump; a non-zero value here historically
        /// silently muted the cascade-twice OCR emitter, which is the
        /// regression this counter trip-wires.
        frames_encode_failed: u64,
        /// Cumulative count of frames dropped by the ADR-0031 §5.3
        /// race-consistency gate — the `FocusedWindowStore.generation`
        /// observed at SCStream callback time did NOT match the
        /// `installedFocusGeneration` the live SCStream's filter was
        /// rebound under. Such frames emit a
        /// `PrivacyTombstone(reason=FocusRaceDropped)` instead of
        /// running the cascade-twice OCR emitter — fail-closed per
        /// ADR-0013 §3 + Amendment 1 §3(b). Promoted to the wire by
        /// the `0x07 → 0x08` bump (V2-P1 / ADR-0031). Content-free
        /// observability counter; never widens `.allow`. A spike here
        /// indicates rapid focus changes (alt-tab cadence faster than
        /// the rebind task), Electron AX intermittency drifting the
        /// FocusTracker, or a pathological focus-loop bug.
        frames_focus_race_dropped: u64,
        /// Per-app failsafe counter map — bundle id → cumulative count
        /// of `.failsafeUnknown` tombstones emitted with that
        /// `appBundleId`. Fixed-cardinality (cap
        /// [`crate::ipc::wire::MAX_FAILSAFE_BY_APP_ENTRIES`] = 8 entries,
        /// least-recent-bump eviction enforced by the helper-side
        /// `HelperHealthCounters` actor). Promoted to the wire by the
        /// `0x08 → 0x09` bump (PR #226 §5.1 (1); CTO Phase 6 PR 6).
        /// Content-free: bundle ids (already cascade-eligible —
        /// `.failsafeUnknown` is the §7 outcome, NEVER OCR text) and
        /// a `u64` counter per entry. The load-bearing addition:
        /// converts the cascade's per-app silence from a structural
        /// unknown into a one-command live measurement
        /// (`mci-agent --health-summary` shape:
        /// `failsafe-by-app: com.example.app=124, …`). Bounded
        /// cardinality prevents information-theoretic PII leak via
        /// the bundle-id stream length. Resets on helper restart
        /// (cumulative-within-process).
        failsafe_by_app: Vec<(String, u64)>,
        /// Instantaneous helper CPU % at HelperHealth flush, multiplied
        /// by 1_000_000 (microfraction). `1_000_000` = 100% of one
        /// core; `15_000` = 1.5% of one core. `0` = sampler did not
        /// take a sample this tick (first flush in a process — no
        /// prior `getrusage` snapshot to compute a delta against, or
        /// `getrusage` syscall failure). Promoted to the wire by the
        /// `0x08 → 0x09` bump (CTO Phase 6 PR 6, S4 acceptance gate:
        /// steady-state ≤10–15% of one CPU core / ≤2 GB RAM per
        /// G2 ratification 2026-05-31). Content-free. Pairs with the
        /// MetricKit non-content footprint telemetry pipeline (also
        /// in this PR) for finer-than-daily-aggregate CPU
        /// observability — MetricKit aggregates daily, this counter
        /// samples per HelperHealth flush (default 30s cadence).
        cpu_pct_micro: u32,
        /// Instantaneous helper resident set size at HelperHealth flush,
        /// in bytes. Sampled via Mach
        /// `task_info(MACH_TASK_BASIC_INFO)`. `0` = sampler failed
        /// (extremely rare; would indicate a Mach kernel error).
        /// Promoted to the wire by the `0x08 → 0x09` bump (CTO Phase
        /// 6 PR 6, S4 acceptance gate ≤2 GB RAM). Content-free.
        /// Pairs with MetricKit (MetricKit aggregates daily; this
        /// counter samples per HelperHealth flush).
        rss_bytes: u64,
        /// RESERVED SLOT for V2-P1 PR 13 (§6.2 = A focused-window
        /// race-gate timeout). Reused under the §8 coordination
        /// contract: "If §6.2 = A and the §5 observability bump is
        /// in flight, V2-P1 reuses the bumped wire version + a new
        /// slot." This PR is that §5 bump; V2-P1 PR 13 populates this
        /// field with the AX-focus-tracker heartbeat timestamp at
        /// snapshot time. `0` = sentinel ("AX focus tracker not yet
        /// implemented" — Phase 6 PR 6 ships the slot at 0 and
        /// V2-P1 PR 13 owns assigning real timestamps). Reused-slot
        /// trade-off vs deferring: deferring would force PR 13 to
        /// bump to 0x0A, expanding the dual-accept window unnecessarily.
        /// Content-free (timestamp microseconds since epoch, no
        /// content metadata).
        tracker_alive_at_us: u64,
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
            Self::OCREvent { .. } => MessageType::OCREvent,
            Self::PageContentEvent { .. } => MessageType::PageContentEvent,
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
    /// Cascade §6 — OCR-time secret/PII regex matched on OCR'd text.
    /// Operationally meaningful starting at ADR-0016 P3.6: a cascade-
    /// twice fire — the frame cleared the pixel-time cascade
    /// (§1–§5 + §7) but the OCR'd text re-run of §6 matched a
    /// SecretBench-tuned pattern. No OCR'd text bytes reach the wire
    /// on this path; only the tombstone does.
    OcrTimeSecret,
    /// Cascade §7 — fail-safe default: helper could not positively classify
    /// the focused element with reasonable confidence.
    FailsafeUnknown,
    /// ADR-0031 §5.3 — focus changed between SCStream filter install and
    /// frame callback. The captured pixel buffer may correspond to a
    /// different focused window than the frame's attribution metadata,
    /// so the helper fails closed and emits this tombstone instead of
    /// running the cascade-twice OCR emitter. PROTECTED-SET — discriminant
    /// lock-stepped with `RedactionReason::focusRaceDropped` (= 8) on the
    /// Swift helper side.
    FocusRaceDropped,
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
            Self::OcrTimeSecret => 6,
            Self::FailsafeUnknown => 7,
            Self::FocusRaceDropped => 8,
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
            6 => Self::OcrTimeSecret,
            7 => Self::FailsafeUnknown,
            8 => Self::FocusRaceDropped,
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
            Self::OcrTimeSecret => "ocr-time-secret",
            Self::FailsafeUnknown => "failsafe-unknown",
            Self::FocusRaceDropped => "focus-race-dropped",
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
            RedactionReason::OcrTimeSecret,
            RedactionReason::FailsafeUnknown,
            RedactionReason::FocusRaceDropped,
        ] {
            let b = r.as_u8();
            let r2 = RedactionReason::from_u8(b).unwrap();
            assert_eq!(r, r2);
            // db_str is stable + non-empty per ADR-0013 §4.
            assert!(!r.as_db_str().is_empty());
        }
    }

    #[test]
    fn redaction_reason_six_is_ocr_time_secret() {
        // Wire 0x03 reserved 6 (§6 OCR-time regex ran in core/, never
        // emitted a tombstone). Wire 0x04 (ADR-0016 P3.6) re-homes §6
        // to the helper because OCR now happens in the helper; §6
        // tombstones cross the wire as reason=6.
        let r = RedactionReason::from_u8(6).expect("reason=6 is OcrTimeSecret on wire 0x04");
        assert_eq!(r, RedactionReason::OcrTimeSecret);
        assert_eq!(r.as_db_str(), "ocr-time-secret");
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
            Message::OCREvent {
                seq: 0,
                ts_us: 1,
                app_bundle_id: [0u8; 64],
                window_title: "Title".to_string(),
                url: "https://example.com".to_string(),
                ocr_text: "hello world".to_string(),
                keyframe_hash: [0u8; 32],
            },
            Message::PageContentEvent {
                seq: 0,
                ts_us: 1,
                url: "https://example.com".to_string(),
                title: "Example".to_string(),
                full_text: "page content".to_string(),
                source_browser: "chrome".to_string(),
                tab_id: 42,
            },
        ];
        for m in &msgs {
            // Trivial smoke test that each variant resolves a MessageType.
            let _t = m.message_type();
        }
    }
}
