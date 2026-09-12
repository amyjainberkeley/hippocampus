import Foundation
import MCICaptureHelperKit
import CoreVideo

@main
struct Task4CaptureBehavior {
    static func main() async throws {
        let policy = KeyframePolicy(materialDistance: 12, maxSilenceNanoseconds: 300)
        let first = KeyframeEvidenceCandidate(
            captureOrdinal: 1,
            focusedWindowId: 7,
            dhash: DHash(bits: 0),
            monotonicNanoseconds: 100
        )
        let same = KeyframeEvidenceCandidate(
            captureOrdinal: 2,
            focusedWindowId: 7,
            dhash: DHash(bits: 0),
            monotonicNanoseconds: 101
        )
        let changed = KeyframeEvidenceCandidate(
            captureOrdinal: 3,
            focusedWindowId: 8,
            dhash: DHash(bits: 0),
            monotonicNanoseconds: 102
        )

        precondition(policy.decision(previous: nil, current: first) == .first)
        precondition(policy.decision(previous: first, current: same) == .skip)
        precondition(policy.decision(previous: first, current: changed) == .windowChanged)
        precondition(
            policy.decision(
                previous: first,
                current: KeyframeEvidenceCandidate(
                    captureOrdinal: 4,
                    focusedWindowId: 7,
                    dhash: DHash(bits: 0),
                    monotonicNanoseconds: 400
                )
            ) == .maximumSilence
        )

        let options = CaptureLaunchOptions.parse(
            ["mci-capture-helper"],
            environment: ["HIPPOCAMPUS_ENABLE_V2P1": "1"]
        )
        precondition(!options.captureEnabled, "environment must not authorize capture")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("task4-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pixels = makePixelBuffer()
        let coordinator = KeyframeRetentionCoordinator(
            blobDirectory: root,
            keyMaterial: Data((0..<32).map(UInt8.init)),
            policy: policy
        )

        guard let retained = try await coordinator.retain(
            input: KeyframePixelInput(pixelBuffer: pixels),
            candidate: first
        ) else {
            preconditionFailure("first eligible keyframe was not retained")
        }
        let retainedURL = root.appendingPathComponent("\(retained.lowercaseHexDigest).bin")
        precondition(FileManager.default.fileExists(atPath: retainedURL.path))
        let retainedBytes = try Data(contentsOf: retainedURL)
        precondition(retainedBytes.count > 44)
        await coordinator.confirm(retained)
        let unchangedRetention = try await coordinator.retain(
            input: KeyframePixelInput(pixelBuffer: pixels),
            candidate: same
        )
        precondition(unchangedRetention == nil, "unchanged frame should not persist")

        let rollbackRoot = root.appendingPathComponent("rollback")
        try FileManager.default.createDirectory(at: rollbackRoot, withIntermediateDirectories: true)
        let rollbackCoordinator = KeyframeRetentionCoordinator(
            blobDirectory: rollbackRoot,
            keyMaterial: Data((0..<32).map(UInt8.init)),
            policy: policy
        )
        guard let rollbackRetention = try await rollbackCoordinator.retain(
            input: KeyframePixelInput(pixelBuffer: pixels),
            candidate: first
        ) else {
            preconditionFailure("rollback fixture did not retain")
        }
        try await rollbackCoordinator.discard(rollbackRetention)
        precondition(
            !FileManager.default.fileExists(
                atPath: rollbackRoot
                    .appendingPathComponent("\(rollbackRetention.lowercaseHexDigest).bin")
                    .path
            )
        )
        let retainedAfterRollback = try await rollbackCoordinator.retain(
            input: KeyframePixelInput(pixelBuffer: pixels),
            candidate: first
        )
        precondition(retainedAfterRollback != nil, "discard must roll policy state back")

        let failedRoot = root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: failedRoot)
        let failingCoordinator = KeyframeRetentionCoordinator(
            blobDirectory: failedRoot,
            keyMaterial: Data((0..<32).map(UInt8.init)),
            policy: policy
        )
        let failedRetention = try await failingCoordinator.retain(
            input: KeyframePixelInput(pixelBuffer: pixels),
            candidate: first
        )
        precondition(failedRetention == nil, "write failure must not return a digest")
        try FileManager.default.removeItem(at: failedRoot)
        try FileManager.default.createDirectory(at: failedRoot, withIntermediateDirectories: true)
        let retainedAfterFailure = try await failingCoordinator.retain(
            input: KeyframePixelInput(pixelBuffer: pixels),
            candidate: first
        )
        precondition(retainedAfterFailure != nil, "failed write must not advance policy state")

        let cancelledRoot = root.appendingPathComponent("cancelled")
        try FileManager.default.createDirectory(at: cancelledRoot, withIntermediateDirectories: true)
        let cancelledCoordinator = KeyframeRetentionCoordinator(
            blobDirectory: cancelledRoot,
            keyMaterial: Data((0..<32).map(UInt8.init)),
            policy: policy
        )
        let cancelledTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cancelledCoordinator.retain(
                input: KeyframePixelInput(pixelBuffer: pixels),
                candidate: first
            )
        }
        let cancelledRetention = try await cancelledTask.value
        precondition(cancelledRetention == nil)
        let cancelledFiles = try FileManager.default.contentsOfDirectory(atPath: cancelledRoot.path)
        precondition(cancelledFiles.isEmpty)

