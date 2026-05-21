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
        XCTAssertEqual(RedactionReason.ocrTimeSecret.rawValue, 6)
        XCTAssertEqual(RedactionReason.failsafeUnknown.rawValue, 7)
    }

    func testRedactionReasonSixIsOcrTimeSecret() {
        // Wire 0x03 reserved 6 (§6 was core/-side). Wire 0x04
        // (ADR-0016 P3.6) re-homes §6 to the helper — OCR now happens
        // in the helper, so §6 emits a tombstone with reason=6.
        let r = RedactionReason(rawValue: 6)
        XCTAssertEqual(r, .ocrTimeSecret)
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
        XCTAssertEqual(RedactionReason.ocrTimeSecret.dbString, "ocr-time-secret")
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
    /// `wire::tests::frame_version_is_0x04` trip-wire. If the two
    /// sides ever disagree the IPC contract is silently broken.
    func testFrameVersionIs0x05() {
        XCTAssertEqual(frameVersion, 0x05)
    }

    /// Byte-exact cross-side fixture — pin the full HelperHealth frame
    /// at wire 0x04. The Rust-side
    /// `wire::tests::helper_health_cross_side_fixture` asserts the
    /// SAME 72-byte vector for the SAME input tuple, and
    /// `tools/wire_decode.py` parses the same layout. If any of those
    /// three drifts, the IPC contract is broken — this is the
    /// observable trip-wire. Wire 0x04 (P3.6) bumps only the version
    /// byte for the new OCREvent variant; HelperHealth's payload
    /// layout is unchanged.
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
        // Header(16): magic(4D) ver(04) msg_type(30 00 LE = 0x0030)
        //             seq(2A 00 ... LE = 42) len(38 00 00 00 = 56)
        // Payload(56): 7 u64 LE = 1, 2, 3, 4, 5, 6, 7 (little-endian)
        let expected: [UInt8] = [
            0x4D, 0x05, 0x30, 0x00,
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
        XCTAssertEqual(Array(frame), expected, "HelperHealth v0x05 byte-exact cross-side fixture")
    }

    /// Byte-exact cross-side fixture — pin the full OCREvent frame at
    /// wire 0x04. Mirrors the Rust-side
    /// `wire::tests::ocr_event_cross_side_fixture` and is parsed by
    /// `tools/wire_decode.py`. ADR-0016 §1.6 byte order.
    ///
    /// LOAD-BEARING (ADR-0016 §4). Drift on this layout breaks the
    /// IPC contract for the FIRST message variant carrying USER
    /// CONTENT across the seam.
    func testOCREventCrossSideFixture() {
        let hash = [UInt8](repeating: 0xAB, count: 32)
        let result = encodeOCREvent(
            seq: 42,
            event: OCREvent(
                seq: 42,
                tsUs: 0x0102_0304_0506_0708,
                appBundleId: "com.apple.Safari",
                windowTitle: "T",
                url: "U",
                ocrText: "Hi",
                keyframeHash: hash
            )
        )
        guard case .success(let frame) = result else {
            return XCTFail("OCREvent encode unexpectedly failed: \(result)")
        }
        // Fixed payload = 8 + 8 + 64 + 2 + 2 + 4 + 32 = 120
        // Variable    = 1 + 1 + 2 = 4
        // Total payload = 124. Frame total = 16 + 124 = 140.
        XCTAssertEqual(frame.count, 140)

        var expected = [UInt8]()
        // Header: magic 4D, version 04, msg_type 0040 LE.
        expected += [0x4D, 0x05, 0x40, 0x00]
        // seq u64 LE = 42.
        expected += [0x2A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        // len u32 LE = 124.
        expected += [0x7C, 0x00, 0x00, 0x00]
        // Payload — seq u64 LE = 42.
        expected += [0x2A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        // ts_us u64 LE = 0x0102_0304_0506_0708.
        expected += [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]
        // app_bundle_id [u8; 64] — "com.apple.Safari" null-padded.
        let bundleBytes = Array("com.apple.Safari".utf8)
        expected += bundleBytes + [UInt8](repeating: 0, count: 64 - bundleBytes.count)
        // window_title_len u16 LE = 1.
        expected += [0x01, 0x00]
        // url_len u16 LE = 1.
        expected += [0x01, 0x00]
        // ocr_text_len u32 LE = 2.
        expected += [0x02, 0x00, 0x00, 0x00]
        // keyframe_hash [u8; 32] = all 0xAB.
        expected += hash
        // window_title "T", url "U", ocr_text "Hi".
        expected += Array("T".utf8) + Array("U".utf8) + Array("Hi".utf8)

        XCTAssertEqual(Array(frame), expected, "OCREvent v0x05 byte-exact cross-side fixture")
    }

    /// OCR text over the 64 KB cap fails closed at encode time
    /// (ADR-0016 §4.9). Caller emits PrivacyTombstone(reason=
    /// failsafeUnknown) instead per ADR-0013 §7. This test pins that
    /// the encoder reports `ocrTextOverCap` rather than truncating
    /// silently.
    func testOCREventOverCapFailsClosed() {
        let overCap = String(repeating: "a", count: maxOCRTextBytes + 1)
        let result = encodeOCREvent(
            seq: 1,
            event: OCREvent(
                seq: 1,
                tsUs: 0,
                appBundleId: "com.example.app",
                windowTitle: "",
                url: "",
                ocrText: overCap
            )
        )
        switch result {
        case .success:
            XCTFail("encoder MUST fail closed on over-cap OCR text")
        case .failure(let err):
            switch err {
            case .ocrTextOverCap(let byteCount):
                XCTAssertEqual(byteCount, maxOCRTextBytes + 1)
            case .fieldOverflow:
                XCTFail("expected ocrTextOverCap, got fieldOverflow")
            }
        }
    }

    /// At exactly 64 KB, OCR text MUST be permitted (boundary check).
    func testOCREventAtCapBoundaryIsAccepted() {
        let exactlyCap = String(repeating: "a", count: maxOCRTextBytes)
        let result = encodeOCREvent(
            seq: 1,
            event: OCREvent(
                seq: 1,
                tsUs: 0,
                appBundleId: "com.example.app",
                windowTitle: "",
                url: "",
                ocrText: exactlyCap
            )
        )
        guard case .success = result else {
            return XCTFail("at-cap OCR text should encode successfully")
        }
    }

    /// MessageType discriminants match the Rust spec.
    func testMessageTypeRawValuesMatchSpec() {
        XCTAssertEqual(MessageType.captureStart.rawValue, 0x0001)
        XCTAssertEqual(MessageType.captureStop.rawValue, 0x0002)
        XCTAssertEqual(MessageType.stateTransitionEvent.rawValue, 0x0010)
        XCTAssertEqual(MessageType.privacyTombstone.rawValue, 0x0011)
        XCTAssertEqual(MessageType.surfaceReleased.rawValue, 0x0020)
        XCTAssertEqual(MessageType.helperHealth.rawValue, 0x0030)
        XCTAssertEqual(MessageType.ocrEvent.rawValue, 0x0040)
        XCTAssertEqual(MessageType.pageContentEvent.rawValue, 0x0050)
    }

    // MARK: - PageContentEvent tests

    func testPageContentEventCrossSideFixture() {
        let result = encodePageContentEvent(
            seq: 7,
            event: PageContentEvent(
                seq: 7,
                tsUs: 0x0102_0304_0506_0708,
                url: "U",
                title: "T",
                fullText: "Hi",
                sourceBrowser: "chrome",
                tabId: 99
            )
        )
        guard case .success(let frame) = result else {
            return XCTFail("encode failed: \(result)")
        }
        // Fixed = 8+8+2+2+4+1+4 = 29. Variable = 1+1+2+6 = 10. Total payload = 39.
        XCTAssertEqual(frame.count, minFrameHeaderBytes + 39)
        XCTAssertEqual(frame.count, 55)

        var expected = [UInt8]()
        expected += [0x4D, 0x05, 0x50, 0x00]
        expected += [0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00] // seq
        expected += [0x27, 0x00, 0x00, 0x00] // len = 39
        // Payload
        expected += [0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00] // seq
        expected += [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01] // ts_us
        expected += [0x01, 0x00] // url_len
        expected += [0x01, 0x00] // title_len
        expected += [0x02, 0x00, 0x00, 0x00] // full_text_len
        expected += [0x06] // source_browser_len
        expected += [0x63, 0x00, 0x00, 0x00] // tab_id = 99
        expected += Array("U".utf8)
        expected += Array("T".utf8)
        expected += Array("Hi".utf8)
        expected += Array("chrome".utf8)

        XCTAssertEqual(Array(frame), expected, "PageContentEvent v0x05 byte-exact cross-side fixture")
    }

    func testPageContentEventOverCapFailsClosed() {
        let overCap = String(repeating: "a", count: maxPageContentTextBytes + 1)
        let result = encodePageContentEvent(
            seq: 1,
            event: PageContentEvent(
                seq: 1,
                tsUs: 0,
                url: "",
                title: "",
                fullText: overCap,
                sourceBrowser: "chrome"
            )
        )
        switch result {
        case .success:
            XCTFail("encoder MUST fail closed on over-cap text")
        case .failure(let err):
            switch err {
            case .fullTextOverCap(let byteCount):
                XCTAssertEqual(byteCount, maxPageContentTextBytes + 1)
            case .fieldOverflow:
                XCTFail("expected fullTextOverCap, got fieldOverflow")
            }
        }
    }

    func testPageContentEventAtCapBoundaryIsAccepted() {
        let exactCap = String(repeating: "a", count: maxPageContentTextBytes)
        let result = encodePageContentEvent(
            seq: 1,
            event: PageContentEvent(
                seq: 1,
                tsUs: 0,
                url: "",
                title: "",
                fullText: exactCap,
                sourceBrowser: "chrome"
            )
        )
        guard case .success = result else {
            return XCTFail("at-cap text should encode successfully")
        }
    }
}
