// SPDX-License-Identifier: TBD-private
//
// SCStreamCaptureSessionScreenShareTests — headless integration
// coverage for the cycle 8.44 audit risk #1 pause/resume wiring.
// PROTECTED-SET per AGENT_PROTOCOL §5. Exercises the state-flag
// transitions on the session that the detector observer callback
// drives; OS-touching `stopCapture()`/`startCapture()` short-circuit
// because `stream` is nil in headless (no `start()` ran). Pins:
//   1. pause sets the flag + records actor;
//   2. pause is idempotent;
//   3. resume-while-not-paused is a no-op;
//   4. observer callback drives pause;
//   5. resume-throw leaves session paused (FAIL-SAFE);
//   6. stop() clears the flag for a fresh restart.

import XCTest

@testable import MCICaptureHelperKit

private enum ShareFixtures {
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

final class SCStreamCaptureSessionScreenShareTests: XCTestCase {
    func testPauseSetsFlagAndRecordsActor() async {
        let session = ShareFixtures.makeSession()
        XCTAssertFalse(session.isPausedForScreenShareForTest())
        await session.pauseForScreenShare(actor: "us.zoom.xos")
        XCTAssertTrue(session.isPausedForScreenShareForTest())
        XCTAssertEqual(session.lastPausedActorForTest(), "us.zoom.xos")
    }

    func testPauseIsIdempotent() async {
        let session = ShareFixtures.makeSession()
        await session.pauseForScreenShare(actor: "us.zoom.xos")
        await session.pauseForScreenShare(actor: "com.google.Chrome")
        XCTAssertTrue(session.isPausedForScreenShareForTest())
        XCTAssertEqual(session.lastPausedActorForTest(), "us.zoom.xos")
    }

    func testResumeWhileNotPausedIsNoop() async throws {
        let session = ShareFixtures.makeSession()
        try await session.resumeFromScreenShare()
        XCTAssertFalse(session.isPausedForScreenShareForTest())
    }

    func testObserverCallbackDrivesPause() async {
        let session = ShareFixtures.makeSession()
        await session.screenShareDetectorDidTransition(
            to: ScreenShareSample(isSharingActive: true, sharingActor: "us.zoom.xos")
        )
        XCTAssertTrue(session.isPausedForScreenShareForTest())
        XCTAssertEqual(session.lastPausedActorForTest(), "us.zoom.xos")
    }

    // FAIL-SAFE: transient resume-throw must NOT accidentally unpause.
    // The observer callback swallows the throw fire-and-forget; the
    // session's paused flag stays set so the next detector cycle can
    // retry.
    func testObserverInactiveResumeAttemptFailsSafeInHeadless() async {
        let session = ShareFixtures.makeSession()
        await session.pauseForScreenShare(actor: "us.zoom.xos")
        await session.screenShareDetectorDidTransition(
            to: ScreenShareSample(isSharingActive: false, sharingActor: nil)
        )
        XCTAssertTrue(
            session.isPausedForScreenShareForTest(),
            "resume-throw must leave the session paused (fail-safe)"
        )
    }

    func testStopClearsPausedFlag() async throws {
        let session = ShareFixtures.makeSession()
        await session.pauseForScreenShare(actor: "us.zoom.xos")
        try await session.stop()
        XCTAssertFalse(session.isPausedForScreenShareForTest())
        XCTAssertNil(session.lastPausedActorForTest())
    }
}
