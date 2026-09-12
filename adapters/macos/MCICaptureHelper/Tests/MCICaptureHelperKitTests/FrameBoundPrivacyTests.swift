import Foundation
import XCTest

@testable import MCICaptureHelperKit

final class FrameBoundPrivacyTests: XCTestCase {
    func testQueuedFrameUsesCallbackPrivacySnapshotInsteadOfLaterProbeState() async throws {
        let secure = MutableSecureProbe(true)
        let ax = MutableAXProbe(false)
        let encoder = PrivacyRecordingEncoder()
        let pipeline = SCStreamPipeline(
            cascade: SuppressionCascade(
                secureEventInput: secure,
                axSecureSubrole: ax,
                denylist: PrivacyEmptyDenylist(),
                blackedRegion: PrivacyNoBlackRegion(),
                knownSafeAppBundles: ["com.example.app"]
            ),
            encoder: encoder,
            sink: PrivacySink()
        )
        let context = WorkflowContext(appBundleId: "com.example.app")
        let snapshot = pipeline.snapshotPixelPrivacy(
            context: context,
            hasBlackedRegion: false
        )
        XCTAssertFalse(snapshot.permitsRawPixels)
        XCTAssertTrue(snapshot.secureEventInputEnabled)
        XCTAssertEqual(snapshot.axSecureSubrole, false)

        secure.set(false)
        let outcome = try await pipeline.process(
            frame: CandidateFrame(
                userIdle: false,
                frameStatusComplete: true,
                dirtyRects: [DirtyRect(x: 0, y: 0, width: 1, height: 1)],
                dhash: DHash(bits: 1),
                priorDhash: nil
            ),
            context: context,
            nowUs: 1,
            lease: SurfaceLease(releaser: PrivacySurfaceReleaser()),
            privacySnapshot: snapshot
        )

        XCTAssertEqual(
            outcome,
            .suppressed(reason: .secureEventInput, forcedByFloor: false)
        )
        XCTAssertEqual(encoder.count(), 0)
    }
}

private final class MutableSecureProbe: SecureEventInputProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func set(_ value: Bool) { lock.withLock { self.value = value } }
    func isSecureEventInputEnabled() -> Bool { lock.withLock { value } }
}

private final class MutableAXProbe: AXSecureSubroleProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    init(_ value: Bool?) { self.value = value }
    func focusedHasSecureSubrole() -> Bool? { lock.withLock { value } }
}

private struct PrivacyEmptyDenylist: DenylistProbe {
    func appIsDenied(bundleId _: String) -> Bool { false }
    func urlIsDenied(_: String) -> Bool { false }
    func windowTitleIsDenied(_: String) -> Bool { false }
}

private struct PrivacyNoBlackRegion: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}

private final class PrivacyRecordingEncoder: FrameEncoder, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func encodeAllowedFrame(input _: EncoderInput?, seq _: UInt64, context _: WorkflowContext) {
        lock.withLock { calls += 1 }
    }
    func count() -> Int { lock.withLock { calls } }
}

private final class PrivacySurfaceReleaser: SurfaceReleasing, @unchecked Sendable {
    func releaseSurface() {}
}

private actor PrivacySink: FrameSink {
    func write(_: Data) {}
}
