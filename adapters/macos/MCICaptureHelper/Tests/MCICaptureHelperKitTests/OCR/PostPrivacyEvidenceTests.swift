import CoreVideo
import Foundation
import MCIKeyframeCodec
import XCTest

@testable import MCICaptureHelperKit

final class PostPrivacyEvidenceTests: XCTestCase {
    func testSupplementalMultilineSecretPreservesRepeatedLabelBeforeRetention() async {
        let password = OCRLine(text: "password", boundingBox: CGRect(x: 0.02, y: 0.92, width: 0.08, height: 0.03), confidence: 1)
        let valueBox = CGRect(x: 0.02, y: 0.88, width: 0.04, height: 0.02)
        var accumulated = OCRLineAccumulator()
        for line in [password, OCRLine(text: "\"deno", boundingBox: valueBox, confidence: 1),
                     OCRLine(text: "Review notes", boundingBox: CGRect(x: 0.6, y: 0.4, width: 0.2, height: 0.03), confidence: 1)] {
            accumulated.append(line)
        }
        accumulated.append(password)
        accumulated.append(OCRLine(text: ": demo", boundingBox: valueBox, confidence: 1))
        let result = OCRResult(recognizedLines: accumulated.lines, durationMs: 1, timedOut: false)
        XCTAssertTrue(result.recognizedLines.map(\.text).joined(separator: "\n").contains("password\n: demo"))
        await Self.assertSecretSuppressed(result: result)
    }

    func testOriginalMultilineSecretStaysContiguousBeforeRetention() async {
        var accumulated = OCRLineAccumulator()
        for text in ["password", ": demo"] {
            accumulated.append(OCRLine(text: text, boundingBox: .zero, confidence: 1))
        }
        accumulated.append(OCRLine(text: "Review notes", boundingBox: .zero, confidence: 1))
        await Self.assertSecretSuppressed(result: OCRResult(recognizedLines: accumulated.lines, durationMs: 1, timedOut: false))
    }

    func testCleanSupplementalTextIsEmitted() async {
        var accumulated = OCRLineAccumulator()
        accumulated.append(OCRLine(text: "Review notes", boundingBox: .zero, confidence: 1))
        accumulated.append(OCRLine(text: "Search settings", boundingBox: .zero, confidence: 1))
        let retainer = CountingRetainer()
        let sink = RecordingSink()
        await Self.drive(result: OCRResult(recognizedLines: accumulated.lines, durationMs: 1, timedOut: false), sink: sink, retainer: retainer)
        let frames = await sink.frames()
        let retainCount = await retainer.retainCount()
        XCTAssertEqual(retainCount, 1)
        XCTAssertEqual(frames.count, 1)
        XCTAssertFalse(frames.first.map(isTombstone) ?? true)
        XCTAssertNotNil(frames.first?.range(of: Data("Search settings".utf8)))
    }

    // Shared with the real-Vision synthetic fixture; all probes and pixels are
    // synthetic, but suppression, wire emission, and retention gating are real.
    static func assertSecretSuppressed(result: OCRResult, file: StaticString = #filePath, line: UInt = #line) async {
        let retainer = CountingRetainer()
        let sink = RecordingSink()
        await Self.drive(result: result, sink: sink, retainer: retainer)
        let retainCount = await retainer.retainCount()
        let frames = await sink.frames()
        XCTAssertEqual(retainCount, 0, file: file, line: line)
        XCTAssertEqual(frames.count, 1, file: file, line: line)
        XCTAssertEqual(frames.first.map { $0.count >= 4 && $0[2] == 0x11 && $0[3] == 0 }, true, file: file, line: line)
        XCTAssertEqual(frames.first?.last, RedactionReason.ocrTimeSecret.rawValue, file: file, line: line)
    }

