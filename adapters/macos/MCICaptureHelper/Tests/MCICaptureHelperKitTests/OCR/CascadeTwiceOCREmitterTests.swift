// SPDX-License-Identifier: TBD-private
//
// CascadeTwiceOCREmitterTests — ADR-0016 P3.6 §1.6 + §4.2 cascade-twice
// invariant tests. Headless — no SCStream, no real OCR engine. Stubs
// inject canned OCR results and observe what reaches the FrameSink.
//
// PROTECTED-SET regression gate. If any test in this file goes red,
// the cascade-twice contract is broken.

import XCTest
import CoreGraphics
import CoreVideo
@testable import MCICaptureHelperKit

// MARK: - Stubs

private actor StubFrameSink: FrameSink {
    private(set) var writes: [Data] = []
    private let onWrite: (@Sendable () -> Void)?
    init(onWrite: (@Sendable () -> Void)? = nil) { self.onWrite = onWrite }
    func write(_ data: Data) async throws {
        writes.append(data)
        onWrite?()
    }
    func snapshot() -> [Data] { writes }
}

private actor RegionSensitiveEngine: OCREngine {
    private(set) var regions: [CGRect] = []
    func recognize(input: OCREngineInput, timeoutMs: Int) async -> OCRResult {
        regions.append(input.roi)
        let outsideDirtyRegion = CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.1)
        return OCRResult(recognizedLines: [OCRLine(
            text: input.roi.contains(outsideDirtyRegion) ? "password: hunter2" : "Updated title",
            boundingBox: outsideDirtyRegion, confidence: 1
        )], durationMs: 0, timedOut: false)
    }
}

private actor CountingKeyframeRetainer: KeyframeRetaining {
    private(set) var attempts = 0
    func retain(input: KeyframePixelInput, candidate: KeyframeEvidenceCandidate) async throws -> KeyframeRetention? {
        attempts += 1
        return nil
    }
    func confirm(_ retention: KeyframeRetention) async {}
    func discard(_ retention: KeyframeRetention) async throws {}
}

// Reuses the cross-test `StubOCREngine` defined in
// `VisionOCRWorkerTests.swift` (module-level, .mode-driven).

private struct AlwaysAllowAX: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { false }
}

private struct NoSecureEventInput: SecureEventInputProbe {
    func isSecureEventInputEnabled() -> Bool { false }
}

private struct NoBlackedRegion: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}

private struct EmptyDenylist: DenylistProbe {
    func appIsDenied(bundleId _: String) -> Bool { false }
    func urlIsDenied(_: String) -> Bool { false }
    func windowTitleIsDenied(_: String) -> Bool { false }
}

private func passthroughCascade() -> SuppressionCascade {
    SuppressionCascade(
        secureEventInput: NoSecureEventInput(),
        axSecureSubrole: AlwaysAllowAX(),
        denylist: EmptyDenylist(),
        blackedRegion: NoBlackedRegion(),
        knownSafeAppBundles: ["com.example.app"]
    )
}

private func makePixelBuffer(width: Int = 32, height: Int = 32) -> CVPixelBuffer {
    var out: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attrs as CFDictionary,
        &out
    )
    precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed")
    return out!
}

// MARK: - decideOcr() §6 tests

final class CascadeSection6RegexTests: XCTestCase {
    func testCleanTextAllows() {
        let c = passthroughCascade()
        let ctx = WorkflowContext(appBundleId: "com.example.app")
        XCTAssertEqual(c.decideOcr(text: "Hello world, no secrets here.", context: ctx), .allow)
    }

    func testEmptyTextAllows() {
        let c = passthroughCascade()
        let ctx = WorkflowContext(appBundleId: "com.example.app")
        XCTAssertEqual(c.decideOcr(text: "", context: ctx), .allow)
    }

    func testPasswordEqualValueSuppresses() {
        let c = passthroughCascade()
        let ctx = WorkflowContext(appBundleId: "com.example.app")
        XCTAssertEqual(
            c.decideOcr(text: "password=hunter2", context: ctx),
            .suppress(reason: .ocrTimeSecret)
        )
    }

