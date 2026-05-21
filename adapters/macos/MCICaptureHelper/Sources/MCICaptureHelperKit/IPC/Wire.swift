// SPDX-License-Identifier: TBD-private
//
// Wire — Swift mirror of `core::ipc::wire` (encode-only on the helper
// side; the Rust core is the sole decoder of helper-originated bytes).
//
// PROTECTED-SET per AGENT_PROTOCOL §5. Any drift between this file and
// `core/src/ipc/wire.rs` silently breaks the contract — the byte-level
// fixture tests in `Tests/MCICaptureHelperKitTests/WireTests.swift`
// assert specific encoded byte sequences that match Rust-side
// reference vectors so drift is caught at CI time.
//
// Wire format (binary, little-endian) — identical to the Rust spec:
//
//   magic(1=0x4D) + version(1=0x04) + msg_type(2) + seq(8) + len(4) + payload(len)
//
// version 0x01 → 0x02 (2026-05-19): HelperHealth gained the
// frames_redacted_by_failsafe counter.
// version 0x02 → 0x03 (2026-05-20): HelperHealth gained the
// cascade_forced_count counter (STEP-2-FINDING-004 — floor-forced
// cascade evaluations are now observable on the wire, strictly
// disjoint from filter-passed evaluations).
// version 0x03 → 0x04 (2026-05-20, ADR-0016 P3.6): new OCREvent message
// type (0x0040) — the FIRST message variant carrying user content
// (OCR'd text) across the IPC seam. Gated by ADR-0013 cascade running
// TWICE (once on pixels at frame time, once on OCR'd text via §6).
// RedactionReason 6 (`ocrTimeSecret`) added so the twice-fired path
// emits a PrivacyTombstone with the distinct reason. ADR-0016 §1.6
// proposed slot 0x0020 but that slot was claimed by SurfaceReleased in
// PR #15; this bump assigns 0x0040.
// Helper + core ship version-locked; the Rust decoder rejects any
// other version.

import Foundation

/// Wire-format magic byte.
public let frameMagic: UInt8 = 0x4D

/// Wire-format version byte. MUST match `core::ipc::wire::FRAME_VERSION`.
/// 0x05→0x06: OCR/PageContent merge — agent merges cached extension text
/// into brain events when URL matches. Wire byte layout unchanged;
/// semantic-only bump.
public let frameVersion: UInt8 = 0x06

/// Minimum frame header size in bytes.
public let minFrameHeaderBytes = 1 + 1 + 2 + 8 + 4

/// Per-event OCR text cap (ADR-0016 §4.9). Over-cap OCR results
/// fail closed — the helper emits a PrivacyTombstone(reason=
/// failsafeUnknown) instead of an OCREvent. Mirrors
/// `core::ipc::wire::MAX_OCR_TEXT_BYTES`.
public let maxOCRTextBytes: Int = 64 * 1024

/// Fixed app-bundle-id length in OCREvent (null-padded). Mirrors
/// `core::ipc::wire::OCR_EVENT_APP_BUNDLE_ID_LEN`.
public let ocrEventAppBundleIdLen: Int = 64

/// Fixed keyframe-hash length in OCREvent. Mirrors
/// `core::ipc::wire::OCR_EVENT_KEYFRAME_HASH_LEN`.
public let ocrEventKeyframeHashLen: Int = 32

/// Wire `msg_type` discriminants. MUST match `core::ipc::wire::MessageType`.
public enum MessageType: UInt16, Sendable {
    case captureStart = 0x0001
    case captureStop = 0x0002
    case stateTransitionEvent = 0x0010
    case privacyTombstone = 0x0011
    case surfaceReleased = 0x0020
    case helperHealth = 0x0030
    /// ADR-0016 P3.6 — twice-cleared OCR event carrying USER CONTENT
    /// (OCR'd text). Slot 0x0040 (0x0020 from ADR-0016 §1.6 was already
    /// claimed by `surfaceReleased`; the ADR owes a follow-up doc PR
    /// to reflect the actual assigned slot).
    case ocrEvent = 0x0040
    /// Phase 7 — browser extension full page content event.
    case pageContentEvent = 0x0050
}

