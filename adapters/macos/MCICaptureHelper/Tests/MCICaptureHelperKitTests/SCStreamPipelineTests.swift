// SPDX-License-Identifier: TBD-private
//
// SCStreamPipelineTests — OS-FREE proof of the ADR-0013 §5 ordering
// invariant: the suppression cascade runs BEFORE any encode call site,
// and the surface lease is released exactly once on every path.
//
// These tests deliberately do NOT touch SCStream / SCShareableContent
// / IOSurface / VideoToolbox — those are `// UNVERIFIED — needs live
// macOS`. They exercise `SCStreamPipeline.process(...)`, the OS-free
// decision+dispatch core the live callback delegates to.

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
    private(set) var calls: [UInt64] = []
    func encodeAllowedFrame(seq: UInt64, context _: WorkflowContext) async throws {
        calls.append(seq)
    }
    func callCount() -> Int { calls.count }
}

private final class SpyReleaser: SurfaceReleasing, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func releaseSurface() {
        lock.lock(); n += 1; lock.unlock()
    }
    var releaseCount: Int {
        lock.lock(); defer { lock.unlock() }; return n
    }
}

private func forwardingFrame() -> CandidateFrame {
    // userIdle=false, status complete, dirty rects present, no prior
    // dHash → SmartCaptureFilter returns `.forward`.
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
    let cascade = SuppressionCascade(
        secureEventInput: NoSEI(),
        axSecureSubrole: ax,
        denylist: DenyApps(apps: denied),
        blackedRegion: NoBlack(),
        knownSafeAppBundles: knownSafe
    )
    return SCStreamPipeline(
        cascade: cascade,
        encoder: encoder,
        sink: sink
    )
}

final class SCStreamPipelineTests: XCTestCase {
    func test_showsCursor_locked_false() {
        let cfg = SCStreamConfigFactory.makeConfiguration()
        XCTAssertFalse(cfg.showsCursor, "showsCursor MUST stay false (§4 SLO)")
        XCTAssertEqual(cfg.queueDepth, StreamPolicy.default.queueDepth)
    }

    func test_excludedBundleIDs_selects_only_denylisted_running_apps() {
        let dl = Denylist(entries: [
            DenylistEntry(kind: .appBundle, pattern: "com.evil.app"),
        ])
        let excluded = SCContentFilterFactory.excludedBundleIDs(
            runningBundleIDs: ["com.apple.Safari", "com.evil.app", "com.good.app"],
            denylist: dl
        )
        XCTAssertEqual(excluded, ["com.evil.app"])
    }

    func test_suppressed_frame_never_reaches_encoder_and_releases_surface() async throws {
        let encoder = SpyEncoder()
        let sink = RecordingSink()
        // App is denylisted → cascade suppresses at §1.
        let pipe = makePipeline(
            denied: ["com.secret.app"],
            ax: AXNonSecure(),
            knownSafe: [],
            encoder: encoder,
            sink: sink
        )
        let releaser = SpyReleaser()
        let lease = SurfaceLease(releaser: releaser)
        let ctx = WorkflowContext(appBundleId: "com.secret.app")

        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: ctx,
            nowUs: 42,
            lease: lease
        )

        XCTAssertEqual(outcome, .suppressed(reason: .denylistSource))
        let enc = await encoder.callCount()
        XCTAssertEqual(enc, 0, "encoder MUST NOT run on a suppressed frame")
        let writes = await sink.count()
        XCTAssertEqual(writes, 1, "exactly one PrivacyTombstone written")
        XCTAssertEqual(releaser.releaseCount, 1, "surface released exactly once")
        XCTAssertTrue(lease.isReleased)
    }

    func test_failsafe_unknown_also_suppresses_before_encode() async throws {
        let encoder = SpyEncoder()
        let sink = RecordingSink()
        // AX returns nil (can't answer) + app not known-safe ⇒ §7
        // fail-safe ⇒ suppress. Encoder still must not run.
        let pipe = makePipeline(
            denied: [],
            ax: AXSilent(),
            knownSafe: [],
            encoder: encoder,
            sink: sink
        )
        let lease = SurfaceLease(releaser: SpyReleaser())
        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.unknown.app"),
            nowUs: 1,
            lease: lease
        )
        XCTAssertEqual(outcome, .suppressed(reason: .failsafeUnknown))
        let enc = await encoder.callCount()
        XCTAssertEqual(enc, 0)
        XCTAssertTrue(lease.isReleased)
    }

    func test_allowed_frame_reaches_encoder_after_cascade() async throws {
        let encoder = SpyEncoder()
        let sink = RecordingSink()
        // AX positively non-secure + app on known-safe list ⇒ the
        // ONLY `.allow` path.
        let pipe = makePipeline(
            denied: [],
            ax: AXNonSecure(),
            knownSafe: ["com.good.app"],
            encoder: encoder,
            sink: sink
        )
        let releaser = SpyReleaser()
        let lease = SurfaceLease(releaser: releaser)
        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.good.app"),
            nowUs: 7,
            lease: lease
        )
        if case .encoded = outcome {} else {
            XCTFail("expected .encoded, got \(outcome)")
        }
        let enc = await encoder.callCount()
        XCTAssertEqual(enc, 1, "encoder runs exactly once on an allowed frame")
        let writes = await sink.count()
        XCTAssertEqual(writes, 0, "no tombstone on an allowed frame")
        XCTAssertEqual(releaser.releaseCount, 1, "surface released exactly once")
    }

    func test_filtered_out_frame_skips_cascade_and_encoder_but_releases() async throws {
        let encoder = SpyEncoder()
        let sink = RecordingSink()
        let pipe = makePipeline(
            denied: ["com.secret.app"], // would suppress IF reached
            ax: AXSilent(),
            knownSafe: [],
            encoder: encoder,
            sink: sink
        )
        let releaser = SpyReleaser()
        let lease = SurfaceLease(releaser: releaser)
        // Idle frame → SmartCaptureFilter drops at stage 1; cascade
        // never consulted, no tombstone, but surface still released.
        let outcome = try await pipe.process(
            frame: idleFrame(),
            context: WorkflowContext(appBundleId: "com.secret.app"),
            nowUs: 0,
            lease: lease
        )
        XCTAssertEqual(outcome, .filteredOut)
        let enc = await encoder.callCount()
        XCTAssertEqual(enc, 0)
        let writes = await sink.count()
        XCTAssertEqual(writes, 0, "filtered frame emits nothing")
        XCTAssertEqual(releaser.releaseCount, 1, "dropped frame still releases the surface (§4)")
    }

    func test_surface_lease_release_is_exactly_once() {
        let releaser = SpyReleaser()
        let lease = SurfaceLease(releaser: releaser)
        lease.release()
        XCTAssertEqual(releaser.releaseCount, 1)
        XCTAssertTrue(lease.isReleased)
    }
}
