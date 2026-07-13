// SPDX-License-Identifier: TBD-private
//
// SCStreamCaptureSessionTCCTests — headless integration coverage for
// the cycle 8.45 audit risk #2 pause/resume wiring. PROTECTED-SET per
// AGENT_PROTOCOL §5. Exercises the state-flag transitions on the
// session that the TCCStatusMonitor observer callback drives; OS-
// touching `stopCapture()`/`startCapture()` short-circuit because
// `stream` is nil in headless. Pins:
//   1. pause sets the flag + records the surface;
//   2. pause is idempotent per-surface;
//   3. multi-surface revoke: SR + AX revoked together, resume of one
//      leaves the pause held on the other;
//   4. observer callback drives pause;
//   5. stop() clears both flags for a fresh restart.

import XCTest

@testable import MCICaptureHelperKit

private enum TCCFixtures {
    private struct NoSEI: SecureEventInputProbe {
        func isSecureEventInputEnabled() -> Bool { false }
    }
    private struct AXNonSecure: AXSecureSubroleProbe {
        func focusedHasSecureSubrole() -> Bool? { false }
    }
    private struct NoApps: DenylistProbe {
        func appIsDenied(bundleId _: String) -> Bool { false }
        func urlIsDenied(_: String) -> Bool { false }
        func windowTitleIsDenied(_: String) -> Bool { false }
    }
    private struct NoBlack: BlackedRegionProbe {
        func hasBlackedRegion() -> Bool { false }
    }
    private struct NoopEncoder: FrameEncoder {
        func encodeAllowedFrame(
            input _: EncoderInput?,
            seq _: UInt64,
            context _: WorkflowContext
        ) async throws {}
    }
    private struct NoopSink: FrameSink {
        func write(_: Data) async throws {}
    }

    static func makeSession() -> SCStreamCaptureSession {
        let cascade = SuppressionCascade(
            secureEventInput: NoSEI(),
            axSecureSubrole: AXNonSecure(),
            denylist: NoApps(),
            blackedRegion: NoBlack(),
            knownSafeAppBundles: []
        )
        let pipeline = SCStreamPipeline(
            cascade: cascade,
            encoder: NoopEncoder(),
            sink: NoopSink()
        )
        return SCStreamCaptureSession(
            pipeline: pipeline,
            denylist: Denylist(entries: [])
        )
    }
}

final class SCStreamCaptureSessionTCCTests: XCTestCase {
    // 1
    func testPauseForTCCSetsFlagAndRecordsSurface() async {
        let session = TCCFixtures.makeSession()
        XCTAssertFalse(session.isPausedForTCCForTest())
        await session.pauseForTCC(surface: .screenRecording)
        XCTAssertTrue(session.isPausedForTCCForTest())
        XCTAssertEqual(
            session.revokedSurfacesForTest(),
            Set([TCCSurface.screenRecording])
        )
    }

    // 2
    func testPauseIsIdempotentPerSurface() async {
        let session = TCCFixtures.makeSession()
        await session.pauseForTCC(surface: .screenRecording)
        await session.pauseForTCC(surface: .screenRecording)
        await session.pauseForTCC(surface: .screenRecording)
        XCTAssertEqual(
            session.revokedSurfacesForTest(),
            Set([TCCSurface.screenRecording])
        )
    }

    // 3
    func testMultiSurfaceRevokeIndependentBookkeeping() async throws {
        let session = TCCFixtures.makeSession()
        await session.pauseForTCC(surface: .screenRecording)
        await session.pauseForTCC(surface: .accessibility)
        XCTAssertEqual(
            session.revokedSurfacesForTest(),
            Set([TCCSurface.screenRecording, TCCSurface.accessibility])
        )

        // Restoring screenRecording alone must NOT clear the pause —
        // accessibility is still revoked. The bringUpSCStreamOnly()
        // path throws in headless (no stream), but the resume path
        // returns early BEFORE the bring-up because stillRevoked is
        // true — so no throw is expected here.
        try await session.resumeFromTCC(surface: .screenRecording)
        XCTAssertEqual(
            session.revokedSurfacesForTest(),
            Set([TCCSurface.accessibility])
        )
        XCTAssertTrue(
            session.isPausedForTCCForTest(),
            "pause must hold while any surface remains revoked"
        )
    }

    // 4
    func testObserverCallbackDrivesPauseOnRevoke() async {
        let session = TCCFixtures.makeSession()
        await session.tccStatusDidTransition(
            TCCStatusMonitor.Transition(
                surface: .screenRecording,
                oldStatus: .granted,
                newStatus: .denied
            )
        )
        XCTAssertTrue(session.isPausedForTCCForTest())
        XCTAssertEqual(
            session.revokedSurfacesForTest(),
            Set([TCCSurface.screenRecording])
        )
    }

    // 4b: unknown transitions never fire
    func testObserverCallbackIgnoresUnknownTransition() async {
        let session = TCCFixtures.makeSession()
        await session.tccStatusDidTransition(
            TCCStatusMonitor.Transition(
                surface: .screenRecording,
                oldStatus: .granted,
                newStatus: .unknown
            )
        )
        XCTAssertFalse(session.isPausedForTCCForTest())
    }

    // 5
    func testStopClearsBothPauseFlags() async throws {
        let session = TCCFixtures.makeSession()
        await session.pauseForTCC(surface: .screenRecording)
        await session.pauseForScreenShare(actor: "us.zoom.xos")
        try await session.stop()
        XCTAssertFalse(session.isPausedForTCCForTest())
        XCTAssertFalse(session.isPausedForScreenShareForTest())
        XCTAssertTrue(session.revokedSurfacesForTest().isEmpty)
    }

    // Independence from screen-share pause: a TCC revoke does NOT
    // touch the screen-share flag and vice versa. The two reasons
    // compose (bringUpSCStreamOnly is only reached when BOTH clear).
    func testTCCAndScreenSharePauseFlagsAreIndependent() async {
        let session = TCCFixtures.makeSession()
        await session.pauseForTCC(surface: .screenRecording)
        XCTAssertTrue(session.isPausedForTCCForTest())
        XCTAssertFalse(session.isPausedForScreenShareForTest())

        await session.pauseForScreenShare(actor: "us.zoom.xos")
        XCTAssertTrue(session.isPausedForTCCForTest())
        XCTAssertTrue(session.isPausedForScreenShareForTest())
    }
}
