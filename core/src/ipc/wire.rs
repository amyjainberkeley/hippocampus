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
/// `0x04 → 0x05` (2026-05-21, Phase 7 pull-forward): new
/// [`MessageType::PageContentEvent`] variant added — browser extension
/// full-page-content capture. Carries `full_text` (up to 200 KB) from
/// `document.body.innerText` via the native messaging host. Same
/// secret-pattern filtering discipline as `OCREvent`; text passes §6
/// regex before encoding.
///
/// `0x05 → 0x06` (2026-05-21, OCR/PageContent merge): semantic change.
/// The agent now merges cached extension text (from
/// [`PageContentCache`]) into brain events when a URL-matched
/// `PageContentEvent` exists within 5 s of an `OCREvent`. The stored
/// event's `text` field may contain extension-sourced text labelled
/// `[VISIBLE-OCR]` as a secondary signal. Wire byte layout is
/// unchanged; bump is a discipline marker so auditors know events
/// stored by ≥v0x06 agents may carry merged content.
///
/// `0x06 → 0x07` (2026-05-28, ocr-emit-silence fix): `HelperHealth`
/// gained the `frames_encode_failed` counter
/// (`docs/research/ocr-emit-silence-2026-05-28.md`). Trip-wire for
/// VideoToolbox HEVC encode throws on the cascade `.allow` branch so
/// the prior silent muting of the cascade-twice OCR emitter cannot
/// regress unnoticed. Content-free counter — same discipline as
/// `frames_redacted_by_failsafe`. **Decoder dual-accept**: this is the
/// first bump that softens the strict version-lock — the decoder
/// accepts both `0x06` and `0x07` so a `0x06`-era helper alive on a
/// CEO machine across an agent restart cannot mute the brain (the
/// exact failure mode of the live `b0496130…` DMG that motivated this
/// fix). When the helper emits a `0x06` frame, the `HelperHealth`
/// decoder reads seven `u64`s and defaults `frames_encode_failed` to
/// `0`; on `0x07` it reads the full eight `u64`s. All other message
/// variants have identical byte layouts between `0x06` and `0x07`, so
/// dual-accept is byte-equivalent for them.
///
/// `0x07 → 0x08` (2026-05-29, ADR-0031 V2-P1): `HelperHealth` gained
/// the `frames_focus_race_dropped` counter
/// (`docs/research/capture-scope-window-vs-display-2026-05-29.md` §5.3).
/// Trip-wire for the ADR-0031 race-consistency gate — frames dropped
/// because the `FocusedWindowStore.generation` observed at SCStream
/// callback time did not match the `installedFocusGeneration` the
/// live SCStream's filter was rebound under. Content-free counter —
/// same discipline as `frames_redacted_by_failsafe` /
/// `frames_encode_failed`. Tells the Telemetry-Gap analyst whether
/// the new Option (a) focused-window filter is racing against the
/// FocusTracker (e.g. rapid alt-tabbing, Electron AX intermittency
/// drifting the tracker). Cascade-twice OCR emitter is NOT consulted
/// on this path; the race gate fails closed before reaching it.
/// Decoder dual-accept continues — the decoder accepts both `0x07`
/// and `0x08` so a `0x07`-era helper alive across an agent restart
/// cannot mute the brain. On a `0x07` frame the
/// `frames_focus_race_dropped` field defaults to `0`; on `0x08` it
/// reads the ninth `u64`. All other message variants have identical
/// byte layouts between `0x07` and `0x08`, so dual-accept is
/// byte-equivalent for them.
///
/// `0x08 → 0x09` (2026-06-01, Phase 6 PR 6 — MetricKit non-content
/// footprint telemetry pipeline + per-app failsafe counter map;
/// `docs/research/ocr-emit-silence-v2-2026-05-29.md` §5.1 + CTO
/// fully-working-product plan §4 Phase 6 PR 6 + S13 acceptance gate).
/// `HelperHealth` gained FOUR trailing fields, all content-free:
///   1. `failsafe_by_app: Vec<(bundle_id, u64 counter)>` — fixed-
///      cardinality per-app failsafe counter map (cap 8 entries,
///      least-recent-bump eviction). Bundle ids the cascade has
///      already seen and emitted `.failsafeUnknown` tombstones for.
///      The wire field is bytes-only; no OCR text bytes leak.
///      This is the load-bearing PR #226 §5.1 (1) addition —
///      converts the cascade's per-app silence from a structural
///      unknown into a one-command live measurement that surfaces
///      via `mci-agent --health-summary` as
///      `failsafe-by-app: com.example.app=124, …`.
///   2. `cpu_pct_micro: u32` — instantaneous helper CPU % × 1_000_000
///      (microfraction; 1_000_000 = 100% of one core), sampled via
///      `getrusage(RUSAGE_SELF)` delta at HelperHealth flush. 0 =
///      not yet sampled (first tick) or sampling unavailable. Pairs
///      with the MetricKit pipeline for finer-than-daily-aggregate
///      CPU observability against the G2-ratified ≤10–15% SLO.
///   3. `rss_bytes: u64` — instantaneous resident set size in bytes,
///      sampled via Mach `task_info(MACH_TASK_BASIC_INFO)`. 0 =
///      sampling unavailable. Pairs with MetricKit for finer-than-
///      daily-aggregate memory observability against the ≤2 GB SLO.
///   4. `tracker_alive_at_us: u64` — RESERVED SLOT for V2-P1 PR 13.
///      Per `docs/research/v2-p1-redesign-architecture-2026-06-01.md`
///      §6.2 = A ratified, §8 coordination: "If §6.2 = A and the
///      §5 observability bump is in flight, V2-P1 reuses the bumped
///      wire version + a new slot." This PR is that §5 bump; the
///      slot is included here so PR 13 reuses 0x09 instead of
///      bumping to 0x0A. 0 = sentinel ("AX focus tracker not yet
///      implemented"); PR 13 populates with the AX-focus-tracker
///      heartbeat timestamp. Allows the §6.2 = A 2000ms race-gate
///      timeout to fire on a sustained AX tracker hang without
///      adding a wire bump.
/// All four fields are content-free observability counters —
/// bundle ids + numeric sample only; no OCR text, no window content.
/// Decoder dual-accept extends to `[0x09, 0x08, 0x07, 0x06]`. On
/// `0x08` frames the four new fields default (empty Vec, 0, 0, 0);
/// on `0x09` they are read in order. All other message variants have
/// identical byte layouts across `0x06 / 0x07 / 0x08 / 0x09`, so
/// dual-accept is byte-equivalent for them.
///
/// `0x06` RE-EXTENDED (2026-05-30, cycle 8.27 emergency revert): the
/// Safari extension's native messaging host writes `PageContentEvent`
/// frames to `page_content.sock` at wire `0x06`; the `0x07 → 0x08`
/// bumps inside the helper binary moved `ACCEPTED_FRAME_VERSIONS` past
/// `0x06`, so cycle 8.27 production showed
/// `page-content-listener: read error: ipc-read decode: unsupported
/// wire version: got 0x06` on a loop and browser context capture went
/// dark. The browser-extension boundary cannot be updated atomically
/// with helper releases (extensions ship through their respective
/// browser app stores), so the dual-accept window is re-extended to
/// include `0x06` for PageContentEvent. Layout discipline (per the
/// `0x05 → 0x06`, `0x06 → 0x07`, `0x07 → 0x08` notes above):
/// `PageContentEvent` byte layout is identical across `0x06`, `0x07`,
/// `0x08` — the bumps only added trailing `u64`s to `HelperHealth`.
/// `HelperHealth` decode therefore defaults `frames_encode_failed` AND
/// `frames_focus_race_dropped` to `0` on `0x06` (seven `u64`s read).
/// `OCREvent` byte layout is also identical across all three accepted
/// versions, so dual-accept is byte-equivalent for it.
///
/// The decoder rejects any other version: helper and core still ship
/// version-locked in the same signed bundle, but the dual-accept at
/// `0x06 / 0x07 / 0x08` covers (a) the rolling-restart window for
/// helper, and (b) the asynchronous-update window for the browser
/// extension. Persisted / in-flight `0x01` / `0x02` / `0x03` / `0x04`
/// / `0x05` frames are still hard-rejected.
pub const FRAME_VERSION: u8 = 0x09;