    func testPasswordColonValueSuppresses() {
        let c = passthroughCascade()
        let ctx = WorkflowContext(appBundleId: "com.example.app")
        XCTAssertEqual(
            c.decideOcr(text: "Password: SuperSecret!", context: ctx),
            .suppress(reason: .ocrTimeSecret)
        )
    }

    func testAPIKeyPatternSuppresses() {
        let c = passthroughCascade()
        let ctx = WorkflowContext(appBundleId: "com.example.app")
        XCTAssertEqual(
            c.decideOcr(text: "api_key = sk-deadbeefcafe", context: ctx),
            .suppress(reason: .ocrTimeSecret)
        )
    }

    func testBearerTokenSuppresses() {
        let c = passthroughCascade()
        let ctx = WorkflowContext(appBundleId: "com.example.app")
        XCTAssertEqual(
            c.decideOcr(text: "Authorization: bearer = abcd1234efgh5678", context: ctx),
            .suppress(reason: .ocrTimeSecret)
        )
    }

    func testGitHubPATSuppresses() {
        let c = passthroughCascade()
        let ctx = WorkflowContext(appBundleId: "com.example.app")
        XCTAssertEqual(
            c.decideOcr(text: "Stale ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 token", context: ctx),
            .suppress(reason: .ocrTimeSecret)
        )
    }

    func testAWSAccessKeyIdSuppresses() {
        let c = passthroughCascade()
        let ctx = WorkflowContext(appBundleId: "com.example.app")
        XCTAssertEqual(
            c.decideOcr(text: "AWS_ACCESS_KEY_ID AKIAIOSFODNN7EXAMPLE", context: ctx),
            .suppress(reason: .ocrTimeSecret)
        )
    }

    func testJWTSuppresses() {
        let c = passthroughCascade()
        let ctx = WorkflowContext(appBundleId: "com.example.app")
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        XCTAssertEqual(
            c.decideOcr(text: "Set-Cookie: \(jwt); HttpOnly", context: ctx),
            .suppress(reason: .ocrTimeSecret)
        )
    }
}

// MARK: - CascadeTwiceOCREmitter wire-emission tests

final class CascadeTwiceOCREmitterTests: XCTestCase {
    /// CSO escalation 2026-05-29 — the cascade-twice §6 mechanics
    /// (this file's purpose) require `killOcrEmit == false`. The
    /// kill-switch is `false` after live qualification; the dedicated
    /// `testKillSwitchEmitsTombstoneForAllowFrames` test below still pins
    /// the emergency rollback branch. These tests restore the qualified
    /// production default after every case.
    override func setUp() {
        super.setUp()
        CascadeTwiceOCREmitter.killOcrEmit = false
    }

    override func tearDown() {
        CascadeTwiceOCREmitter.killOcrEmit = false
        super.tearDown()
    }