/// A privacy tombstone — the only message the helper emits in this cycle.
/// `StateTransitionEvent` lands once SCStream actually delivers frames
/// (Phase-1 cycle 2+).
public struct PrivacyTombstone: Sendable, Equatable {
    public let tsUs: UInt64
    public let appBundle: String
    public let reason: RedactionReason

    public init(tsUs: UInt64, appBundle: String, reason: RedactionReason) {
        self.tsUs = tsUs
        self.appBundle = appBundle
        self.reason = reason
    }
}

/// Encode a privacy tombstone as a complete wire frame.
///
/// Returns the bytes in exactly the layout `core::ipc::wire::decode`
/// expects, including the framing envelope. The Rust decoder is the
/// trust boundary; if this encoder produces something the decoder
/// rejects, that's a bug here.
public func encodePrivacyTombstone(seq: UInt64, tombstone: PrivacyTombstone) -> Data {
    var payload = Data()
    payload.appendUInt64LE(tombstone.tsUs)
    payload.appendString(tombstone.appBundle)
    payload.append(tombstone.reason.rawValue)

    return assembleFrame(
        msgType: .privacyTombstone,
        seq: seq,
        payload: payload
    )
}

/// Encode a `CaptureStop` ack message (helper → core).
///
/// The helper sends this when it has stopped the SCStream in response
/// to a core `CaptureStop` request, so the core knows the helper is
/// ready to be torn down.
public func encodeCaptureStop(seq: UInt64) -> Data {
    assembleFrame(msgType: .captureStop, seq: seq, payload: Data())
}

/// Errors the OCREvent encoder surfaces when its input violates the
/// helper-side trust-boundary contract (ADR-0016 §4.9). Surfaced as
/// values, not throws, so the caller (cascade-after-OCR emitter) can
/// translate them into the documented fail-closed
/// `PrivacyTombstone(reason=failsafeUnknown)` arm.
public enum OCREventEncodeError: Error, Equatable {
    /// OCR text exceeded `maxOCRTextBytes` (ADR-0016 §4.9). Helper-side
    /// fail-closed default: caller emits a tombstone with reason 7.
    case ocrTextOverCap(byteCount: Int)
    /// window_title or url length exceeded `UInt16.max` — defensive,
    /// not expected in real-world apps; caller should also fail closed.
    case fieldOverflow(field: String, byteCount: Int)
}

/// A twice-cleared OCR event payload — ADR-0016 P3.6 §1.6. The cascade
/// has fired on pixels at frame time AND on OCR'd text via §6, and BOTH
/// returned `.allow`. Only then does this struct exist; only then does
/// the helper emit `encodeOCREvent(...)` bytes.
///
/// PROTECTED-SET per AGENT_PROTOCOL §5. The bytes carry USER CONTENT
/// (the OCR'd text). Any change to how this struct reaches the wire
/// requires CSO review per ADR-0016 §4 invariants.
public struct OCREvent: Sendable, Equatable {
    /// Event-level sequence; in production matches the wire-frame seq.
    public let seq: UInt64
    public let tsUs: UInt64
    /// Bundle id of the foreground app, plain UTF-8 (the encoder
    /// null-pads to `ocrEventAppBundleIdLen` bytes on the wire).
    public let appBundleId: String
    public let windowTitle: String
    public let url: String
    /// Post-cascade-twice OCR'd text. MUST be ≤ `maxOCRTextBytes`
    /// (UTF-8 byte length); over-cap fails closed via the encoder.
    public let ocrText: String
    /// blake3 of the keyframe blob. All-zero bytes signals "no blob
    /// yet" — P3.6.5 lands the blob writer.
    public let keyframeHash: [UInt8]

    public init(
        seq: UInt64,
        tsUs: UInt64,
        appBundleId: String,
        windowTitle: String,
        url: String,
        ocrText: String,
        keyframeHash: [UInt8] = [UInt8](repeating: 0, count: 32)
    ) {
        precondition(keyframeHash.count == ocrEventKeyframeHashLen,
                     "OCREvent keyframeHash MUST be \(ocrEventKeyframeHashLen) bytes")
        self.seq = seq
        self.tsUs = tsUs
        self.appBundleId = appBundleId
        self.windowTitle = windowTitle
        self.url = url
        self.ocrText = ocrText
        self.keyframeHash = keyframeHash
    }
}

