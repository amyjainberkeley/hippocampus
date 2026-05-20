// SPDX-License-Identifier: TBD-private
//
// RetainedSurfaceTests — OS-FREE proof of the enabler PR-2 retain →
// owned-lease release discipline (the §4 IOSurface-pool-stall failure
// mode). The live `SCStream` is `// UNVERIFIED` and is NOT exercised.
// What IS proven:
//   • `PixelSurfaceReleaser` forwards exactly one relinquish.
//   • Through the REAL `SCStreamPipeline`, the retained surface is
//     relinquished exactly once on EVERY path — suppress, allow,
//     filtered-out, throwing encoder, throwing sink.
//   • `CVPixelBufferRetainedSurface`'s reference lifecycle is
//     set-once / drop-once / idempotent (real CVPixelBuffer, created
//     headlessly via CVPixelBufferCreate — no screen needed).

import CoreVideo
import XCTest

@testable import MCICaptureHelperKit

private struct NoSEI: SecureEventInputProbe {
    func isSecureEventInputEnabled() -> Bool { false }
}
private struct AXNonSecure: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { false }
}
private struct AXSilent: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { nil }
}
private struct DenyApps: DenylistProbe {
    let apps: Set<String>
    func appIsDenied(bundleId: String) -> Bool { apps.contains(bundleId) }
    func urlIsDenied(_: String) -> Bool { false }
    func windowTitleIsDenied(_: String) -> Bool { false }
}
private struct NoBlack: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}

private actor RecordingSink: FrameSink {
    private(set) var writes: [Data] = []
    func write(_ data: Data) async throws { writes.append(data) }
    func count() -> Int { writes.count }
}

private actor SpyEncoder: FrameEncoder {
    private(set) var calls = 0
    func encodeAllowedFrame(seq _: UInt64, context _: WorkflowContext) async throws { calls += 1 }
    func callCount() -> Int { calls }
}

private struct EncodeBoom: Error {}
private struct SinkBoom: Error {}

private struct ThrowingEncoder: FrameEncoder {
    func encodeAllowedFrame(seq _: UInt64, context _: WorkflowContext) async throws {
        throw EncodeBoom()
    }
}

private struct ThrowingSink: FrameSink {
    func write(_: Data) async throws { throw SinkBoom() }
}

/// Counting `PixelSurfaceRetaining` double — stands in for the live
/// `CVPixelBufferRetainedSurface` so the discipline is OS-free testable.
private final class SpyRetainable: PixelSurfaceRetaining, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func relinquish() { lock.lock(); n += 1; lock.unlock() }
    var relinquishCount: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private func forwardingFrame() -> CandidateFrame {
    CandidateFrame(
        userIdle: false,
        frameStatusComplete: true,
        dirtyRects: [DirtyRect(x: 0, y: 0, width: 4, height: 4)],
        dhash: DHash(bits: 0),
        priorDhash: nil
    )
}

private func idleFrame() -> CandidateFrame {
    CandidateFrame(
        userIdle: true,
        frameStatusComplete: true,
        dirtyRects: [DirtyRect(x: 0, y: 0, width: 4, height: 4)],
        dhash: DHash(bits: 0),
        priorDhash: nil
    )
}

private func makePipeline(
    denied: Set<String>,
    ax: any AXSecureSubroleProbe,
    knownSafe: Set<String>,
    encoder: any FrameEncoder,
    sink: any FrameSink
) -> SCStreamPipeline {
    SCStreamPipeline(
        cascade: SuppressionCascade(
            secureEventInput: NoSEI(),
            axSecureSubrole: ax,
            denylist: DenyApps(apps: denied),
            blackedRegion: NoBlack(),
            knownSafeAppBundles: knownSafe
        ),
        encoder: encoder,
        sink: sink
    )
}

final class RetainedSurfaceTests: XCTestCase {
    // ── The releaser forwards exactly one relinquish. ────────────────
    func test_PixelSurfaceReleaser_forwards_relinquish() {
        let spy = SpyRetainable()
        PixelSurfaceReleaser(surface: spy).releaseSurface()
        XCTAssertEqual(spy.relinquishCount, 1)
    }

    func test_SurfaceLease_over_PixelSurfaceReleaser_releases_once() {
        // One release ⇒ exactly one relinquish. (The double-release
        // guard is `assertionFailure` — deliberately fatal in debug —
        // so the exactly-once-under-redundant-paths property is proven
        // by the pipeline-path tests below, not by calling release()
        // twice here.)
        let spy = SpyRetainable()
        let lease = SurfaceLease(releaser: PixelSurfaceReleaser(surface: spy))
        lease.release()
        XCTAssertEqual(spy.relinquishCount, 1)
        XCTAssertTrue(lease.isReleased)
    }

