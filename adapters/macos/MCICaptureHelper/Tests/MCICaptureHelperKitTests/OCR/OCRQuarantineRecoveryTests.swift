import CoreGraphics
import CoreVideo
import Foundation
import XCTest
@testable import MCICaptureHelperKit

final class OCRQuarantineRecoveryTests: XCTestCase {
    private var previousKillSwitch = false

    override func setUp() {
        super.setUp()
        previousKillSwitch = CascadeTwiceOCREmitter.killOcrEmit
        CascadeTwiceOCREmitter.killOcrEmit = false
    }

    override func tearDown() {
        CascadeTwiceOCREmitter.killOcrEmit = previousKillSwitch
        super.tearDown()
    }

    func testDefaultAvailabilityStartsNoRecognitionAndHonorsCancellation() async {
        let engine = StubOCREngine(mode: .canned(.empty))
        let available = await engine.waitUntilAvailable(timeoutMs: 1_000)
        XCTAssertTrue(available)
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.waitUntilAvailable(timeoutMs: 1_000)
        }.value
        XCTAssertFalse(cancelled)
        XCTAssertEqual(engine.callCount, 0)
    }

    func testStaticFrameRetryWaitsForQuarantineAndRetainsEvidenceExactlyOnce() async throws {
        let fixture = try makeFixture()
        await fixture.submit()
        await fulfillment(of: [fixture.observer.firstTimeout], timeout: 2)
        // The first perform outlives its 100 ms recognition deadline by 20 ms.
        try await Task.sleep(for: .milliseconds(20))
        fixture.perform.release.signal()
        await fulfillment(of: [fixture.finished], timeout: 2)
        await fixture.emitter.stopAndDrain()

        let frames = await fixture.sink.snapshot()
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertEqual(fixture.perform.calls, 2, "The one static-frame retry must reach the engine")
        XCTAssertEqual(fixture.perform.maxConcurrent, 1)
        XCTAssertEqual(fixture.perform.pixelIDs, Array(repeating: ObjectIdentifier(fixture.input.pixelBuffer), count: 2))
        XCTAssertEqual(fixture.perform.regions, Array(repeating: CGRect(x: 0, y: 0, width: 1, height: 1), count: 2))
        XCTAssertEqual(fixture.observer.dispositions, [.finalized])
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(files.count, 1)
        let frame = try XCTUnwrap(frames.first)
        let hashOffset = minFrameHeaderBytes + 8 + 8 + ocrEventAppBundleIdLen + 2 + 2 + 4
        guard frame.count >= hashOffset + ocrEventKeyframeHashLen else {
            return XCTFail("OCR frame must contain its retained evidence hash")
        }
        let hash = Array(frame[hashOffset ..< hashOffset + ocrEventKeyframeHashLen])
        XCTAssertFalse(hash.allSatisfy { $0 == 0 })
        XCTAssertEqual(files, [hash.map { String(format: "%02x", $0) }.joined() + ".bin"])
        let expected = OCREvent(seq: 0, tsUs: 12_345, appBundleId: "com.example.app",
                                windowTitle: "Synthetic static window", url: "", ocrText: "Recovered static text",
                                keyframeHash: hash)
        guard case .success(let expectedFrame) = encodeOCREvent(seq: 0, event: expected) else {
            return XCTFail("Synthetic event must encode")
        }
        XCTAssertEqual(frame, expectedFrame)
        XCTAssertNil(frame.range(of: Data("late first result".utf8)))
        XCTAssertEqual(fixture.observer.waitBudgets, [100])
        XCTAssertEqual(fixture.observer.availability, [true])
    }

    func testRecoveredRetryStillSuppressesSecretBeforeWireAndRetention() async throws {
        let fixture = try makeFixture(retryText: "password: synthetic-secret")
        await fixture.submit()
        await fulfillment(of: [fixture.observer.firstTimeout], timeout: 2)
        try await Task.sleep(for: .milliseconds(20))
        fixture.perform.release.signal()
        await fulfillment(of: [fixture.finished], timeout: 2)
        await fixture.emitter.stopAndDrain()

        let frames = await fixture.sink.snapshot()
        XCTAssertEqual(fixture.perform.calls, 2)
        XCTAssertEqual(fixture.perform.maxConcurrent, 1)
        XCTAssertEqual(fixture.observer.dispositions, [.finalized])
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?[2], 0x11)
        XCTAssertEqual(frames.first?.last, RedactionReason.ocrTimeSecret.rawValue)
        XCTAssertFalse(frames.contains { $0.range(of: Data("synthetic-secret".utf8)) != nil })
        XCTAssertFalse(frames.contains { $0.range(of: Data("late first result".utf8)) != nil })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    func testStopCancelsRecoveryWaitWithoutPublishingOrRetainingLateResult() async throws {
        let fixture = try makeFixture(timeoutMs: 1_000)
        await fixture.submit()
        await fulfillment(of: [fixture.observer.recoveryEntered], timeout: 2)
        let stopped = expectation(description: "Recovery wait cancelled")
        let stopping = Task {
            await fixture.emitter.stopAndDrain()
            stopped.fulfill()
        }
        let stopResult = await XCTWaiter.fulfillment(of: [stopped], timeout: 0.2)
        XCTAssertEqual(stopResult, .completed, "Stopping must not spend the 1000 ms recovery budget")
        if stopResult != .completed { fixture.perform.release.signal() }
        await stopping.value
        XCTAssertEqual(fixture.observer.availability, [false])
        XCTAssertTrue(fixture.observer.waitWasCancelled)
        XCTAssertEqual(fixture.perform.calls, 1)
        fixture.perform.release.signal()
        let idle = await fixture.runner.waitUntilIdle(timeoutMs: 2_000)
        XCTAssertTrue(idle)
        let frames = await fixture.sink.snapshot()
        XCTAssertTrue(frames.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    func testPermanentQuarantineExhaustsOnlyExistingRetryWithinBound() async throws {
        let fixture = try makeFixture()
        await fixture.submit()
        let finished = await XCTWaiter.fulfillment(of: [fixture.finished], timeout: 1)
        XCTAssertEqual(finished, .completed, "A hung perform must not make the cached retry unbounded")
        await fixture.emitter.stopAndDrain()
        XCTAssertEqual(fixture.perform.calls, 1, "Quarantine must not admit another synchronous perform")
        XCTAssertEqual(fixture.perform.maxConcurrent, 1)
        XCTAssertEqual(fixture.observer.recognitionCalls, 2, "Do not add retries beyond the emitter's existing one")
        XCTAssertEqual(fixture.observer.dispositions, [.retryableNoContent])
        XCTAssertEqual(fixture.observer.waitBudgets.first, 100)
        XCTAssertEqual(fixture.observer.availability.first, false)
        let stillBlocked = await fixture.runner.waitUntilIdle(timeoutMs: 0)
        XCTAssertFalse(stillBlocked)
        fixture.perform.release.signal()
        let idle = await fixture.runner.waitUntilIdle(timeoutMs: 2_000)
        XCTAssertTrue(idle)
        let frames = await fixture.sink.snapshot()
        XCTAssertTrue(frames.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    private func makeFixture(timeoutMs: Int = 100, retryText: String = "Recovered static text") throws -> RecoveryFixture {
        let fixture = try RecoveryFixture(timeoutMs: timeoutMs, retryText: retryText)
        addTeardownBlock {
            await fixture.emitter.stopAndDrain()
            fixture.perform.release.signal()
            let idle = await fixture.runner.waitUntilIdle(timeoutMs: 2_000)
            XCTAssertTrue(idle, "Synthetic perform must drain without another recognition probe")
            try FileManager.default.removeItem(at: fixture.root)
        }
        return fixture
    }
}

private final class RecoveryFixture: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-quarantine-\(UUID().uuidString)")
    let perform: LingeringPerform
    let runner: VisionOCRRunner
    let observer = RecoveryObserver()
    let sink = RecoveryFrameSink()
    let worker: VisionOCRWorker
    let emitter: CascadeTwiceOCREmitter
    let input: OCREngineInput
    let finished = XCTestExpectation(description: "Static frame finalized")

    init(timeoutMs: Int, retryText: String) throws {
        perform = LingeringPerform(retryText: retryText)
        runner = VisionOCRRunner(synchronousPerform: perform.run)
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferCGImageCompatibilityKey: true,
                                         kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 0x7f, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        input = OCREngineInput(pixelBuffer: pixels, roi: CGRect(x: 0, y: 0, width: 0.1, height: 0.1))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let retainer = KeyframeRetentionCoordinator(blobDirectory: root, keyMaterial: Data((0..<32).map(UInt8.init)),
                                                   policy: KeyframePolicy(materialDistance: 12, maxSilenceNanoseconds: 300))
        worker = VisionOCRWorker(engine: ObservedRecoveryEngine(runner: runner, observer: observer), timeoutMs: timeoutMs)
        emitter = CascadeTwiceOCREmitter(
            worker: worker,
            cascade: SuppressionCascade(secureEventInput: RecoveryPrivacy(), axSecureSubrole: RecoveryPrivacy(),
                                        denylist: RecoveryPrivacy(), blackedRegion: RecoveryPrivacy(),
                                        knownSafeAppBundles: ["com.example.app"]),
            sink: sink, sequence: FrameSequence(), counters: HelperHealthCounters(), keyframeRetainer: retainer
        )
    }

    func submit() async {
        await worker.start()
        await emitter.processAfterAllow(
            captureOrdinal: 1, tsUs: 12_345,
            context: WorkflowContext(appBundleId: "com.example.app", windowTitle: "Synthetic static window"),
            input: input,
            evidenceCandidate: KeyframeEvidenceCandidate(captureOrdinal: 1, focusedWindowId: 7,
                                                         dhash: DHash(bits: 0), monotonicNanoseconds: 1),
            disposition: { [observer, finished] value in
                observer.recordDisposition(value)
                finished.fulfill()
            }
        )
    }
}

private final class LingeringPerform: @unchecked Sendable {
    private let lock = NSLock()
    private let retryText: String
    private var active = 0
    private var maximumActive = 0
    private var inputs: [(ObjectIdentifier, CGRect)] = []
    let release = DispatchSemaphore(value: 0)

    init(retryText: String) { self.retryText = retryText }
    var calls: Int { lock.withLock { inputs.count } }
    var maxConcurrent: Int { lock.withLock { maximumActive } }
    var pixelIDs: [ObjectIdentifier] { lock.withLock { inputs.map(\.0) } }
    var regions: [CGRect] { lock.withLock { inputs.map(\.1) } }

    func run(_ input: OCREngineInput, _ languages: [String]) -> OCRResult {
        let ordinal = lock.withLock {
            inputs.append((ObjectIdentifier(input.pixelBuffer), input.roi))
            active += 1
            maximumActive = max(maximumActive, active)
            return inputs.count
        }
        defer { lock.withLock { active -= 1 } }
        if ordinal == 1 { release.wait() }
        return OCRResult(recognizedLines: [OCRLine(text: ordinal == 1 ? "late first result" : retryText,
                                                  boundingBox: .zero, confidence: 1)], durationMs: 0, timedOut: false)
    }
}

private struct ObservedRecoveryEngine: OCREngine {
    let runner: VisionOCRRunner
    let observer: RecoveryObserver

    func recognize(input: OCREngineInput, timeoutMs: Int) async -> OCRResult {
        let result = await runner.recognize(input: input, timeoutMs: timeoutMs)
        observer.recordRecognition(result)
        return result
    }

    func waitUntilAvailable(timeoutMs: Int) async -> Bool {
        observer.recordWait(timeoutMs)
        let available = await runner.waitUntilAvailable(timeoutMs: timeoutMs)
        observer.recordAvailability(available, cancelled: Task.isCancelled)
        return available
    }
}

private final class RecoveryObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var results = 0
    private var budgets: [Int] = []
    private var available: [Bool] = []
    private var cancelled = false
    private var finalized: [OCRPostAllowDisposition] = []
    let firstTimeout = XCTestExpectation(description: "First recognition timed out")
    let recoveryEntered = XCTestExpectation(description: "Worker entered recovery wait")

    var recognitionCalls: Int { lock.withLock { results } }
    var waitBudgets: [Int] { lock.withLock { budgets } }
    var availability: [Bool] { lock.withLock { available } }
    var waitWasCancelled: Bool { lock.withLock { cancelled } }
    var dispositions: [OCRPostAllowDisposition] { lock.withLock { finalized } }

    func recordRecognition(_ result: OCRResult) {
        let first = lock.withLock { results += 1; return results == 1 }
        if first && result.timedOut { firstTimeout.fulfill() }
    }
    func recordWait(_ budget: Int) {
        let first = lock.withLock { budgets.append(budget); return budgets.count == 1 }
        if first { recoveryEntered.fulfill() }
    }
    func recordAvailability(_ value: Bool, cancelled: Bool) {
        lock.withLock { available.append(value); self.cancelled = self.cancelled || cancelled }
    }
    func recordDisposition(_ value: OCRPostAllowDisposition) { lock.withLock { finalized.append(value) } }
}

private actor RecoveryFrameSink: FrameSink {
    private var frames: [Data] = []
    func write(_ bytes: Data) { frames.append(bytes) }
    func snapshot() -> [Data] { frames }
}

private struct RecoveryPrivacy: SecureEventInputProbe, AXSecureSubroleProbe, DenylistProbe, BlackedRegionProbe {
    func isSecureEventInputEnabled() -> Bool { false }
    func focusedHasSecureSubrole() -> Bool? { false }
    func appIsDenied(bundleId: String) -> Bool { false }
    func urlIsDenied(_ url: String) -> Bool { false }
    func windowTitleIsDenied(_ title: String) -> Bool { false }
    func hasBlackedRegion() -> Bool { false }
}