        CascadeTwiceOCREmitter.activateM4Lift(enabled: true)
        let secret = await runEmitter(
            result: OCRResult(
                recognizedLines: [
                    OCRLine(text: "password: private", boundingBox: .zero, confidence: 1)
                ],
                durationMs: 1,
                timedOut: false
            ),
            root: root.appendingPathComponent("secret"),
            pixels: pixels,
            policy: policy
        )
        precondition(secret.files.isEmpty)
        precondition(secret.frames.count == 1 && isTombstone(secret.frames[0]))
        precondition(secret.dispositions == [.finalized])

        let timedOut = await runEmitter(
            result: OCRResult(recognizedLines: [], durationMs: 1_000, timedOut: true),
            root: root.appendingPathComponent("timeout"),
            pixels: pixels,
            policy: policy
        )
        precondition(timedOut.files.isEmpty)
        precondition(timedOut.frames.isEmpty, "timed-out OCR must publish no memory event")
        precondition(
            timedOut.dispositions == [.retryableNoContent],
            "timed-out OCR must reopen the visual baseline for retry"
        )

        let empty = await runEmitter(
            result: OCRResult(recognizedLines: [], durationMs: 1, timedOut: false),
            root: root.appendingPathComponent("empty"),
            pixels: pixels,
            policy: policy
        )
        precondition(empty.files.isEmpty)
        precondition(empty.frames.isEmpty, "empty OCR must publish no memory event")
        precondition(empty.dispositions == [.retryableNoContent])

        let whitespace = await runEmitter(
            result: OCRResult(
                recognizedLines: [OCRLine(text: "  \n\t ", boundingBox: .zero, confidence: 1)],
                durationMs: 1,
                timedOut: false
            ),
            root: root.appendingPathComponent("whitespace"),
            pixels: pixels,
            policy: policy
        )
        precondition(whitespace.files.isEmpty)
        precondition(whitespace.frames.isEmpty, "whitespace-only OCR must publish no memory event")
        precondition(whitespace.dispositions == [.retryableNoContent])

        let overflow = await runEmitter(
            context: WorkflowContext(
                appBundleId: "com.example.app",
                windowTitle: String(repeating: "w", count: Int(UInt16.max) + 1)
            ),
            result: OCRResult(
                recognizedLines: [OCRLine(text: "clean", boundingBox: .zero, confidence: 1)],
                durationMs: 1,
                timedOut: false
            ),
            root: root.appendingPathComponent("overflow"),
            pixels: pixels,
            policy: policy
        )
        precondition(overflow.files.isEmpty)
        precondition(overflow.frames.count == 1 && isTombstone(overflow.frames[0]))
        precondition(overflow.dispositions == [.finalized])

        let clean = await runEmitter(
            result: OCRResult(
                recognizedLines: [OCRLine(text: "clean", boundingBox: .zero, confidence: 1)],
                durationMs: 1,
                timedOut: false
            ),
            root: root.appendingPathComponent("clean"),
            pixels: pixels,
            policy: policy
        )
        precondition(clean.frames.count == 1)
        precondition(clean.files.count == 1)
        precondition(clean.dispositions == [.finalized])
        let cleanHash = keyframeHash(clean.frames[0])
        precondition(!cleanHash.allSatisfy { $0 == 0 })
        precondition(clean.files[0] == cleanHash.map { String(format: "%02x", $0) }.joined() + ".bin")