/// The set of wire versions the decoder accepts. The encoder always
/// emits [`FRAME_VERSION`]; the decoder accepts the current version
/// AND `0x08` (rolling-restart safety against an `0x08`-era helper
/// alive across an agent restart) AND `0x07` (one earlier window —
/// kept conservative until the `0x07`-era rolling-restart risk has
/// fully aged out) AND `0x06` (asynchronous-update window for the
/// Safari extension native messaging host that emits
/// `PageContentEvent` frames at `0x06`, see the `0x06` RE-EXTENDED
/// note on [`FRAME_VERSION`] — NEVER drop `0x06` per the cycle 8.27
/// emergency lesson). Order matters only in that the current
/// version is the first entry — callers building a tripwire can
/// `assert_eq!(ACCEPTED_FRAME_VERSIONS[0], FRAME_VERSION)`.
pub const ACCEPTED_FRAME_VERSIONS: &[u8] = &[FRAME_VERSION, 0x08, 0x07, 0x06];

/// Maximum number of per-app entries in the wire-0x09 `failsafe_by_app`
/// counter map. Cap is structural (defensive against a fuzzed helper
/// claiming `count > 8`) AND policy (PR #226 §5.1 fixed-cardinality
/// content-free discipline — bounded cardinality means no
/// information-theoretic PII leak via the bundle-id stream length).
/// The helper's `HelperHealthCounters` actor enforces the same cap
/// on the write side via least-recent-bump eviction.
pub const MAX_FAILSAFE_BY_APP_ENTRIES: u8 = 8;

/// Maximum byte length of a single `bundle_id` string in the wire-0x09
/// `failsafe_by_app` map. Bundle ids are typically ≤64 bytes
/// (`com.example.app.subcomponent.binary` shape); the cap is loose
/// enough not to truncate any production bundle id and tight enough
/// that the per-entry wire cost is bounded.
pub const MAX_FAILSAFE_BY_APP_BUNDLE_ID_LEN: u8 = 255;

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

/// Maximum bytes of full page text the native messaging host is permitted
/// to emit in a single [`super::Message::PageContentEvent`] payload.
/// Over-cap text is truncated at a sentence boundary in the native host
/// before encoding. 200 KB matches the content script's
/// `document.body.innerText.slice(0, 200_000)` cap.
pub const MAX_PAGE_CONTENT_TEXT_BYTES: u32 = 200 * 1024;

