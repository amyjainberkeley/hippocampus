import CoreVideo
import Foundation
import MCICaptureHelperKit

@main
struct Task4R1Behavior {
    static func main() async throws {
        try await verifyFrameBoundPrivacy()
        print("frame_bound_privacy=pass")
        try verifySessionHasNoDetachedPublication()
        print("session_publication_ownership=pass")
        try await verifyOwnedOCRLifecycle()
        print("owned_ocr_lifecycle=pass")
        try await verifyBoundedVisionTimeout()
        print("bounded_vision_timeout=pass")
        try await verifyConfirmedRetentionAndCleanup()
        print("confirmed_retention_cleanup=pass")
    }

    private static func verifySessionHasNoDetachedPublication() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sessionURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("MCICaptureHelperKit")
            .appendingPathComponent("Capture")
            .appendingPathComponent("SCStreamCaptureSession.swift")
        let source = try String(contentsOf: sessionURL, encoding: .utf8)
        precondition(
            !source.contains("Task.detached {"),
            "session callback publication must use the owned dispatcher"
        )
        precondition(source.contains("await ocrPostAllowEmitter?.stopAndDrain()"))
        precondition(source.contains("probe.classify(grayscale: sample.grayscale)"))
    }

    private static func verifyFrameBoundPrivacy() async throws {
        let secure = MutableSecureInput(true)
        let ax = MutableAXState(false)
        let encoder = RecordingEncoder()
        let pipeline = SCStreamPipeline(
            cascade: SuppressionCascade(
                secureEventInput: secure,
                axSecureSubrole: ax,
                denylist: EmptyDenylist(),
                blackedRegion: NoBlackRegion(),
                knownSafeAppBundles: ["com.example.app"]
            ),
            encoder: encoder,
            sink: FixtureFrameSink()
        )
        let context = WorkflowContext(appBundleId: "com.example.app")

        let denied = pipeline.snapshotPixelPrivacy(
            context: context,
            hasBlackedRegion: false
        )
        precondition(denied.secureEventInputEnabled)
        precondition(denied.axSecureSubrole == false)
        precondition(!denied.permitsRawPixels)

        secure.set(false)
        let deniedOutcome = try await pipeline.process(
            frame: candidateFrame(),
            context: context,
            nowUs: 1,
            lease: SurfaceLease(releaser: FixtureSurfaceReleaser()),
            privacySnapshot: denied
        )
        precondition(
            deniedOutcome == .suppressed(reason: .secureEventInput, forcedByFloor: false),
            "a later allowed probe state must not authorize an earlier frame"
        )
        precondition(encoder.count() == 0)

        let allowed = pipeline.snapshotPixelPrivacy(
            context: context,
            hasBlackedRegion: false
        )
        precondition(allowed.permitsRawPixels)
        secure.set(true)
        ax.set(true)
        let allowedOutcome = try await pipeline.process(
            frame: candidateFrame(),
            context: context,
            nowUs: 2,
            lease: SurfaceLease(releaser: FixtureSurfaceReleaser()),
            privacySnapshot: allowed
        )
        guard case .encoded = allowedOutcome else {
            preconditionFailure("a frame-bound allow snapshot must not be changed by later probes")
        }
        precondition(encoder.count() == 1)
    }

    private static func verifyOwnedOCRLifecycle() async throws {
        CascadeTwiceOCREmitter.activateM4Lift(enabled: true)
        defer { CascadeTwiceOCREmitter.activateM4Lift(enabled: false) }

        let orderedSink = FixtureFrameSink()
        let orderedWorker = VisionOCRWorker(engine: OrderedOCREngine())
        let orderedEmitter = CascadeTwiceOCREmitter(
            worker: orderedWorker,
            cascade: allowCascade(),
            sink: orderedSink,
            sequence: FrameSequence(),
            counters: HelperHealthCounters()
        )
        await orderedWorker.start()
        for ordinal in 1...2 {
            await orderedEmitter.processAfterAllow(
                tsUs: UInt64(ordinal),
                context: WorkflowContext(appBundleId: "com.example.app"),
                input: OCREngineInput(pixelBuffer: makePixelBuffer(), roi: unitROI),
                evidenceCandidate: evidenceCandidate(UInt64(ordinal))
            )
        }
        for _ in 0..<200 {
            if await orderedSink.count() == 2 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        await orderedEmitter.stopAndDrain()
        let orderedFrames = await orderedSink.frames()
        precondition(orderedFrames.count == 2)
        precondition(orderedFrames[0].range(of: Data("frame-1".utf8)) != nil)
        precondition(orderedFrames[1].range(of: Data("frame-2".utf8)) != nil)

        let cancelledSink = FixtureFrameSink()
        let cancelledWorker = VisionOCRWorker(engine: CancellationResistantOCREngine())
        let cancelledEmitter = CascadeTwiceOCREmitter(
            worker: cancelledWorker,
            cascade: allowCascade(),
            sink: cancelledSink,
            sequence: FrameSequence(),
            counters: HelperHealthCounters()
        )
        await cancelledWorker.start()
        await cancelledEmitter.processAfterAllow(
            tsUs: 3,
            context: WorkflowContext(appBundleId: "com.example.app"),
            input: OCREngineInput(pixelBuffer: makePixelBuffer(), roi: unitROI),
            evidenceCandidate: evidenceCandidate(3)
        )
        await cancelledEmitter.stopAndDrain()
        let countAtStop = await cancelledSink.count()
        try? await Task.sleep(for: .milliseconds(100))
        let countAfterStop = await cancelledSink.count()
        precondition(countAfterStop == countAtStop)
        precondition(countAtStop == 0, "cancelled OCR publication must not outlive stop")
    }

    private static func verifyBoundedVisionTimeout() async throws {
        let harness = CancellationIgnoringVisionHarness()
        let runner = VisionOCRRunner(synchronousPerform: harness.perform)
        let worker = VisionOCRWorker(engine: runner, capacity: 2, timeoutMs: 40)
        let ledger = OCRCompletionLedger()
        await worker.start()

        let started = ContinuousClock.now
        await worker.submit(
            input: OCREngineInput(pixelBuffer: makePixelBuffer(), roi: unitROI),
            completion: { result in ledger.record(ordinal: 1, result: result) }
        )
        precondition(
            ledger.waitForCount(1, timeout: .milliseconds(300)),
            "cancellation-insensitive Vision work must not hold the timeout result"
        )
        let elapsed = started.duration(to: .now)
        precondition(elapsed < .milliseconds(300), "OCR timeout exceeded its wall-clock bound")
        precondition(ledger.result(for: 1)?.timedOut == true)

        await worker.submit(
            input: OCREngineInput(pixelBuffer: makePixelBuffer(), roi: unitROI),
            completion: { result in ledger.record(ordinal: 2, result: result) }
        )
        precondition(ledger.waitForCount(2, timeout: .milliseconds(300)))
        precondition(ledger.result(for: 2)?.timedOut == true)
        precondition(
            harness.callCount == 1,
            "a quarantined Vision lane must not accumulate blocked operations"
        )

        harness.releaseFirstCall()
        precondition(harness.waitUntilFirstCallReturns(timeout: .milliseconds(300)))
        try? await Task.sleep(for: .milliseconds(20))

        await worker.submit(
            input: OCREngineInput(pixelBuffer: makePixelBuffer(), roi: unitROI),
            completion: { result in ledger.record(ordinal: 3, result: result) }
        )
        precondition(ledger.waitForCount(3, timeout: .milliseconds(300)))
        precondition(ledger.result(for: 3)?.timedOut == false)
        precondition(harness.callCount == 2, "Vision lane must recover after late completion")

        try? await Task.sleep(for: .milliseconds(80))
        precondition(
            ledger.ordinals == [1, 2, 3],
            "OCR completions must remain ordered and exactly once"
        )
        await worker.stopAndDrain()
    }

    private static func verifyConfirmedRetentionAndCleanup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("task4-r1-retention-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coordinator = KeyframeRetentionCoordinator(
            blobDirectory: root,
            keyMaterial: Data((0..<32).map(UInt8.init))
        )
        let pixels = KeyframePixelInput(pixelBuffer: makePixelBuffer())
        guard let first = try await coordinator.retain(
            input: pixels,
            candidate: evidenceCandidate(1, windowId: 1)
        ) else {
            preconditionFailure("first keyframe must retain")
        }

        let secondWhilePending = try await coordinator.retain(
            input: pixels,
            candidate: evidenceCandidate(2, windowId: 2)
        )
        precondition(
            secondWhilePending == nil,
            "confirmed-state semantics allow only one unpublished keyframe"
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: root.path
        )
        do {
            try await coordinator.discard(first)
            preconditionFailure("cleanup failure must be surfaced after deterministic retries")
        } catch {
            let blobURL = root.appendingPathComponent("\(first.lowercaseHexDigest).bin")
            precondition(FileManager.default.fileExists(atPath: blobURL.path))
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        guard let confirmed = try await coordinator.retain(
            input: pixels,
            candidate: evidenceCandidate(2, windowId: 2)
        ) else {
            preconditionFailure("next retention must retry failed cleanup and recover")
        }
        await coordinator.confirm(confirmed)
        let nearDuplicate = try await coordinator.retain(
            input: pixels,
            candidate: evidenceCandidate(3, windowId: 2)
        )
        precondition(nearDuplicate == nil, "policy must compare against confirmed state")
    }

    private static var unitROI: CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private static func candidateFrame() -> CandidateFrame {
        CandidateFrame(
            userIdle: false,
            frameStatusComplete: true,
            dirtyRects: [DirtyRect(x: 0, y: 0, width: 1, height: 1)],
            dhash: DHash(bits: 1),
            priorDhash: nil
        )
    }

    private static func evidenceCandidate(
        _ ordinal: UInt64,
        windowId: UInt32 = 7
    ) -> KeyframeEvidenceCandidate {
        KeyframeEvidenceCandidate(
            captureOrdinal: ordinal,
            focusedWindowId: windowId,
            dhash: DHash(bits: 0),
            monotonicNanoseconds: ordinal
        )
    }

    private static func allowCascade() -> SuppressionCascade {
        SuppressionCascade(
            secureEventInput: MutableSecureInput(false),
            axSecureSubrole: MutableAXState(false),
            denylist: EmptyDenylist(),
            blackedRegion: NoBlackRegion(),
            knownSafeAppBundles: ["com.example.app"]
        )
    }

    private static func makePixelBuffer() -> CVPixelBuffer {
        var output: CVPixelBuffer?
        precondition(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                16,
                16,
                kCVPixelFormatType_32BGRA,
                nil,
                &output
            ) == kCVReturnSuccess
        )
        return output!
    }
}