        let retryEngine = SequencedOCREngine(results: [
            .empty,
            OCRResult(
                recognizedLines: [OCRLine(text: "recovered", boundingBox: .zero, confidence: 1)],
                durationMs: 1,
                timedOut: false
            ),
        ])
        let recovered = await runEmitter(
            engine: retryEngine,
            root: root.appendingPathComponent("same-buffer-retry"),
            pixels: pixels,
            policy: policy
        )
        let retryCalls = await retryEngine.callCount()
        precondition(
            retryCalls == 2,
            "empty OCR must retry the same retained pixel buffer exactly once"
        )
        precondition(recovered.frames.count == 1)
        precondition(recovered.files.count == 1)
        precondition(recovered.dispositions == [.finalized])

        let dropEngine = BlockingOCREngine()
        let dropWorker = VisionOCRWorker(engine: dropEngine, capacity: 1)
        let droppedOrdinals = FixtureOrdinalCollector()
        await dropWorker.start()
        await dropWorker.submit(
            input: OCREngineInput(pixelBuffer: pixels, roi: .zero),
            onDrop: { Task { await droppedOrdinals.append(1) } },
            completion: { _ in }
        )
        await dropEngine.waitUntilFirstCallStarts()
        await dropWorker.submit(
            input: OCREngineInput(pixelBuffer: pixels, roi: .zero),
            onDrop: { Task { await droppedOrdinals.append(2) } },
            completion: { _ in }
        )
        await dropWorker.submit(
            input: OCREngineInput(pixelBuffer: pixels, roi: .zero),
            onDrop: { Task { await droppedOrdinals.append(3) } },
            completion: { _ in }
        )
        for _ in 0..<100 where await droppedOrdinals.values().isEmpty {
            try? await Task.sleep(for: .milliseconds(2))
        }
        let droppedValues = await droppedOrdinals.values()
        precondition(
            droppedValues == [2],
            "drop-oldest must notify the exact submission whose OCR will never complete"
        )
        await dropEngine.releaseFirstCall()
        await dropWorker.stopAndDrain()
        CascadeTwiceOCREmitter.activateM4Lift(enabled: false)
    }

    private static func runEmitter(
        context: WorkflowContext = WorkflowContext(appBundleId: "com.example.app"),
        result: OCRResult,
        root: URL,
        pixels: CVPixelBuffer,
        policy: KeyframePolicy
    ) async -> (frames: [Data], files: [String], dispositions: [OCRPostAllowDisposition]) {
        await runEmitter(
            context: context,
            engine: FixtureOCREngine(result: result),
            root: root,
            pixels: pixels,
            policy: policy
        )
    }

    private static func runEmitter(
        context: WorkflowContext = WorkflowContext(appBundleId: "com.example.app"),
        engine: any OCREngine,
        root: URL,
        pixels: CVPixelBuffer,
        policy: KeyframePolicy
    ) async -> (frames: [Data], files: [String], dispositions: [OCRPostAllowDisposition]) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sink = FixtureFrameSink()
        let worker = VisionOCRWorker(engine: engine)
        let retainer = KeyframeRetentionCoordinator(
            blobDirectory: root,
            keyMaterial: Data((0..<32).map(UInt8.init)),
            policy: policy
        )
        let emitter = CascadeTwiceOCREmitter(
            worker: worker,
            cascade: fixtureCascade(),
            sink: sink,
            sequence: FrameSequence(),
            counters: HelperHealthCounters(),
            keyframeRetainer: retainer
        )
        let dispositionCollector = FixtureDispositionCollector()
        await worker.start()
        await emitter.processAfterAllow(
            captureOrdinal: 1,
            tsUs: 1,
            context: context,
            input: OCREngineInput(
                pixelBuffer: pixels,
                roi: CGRect(x: 0, y: 0, width: 1, height: 1)
            ),
            evidenceCandidate: KeyframeEvidenceCandidate(
                captureOrdinal: 1,
                focusedWindowId: 7,
                dhash: DHash(bits: 0),
                monotonicNanoseconds: 1
            ),
            disposition: { value in
                Task { await dispositionCollector.append(value) }
            }
        )
        for _ in 0..<200 {
            if await dispositionCollector.count() >= 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        await emitter.stopAndDrain()
        let frames = await sink.frames()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return (frames, files.sorted(), await dispositionCollector.values())
    }

    private static func fixtureCascade() -> SuppressionCascade {
        SuppressionCascade(
            secureEventInput: FixtureSecureEventInput(),
            axSecureSubrole: FixtureAXSubrole(),
            denylist: FixtureDenylist(),
            blackedRegion: FixtureBlackRegion(),
            knownSafeAppBundles: ["com.example.app"]
        )
    }

    private static func isTombstone(_ frame: Data) -> Bool {
        frame.count >= 4 && frame[2] == 0x11 && frame[3] == 0
    }

    private static func keyframeHash(_ frame: Data) -> [UInt8] {
        let offset = minFrameHeaderBytes + 8 + 8 + ocrEventAppBundleIdLen + 2 + 2 + 4
        precondition(frame.count >= offset + ocrEventKeyframeHashLen)
        return Array(frame[offset ..< offset + ocrEventKeyframeHashLen])
    }

    private static func makePixelBuffer() -> CVPixelBuffer {
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            32,
            32,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &output
        )
        precondition(status == kCVReturnSuccess)
        guard let output else { preconditionFailure("missing pixel buffer") }
        CVPixelBufferLockBaseAddress(output, [])
        if let base = CVPixelBufferGetBaseAddress(output) {
            memset(base, 0x7f, CVPixelBufferGetDataSize(output))
        }
        CVPixelBufferUnlockBaseAddress(output, [])
        return output
    }
}