/// Encode an OCREvent as a complete wire frame. The 64 KB OCR-text cap
/// is enforced helper-side here; over-cap returns
/// `.failure(.ocrTextOverCap(...))` so the caller emits a
/// `PrivacyTombstone(reason=failsafeUnknown)` instead per ADR-0013 §7.
///
/// Returns the bytes in exactly the layout `core::ipc::wire::decode`
/// expects for `MessageType::OCREvent`. ADR-0016 §1.6 byte order:
///   seq u64 LE · ts_us u64 LE · app_bundle_id [u8; 64] null-padded
///   · window_title_len u16 LE · url_len u16 LE · ocr_text_len u32 LE
///   · keyframe_hash [u8; 32]
///   · window_title bytes · url bytes · ocr_text bytes
public func encodeOCREvent(
    seq: UInt64,
    event: OCREvent
) -> Result<Data, OCREventEncodeError> {
    let titleBytes = Array(event.windowTitle.utf8)
    let urlBytes = Array(event.url.utf8)
    let textBytes = Array(event.ocrText.utf8)

    guard textBytes.count <= maxOCRTextBytes else {
        return .failure(.ocrTextOverCap(byteCount: textBytes.count))
    }
    guard titleBytes.count <= Int(UInt16.max) else {
        return .failure(.fieldOverflow(field: "window_title", byteCount: titleBytes.count))
    }
    guard urlBytes.count <= Int(UInt16.max) else {
        return .failure(.fieldOverflow(field: "url", byteCount: urlBytes.count))
    }

    var bundlePadded = [UInt8](repeating: 0, count: ocrEventAppBundleIdLen)
    let bundleBytes = Array(event.appBundleId.utf8)
    let copyLen = min(bundleBytes.count, ocrEventAppBundleIdLen)
    if copyLen > 0 {
        bundlePadded.replaceSubrange(0..<copyLen, with: bundleBytes.prefix(copyLen))
    }

    var payload = Data()
    payload.appendUInt64LE(event.seq)
    payload.appendUInt64LE(event.tsUs)
    payload.append(contentsOf: bundlePadded)
    payload.appendUInt16LE(UInt16(titleBytes.count))
    payload.appendUInt16LE(UInt16(urlBytes.count))
    payload.appendUInt32LE(UInt32(textBytes.count))
    payload.append(contentsOf: event.keyframeHash)
    payload.append(contentsOf: titleBytes)
    payload.append(contentsOf: urlBytes)
    payload.append(contentsOf: textBytes)

    return .success(assembleFrame(msgType: .ocrEvent, seq: seq, payload: payload))
}

/// Per-event page content text cap (200 KB). Mirrors
/// `core::ipc::wire::MAX_PAGE_CONTENT_TEXT_BYTES`.
public let maxPageContentTextBytes: Int = 200 * 1024

/// Browser extension page content event — Phase 7 pull-forward.
/// Full page text from `document.body.innerText` via native messaging.
public struct PageContentEvent: Sendable, Equatable {
    public let seq: UInt64
    public let tsUs: UInt64
    public let url: String
    public let title: String
    public let fullText: String
    public let sourceBrowser: String
    public let tabId: UInt32

    public init(
        seq: UInt64,
        tsUs: UInt64,
        url: String,
        title: String,
        fullText: String,
        sourceBrowser: String,
        tabId: UInt32 = 0
    ) {
        self.seq = seq
        self.tsUs = tsUs
        self.url = url
        self.title = title
        self.fullText = fullText
        self.sourceBrowser = sourceBrowser
        self.tabId = tabId
    }
}

/// Errors the PageContentEvent encoder surfaces.
public enum PageContentEventEncodeError: Error, Equatable {
    case fullTextOverCap(byteCount: Int)
    case fieldOverflow(field: String, byteCount: Int)
}