    func testOCRSecretNeverInvokesRetention() async {
        let retainer = CountingRetainer()
        let sink = RecordingSink()

        await Self.drive(
            result: Self.result(text: "password: private"),
            sink: sink,
            retainer: retainer
        )

        let retainCount = await retainer.retainCount()
        let frames = await sink.frames()
        XCTAssertEqual(retainCount, 0)
        XCTAssertTrue(frames.first.map(isTombstone) == true)
    }

    func testTimedOutOCRNeverInvokesRetentionOrPublishesEvidence() async {
        let retainer = CountingRetainer()
        let sink = RecordingSink()

        await Self.drive(
            result: OCRResult(recognizedLines: [], durationMs: 1_000, timedOut: true),
            sink: sink,
            retainer: retainer
        )

        let retainCount = await retainer.retainCount()
        let frames = await sink.frames()
        XCTAssertEqual(retainCount, 0)
        XCTAssertTrue(frames.isEmpty)
    }

    func testFieldOverflowIsValidatedBeforeRetention() async {
        let retainer = CountingRetainer()
        let sink = RecordingSink()

        await Self.drive(
            context: WorkflowContext(
                appBundleId: "com.example.app",
                windowTitle: String(repeating: "w", count: Int(UInt16.max) + 1)
            ),
            result: Self.result(text: "clean"),
            sink: sink,
            retainer: retainer
        )

        let retainCount = await retainer.retainCount()
        let frames = await sink.frames()
        XCTAssertEqual(retainCount, 0)
        XCTAssertTrue(frames.first.map(isTombstone) == true)
    }

    func testCleanOCRPublishesNonzeroHashOnlyAfterRetention() async throws {
        let sealed = try KeyframeBlobCodec.seal(
            plaintext: Data("jpeg".utf8),
            keyMaterial: Data((0..<32).map(UInt8.init))
        )
        let retainer = CountingRetainer(retention: KeyframeRetention(sealedBlob: sealed))
        let sink = RecordingSink()

        await Self.drive(
            result: Self.result(text: "clean"),
            sink: sink,
            retainer: retainer
        )

        let retainCount = await retainer.retainCount()
        let confirmCount = await retainer.confirmCount()
        let frames = await sink.frames()
        XCTAssertEqual(retainCount, 1)
        XCTAssertEqual(confirmCount, 1)
        XCTAssertEqual(frames.first.flatMap(keyframeHash), sealed.digest)
    }

    func testSinkFailureDiscardsBlobAndRetriesZeroHash() async throws {
        let sealed = try KeyframeBlobCodec.seal(
            plaintext: Data("jpeg".utf8),
            keyMaterial: Data((0..<32).map(UInt8.init))
        )
        let retainer = CountingRetainer(retention: KeyframeRetention(sealedBlob: sealed))
        let sink = RecordingSink(failFirstWrite: true)

        await Self.drive(
            result: Self.result(text: "clean"),
            sink: sink,
            retainer: retainer
        )

        let discardCount = await retainer.discardCount()
        let confirmCount = await retainer.confirmCount()
        let frames = await sink.frames()
        XCTAssertEqual(discardCount, 1)
        XCTAssertEqual(confirmCount, 0)
        XCTAssertEqual(frames.first.flatMap(keyframeHash), zeroHash)
    }

    func testCancellationNeverInvokesRetentionAndEmitsZeroHash() async {
        let retainer = CountingRetainer()
        let sink = RecordingSink()
        let task = Task.detached { @Sendable [sink, retainer] in
            withUnsafeCurrentTask { $0?.cancel() }
            await Self.drive(
                result: Self.result(text: "clean"),
                sink: sink,
                retainer: retainer
            )
        }
        await task.value

        let retainCount = await retainer.retainCount()
        let frames = await sink.frames()
        XCTAssertEqual(retainCount, 0)
        XCTAssertEqual(frames.first.flatMap(keyframeHash), zeroHash)
    }

    private var zeroHash: [UInt8] {
        [UInt8](repeating: 0, count: ocrEventKeyframeHashLen)
    }