private final class MutableSecureInput: SecureEventInputProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) { self.value = value }
    func set(_ value: Bool) { lock.withLock { self.value = value } }
    func isSecureEventInputEnabled() -> Bool { lock.withLock { value } }
}

private final class MutableAXState: AXSecureSubroleProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    init(_ value: Bool?) { self.value = value }
    func set(_ value: Bool?) { lock.withLock { self.value = value } }
    func focusedHasSecureSubrole() -> Bool? { lock.withLock { value } }
}

private struct EmptyDenylist: DenylistProbe {
    func appIsDenied(bundleId _: String) -> Bool { false }
    func urlIsDenied(_: String) -> Bool { false }
    func windowTitleIsDenied(_: String) -> Bool { false }
}

private struct NoBlackRegion: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}

private final class RecordingEncoder: FrameEncoder, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func encodeAllowedFrame(
        input _: EncoderInput?,
        seq _: UInt64,
        context _: WorkflowContext
    ) {
        lock.withLock { calls += 1 }
    }

    func count() -> Int { lock.withLock { calls } }
}

private final class FixtureSurfaceReleaser: SurfaceReleasing, @unchecked Sendable {
    func releaseSurface() {}
}

private actor FixtureFrameSink: FrameSink {
    private var recorded: [Data] = []
    func write(_ data: Data) { recorded.append(data) }
    func count() -> Int { recorded.count }
    func frames() -> [Data] { recorded }
}