/// Fixed-portion byte length of a `PageContentEvent` payload, before the
/// variable-length `url` / `title` / `full_text` / `source_browser` bytes:
///   `seq(8)` + `ts_us(8)` + `url_len(2)` + `title_len(2)`
///   + `full_text_len(4)` + `source_browser_len(1)` + `tab_id(4)` = 29.
pub const PAGE_CONTENT_EVENT_FIXED_HEADER_BYTES: usize = 8 + 8 + 2 + 2 + 4 + 1 + 4;

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
    /// Browser extension → agent full page content
    /// (see [`super::Message::PageContentEvent`]). Phase 7 pull-forward.
    PageContentEvent = 0x0050,
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
            0x0050 => Self::PageContentEvent,
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
            frames_encode_failed,
            frames_focus_race_dropped,
            failsafe_by_app,
            cpu_pct_micro,
            rss_bytes,
            tracker_alive_at_us,
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
            // wire 0x07: frames_encode_failed appended last (ocr-emit-
            // silence fix). Last-position preserves the dual-accept
            // contract — a 0x06 decoder reading a 0x07 payload would
            // tail-strict-mismatch (defense-in-depth), and a 0x07
            // decoder reading a 0x06 payload defaults this field to 0
            // by consuming only 7 u64s.
            out.extend_from_slice(&frames_encode_failed.to_le_bytes());
            // wire 0x08: frames_focus_race_dropped appended last
            // (ADR-0031 V2-P1). Same dual-accept discipline: a 0x07
            // decoder reading a 0x08 payload would tail-strict-
            // mismatch, a 0x08 decoder reading a 0x07 payload defaults
            // this field to 0 by consuming only 8 u64s.
            out.extend_from_slice(&frames_focus_race_dropped.to_le_bytes());
            // wire 0x09 (Phase 6 PR 6 — PR #226 §5.1 + CTO §4 Phase 6
            // PR 6): four new content-free fields appended in this
            // order: failsafe_by_app map (cap 8) → cpu_pct_micro →
            // rss_bytes → tracker_alive_at_us. The map is encoded as
            // a u8 entry count followed by N × (u8 bundle_id_len +
            // bundle_id bytes + u64 counter); the encoder caps at
            // [`MAX_FAILSAFE_BY_APP_ENTRIES`] entries (defense in
            // depth — the helper's `HelperHealthCounters` actor
            // already enforces the cap on writes, but a malformed
            // caller cannot bypass it here). Each bundle_id is capped
            // at [`MAX_FAILSAFE_BY_APP_BUNDLE_ID_LEN`] bytes.
            debug_assert!(
                failsafe_by_app.len() <= MAX_FAILSAFE_BY_APP_ENTRIES as usize,
                "failsafe_by_app exceeds MAX_FAILSAFE_BY_APP_ENTRIES — \
                 HelperHealthCounters cap-8 LRU was bypassed"
            );
            let entry_count = failsafe_by_app
                .len()
                .min(MAX_FAILSAFE_BY_APP_ENTRIES as usize);
            #[allow(clippy::cast_possible_truncation)]
            let entry_count_u8 = entry_count as u8;
            out.push(entry_count_u8);
            for (bundle_id, counter) in failsafe_by_app.iter().take(entry_count) {
                let bundle_bytes = bundle_id.as_bytes();
                debug_assert!(
                    bundle_bytes.len() <= MAX_FAILSAFE_BY_APP_BUNDLE_ID_LEN as usize,
                    "failsafe_by_app bundle_id exceeds MAX_FAILSAFE_BY_APP_BUNDLE_ID_LEN"
                );
                let id_len = bundle_bytes
                    .len()
                    .min(MAX_FAILSAFE_BY_APP_BUNDLE_ID_LEN as usize);
                #[allow(clippy::cast_possible_truncation)]
                let id_len_u8 = id_len as u8;
                out.push(id_len_u8);
                out.extend_from_slice(&bundle_bytes[..id_len]);
                out.extend_from_slice(&counter.to_le_bytes());
            }
            out.extend_from_slice(&cpu_pct_micro.to_le_bytes());
            out.extend_from_slice(&rss_bytes.to_le_bytes());
            out.extend_from_slice(&tracker_alive_at_us.to_le_bytes());
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
        Message::PageContentEvent {
            seq,
            ts_us,
            url,
            title,
            full_text,
            source_browser,
            tab_id,
        } => {
            out.extend_from_slice(&seq.to_le_bytes());
            out.extend_from_slice(&ts_us.to_le_bytes());
            debug_assert!(
                u16::try_from(url.len()).is_ok(),
                "PageContentEvent url too long for u16 length prefix"
            );
            debug_assert!(
                u16::try_from(title.len()).is_ok(),
                "PageContentEvent title too long for u16 length prefix"
            );
            debug_assert!(
                full_text.len() as u64 <= u64::from(MAX_PAGE_CONTENT_TEXT_BYTES),
                "PageContentEvent full_text exceeds MAX_PAGE_CONTENT_TEXT_BYTES"
            );
            debug_assert!(
                u8::try_from(source_browser.len()).is_ok(),
                "PageContentEvent source_browser too long for u8 length prefix"
            );
            #[allow(clippy::cast_possible_truncation)]
            let url_len = url.len() as u16;
            #[allow(clippy::cast_possible_truncation)]
            let title_len = title.len() as u16;
            #[allow(clippy::cast_possible_truncation)]
            let full_text_len = full_text.len() as u32;
            #[allow(clippy::cast_possible_truncation)]
            let source_browser_len = source_browser.len() as u8;
            out.extend_from_slice(&url_len.to_le_bytes());
            out.extend_from_slice(&title_len.to_le_bytes());
            out.extend_from_slice(&full_text_len.to_le_bytes());
            out.push(source_browser_len);
            out.extend_from_slice(&tab_id.to_le_bytes());
            out.extend_from_slice(url.as_bytes());
            out.extend_from_slice(title.as_bytes());
            out.extend_from_slice(full_text.as_bytes());
            out.extend_from_slice(source_browser.as_bytes());
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
    if !ACCEPTED_FRAME_VERSIONS.contains(&version) {
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

    let (message, used) = decode_payload(msg_type, payload, version)?;
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
fn decode_payload(
    msg_type: MessageType,
    payload: &[u8],
    version: u8,
) -> Result<(Message, usize), DecodeError> {
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
            // Quadruple-version dual-accept (cycle 8.27 revert
            // re-extends to include 0x06; 0x07 / 0x08 / 0x09 accepted
            // per the ADR-0031 V2-P1 + Phase 6 PR 6 bumps):
            //   - 0x06: seven u64s (uptime, delivered, suppressed,
            //     redacted_by_failsafe, cascade_forced, dropped_bp,
            //     dropped_late_ack). Defaults frames_encode_failed,
            //     frames_focus_race_dropped, failsafe_by_app,
            //     cpu_pct_micro, rss_bytes, tracker_alive_at_us.
            //   - 0x07: eight u64s (adds frames_encode_failed).
            //   - 0x08: nine u64s (adds frames_focus_race_dropped).
            //   - 0x09: nine u64s + failsafe_by_app map (u8 count + N
            //     × (u8 bundle_id_len + bytes + u64 counter)) +
            //     cpu_pct_micro (u32) + rss_bytes (u64) +
            //     tracker_alive_at_us (u64).
            //
            // Strict payload-length consumption in the caller catches a
            // malformed payload (extra bytes or trailing garbage) as
            // PayloadLengthMismatch. PageContentEvent / OCREvent byte
            // layouts are identical across all four accepted versions
            // (see FRAME_VERSION doc), so dual-accept is byte-equivalent
            // for them.
            let frames_encode_failed = if version == 0x06 { 0 } else { p.u64_le()? };
            let frames_focus_race_dropped = if version == 0x07 || version == 0x06 {
                0
            } else {
                p.u64_le()?
            };
            let (failsafe_by_app, cpu_pct_micro, rss_bytes, tracker_alive_at_us) =
                if version == 0x09 {
                    let entry_count = p.u8_le()?;
                    if entry_count > MAX_FAILSAFE_BY_APP_ENTRIES {
                        // Trust-boundary check: a fuzzed / malicious
                        // helper cannot claim more entries than the
                        // documented cap. The helper-side write path
                        // also enforces the cap (HelperHealthCounters
                        // actor); this is defense in depth.
                        return Err(DecodeError::OversizedPayload {
                            len: u32::from(entry_count),
                        });
                    }
                    let mut map = Vec::with_capacity(entry_count as usize);
                    for _ in 0..entry_count {
                        let id_len = p.u8_le()? as usize;
                        let bundle_id = p.string_bytes(id_len)?;
                        let counter = p.u64_le()?;
                        map.push((bundle_id, counter));
                    }
                    let cpu = p.u32_le()?;
                    let rss = p.u64_le()?;
                    let tracker = p.u64_le()?;
                    (map, cpu, rss, tracker)
                } else {
                    (Vec::new(), 0, 0, 0)
                };
            Message::HelperHealth {
                uptime_ms,
                frames_delivered,
                frames_suppressed,
                frames_redacted_by_failsafe,
                cascade_forced_count,
                frames_dropped_backpressure,
                frames_dropped_late_ack,
                frames_encode_failed,
                frames_focus_race_dropped,
                failsafe_by_app,
                cpu_pct_micro,
                rss_bytes,
                tracker_alive_at_us,
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
        MessageType::PageContentEvent => {
            let seq = p.u64_le()?;
            let ts_us = p.u64_le()?;
            let url_len = p.u16_le()? as usize;
            let title_len = p.u16_le()? as usize;
            let full_text_len_raw = p.u32_le()?;
            if full_text_len_raw > MAX_PAGE_CONTENT_TEXT_BYTES {
                return Err(DecodeError::OversizedPayload {
                    len: full_text_len_raw,
                });
            }
            let full_text_len = full_text_len_raw as usize;
            let source_browser_len = p.u8_le()? as usize;
            let tab_id = p.u32_le()?;
            let url = p.string_bytes(url_len)?;
            let title = p.string_bytes(title_len)?;
            let full_text = p.string_bytes(full_text_len)?;
            let source_browser = p.string_bytes(source_browser_len)?;
            Message::PageContentEvent {
                seq,
                ts_us,
                url,
                title,
                full_text,
                source_browser,
                tab_id,
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
            frames_encode_failed: 21,
            frames_focus_race_dropped: 31,
            failsafe_by_app: vec![
                ("com.anthropic.claudefordesktop".to_string(), 124),
                ("com.microsoft.VSCode".to_string(), 87),
                ("com.googlecode.iterm2".to_string(), 63),
            ],
            cpu_pct_micro: 15_000,        // 1.5%
            rss_bytes: 187 * 1024 * 1024, // 187 MiB
            tracker_alive_at_us: 1_700_000_000_000_000,
        });
    }

    #[test]
    fn roundtrip_helper_health_empty_failsafe_by_app() {
        // Most flushes won't have any per-app entries (the cascade
        // hasn't fail-safed anything in this window). Empty map must
        // round-trip — `u8 count = 0` consumes 1 byte and no entries.
        roundtrip(&Message::HelperHealth {
            uptime_ms: 30_000,
            frames_delivered: 150,
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
        });
    }

    #[test]
    fn roundtrip_helper_health_full_failsafe_by_app() {
        // Boundary: a flush with the cap-8 map fully populated must
        // round-trip. This is the upper-bound payload size for
        // failsafe_by_app — 1 byte count + 8 × (1 byte id_len + N
        // bundle id bytes + 8 byte counter).
        let entries: Vec<(String, u64)> = (0..MAX_FAILSAFE_BY_APP_ENTRIES)
            .map(|i| (format!("com.example.app{i}"), u64::from(i) * 100))
            .collect();
        assert_eq!(entries.len(), MAX_FAILSAFE_BY_APP_ENTRIES as usize);
        roundtrip(&Message::HelperHealth {
            uptime_ms: 60_000,
            frames_delivered: 300,
            frames_suppressed: 50,
            frames_redacted_by_failsafe: 50,
            cascade_forced_count: 12,
            frames_dropped_backpressure: 0,
            frames_dropped_late_ack: 0,
            frames_encode_failed: 0,
            frames_focus_race_dropped: 0,
            failsafe_by_app: entries,
            cpu_pct_micro: 100_000, // 10%
            rss_bytes: 1_500_000_000,
            tracker_alive_at_us: 0,
        });
    }

    #[test]
    fn helper_health_cross_side_fixture() {
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
                frames_encode_failed: 8,
                frames_focus_race_dropped: 9,
                // Empty failsafe_by_app + zero footprint sample +
                // tracker sentinel — the simplest 0x09 shape so the
                // Swift mirror's `testHelperHealthCrossSideFixture`
                // pins the same bytes.
                failsafe_by_app: vec![],
                cpu_pct_micro: 0,
                rss_bytes: 0,
                tracker_alive_at_us: 0,
            },
        );
        // Wire 0x09 with empty failsafe_by_app + zero footprint:
        //   header(16) + 9 × u64(72) + u8 entry_count(1)
        //   + u32 cpu_pct_micro(4) + u64 rss_bytes(8)
        //   + u64 tracker_alive_at_us(8)
        // = 16 + 72 + 1 + 4 + 8 + 8 = 109 bytes.
        // Payload length = 109 - 16 = 93 = 0x5D.
        let expected: [u8; 109] = [
            0x4D, 0x09, 0x30, 0x00, // magic + ver + msg_type LE
            0x2A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // seq = 42
            0x5D, 0x00, 0x00, 0x00, // payload len = 93
            // 9 × u64 LE (1..=9):
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, // failsafe_by_app: entry_count = 0 (1 byte), no entries.
            0x00, // cpu_pct_micro = 0 (u32 LE)
            0x00, 0x00, 0x00, 0x00, // rss_bytes = 0 (u64 LE)
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            // tracker_alive_at_us = 0 (u64 LE)
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ];
        assert_eq!(
            buf,
            expected.to_vec(),
            "HelperHealth v0x09 empty-map cross-side fixture"
        );

        // And the round-trip decoder reads exactly back what the
        // encoder produced — proves the v0x09 layout is self-consistent.
        let (frame, used) = decode(&buf).expect("decode v0x09 fixture");
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
                frames_encode_failed: 8,
                frames_focus_race_dropped: 9,
                failsafe_by_app: vec![],
                cpu_pct_micro: 0,
                rss_bytes: 0,
                tracker_alive_at_us: 0,
            }
        );
    }

    #[test]
    fn helper_health_v0x09_layout_offsets() {
        // Trip-wire: the wire 0x09 bump adds four trailing fields
        // (failsafe_by_app, cpu_pct_micro, rss_bytes,
        // tracker_alive_at_us). With an empty failsafe_by_app the
        // payload is 9 × u64 + u8(0) + u32 + u64 + u64 = 72 + 1 + 4
        // + 8 + 8 = 93 bytes. The Swift mirror's
        // `testHelperHealthFixture` asserts the same length.
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
                frames_encode_failed: 17,
                frames_focus_race_dropped: 23,
                failsafe_by_app: vec![],
                cpu_pct_micro: 5_500, // 0.55%
                rss_bytes: 90 * 1024 * 1024,
                tracker_alive_at_us: 0,
            },
        );
        assert_eq!(buf.len(), MIN_FRAME_HEADER_BYTES + 93);

        // failsafe_by_app entry_count is the byte after the 9th u64.
        // Offset = header(16) + 9 × u64(72) = 88.
        let entry_count_off = MIN_FRAME_HEADER_BYTES + 9 * 8;
        assert_eq!(buf[entry_count_off], 0);

        // cpu_pct_micro starts 1 byte later.
        let cpu_off = entry_count_off + 1;
        let cpu = u32::from_le_bytes(buf[cpu_off..cpu_off + 4].try_into().unwrap());
        assert_eq!(cpu, 5_500);

        // rss_bytes starts 4 bytes after cpu_pct_micro.
        let rss_off = cpu_off + 4;
        let rss = u64::from_le_bytes(buf[rss_off..rss_off + 8].try_into().unwrap());
        assert_eq!(rss, 90 * 1024 * 1024);
    }

    #[test]
    fn frame_version_is_0x09() {
        assert_eq!(FRAME_VERSION, 0x09);
        let buf = encode(0, &Message::CaptureStop);
        assert_eq!(buf[1], 0x09, "version byte in the framed header");
    }

    #[test]
    fn accepted_frame_versions_includes_current_and_prior() {
        assert_eq!(
            ACCEPTED_FRAME_VERSIONS[0], FRAME_VERSION,
            "current version must lead the accept set"
        );
        assert!(
            ACCEPTED_FRAME_VERSIONS.contains(&0x08),
            "0x08 must remain accepted for rolling-restart safety per the \
             Phase 6 PR 6 bump (an 0x08-era helper alive across an agent \
             restart must still be readable)"
        );
        assert!(
            ACCEPTED_FRAME_VERSIONS.contains(&0x07),
            "0x07 retained as a conservative one-extra-window cushion until \
             the 0x07-era rolling-restart risk has fully aged out"
        );
        assert!(
            ACCEPTED_FRAME_VERSIONS.contains(&0x06),
            "0x06 must remain accepted: the Safari extension native messaging host \
             emits PageContentEvent frames at 0x06 and the extension cannot be updated \
             atomically with helper releases (cycle 8.27 emergency revert lesson — \
             PR #266 discipline: NEVER drop 0x06)"
        );
        // Hard-rejected: anything older than 0x06 is out of the
        // documented asynchronous-update + rolling-restart window.
        assert!(
            !ACCEPTED_FRAME_VERSIONS.contains(&0x05),
            "0x05 reaches end-of-support"
        );
        assert_eq!(
            ACCEPTED_FRAME_VERSIONS.len(),
            4,
            "the accept window is [0x09, 0x08, 0x07, 0x06]; growing it \
             further widens trust-boundary surface area"
        );
    }

    #[test]
    fn decode_accepts_legacy_0x08_helper_health_payload() {
        // Rolling-restart contract: an 0x08-era helper alive on a CEO
        // machine across an agent restart can still emit valid
        // HelperHealth frames; the v0x09 decoder reads them with the
        // four trailing fields defaulted (empty Vec, 0, 0, 0).
        let mut buf = encode(
            42,
            &Message::HelperHealth {
                uptime_ms: 1,
                frames_delivered: 2,
                frames_suppressed: 3,
                frames_redacted_by_failsafe: 4,
                cascade_forced_count: 5,
                frames_dropped_backpressure: 6,
                frames_dropped_late_ack: 7,
                frames_encode_failed: 8,
                frames_focus_race_dropped: 9,
                // These source values get dropped on the re-shape because
                // an 0x08 helper never emitted them.
                failsafe_by_app: vec![("com.example".to_string(), 7)],
                cpu_pct_micro: 12_345,
                rss_bytes: 67_890,
                tracker_alive_at_us: 11_111,
            },
        );
        // Re-shape the buffer as if an 0x08 helper had emitted it:
        // version byte → 0x08, drop the 0x09-only trailing bytes
        // (failsafe_by_app + cpu + rss + tracker), shrink declared
        // payload length to 9 × u64 = 72.
        buf[1] = 0x08;
        // Trailing payload bytes to strip = total - header - 72.
        let payload_strip = buf.len() - MIN_FRAME_HEADER_BYTES - 72;
        let new_payload_len = 72_u32;
        buf[12..16].copy_from_slice(&new_payload_len.to_le_bytes());
        buf.truncate(buf.len() - payload_strip);
        assert_eq!(buf.len(), MIN_FRAME_HEADER_BYTES + 72);

        let (frame, used) = decode(&buf).expect("decode legacy 0x08 HelperHealth");
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
                frames_encode_failed: 8,
                frames_focus_race_dropped: 9,
                // Defaulted on 0x08 — the source values are stripped.
                failsafe_by_app: vec![],
                cpu_pct_micro: 0,
                rss_bytes: 0,
                tracker_alive_at_us: 0,
            }
        );
    }

    #[test]
    fn decode_accepts_legacy_0x07_helper_health_payload() {
        // 0x07-era helper alive across an agent restart: the v0x09
        // decoder reads them with `frames_focus_race_dropped` +
        // four 0x09-only fields defaulted.
        let mut buf = encode(
            42,
            &Message::HelperHealth {
                uptime_ms: 1,
                frames_delivered: 2,
                frames_suppressed: 3,
                frames_redacted_by_failsafe: 4,
                cascade_forced_count: 5,
                frames_dropped_backpressure: 6,
                frames_dropped_late_ack: 7,
                frames_encode_failed: 8,
                frames_focus_race_dropped: 9_999,
                failsafe_by_app: vec![],
                cpu_pct_micro: 0,
                rss_bytes: 0,
                tracker_alive_at_us: 0,
            },
        );
        // Re-shape as 0x07: 8 × u64 = 64 byte payload.
        buf[1] = 0x07;
        let strip = buf.len() - MIN_FRAME_HEADER_BYTES - 64;
        let new_payload_len = 64_u32;
        buf[12..16].copy_from_slice(&new_payload_len.to_le_bytes());
        buf.truncate(buf.len() - strip);

        let (frame, used) = decode(&buf).expect("decode legacy 0x07 HelperHealth");
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
                frames_encode_failed: 8,
                frames_focus_race_dropped: 0,
                failsafe_by_app: vec![],
                cpu_pct_micro: 0,
                rss_bytes: 0,
                tracker_alive_at_us: 0,
            }
        );
    }

    #[test]
    fn decode_accepts_legacy_0x06_helper_health_payload() {
        // 0x06-era PageContentEvent helper is the documented async-
        // update case for the Safari native messaging host. The same
        // 0x06 acceptance also covers HelperHealth at 7-u64 shape
        // (the original wire 0x06 helper carried only seven counters).
        let mut buf = encode(
            42,
            &Message::HelperHealth {
                uptime_ms: 1,
                frames_delivered: 2,
                frames_suppressed: 3,
                frames_redacted_by_failsafe: 4,
                cascade_forced_count: 5,
                frames_dropped_backpressure: 6,
                frames_dropped_late_ack: 7,
                frames_encode_failed: 0,
                frames_focus_race_dropped: 0,
                failsafe_by_app: vec![],
                cpu_pct_micro: 0,
                rss_bytes: 0,
                tracker_alive_at_us: 0,
            },
        );
        // Re-shape as 0x06: 7 × u64 = 56 byte payload.
        buf[1] = 0x06;
        let strip = buf.len() - MIN_FRAME_HEADER_BYTES - 56;
        let new_payload_len = 56_u32;
        buf[12..16].copy_from_slice(&new_payload_len.to_le_bytes());
        buf.truncate(buf.len() - strip);

        let (frame, used) = decode(&buf).expect("decode legacy 0x06 HelperHealth");
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
                frames_encode_failed: 0,
                frames_focus_race_dropped: 0,
                failsafe_by_app: vec![],
                cpu_pct_micro: 0,
                rss_bytes: 0,
                tracker_alive_at_us: 0,
            }
        );
    }

    #[test]
    fn decode_rejects_failsafe_by_app_over_cap() {
        // Trust-boundary check: a fuzzed / malicious helper claiming
        // more than MAX_FAILSAFE_BY_APP_ENTRIES (8) entries must be
        // rejected before the decoder allocates the Vec. Hand-craft a
        // payload that declares entry_count = 9.
        let mut payload = Vec::new();
        for v in 0u64..9 {
            // 9 u64 counters as the pre-map portion.
            payload.extend_from_slice(&v.to_le_bytes());
        }
        payload.push(MAX_FAILSAFE_BY_APP_ENTRIES + 1); // entry_count = 9
                                                       // No entries follow — decoder rejects on the count alone.

        let mut buf = vec![FRAME_MAGIC, FRAME_VERSION];
        buf.extend_from_slice(&(MessageType::HelperHealth as u16).to_le_bytes());
        buf.extend_from_slice(&0_u64.to_le_bytes());
        #[allow(clippy::cast_possible_truncation)]
        let payload_len = payload.len() as u32;
        buf.extend_from_slice(&payload_len.to_le_bytes());
        buf.extend_from_slice(&payload);

        let err = decode(&buf).unwrap_err();
        assert!(
            matches!(err, DecodeError::OversizedPayload { len: 9 }),
            "expected OversizedPayload on over-cap failsafe_by_app entry_count, got {err:?}"
        );
    }

    #[test]
    fn decode_accepts_legacy_0x06_page_content_payload() {
        // Cycle 8.27 emergency revert: the Safari extension's native
        // messaging host emits PageContentEvent frames at wire 0x06.
        // Cycle 8.27 production showed `unsupported wire version: got
        // 0x06` on a loop when the helper bumped to 0x08 without
        // dual-accepting 0x06. PageContentEvent byte layout is
        // identical across 0x06 / 0x07 / 0x08 per the FRAME_VERSION
        // doc, so re-shaping a 0x08-encoded frame to 0x06 must decode
        // round-trip identical.
        let original = Message::PageContentEvent {
            seq: 7,
            ts_us: 1_700_000_000_000_000,
            url: "https://example.com/article".into(),
            title: "Example Article".into(),
            full_text: "page body text".into(),
            source_browser: "safari".into(),
            tab_id: 42,
        };
        let mut buf = encode(123, &original);
        // Re-shape the frame header as if a 0x06-era Safari extension
        // had emitted it. PageContentEvent payload bytes are unchanged.
        buf[1] = 0x06;

        let (frame, used) = decode(&buf).expect("decode legacy 0x06 PageContentEvent");
        assert_eq!(used, buf.len());
        assert_eq!(frame.seq, 123);
        assert_eq!(frame.message, original);
    }

    #[test]
    fn decode_rejects_old_0x05_frame_at_v0x07_layout() {
        let mut buf = encode(0, &Message::CaptureStop);
        buf[1] = 0x05;
        let err = decode(&buf).unwrap_err();
        assert!(matches!(err, DecodeError::UnsupportedVersion { got: 0x05 }));
    }

    #[test]
    fn decode_rejects_old_0x04_frame() {
        let mut buf = encode(0, &Message::CaptureStop);
        buf[1] = 0x04;
        let err = decode(&buf).unwrap_err();
        assert!(matches!(err, DecodeError::UnsupportedVersion { got: 0x04 }));
    }

    #[test]
    fn decode_rejects_old_0x03_frame() {
        let mut buf = encode(0, &Message::CaptureStop);
        buf[1] = 0x03;
        let err = decode(&buf).unwrap_err();
        assert!(matches!(err, DecodeError::UnsupportedVersion { got: 0x03 }));
    }

    #[test]
    fn decode_rejects_old_0x02_frame() {
        let mut buf = encode(0, &Message::CaptureStop);
        buf[1] = 0x02;
        let err = decode(&buf).unwrap_err();
        assert!(matches!(err, DecodeError::UnsupportedVersion { got: 0x02 }));
    }

    #[test]
    fn decode_rejects_old_0x01_frame() {
        let mut buf = encode(0, &Message::CaptureStop);
        buf[1] = 0x01;
        let err = decode(&buf).unwrap_err();
        assert!(matches!(err, DecodeError::UnsupportedVersion { got: 0x01 }));
    }

    #[test]
    fn decode_rejects_old_v0x02_helper_health_payload() {
        // A v0x02 HelperHealth payload was 6 × u64 = 48 bytes; the
        // current v0x09 decoder expects at minimum 7 × u64 (the
        // always-read prefix) before any version-conditional reads.
        // Hand-craft a header that claims FRAME_VERSION but carries a
        // v0x02-shaped payload — strict payload-length consumption is
        // what guards against silent cross-version reads after the
        // version byte alone would not (e.g. a misconfigured proxy).
        // This is the "payload-strict-consumption tripwire" called
        // out in the PR body. (The dual-accept window
        // [0x09, 0x08, 0x07, 0x06] does NOT widen this — older bytes
        // still fail-closed at the truncated-payload tripwire.)
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
        // 7th u64 (frames_dropped_late_ack) — surfaces as a Truncated
        // parser error.
        assert!(
            matches!(err, DecodeError::Truncated { .. }),
            "expected Truncated on a 48-byte v0x02-shaped payload at v0x09, got {err:?}"
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

        assert_eq!(&buf[0..4], &[0x4D, 0x09, 0x40, 0x00]);
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
        let buf = encode(0, &Message::CaptureStop);
        assert_eq!(
            buf.len(),
            MIN_FRAME_HEADER_BYTES,
            "CaptureStop has zero-byte payload"
        );
    }

    #[test]
    fn roundtrip_page_content_event_minimal() {
        roundtrip(&Message::PageContentEvent {
            seq: 0,
            ts_us: 0,
            url: String::new(),
            title: String::new(),
            full_text: String::new(),
            source_browser: String::new(),
            tab_id: 0,
        });
    }

    #[test]
    fn roundtrip_page_content_event_populated() {
        roundtrip(&Message::PageContentEvent {
            seq: 99,
            ts_us: 1_700_000_000_000_000,
            url: "https://example.com/pricing".to_string(),
            title: "Pricing — Example Corp".to_string(),
            full_text: "Plans start at $10/mo.\nEnterprise pricing available.".to_string(),
            source_browser: "chrome".to_string(),
            tab_id: 42,
        });
    }

    #[test]
    fn page_content_event_cross_side_fixture() {
        let buf = encode(
            7,
            &Message::PageContentEvent {
                seq: 7,
                ts_us: 0x0102_0304_0506_0708,
                url: "U".to_string(),
                title: "T".to_string(),
                full_text: "Hi".to_string(),
                source_browser: "chrome".to_string(),
                tab_id: 99,
            },
        );
        // Fixed header = 8+8+2+2+4+1+4 = 29
        // Variable = 1(U) + 1(T) + 2(Hi) + 6(chrome) = 10
        // Total payload = 39. Frame total = 16 + 39 = 55.
        assert_eq!(
            buf.len(),
            MIN_FRAME_HEADER_BYTES + PAGE_CONTENT_EVENT_FIXED_HEADER_BYTES + 10
        );
        assert_eq!(buf.len(), 55);

        // Header check.
        assert_eq!(&buf[0..4], &[0x4D, 0x09, 0x50, 0x00]);
        assert_eq!(&buf[4..12], &7u64.to_le_bytes());
        assert_eq!(&buf[12..16], &39u32.to_le_bytes());

        // Payload: seq u64 = 7.
        assert_eq!(&buf[16..24], &7u64.to_le_bytes());
        // ts_us u64.
        assert_eq!(&buf[24..32], &0x0102_0304_0506_0708u64.to_le_bytes());
        // url_len u16 = 1.
        assert_eq!(&buf[32..34], &1u16.to_le_bytes());
        // title_len u16 = 1.
        assert_eq!(&buf[34..36], &1u16.to_le_bytes());
        // full_text_len u32 = 2.
        assert_eq!(&buf[36..40], &2u32.to_le_bytes());
        // source_browser_len u8 = 6.
        assert_eq!(buf[40], 6);
        // tab_id u32 = 99.
        assert_eq!(&buf[41..45], &99u32.to_le_bytes());
        // Variable: url(1) + title(1) + full_text(2) + source_browser(6).
        assert_eq!(&buf[45..46], b"U");
        assert_eq!(&buf[46..47], b"T");
        assert_eq!(&buf[47..49], b"Hi");
        assert_eq!(&buf[49..55], b"chrome");

        let (frame, used) = decode(&buf).expect("decode PageContentEvent fixture");
        assert_eq!(used, buf.len());
        assert_eq!(frame.seq, 7);
        match frame.message {
            Message::PageContentEvent {
                seq,
                ts_us,
                url,
                title,
                full_text,
                source_browser,
                tab_id,
            } => {
                assert_eq!(seq, 7);
                assert_eq!(ts_us, 0x0102_0304_0506_0708);
                assert_eq!(url, "U");
                assert_eq!(title, "T");
                assert_eq!(full_text, "Hi");
                assert_eq!(source_browser, "chrome");
                assert_eq!(tab_id, 99);
            }
            other => panic!("expected PageContentEvent, got {other:?}"),
        }
    }

    #[test]
    fn decode_rejects_oversized_page_content_text() {
        let mut payload = Vec::new();
        payload.extend_from_slice(&0u64.to_le_bytes()); // seq
        payload.extend_from_slice(&0u64.to_le_bytes()); // ts_us
        payload.extend_from_slice(&0u16.to_le_bytes()); // url_len
        payload.extend_from_slice(&0u16.to_le_bytes()); // title_len
        payload.extend_from_slice(&(MAX_PAGE_CONTENT_TEXT_BYTES + 1).to_le_bytes());
        payload.push(0); // source_browser_len
        payload.extend_from_slice(&0u32.to_le_bytes()); // tab_id

        let mut buf = vec![FRAME_MAGIC, FRAME_VERSION];
        buf.extend_from_slice(&(MessageType::PageContentEvent as u16).to_le_bytes());
        buf.extend_from_slice(&0u64.to_le_bytes());
        #[allow(clippy::cast_possible_truncation)]
        let payload_len = payload.len() as u32;
        buf.extend_from_slice(&payload_len.to_le_bytes());
        buf.extend_from_slice(&payload);

        let err = decode(&buf).unwrap_err();
        assert!(
            matches!(err, DecodeError::OversizedPayload { .. }),
            "expected OversizedPayload on over-cap page content text, got {err:?}"
        );
    }
}
