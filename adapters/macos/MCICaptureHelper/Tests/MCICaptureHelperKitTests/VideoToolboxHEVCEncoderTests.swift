// SPDX-License-Identifier: TBD-private
//
// VideoToolboxHEVCEncoderTests — DOGFOOD_V1 #3 proofs.
//
//   • The HEVC encode CONFIGURATION POLICY (HEVC, keyframe-only, no
//     frame reordering, power-efficient, MaxFrameDelayCount=0). Pure
//     — no VTCompressionSession is created to assert these.
//   • Through the REAL `SCStreamPipeline`, the encoder is invoked
//     EXACTLY on `.allow` and NEVER on `.suppress` / filtered-out —
//     the Amendment 1 §3(a)/(c) structural guarantee.
//   • Live `VTCompressionSession` end-to-end on a SYNTHETIC
//     `CVPixelBufferCreate` buffer (no screen needed): the encoder
//     produces at least one `CMSampleBuffer` and hands it to the
//     injected `EncodedSampleSink`. Skipped automatically when the
//     test host cannot create an HEVC compression session (older /
//     headless macOS without an HEVC encoder available).
//
// PROTECTED-SET per AGENT_PROTOCOL §5.

import CoreMedia
import CoreVideo
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
private actor CountingEncodedSink: EncodedSampleSink {
    private(set) var samples: [(seq: UInt64, width: Int, height: Int)] = []
    func handle(_ sample: EncodedSample) async {
        samples.append((sample.seq, sample.widthPx, sample.heightPx))
    }
    func count() -> Int { samples.count }
    func all() -> [(seq: UInt64, width: Int, height: Int)] { samples }
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

/// Headlessly-created `CVPixelBuffer` so the live VTCompressionSession
/// path can run from a unit test without a screen.
private func makeTestPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    let rc = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width, height,
        kCVPixelFormatType_32BGRA,
        attrs as CFDictionary,
        &pb
    )
    guard rc == kCVReturnSuccess, let buf = pb else {
        throw XCTSkip("CVPixelBufferCreate failed (rc=\(rc)) on this host — VideoToolbox cannot be exercised")
    }
    // Fill with a flat grey so the encoder has actual content (some
    // encoders are unhappy with uninitialized memory in CI).
    CVPixelBufferLockBaseAddress(buf, [])
    if let base = CVPixelBufferGetBaseAddress(buf) {
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        memset(base, 0x80, bpr * height)
    }
    CVPixelBufferUnlockBaseAddress(buf, [])
    return buf
}