    func testScreenshotScansSecretOutsideDirtyRegionBeforeRetention() async {
        let engine = RegionSensitiveEngine()
        let sink = StubFrameSink()
        let retainer = CountingKeyframeRetainer()
        let emitter = CascadeTwiceOCREmitter(
            worker: VisionOCRWorker(engine: engine), cascade: passthroughCascade(),
            sink: sink, sequence: FrameSequence(), counters: HelperHealthCounters(),
            keyframeRetainer: retainer
        )
        let finished = expectation(description: "OCR privacy decision completed")
        await emitter.worker.start()
        await emitter.processAfterAllow(
            captureOrdinal: 1, tsUs: 12_345,
            context: WorkflowContext(appBundleId: "com.example.app"),
            input: OCREngineInput(pixelBuffer: makePixelBuffer(), roi: CGRect(x: 0, y: 0, width: 0.1, height: 0.1)),
            evidenceCandidate: KeyframeEvidenceCandidate(
                captureOrdinal: 1, focusedWindowId: 10, dhash: DHash(bits: 0),
                monotonicNanoseconds: 1
            ),
            disposition: { _ in finished.fulfill() }
        )
        await fulfillment(of: [finished], timeout: 3)
        await emitter.worker.stopAndDrain()
        let regions = await engine.regions
        let attempts = await retainer.attempts
        let frames = await sink.snapshot()
        XCTAssertEqual(regions, [CGRect(x: 0, y: 0, width: 1, height: 1)])
        XCTAssertEqual(attempts, 0, "A secret outside the dirty region must prevent image retention")
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?[2], 0x11, "Only a privacy tombstone may be emitted")
        XCTAssertEqual(frames.first?.last, RedactionReason.ocrTimeSecret.rawValue)
    }

    func testTextOnlyOCRPreservesRequestedRegion() async {
        let engine = RegionSensitiveEngine()
        let emitter = CascadeTwiceOCREmitter(
            worker: VisionOCRWorker(engine: engine), cascade: passthroughCascade(),
            sink: StubFrameSink(), sequence: FrameSequence(), counters: HelperHealthCounters()
        )
        let finished = expectation(description: "Text-only OCR completed")
        let roi = CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
        await emitter.worker.start()
        await emitter.processAfterAllow(
            captureOrdinal: 1, tsUs: 12_345,
            context: WorkflowContext(appBundleId: "com.example.app"),
            input: OCREngineInput(pixelBuffer: makePixelBuffer(), roi: roi),
            evidenceCandidate: nil, disposition: { _ in finished.fulfill() }
        )
        await fulfillment(of: [finished], timeout: 3)
        await emitter.worker.stopAndDrain()
        let regions = await engine.regions
        XCTAssertEqual(regions, [roi])
    }

    /// SecretBench-pattern OCR text ⇒ tombstone reason=ocrTimeSecret;
    /// NO OCREvent emitted. ADR-0016 §4.2 invariant.
    func testSecretBenchTextEmitsTombstoneNotOCREvent() async {
        let sink = StubFrameSink()
        let emitter = CascadeTwiceOCREmitter(
            worker: VisionOCRWorker(engine: StubOCREngine(mode: .canned(OCRResult(
                recognizedLines: [
                    OCRLine(text: "password: hunter2", boundingBox: .zero, confidence: 1.0)
                ],
                durationMs: 0,
                timedOut: false
            )))),
            cascade: passthroughCascade(),
            sink: sink,
            sequence: FrameSequence(),
            counters: HelperHealthCounters()
        )
        await emitter.worker.start()
        await emitter.processAfterAllow(
            tsUs: 12_345,
            context: WorkflowContext(appBundleId: "com.example.app"),
            input: OCREngineInput(pixelBuffer: makePixelBuffer(), roi: .init(x: 0, y: 0, width: 1, height: 1))
        )
        // Allow OCR completion + emit Task to settle.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let frames = await sink.snapshot()
        XCTAssertEqual(frames.count, 1, "exactly one frame should reach the sink")
        guard let bytes = frames.first else { return XCTFail() }
        // PrivacyTombstone msg_type = 0x0011; last byte = reason.
        XCTAssertEqual(bytes[2], 0x11, "msg_type LE low byte = PrivacyTombstone")
        XCTAssertEqual(bytes[3], 0x00)
        XCTAssertEqual(bytes.last, RedactionReason.ocrTimeSecret.rawValue,
                       "tombstone reason must be ocrTimeSecret (=6)")
        await emitter.stopAndDrain()
    }

    /// Clean OCR text ⇒ OCREvent emitted carrying the OCR text bytes.
    func testCleanTextEmitsOCREvent() async {
        let sink = StubFrameSink()
        let emitter = CascadeTwiceOCREmitter(
            worker: VisionOCRWorker(engine: StubOCREngine(mode: .canned(OCRResult(
                recognizedLines: [
                    OCRLine(text: "Hello", boundingBox: .zero, confidence: 1.0),
                    OCRLine(text: "world", boundingBox: .zero, confidence: 1.0)
                ],
                durationMs: 0,
                timedOut: false
            )))),
            cascade: passthroughCascade(),
            sink: sink,
            sequence: FrameSequence(),
            counters: HelperHealthCounters()
        )
        await emitter.worker.start()
        await emitter.processAfterAllow(
            tsUs: 99,
            context: WorkflowContext(
                appBundleId: "com.example.app",
                windowTitle: "Browser",
                url: "https://example.com"
            ),
            input: OCREngineInput(pixelBuffer: makePixelBuffer(), roi: .init(x: 0, y: 0, width: 1, height: 1))
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        let frames = await sink.snapshot()
        XCTAssertEqual(frames.count, 1)
        guard let bytes = frames.first else { return XCTFail() }
        // OCREvent msg_type = 0x0040; little-endian → byte 2 = 0x40.
        XCTAssertEqual(bytes[2], 0x40, "msg_type byte 2 must be OCREvent (0x0040 LE)")
        XCTAssertEqual(bytes[3], 0x00)
        // Confirm "Hello\nworld" is present in the variable trailer.
        XCTAssertTrue(bytes.range(of: "Hello\nworld".data(using: .utf8)!) != nil,
                      "OCREvent payload must carry the joined OCR text")
        await emitter.stopAndDrain()
    }

    /// Over-cap OCR text ⇒ fail-closed tombstone with reason=
    /// failsafeUnknown; NO OCREvent emitted. ADR-0013 §7 / ADR-0016 §4.9.
    func testOverCapOCRTextFailsClosed() async {
        let oversized = String(repeating: "a", count: maxOCRTextBytes + 1)
        let written = expectation(description: "Over-cap OCR publishes its privacy tombstone")
        let sink = StubFrameSink(onWrite: { written.fulfill() })
        let emitter = CascadeTwiceOCREmitter(
            worker: VisionOCRWorker(engine: StubOCREngine(mode: .canned(OCRResult(
                recognizedLines: [
                    OCRLine(text: oversized, boundingBox: .zero, confidence: 1.0)
                ],
                durationMs: 0,
                timedOut: false
            )))),
            cascade: passthroughCascade(),
            sink: sink,
            sequence: FrameSequence(),
            counters: HelperHealthCounters()
        )
        await emitter.worker.start()
        await emitter.processAfterAllow(
            tsUs: 1,
            context: WorkflowContext(appBundleId: "com.example.app"),
            input: OCREngineInput(pixelBuffer: makePixelBuffer(), roi: .init(x: 0, y: 0, width: 1, height: 1))
        )
        await fulfillment(of: [written], timeout: 5)
        await emitter.stopAndDrain()
        let frames = await sink.snapshot()
        XCTAssertEqual(frames.count, 1)
        guard let bytes = frames.first else { return XCTFail() }
        XCTAssertEqual(bytes[2], 0x11, "must be a PrivacyTombstone, not OCREvent")
        XCTAssertEqual(bytes.last, RedactionReason.failsafeUnknown.rawValue,
                       "fail-closed reason on over-cap")
    }

    /// CSO escalation 2026-05-29 — Phase A interim mitigation (option
    /// M4 in `docs/research/capture-scope-window-vs-display-2026-05-29.md`).
    /// With the emergency kill-switch ON, every cleared-
    /// pixel-time `.allow` frame must emit a `PrivacyTombstone(
    /// failsafeUnknown)` instead of an OCREvent — proving no OCR
    /// text bytes from the whole-display SCStream sample can reach
    /// the wire while the architectural fix bakes.
    func testKillSwitchEmitsTombstoneForAllowFrames() async {
        // Emergency rollback posture — kill-switch ON.
        CascadeTwiceOCREmitter.killOcrEmit = true
        defer { CascadeTwiceOCREmitter.killOcrEmit = false }
        let sink = StubFrameSink()
        let emitter = CascadeTwiceOCREmitter(
            worker: VisionOCRWorker(engine: StubOCREngine(mode: .canned(OCRResult(
                recognizedLines: [
                    // Text that, absent the kill-switch, would
                    // successfully emit an OCREvent (no §6 regex hit,
                    // within the 64 KB cap).
                    OCRLine(text: "innocuous content", boundingBox: .zero, confidence: 1.0)
                ],
                durationMs: 0,
                timedOut: false
            )))),
            cascade: passthroughCascade(),
            sink: sink,
            sequence: FrameSequence(),
            counters: HelperHealthCounters()
        )
        await emitter.worker.start()
        await emitter.processAfterAllow(
            tsUs: 555,
            context: WorkflowContext(
                appBundleId: "com.apple.Safari",
                windowTitle: "spur",
                url: nil
            ),
            input: OCREngineInput(pixelBuffer: makePixelBuffer(), roi: .init(x: 0, y: 0, width: 1, height: 1))
        )
        // The kill-switch path is synchronous through emitTombstone
        // — no Vision worker round-trip — but we await briefly so the
        // FrameSink actor processes the write.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let frames = await sink.snapshot()
        XCTAssertEqual(frames.count, 1, "kill-switch must emit exactly one frame per allow")
        guard let bytes = frames.first else { return XCTFail() }
        XCTAssertEqual(bytes[2], 0x11,
                       "kill-switch frame must be a PrivacyTombstone, not an OCREvent")
        XCTAssertEqual(bytes[3], 0x00)
        XCTAssertEqual(bytes.last, RedactionReason.failsafeUnknown.rawValue,
                       "kill-switch tombstone reason must be failsafeUnknown")
        await emitter.stopAndDrain()
    }
}