    private static func drive(
        context: WorkflowContext = WorkflowContext(appBundleId: "com.example.app"),
        result: OCRResult,
        sink: any FrameSink,
        retainer: any KeyframeRetaining
    ) async {
        await CascadeTwiceOCREmitter.handleOCRResult(
            tsUs: 1,
            context: context,
            result: result,
            cascade: Self.allowCascade(),
            sink: sink,
            sequence: FrameSequence(),
            counters: HelperHealthCounters(),
            pixelBuffer: Self.makePixelBuffer(),
            keyframeRetainer: retainer,
            evidenceCandidate: KeyframeEvidenceCandidate(
                captureOrdinal: 1,
                focusedWindowId: 7,
                dhash: DHash(bits: 0),
                monotonicNanoseconds: 1
            )
        )
    }

    private static func result(text: String) -> OCRResult {
        OCRResult(
            recognizedLines: [OCRLine(text: text, boundingBox: .zero, confidence: 1)],
            durationMs: 1,
            timedOut: false
        )
    }

    private static func allowCascade() -> SuppressionCascade {
        SuppressionCascade(
            secureEventInput: NoSecureEventInputForEvidence(),
            axSecureSubrole: NonSecureAXForEvidence(),
            denylist: EmptyDenylistForEvidence(),
            blackedRegion: NoBlackRegionForEvidence(),
            knownSafeAppBundles: ["com.example.app"]
        )
    }

    private static func makePixelBuffer() -> CVPixelBuffer {
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        precondition(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                16,
                16,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &output
            ) == kCVReturnSuccess
        )
        return output!
    }

    private func keyframeHash(_ frame: Data) -> [UInt8]? {
        guard !isTombstone(frame) else { return nil }
        let offset = minFrameHeaderBytes + 8 + 8 + ocrEventAppBundleIdLen + 2 + 2 + 4
        guard frame.count >= offset + ocrEventKeyframeHashLen else { return nil }
        return Array(frame[offset ..< offset + ocrEventKeyframeHashLen])
    }

    private func isTombstone(_ frame: Data) -> Bool {
        frame.count >= 4 && frame[2] == 0x11 && frame[3] == 0
    }
}

private actor RecordingSink: FrameSink {
    private var recorded: [Data] = []
    private var shouldFail: Bool

    init(failFirstWrite: Bool = false) {
        self.shouldFail = failFirstWrite
    }

    func write(_ bytes: Data) throws {
        if shouldFail {
            shouldFail = false
            throw RecordingSinkError.failed
        }
        recorded.append(bytes)
    }

    func frames() -> [Data] { recorded }
}

private enum RecordingSinkError: Error {
    case failed
}

private actor CountingRetainer: KeyframeRetaining {
    private let retention: KeyframeRetention?
    private var retained = 0
    private var confirmed = 0
    private var discarded = 0

    init(retention: KeyframeRetention? = nil) {
        self.retention = retention
    }

    func retain(
        input _: KeyframePixelInput,
        candidate _: KeyframeEvidenceCandidate
    ) -> KeyframeRetention? {
        retained += 1
        return retention
    }

    func confirm(_: KeyframeRetention) {
        confirmed += 1
    }

    func discard(_: KeyframeRetention) {
        discarded += 1
    }

    func retainCount() -> Int { retained }
    func confirmCount() -> Int { confirmed }
    func discardCount() -> Int { discarded }
}

private struct NoSecureEventInputForEvidence: SecureEventInputProbe {
    func isSecureEventInputEnabled() -> Bool { false }
}

private struct NonSecureAXForEvidence: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { false }
}

private struct EmptyDenylistForEvidence: DenylistProbe {
    func appIsDenied(bundleId _: String) -> Bool { false }
    func urlIsDenied(_: String) -> Bool { false }
    func windowTitleIsDenied(_: String) -> Bool { false }
}

private struct NoBlackRegionForEvidence: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}