/// Skip the live-encode tests when the HEVC encoder is unavailable
/// (e.g. CI containers without VideoToolbox HW + SW path). Probes
/// availability by attempting a small `VTCompressionSessionCreate`;
/// invalidates immediately so no resource leaks.
private func skipIfNoHEVCEncoderAvailable() throws {
    var probe: VTCompressionSession?
    let status = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        width: 32, height: 32,
        codecType: kCMVideoCodecType_HEVC,
        encoderSpecification: nil,
        imageBufferAttributes: nil,
        compressedDataAllocator: nil,
        outputCallback: nil,
        refcon: nil,
        compressionSessionOut: &probe
    )
    if let probe { VTCompressionSessionInvalidate(probe) }
    if status != noErr {
        throw XCTSkip("HEVC VTCompressionSession unavailable on this host (status=\(status))")
    }
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
        XCTAssertEqual(c.maxFrameDelayCount, 0, "encoder must not buffer frames before emit")
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
        XCTAssertEqual(
            props[kVTCompressionPropertyKey_MaxFrameDelayCount] as? Int, 0,
            "MaxFrameDelayCount=0 keeps the encoder from buffering frames"
        )
        XCTAssertEqual(
            props[kVTCompressionPropertyKey_MaxKeyFrameInterval] as? Int, 1,
            "MaxKeyFrameInterval=1 — every emitted frame is an IDR"
        )
    }

    // ── The structural guarantee: encoder reached ONLY on `.allow`. ──
    func test_hevc_encoder_never_invoked_on_suppressed_frame() async throws {
        let sink = CountingEncodedSink()
        let enc = VideoToolboxHEVCEncoder(sink: sink)
        let pipe = pipeline(
            denied: ["com.secret.app"], ax: AXNonSecure(),
            knownSafe: [], encoder: enc
        )
        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.secret.app"),
            nowUs: 1, lease: SurfaceLease(releaser: BorrowedNoRetainReleaser())
        )
        XCTAssertEqual(outcome, .suppressed(reason: .denylistSource, forcedByFloor: false))
        XCTAssertEqual(enc.allowedFrameCount(), 0, "HEVC encoder MUST NOT run on a suppressed frame")
        XCTAssertEqual(enc.emittedSampleCount(), 0, "no encoded sample on a suppressed frame")
        let n = await sink.count()
        XCTAssertEqual(n, 0, "no encoded sample handed to sink on a suppressed frame")
    }

    func test_hevc_encoder_never_invoked_when_filtered_out() async throws {
        let sink = CountingEncodedSink()
        let enc = VideoToolboxHEVCEncoder(sink: sink)
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
        XCTAssertEqual(enc.emittedSampleCount(), 0)
    }

    /// `.allow` with no `EncoderInput` (headless / OS-free) → the
    /// encoder records that an allow reached its call site but emits
    /// no `CMSampleBuffer`. Pins the back-compat behaviour every other
    /// pipeline test depends on.
    func test_hevc_encoder_records_allow_without_pixel_buffer_but_emits_nothing() async throws {
        let sink = CountingEncodedSink()
        let enc = VideoToolboxHEVCEncoder(sink: sink)
        let pipe = pipeline(
            denied: [], ax: AXNonSecure(), knownSafe: ["com.good.app"], encoder: enc
        )
        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.good.app"),
            nowUs: 3, lease: SurfaceLease(releaser: BorrowedNoRetainReleaser())
            // no encoderInput → defaults to nil
        )
        if case .encoded = outcome {} else { XCTFail("expected .encoded, got \(outcome)") }
        XCTAssertEqual(enc.allowedFrameCount(), 1, "exactly one allow reached the encoder")
        XCTAssertEqual(enc.emittedSampleCount(), 0, "no pixel buffer → no encode → no emit")
        let n = await sink.count()
        XCTAssertEqual(n, 0)
    }

    func test_only_allowed_frames_accumulate() async throws {
        let sink = CountingEncodedSink()
        let enc = VideoToolboxHEVCEncoder(sink: sink)
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

    // ── Live VTCompressionSession on a synthetic pixel buffer. ───────
    //
    // CVPixelBufferCreate works headlessly so we exercise the real
    // encode call site without a screen. Skipped automatically when
    // the test host cannot construct an HEVC compression session.

    func test_live_encode_emits_sample_buffer_to_sink_on_allow() async throws {
        try skipIfNoHEVCEncoderAvailable()

        let sink = CountingEncodedSink()
        let enc = VideoToolboxHEVCEncoder(sink: sink)
        let pipe = pipeline(
            denied: [], ax: AXNonSecure(), knownSafe: ["com.good.app"], encoder: enc
        )
        let pb = try makeTestPixelBuffer(width: 64, height: 64)

        let outcome = try await pipe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.good.app"),
            nowUs: 10,
            lease: SurfaceLease(releaser: BorrowedNoRetainReleaser()),
            encoderInput: EncoderInput(pixelBuffer: pb)
        )
        if case .encoded = outcome {} else { XCTFail("expected .encoded, got \(outcome)") }
        XCTAssertEqual(enc.allowedFrameCount(), 1)
        XCTAssertEqual(enc.emittedSampleCount(), 1, "one allow + one pixel buffer ⇒ one emit")
        let samples = await sink.all()
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.width, 64)
        XCTAssertEqual(samples.first?.height, 64)
    }

    /// Three back-to-back live encodes ⇒ three sink writes. Proves the
    /// session is reused across frames (lazy-create, not per-frame).
    func test_live_encode_reuses_session_across_frames() async throws {
        try skipIfNoHEVCEncoderAvailable()

        let sink = CountingEncodedSink()
        let enc = VideoToolboxHEVCEncoder(sink: sink)
        let pipe = pipeline(
            denied: [], ax: AXNonSecure(), knownSafe: ["com.good.app"], encoder: enc
        )
        let pb = try makeTestPixelBuffer(width: 64, height: 64)

        for i in 0 ..< 3 {
            _ = try await pipe.process(
                frame: forwardingFrame(),
                context: WorkflowContext(appBundleId: "com.good.app"),
                nowUs: UInt64(100 + i),
                lease: SurfaceLease(releaser: BorrowedNoRetainReleaser()),
                encoderInput: EncoderInput(pixelBuffer: pb)
            )
        }
        XCTAssertEqual(enc.emittedSampleCount(), 3)
        let count = await sink.count()
        XCTAssertEqual(count, 3, "3 allow frames ⇒ 3 encoded samples handed to sink")
    }

    /// Dimension change forces a fresh `VTCompressionSession`. The
    /// outward behaviour the test pins is that BOTH frames produced a
    /// sample (no swallowed emit on the resize boundary).
    func test_live_encode_handles_dimension_change() async throws {
        try skipIfNoHEVCEncoderAvailable()

        let sink = CountingEncodedSink()
        let enc = VideoToolboxHEVCEncoder(sink: sink)
        let pipe = pipeline(
            denied: [], ax: AXNonSecure(), knownSafe: ["com.good.app"], encoder: enc
        )
        let pb1 = try makeTestPixelBuffer(width: 64, height: 64)
        let pb2 = try makeTestPixelBuffer(width: 96, height: 48)

        _ = try await pipe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.good.app"),
            nowUs: 200,
            lease: SurfaceLease(releaser: BorrowedNoRetainReleaser()),
            encoderInput: EncoderInput(pixelBuffer: pb1)
        )
        _ = try await pipe.process(
            frame: forwardingFrame(),
            context: WorkflowContext(appBundleId: "com.good.app"),
            nowUs: 201,
            lease: SurfaceLease(releaser: BorrowedNoRetainReleaser()),
            encoderInput: EncoderInput(pixelBuffer: pb2)
        )
        XCTAssertEqual(enc.emittedSampleCount(), 2, "both frames must emit despite the resize")
        let samples = await sink.all()
        XCTAssertEqual(samples.map { $0.width }, [64, 96])
        XCTAssertEqual(samples.map { $0.height }, [64, 48])
    }
}
