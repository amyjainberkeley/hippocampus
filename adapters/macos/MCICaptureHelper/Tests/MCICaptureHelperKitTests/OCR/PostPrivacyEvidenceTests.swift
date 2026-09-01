import CoreVideo
import Foundation
import MCIKeyframeCodec
import XCTest

@testable import MCICaptureHelperKit

final class PostPrivacyEvidenceTests: XCTestCase {
    func testOCRSecretNeverInvokesRetention() async {
        let retainer = CountingRetainer()
        let sink = RecordingSink()

        await drive(
            result: result(text: "password: private"),
            sink: sink,
            retainer: retainer
        )

        let retainCount = await retainer.retainCount()
        let frames = await sink.frames()
        XCTAssertEqual(retainCount, 0)
        XCTAssertTrue(frames.first.map(isTombstone) == true)
    }

    func testTimedOutOCRNeverInvokesRetentionAndEmitsZeroHash() async {
        let retainer = CountingRetainer()
        let sink = RecordingSink()

        await drive(
            result: OCRResult(recognizedLines: [], durationMs: 1_000, timedOut: true),
            sink: sink,
            retainer: retainer
        )

        let retainCount = await retainer.retainCount()
        let frames = await sink.frames()
        XCTAssertEqual(retainCount, 0)
        XCTAssertEqual(frames.first.flatMap(keyframeHash), zeroHash)
    }

    func testFieldOverflowIsValidatedBeforeRetention() async {
        let retainer = CountingRetainer()
        let sink = RecordingSink()

        await drive(
            context: WorkflowContext(
                appBundleId: "com.example.app",
                windowTitle: String(repeating: "w", count: Int(UInt16.max) + 1)
            ),
            result: result(text: "clean"),
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

        await drive(
            result: result(text: "clean"),
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

        await drive(
            result: result(text: "clean"),
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
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await self.drive(
                result: self.result(text: "clean"),
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

    private func drive(
        context: WorkflowContext = WorkflowContext(appBundleId: "com.example.app"),
        result: OCRResult,
        sink: any FrameSink,
        retainer: any KeyframeRetaining
    ) async {
        await CascadeTwiceOCREmitter.handleOCRResult(
            tsUs: 1,
            context: context,
            result: result,
            cascade: allowCascade(),
            sink: sink,
            sequence: FrameSequence(),
            counters: HelperHealthCounters(),
            pixelBuffer: makePixelBuffer(),
            keyframeRetainer: retainer,
            evidenceCandidate: KeyframeEvidenceCandidate(
                captureOrdinal: 1,
                focusedWindowId: 7,
                dhash: DHash(bits: 0),
                monotonicNanoseconds: 1
            )
        )
    }

    private func result(text: String) -> OCRResult {
        OCRResult(
            recognizedLines: [OCRLine(text: text, boundingBox: .zero, confidence: 1)],
            durationMs: 1,
            timedOut: false
        )
    }

    private func allowCascade() -> SuppressionCascade {
        SuppressionCascade(
            secureEventInput: NoSecureEventInputForEvidence(),
            axSecureSubrole: NonSecureAXForEvidence(),
            denylist: EmptyDenylistForEvidence(),
            blackedRegion: NoBlackRegionForEvidence(),
            knownSafeAppBundles: ["com.example.app"]
        )
    }

    private func makePixelBuffer() -> CVPixelBuffer {
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
