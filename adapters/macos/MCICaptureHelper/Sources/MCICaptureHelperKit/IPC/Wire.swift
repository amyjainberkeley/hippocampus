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
//   magic(1=0x4D) + version(1=0x02) + msg_type(2) + seq(8) + len(4) + payload(len)
//
// version 0x01 → 0x02 (2026-05-19): HelperHealth gained the
// frames_redacted_by_failsafe counter. Helper + core ship version-
// locked; the Rust decoder rejects any other version.

import Foundation

/// Wire-format magic byte.
public let frameMagic: UInt8 = 0x4D

/// Wire-format version byte. MUST match `core::ipc::wire::FRAME_VERSION`.
public let frameVersion: UInt8 = 0x02

/// Minimum frame header size in bytes.
public let minFrameHeaderBytes = 1 + 1 + 2 + 8 + 4

/// Wire `msg_type` discriminants. MUST match `core::ipc::wire::MessageType`.
public enum MessageType: UInt16, Sendable {
    case captureStart = 0x0001
    case captureStop = 0x0002
    case stateTransitionEvent = 0x0010
    case privacyTombstone = 0x0011
    case surfaceReleased = 0x0020
    case helperHealth = 0x0030
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

/// Encode a periodic helper-health counter frame.
public func encodeHelperHealth(
    seq: UInt64,
    uptimeMs: UInt64,
    framesDelivered: UInt64,
    framesSuppressed: UInt64,
    framesRedactedByFailsafe: UInt64,
    framesDroppedBackpressure: UInt64,
    framesDroppedLateAck: UInt64
) -> Data {
    var payload = Data()
    payload.appendUInt64LE(uptimeMs)
    payload.appendUInt64LE(framesDelivered)
    payload.appendUInt64LE(framesSuppressed)
    // §7 fail-safe subcount — wire 0x02. Order matches
    // core::ipc::wire decode: directly after frames_suppressed.
    payload.appendUInt64LE(framesRedactedByFailsafe)
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