private actor OrderedOCREngine: OCREngine {
    private var next = 1

    func recognize(input _: OCREngineInput, timeoutMs _: Int) -> OCRResult {
        defer { next += 1 }
        return OCRResult(
            recognizedLines: [
                OCRLine(text: "frame-\(next)", boundingBox: .zero, confidence: 1)
            ],
            durationMs: 1,
            timedOut: false
        )
    }
}

private struct CancellationResistantOCREngine: OCREngine {
    func recognize(input _: OCREngineInput, timeoutMs _: Int) async -> OCRResult {
        try? await Task.sleep(for: .seconds(5))
        return OCRResult(
            recognizedLines: [
                OCRLine(text: "late", boundingBox: .zero, confidence: 1)
            ],
            durationMs: 1,
            timedOut: false
        )
    }
}

private final class CancellationIgnoringVisionHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let firstReturned = DispatchSemaphore(value: 0)
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func perform(input _: OCREngineInput, languages _: [String]) -> OCRResult {
        let ordinal = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        if ordinal == 1 {
            releaseFirst.wait()
            firstReturned.signal()
        }
        return OCRResult(
            recognizedLines: [
                OCRLine(text: "vision-\(ordinal)", boundingBox: .zero, confidence: 1)
            ],
            durationMs: 0,
            timedOut: false
        )
    }

    func releaseFirstCall() {
        releaseFirst.signal()
    }

    func waitUntilFirstCallReturns(timeout: Duration) -> Bool {
        firstReturned.wait(timeout: .now() + timeout.timeInterval) == .success
    }
}

private final class OCRCompletionLedger: @unchecked Sendable {
    private let condition = NSCondition()
    private var entries: [(Int, OCRResult)] = []

    var ordinals: [Int] {
        condition.withLock { entries.map(\.0) }
    }

    func record(ordinal: Int, result: OCRResult) {
        condition.withLock {
            precondition(!entries.contains(where: { $0.0 == ordinal }), "duplicate OCR completion")
            entries.append((ordinal, result))
            condition.broadcast()
        }
    }

    func result(for ordinal: Int) -> OCRResult? {
        condition.withLock { entries.first(where: { $0.0 == ordinal })?.1 }
    }

    func waitForCount(_ count: Int, timeout: Duration) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout.timeInterval)
        while entries.count < count {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
