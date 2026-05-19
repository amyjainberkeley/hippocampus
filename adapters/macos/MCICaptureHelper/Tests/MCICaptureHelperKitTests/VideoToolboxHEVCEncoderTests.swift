// SPDX-License-Identifier: TBD-private
//
// VideoToolboxHEVCEncoderTests — OS-FREE proof of enabler PR-3:
//   • the HEVC encode CONFIGURATION POLICY (HEVC, keyframe-only, no
//     frame reordering, power-efficient) — pure, no VTCompressionSession.
//   • through the REAL `SCStreamPipeline`, the encoder is invoked
//     EXACTLY on `.allow` and NEVER on `.suppress` / filtered-out —
//     the Amendment 1 §3(a)/(c) structural guarantee.
//
// The live `VTCompressionSession` is `// UNVERIFIED` and is never
// constructed here (the seam carries no pixel buffer, so its UNVERIFIED
// branch is unreachable).

import CoreMedia
import VideoToolbox
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
    private(set) var writes = 0
    func write(_: Data) async throws { writes += 1 }
    func count() -> Int { writes }
}

private func forwardingFrame() -> CandidateFrame {
    CandidateFrame(
        userIdle: false, frameStatusComplete: true,
        dirtyRects: [DirtyRect(x: 0, y: 0, width: 4, height: 4)],
        dhash: DHash(bits: 0), priorDhash: nil
    )
}
private func idleFrame() -> CandidateFrame {
    CandidateFrame(
        userIdle: true, frameStatusComplete: true,
        dirtyRects: [DirtyRect(x: 0, y: 0, width: 4, height: 4)],
        dhash: DHash(bits: 0), priorDhash: nil
    )
}
private func pipeline(
    denied: Set<String>, ax: any AXSecureSubroleProbe,
    knownSafe: Set<String>, encoder: any FrameEncoder
) -> SCStreamPipeline {
    SCStreamPipeline(
        cascade: SuppressionCascade(
            secureEventInput: NoSEI(), axSecureSubrole: ax,
            denylist: DenyApps(apps: denied), blackedRegion: NoBlack(),
            knownSafeAppBundles: knownSafe
        ),
        encoder: encoder, sink: RecordingSink()
    )
}

final class VideoToolboxHEVCEncoderTests: XCTestCase {
    // ── The encode policy. ───────────────────────────────────────────
    func test_default_policy_is_hevc_keyframe_only_no_reordering() {
        let c = HEVCEncodeConfig.default
        XCTAssertEqual(c.codec, kCMVideoCodecType_HEVC, "HEVC (H.265), DESIGN.md §5.3")
        XCTAssertTrue(c.keyframeOnly, "every stored frame an IDR — no cross-frame reference")
        XCTAssertFalse(c.allowFrameReordering, "no B-frames / no reordering")
        XCTAssertTrue(c.maximizePowerEfficiency, "§4 footprint over an all-day session")
        XCTAssertFalse(c.realtime, "event-driven capture is not realtime")
    }

    func test_sessionProperties_forbid_frame_reordering() {
        let props = HEVCEncodeConfig.default.sessionProperties()
        XCTAssertEqual(
            props[kVTCompressionPropertyKey_AllowFrameReordering] as? Bool, false,
            "AllowFrameReordering MUST be false (keyframe-only; no P/B leak across frames)"
        )
        XCTAssertEqual(
            props[kVTCompressionPropertyKey_MaximizePowerEfficiency] as? Bool, true
        )
        XCTAssertEqual(
            props[kVTCompressionPropertyKey_RealTime] as? Bool, false
        )
    }

    // ── The structural guarantee: encoder reached ONLY on `.allow`. ──
    func test_hevc_encoder_never_invoked_on_suppressed_frame() async throws {
        let enc = VideoToolboxHEVCEncoder()
        let pipe = pipeline(
            denied: ["com.secret.app"], ax: AXNonSecure(),
            knownSafe: [], encoder: enc
        )
        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.secret.app"),
            nowUs: 1, lease: SurfaceLease(releaser: BorrowedNoRetainReleaser())
        )
        XCTAssertEqual(outcome, .suppressed(reason: .denylistSource))
        XCTAssertEqual(enc.allowedFrameCount(), 0, "HEVC encoder MUST NOT run on a suppressed frame")
    }

    func test_hevc_encoder_never_invoked_when_filtered_out() async throws {
        let enc = VideoToolboxHEVCEncoder()
        let pipe = pipeline(
            denied: [], ax: AXSilent(), knownSafe: [], encoder: enc
        )
        let outcome = try await pipe.process(
            frame: idleFrame(),
            context: WorkflowContext(appBundleId: "com.whatever.app"),
            nowUs: 2, lease: SurfaceLease(releaser: BorrowedNoRetainReleaser())
        )
        XCTAssertEqual(outcome, .filteredOut)
        XCTAssertEqual(enc.allowedFrameCount(), 0)
    }

    func test_hevc_encoder_invoked_exactly_once_on_allow() async throws {
        let enc = VideoToolboxHEVCEncoder()
        let pipe = pipeline(
            denied: [], ax: AXNonSecure(), knownSafe: ["com.good.app"], encoder: enc
        )
        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.good.app"),
            nowUs: 3, lease: SurfaceLease(releaser: BorrowedNoRetainReleaser())
        )
        if case .encoded = outcome {} else { XCTFail("expected .encoded, got \(outcome)") }
        XCTAssertEqual(enc.allowedFrameCount(), 1, "exactly one allowed frame reached the encode site")
    }

    func test_only_allowed_frames_accumulate() async throws {
        let enc = VideoToolboxHEVCEncoder()
        // Two suppressed (denylisted) then one allowed ⇒ count == 1.
        let suppressPipe = pipeline(
            denied: ["com.secret.app"], ax: AXNonSecure(), knownSafe: [], encoder: enc
        )
        let allowPipe = pipeline(
            denied: [], ax: AXNonSecure(), knownSafe: ["com.good.app"], encoder: enc
        )
        for _ in 0 ..< 2 {
            _ = try await suppressPipe.process(
                frame: forwardingFrame(),
                context: WorkflowContext(appBundleId: "com.secret.app"),
                nowUs: 4, lease: SurfaceLease(releaser: BorrowedNoRetainReleaser())
            )
        }
        _ = try await allowPipe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.good.app"),
            nowUs: 5, lease: SurfaceLease(releaser: BorrowedNoRetainReleaser())
        )
        XCTAssertEqual(enc.allowedFrameCount(), 1, "only the `.allow` decision increments")
    }
}