private actor FixtureDispositionCollector {
    private var recorded: [OCRPostAllowDisposition] = []

    func append(_ value: OCRPostAllowDisposition) { recorded.append(value) }
    func count() -> Int { recorded.count }
    func values() -> [OCRPostAllowDisposition] { recorded }
}

private actor FixtureOrdinalCollector {
    private var recorded: [Int] = []

    func append(_ value: Int) { recorded.append(value) }
    func values() -> [Int] { recorded }
}

private actor BlockingOCREngine: OCREngine {
    private var calls = 0
    private var firstCallStarted = false
    private var firstCallRelease: CheckedContinuation<Void, Never>?

    func recognize(input _: OCREngineInput, timeoutMs _: Int) async -> OCRResult {
        calls += 1
        if calls == 1 {
            firstCallStarted = true
            await withCheckedContinuation { continuation in
                firstCallRelease = continuation
            }
        }
        return .empty
    }

    func waitUntilFirstCallStarts() async {
        while !firstCallStarted {
            await Task.yield()
        }
    }

    func releaseFirstCall() {
        firstCallRelease?.resume()
        firstCallRelease = nil
    }
}

private struct FixtureOCREngine: OCREngine {
    let result: OCRResult

    func recognize(input _: OCREngineInput, timeoutMs _: Int) async -> OCRResult {
        result
    }
}

private actor SequencedOCREngine: OCREngine {
    private let results: [OCRResult]
    private var calls = 0

    init(results: [OCRResult]) {
        precondition(!results.isEmpty)
        self.results = results
    }

    func recognize(input _: OCREngineInput, timeoutMs _: Int) async -> OCRResult {
        let index = min(calls, results.count - 1)
        calls += 1
        return results[index]
    }

    func callCount() -> Int { calls }
}

private actor FixtureFrameSink: FrameSink {
    private var recorded: [Data] = []

    func write(_ bytes: Data) {
        recorded.append(bytes)
    }

    func count() -> Int { recorded.count }
    func frames() -> [Data] { recorded }
}

private struct FixtureSecureEventInput: SecureEventInputProbe {
    func isSecureEventInputEnabled() -> Bool { false }
}

private struct FixtureAXSubrole: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { false }
}

private struct FixtureDenylist: DenylistProbe {
    func appIsDenied(bundleId _: String) -> Bool { false }
    func urlIsDenied(_: String) -> Bool { false }
    func windowTitleIsDenied(_: String) -> Bool { false }
}

private struct FixtureBlackRegion: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}