/// Encode a PageContentEvent as a complete wire frame.
public func encodePageContentEvent(
    seq: UInt64,
    event: PageContentEvent
) -> Result<Data, PageContentEventEncodeError> {
    let urlBytes = Array(event.url.utf8)
    let titleBytes = Array(event.title.utf8)
    let textBytes = Array(event.fullText.utf8)
    let browserBytes = Array(event.sourceBrowser.utf8)

    guard textBytes.count <= maxPageContentTextBytes else {
        return .failure(.fullTextOverCap(byteCount: textBytes.count))
    }
    guard urlBytes.count <= Int(UInt16.max) else {
        return .failure(.fieldOverflow(field: "url", byteCount: urlBytes.count))
    }
    guard titleBytes.count <= Int(UInt16.max) else {
        return .failure(.fieldOverflow(field: "title", byteCount: titleBytes.count))
    }
    guard browserBytes.count <= Int(UInt8.max) else {
        return .failure(.fieldOverflow(field: "source_browser", byteCount: browserBytes.count))
    }

    var payload = Data()
    payload.appendUInt64LE(event.seq)
    payload.appendUInt64LE(event.tsUs)
    payload.appendUInt16LE(UInt16(urlBytes.count))
    payload.appendUInt16LE(UInt16(titleBytes.count))
    payload.appendUInt32LE(UInt32(textBytes.count))
    payload.append(UInt8(browserBytes.count))
    payload.appendUInt32LE(event.tabId)
    payload.append(contentsOf: urlBytes)
    payload.append(contentsOf: titleBytes)
    payload.append(contentsOf: textBytes)
    payload.append(contentsOf: browserBytes)

    return .success(assembleFrame(msgType: .pageContentEvent, seq: seq, payload: payload))
}

/// Encode a periodic helper-health counter frame.
public func encodeHelperHealth(
    seq: UInt64,
    uptimeMs: UInt64,
    framesDelivered: UInt64,
    framesSuppressed: UInt64,
    framesRedactedByFailsafe: UInt64,
    cascadeForcedCount: UInt64,
    framesDroppedBackpressure: UInt64,
    framesDroppedLateAck: UInt64
) -> Data {
    var payload = Data()
    payload.appendUInt64LE(uptimeMs)
    payload.appendUInt64LE(framesDelivered)
    payload.appendUInt64LE(framesSuppressed)
    // §7 fail-safe subcount — introduced wire 0x02. Order matches
    // core::ipc::wire decode: directly after frames_suppressed.
    payload.appendUInt64LE(framesRedactedByFailsafe)
    // STEP-2-FINDING-004 floor-forced cascade counter — wire 0x03.
    // Disjoint from filter-passed cascade calls; observability-only.
    // Order matches core::ipc::wire decode: directly after
    // frames_redacted_by_failsafe and before the drop-side counters.
    payload.appendUInt64LE(cascadeForcedCount)
    payload.appendUInt64LE(framesDroppedBackpressure)
    payload.appendUInt64LE(framesDroppedLateAck)
    return assembleFrame(msgType: .helperHealth, seq: seq, payload: payload)
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

private func assembleFrame(msgType: MessageType, seq: UInt64, payload: Data) -> Data {
    var out = Data(capacity: minFrameHeaderBytes + payload.count)
    out.append(frameMagic)
    out.append(frameVersion)
    out.appendUInt16LE(msgType.rawValue)
    out.appendUInt64LE(seq)
    let len = UInt32(payload.count)
    out.appendUInt32LE(len)
    out.append(payload)
    return out
}

extension Data {
    mutating func appendUInt16LE(_ v: UInt16) {
        append(UInt8(v & 0xff))
        append(UInt8((v >> 8) & 0xff))
    }
    mutating func appendUInt32LE(_ v: UInt32) {
        append(UInt8(v & 0xff))
        append(UInt8((v >> 8) & 0xff))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 24) & 0xff))
    }
    mutating func appendUInt64LE(_ v: UInt64) {
        for i in 0..<8 {
            append(UInt8((v >> (i * 8)) & 0xff))
        }
    }
    mutating func appendString(_ s: String) {
        let bytes = Array(s.utf8)
        precondition(bytes.count <= Int(UInt16.max), "string too long for u16 prefix")
        appendUInt16LE(UInt16(bytes.count))
        append(contentsOf: bytes)
    }
}