// MARK: - Convenience for the tests above

private extension CascadeTwiceOCREmitter {
    /// Test-only accessor to drive the underlying worker. Not on the
    /// public API surface.
    var worker: VisionOCRWorker { Mirror(reflecting: self).children.first(where: { $0.label == "worker" })!.value as! VisionOCRWorker }
}

// MARK: - OCRROIComputer pure-function tests

final class OCRROIComputerTests: XCTestCase {
    func testEmptyDirtyRectsReturnsFullFrame() {
        let roi = OCRROIComputer.normalizedBoundingROI(
            widthPx: 1920,
            heightPx: 1080,
            dirtyRects: []
        )
        XCTAssertEqual(roi, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testZeroWidthFrameReturnsFullFrameROI() {
        let roi = OCRROIComputer.normalizedBoundingROI(
            widthPx: 0,
            heightPx: 0,
            dirtyRects: [DirtyRect(x: 1, y: 2, width: 3, height: 4)]
        )
        XCTAssertEqual(roi, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testSingleRectNormalizesAndFlipsToLowerLeftOrigin() {
        // Frame 100 × 100 px. Dirty rect at top-left (origin top-left
        // per SCStreamFrameInfo): (10, 20, 30, 40). After flipping to
        // Vision's lower-left convention: y = 1 - (20+40)/100 = 0.40.
        let roi = OCRROIComputer.normalizedBoundingROI(
            widthPx: 100,
            heightPx: 100,
            dirtyRects: [DirtyRect(x: 10, y: 20, width: 30, height: 40)]
        )
        XCTAssertEqual(roi.origin.x, 0.10, accuracy: 1e-6)
        XCTAssertEqual(roi.origin.y, 0.40, accuracy: 1e-6)
        XCTAssertEqual(roi.size.width, 0.30, accuracy: 1e-6)
        XCTAssertEqual(roi.size.height, 0.40, accuracy: 1e-6)
    }

    func testMultipleRectsAreUnioned() {
        // Two rects in a 100x100 frame; bounding rect = (5,10) -> (50,80)
        // ⇒ width 45, height 70. Flipped y = 1 - 80/100 = 0.20.
        let roi = OCRROIComputer.normalizedBoundingROI(
            widthPx: 100,
            heightPx: 100,
            dirtyRects: [
                DirtyRect(x: 5, y: 10, width: 10, height: 10),
                DirtyRect(x: 40, y: 30, width: 10, height: 50)
            ]
        )
        XCTAssertEqual(roi.origin.x, 0.05, accuracy: 1e-6)
        XCTAssertEqual(roi.origin.y, 0.20, accuracy: 1e-6)
        XCTAssertEqual(roi.size.width, 0.45, accuracy: 1e-6)
        XCTAssertEqual(roi.size.height, 0.70, accuracy: 1e-6)
    }
}