    // ── Exactly-once on EVERY pipeline path (the §4 invariant). ───────
    private func leaseSpy() -> (SurfaceLease, SpyRetainable) {
        let spy = SpyRetainable()
        return (SurfaceLease(releaser: PixelSurfaceReleaser(surface: spy)), spy)
    }

    func test_retain_relinquished_once_on_suppress() async throws {
        let (lease, spy) = leaseSpy()
        let pipe = makePipeline(
            denied: ["com.secret.app"], ax: AXNonSecure(), knownSafe: [],
            encoder: SpyEncoder(), sink: RecordingSink()
        )
        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.secret.app"),
            nowUs: 1, lease: lease
        )
        XCTAssertEqual(outcome, .suppressed(reason: .denylistSource, forcedByFloor: false))
        XCTAssertEqual(spy.relinquishCount, 1, "suppressed frame relinquishes the retain once")
    }

    func test_retain_relinquished_once_on_allow() async throws {
        let (lease, spy) = leaseSpy()
        let enc = SpyEncoder()
        let pipe = makePipeline(
            denied: [], ax: AXNonSecure(), knownSafe: ["com.good.app"],
            encoder: enc, sink: RecordingSink()
        )
        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.good.app"),
            nowUs: 2, lease: lease
        )
        if case .encoded = outcome {} else { XCTFail("expected .encoded, got \(outcome)") }
        let calls = await enc.callCount()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(spy.relinquishCount, 1, "allowed frame relinquishes the retain once")
    }

    func test_retain_relinquished_once_when_filtered_out() async throws {
        let (lease, spy) = leaseSpy()
        let pipe = makePipeline(
            denied: ["com.secret.app"], ax: AXSilent(), knownSafe: [],
            encoder: SpyEncoder(), sink: RecordingSink()
        )
        let outcome = try await pipe.process(
            frame: idleFrame(),
            context: WorkflowContext(appBundleId: "com.secret.app"),
            nowUs: 3, lease: lease
        )
        XCTAssertEqual(outcome, .filteredOut)
        XCTAssertEqual(spy.relinquishCount, 1, "a dropped frame still relinquishes the retain (§4)")
    }

    func test_retain_relinquished_once_when_encoder_throws() async throws {
        let (lease, spy) = leaseSpy()
        let pipe = makePipeline(
            denied: [], ax: AXNonSecure(), knownSafe: ["com.good.app"],
            encoder: ThrowingEncoder(), sink: RecordingSink()
        )
        do {
            _ = try await pipe.process(
                frame: forwardingFrame(),
                context: WorkflowContext(appBundleId: "com.good.app"),
                nowUs: 4, lease: lease
            )
            XCTFail("encoder threw — must propagate")
        } catch is EncodeBoom {}
        XCTAssertEqual(spy.relinquishCount, 1, "throwing encoder must not leak the retain (no pool stall)")
    }

    func test_retain_relinquished_once_when_sink_throws_on_suppress() async throws {
        let (lease, spy) = leaseSpy()
        let pipe = makePipeline(
            denied: ["com.secret.app"], ax: AXNonSecure(), knownSafe: [],
            encoder: SpyEncoder(), sink: ThrowingSink()
        )
        do {
            _ = try await pipe.process(
                frame: forwardingFrame(),
                context: WorkflowContext(appBundleId: "com.secret.app"),
                nowUs: 5, lease: lease
            )
            XCTFail("sink threw — must propagate")
        } catch is SinkBoom {}
        XCTAssertEqual(spy.relinquishCount, 1, "throwing tombstone sink must not leak the retain")
    }

    // ── The production retain holder's reference lifecycle. A real
    //    CVPixelBuffer, created HEADLESSLY (no screen) via
    //    CVPixelBufferCreate — proves set-once / drop-once / idempotent.
    func test_CVPixelBufferRetainedSurface_reference_lifecycle_is_idempotent() throws {
        var pb: CVPixelBuffer?
        let rc = CVPixelBufferCreate(
            kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pb
        )
        XCTAssertEqual(rc, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)

        let surface = CVPixelBufferRetainedSurface(retaining: buffer)
        XCTAssertFalse(surface.isRelinquished, "retained until relinquish()")

        surface.relinquish()
        XCTAssertTrue(surface.isRelinquished, "reference dropped after relinquish()")

        surface.relinquish() // idempotent — must not crash / double-free
        XCTAssertTrue(surface.isRelinquished, "second relinquish is a safe no-op")
    }

    func test_BorrowedNoRetainReleaser_is_a_safe_noop() {
        // PR-1 baseline path: nothing retained ⇒ release is a no-op and
        // the lease still records exactly-once.
        let lease = SurfaceLease(releaser: BorrowedNoRetainReleaser())
        lease.release()
        XCTAssertTrue(lease.isReleased)
    }
}
