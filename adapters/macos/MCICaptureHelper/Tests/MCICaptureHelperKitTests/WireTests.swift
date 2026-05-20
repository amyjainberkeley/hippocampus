// SPDX-License-Identifier: TBD-private
//
// WireTests — byte-level fixtures that lock the Swift encoder's output
// to the Rust `core::ipc::wire` decoder's expected layout.
//
// PROTECTED-SET regression gate. If any of these fail, the helper and
// the core have silently drifted and the IPC contract is broken.
//
// Fixture vectors below are hand-computed against the spec in
// `core/src/ipc/mod.rs`. They MUST also pass a round-trip through the
// Rust decoder — Phase-1 cycle 2+ wires an integration test that
// shells out to `cargo test -p mci-core ipc::wire` and feeds these
// fixtures in. For this cycle the fixtures lock the Swift side
// independently.

import XCTest
@testable import MCICaptureHelperKit

final class WireFixturesTests: XCTestCase {
    func testCaptureStopFixture() {
        // CaptureStop has zero payload. Frame = header only, 16 bytes.
        let frame = encodeCaptureStop(seq: 0)
        var expected = Data()
        expected.append(0x4D)                              // magic
        expected.append(frameVersion)                      // version (0x03)
        expected.append(contentsOf: [0x02, 0x00])          // msg_type 0x0002 LE
        expected.append(contentsOf: [UInt8](repeating: 0, count: 8))  // seq 0
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x00])         // len 0
        XCTAssertEqual(frame, expected, "CaptureStop fixture")
        XCTAssertEqual(frame.count, minFrameHeaderBytes)
    }

    func testPrivacyTombstoneFixture() {
        let t = PrivacyTombstone(
            tsUs: 0,
            appBundle: "com.apple.Safari",
            reason: .axSecureSubrole
        )
        let frame = encodePrivacyTombstone(seq: 7, tombstone: t)

        // Header: magic 4D + ver 03 + msg_type 0011 + seq 7 + len = ?
        // Payload: ts_us(8=0) + app_bundle_len(2=16) + "com.apple.Safari"(16) + reason(1=4)
        // = 8 + 2 + 16 + 1 = 27 bytes
        let expectedPayloadLen = 27
        XCTAssertEqual(frame.count, minFrameHeaderBytes + expectedPayloadLen)

        // Spot-check header bytes.
        XCTAssertEqual(frame[0], 0x4D)
        XCTAssertEqual(frame[1], frameVersion)
        XCTAssertEqual(frame[2], 0x11)
        XCTAssertEqual(frame[3], 0x00)

        // Seq.
        let seqBytes = frame[4..<12]
        XCTAssertEqual(seqBytes.first, 0x07)

        // Len.
        XCTAssertEqual(frame[12], UInt8(expectedPayloadLen))
        XCTAssertEqual(frame[13], 0)
        XCTAssertEqual(frame[14], 0)
        XCTAssertEqual(frame[15], 0)

        // Reason byte is the last byte of the frame.
        XCTAssertEqual(frame.last, RedactionReason.axSecureSubrole.rawValue)
    }

    func testRedactionReasonDiscriminantsMatchSpec() {
        // Lock the wire-byte discriminants. The Rust side has the same
        // values; drift here is a silent contract break.
        XCTAssertEqual(RedactionReason.denylistSource.rawValue, 1)
        XCTAssertEqual(RedactionReason.osBlackedRegion.rawValue, 2)
        XCTAssertEqual(RedactionReason.secureEventInput.rawValue, 3)
        XCTAssertEqual(RedactionReason.axSecureSubrole.rawValue, 4)
        XCTAssertEqual(RedactionReason.denylistPostCapture.rawValue, 5)
        XCTAssertEqual(RedactionReason.failsafeUnknown.rawValue, 7)
    }

    func testRedactionReasonSkipsSix() {
        // §6 is OCR-time regex; runs in `core/`, never crosses IPC.
        // The discriminant numbering must skip 6 to match the cascade's
        // §-numbering. This test is the trip-wire for that contract.
        XCTAssertNil(RedactionReason(rawValue: 6))
    }

    func testRedactionReasonDBStringsAreStable() {
        // These strings get written to `events.redaction_reason` in the
        // store. Changing one is a schema-visible drift requiring a
        // migration. Lock them.
        XCTAssertEqual(RedactionReason.denylistSource.dbString, "denylist-source")
        XCTAssertEqual(RedactionReason.osBlackedRegion.dbString, "os-blacked-region")
        XCTAssertEqual(RedactionReason.secureEventInput.dbString, "secure-event-input")
        XCTAssertEqual(RedactionReason.axSecureSubrole.dbString, "ax-secure-subrole")
        XCTAssertEqual(RedactionReason.denylistPostCapture.dbString, "denylist-postcapture")
        XCTAssertEqual(RedactionReason.failsafeUnknown.dbString, "failsafe-unknown")
    }

    func testHelperHealthFixture() {
        let frame = encodeHelperHealth(
            seq: 1,
            uptimeMs: 1000,
            framesDelivered: 100,
            framesSuppressed: 5,
            framesRedactedByFailsafe: 3,
            cascadeForcedCount: 11,
            framesDroppedBackpressure: 2,
            framesDroppedLateAck: 0
        )
        // wire 0x03: Header(16) + 7 × u64(8) = 72 bytes (was 64 at
        // 0x02 = 6 × u64; cascade_forced_count added the 7th —
        // STEP-2-FINDING-004 floor-forced cascade observability).
        XCTAssertEqual(frame.count, minFrameHeaderBytes + 56)
        XCTAssertEqual(frame[0], 0x4D)
        XCTAssertEqual(frame[1], frameVersion)
        XCTAssertEqual(frame[2], 0x30)  // msg_type 0x0030
        XCTAssertEqual(frame[3], 0x00)

        // The 4th u64 of the payload is frames_redacted_by_failsafe
        // (= 3 here). Offset = header(16) + 3×u64(24) = 40.
        let fsOffset = minFrameHeaderBytes + 24
        XCTAssertEqual(frame[fsOffset], 3)
        for i in 1..<8 { XCTAssertEqual(frame[fsOffset + i], 0) }

        // The 5th u64 of the payload is cascade_forced_count (= 11
        // here). Offset = header(16) + 4×u64(32) = 48.
        let cfcOffset = minFrameHeaderBytes + 32
        XCTAssertEqual(frame[cfcOffset], 11)
        for i in 1..<8 { XCTAssertEqual(frame[cfcOffset + i], 0) }
    }

    /// Cross-side version lock — mirrors the Rust
    /// `wire::tests::frame_version_is_0x03` trip-wire. If the two
    /// sides ever disagree the IPC contract is silently broken.
    func testFrameVersionIs0x03() {
        XCTAssertEqual(frameVersion, 0x03)
    }

    /// Byte-exact cross-side fixture — pin the full HelperHealth v0x03
    /// frame. The Rust-side `wire::tests::helper_health_cross_side_fixture`
    /// asserts the SAME 72-byte vector for the SAME input tuple, and
    /// `tools/wire_decode.py` parses the same layout. If any of those
    /// three drifts, the IPC contract is broken — this is the
    /// observable trip-wire.
    func testHelperHealthCrossSideFixture() {
        let frame = encodeHelperHealth(
            seq: 42,
            uptimeMs: 1,
            framesDelivered: 2,
            framesSuppressed: 3,
            framesRedactedByFailsafe: 4,
            cascadeForcedCount: 5,
            framesDroppedBackpressure: 6,
            framesDroppedLateAck: 7
        )
        // Header(16): magic(4D) ver(03) msg_type(30 00 LE = 0x0030)
        //             seq(2A 00 ... LE = 42) len(38 00 00 00 = 56)
        // Payload(56): 7 u64 LE = 1, 2, 3, 4, 5, 6, 7 (little-endian)
        let expected: [UInt8] = [
            0x4D, 0x03, 0x30, 0x00,
            0x2A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x38, 0x00, 0x00, 0x00,
            // u64 LE × 7
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        XCTAssertEqual(frame.count, 72)
        XCTAssertEqual(Array(frame), expected, "HelperHealth v0x03 byte-exact cross-side fixture")
    }

    /// MessageType discriminants match the Rust spec.
    func testMessageTypeRawValuesMatchSpec() {
        XCTAssertEqual(MessageType.captureStart.rawValue, 0x0001)
        XCTAssertEqual(MessageType.captureStop.rawValue, 0x0002)
        XCTAssertEqual(MessageType.stateTransitionEvent.rawValue, 0x0010)
        XCTAssertEqual(MessageType.privacyTombstone.rawValue, 0x0011)
        XCTAssertEqual(MessageType.surfaceReleased.rawValue, 0x0020)
        XCTAssertEqual(MessageType.helperHealth.rawValue, 0x0030)
    }
}
