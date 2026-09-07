import CoreGraphics
import CoreVideo
import Foundation
import XCTest

@testable import MCICaptureHelperKit

final class VisionOCRDeadlineTests: XCTestCase {
    func testBlockedPerformDiscardsLateTextAndQuarantinesUntilReturn() async throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA, nil, &buffer
        ), kCVReturnSuccess)
        let input = OCREngineInput(
            pixelBuffer: try XCTUnwrap(buffer),
            roi: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        let perform = BlockingPerform()
        defer { perform.release.signal() }
        let runner = VisionOCRRunner(synchronousPerform: perform.run)

        let completed = XCTestExpectation(description: "OCR deadline returned")
        let pending = Task {
            let result = await runner.recognize(input: input, timeoutMs: 100)
            completed.fulfill()
            return result
        }
        await fulfillment(of: [perform.started], timeout: 2)
        let completion = await XCTWaiter.fulfillment(of: [completed], timeout: 2)
        if completion != .completed { perform.release.signal() }
        XCTAssertEqual(completion, .completed, "Deadline must return while synchronous work is still blocked")
        let timedOut = await pending.value
        XCTAssertTrue(timedOut.timedOut)
        XCTAssertTrue(timedOut.recognizedLines.isEmpty, "A deadline cannot publish incomplete privacy input")

        let quarantined = await runner.recognize(input: input, timeoutMs: 100)
        XCTAssertTrue(quarantined.timedOut)
        XCTAssertTrue(quarantined.recognizedLines.isEmpty)
        XCTAssertEqual(perform.calls, 1, "A timed-out perform still owns the lane")

        perform.release.signal()
        // Probe only admission, without depending on Vision speed or a fixed
        // sleep to guess when the cancellation-insensitive call has returned.
        let deadline = ContinuousClock.now + .seconds(2)
        var recovered = OCRResult.empty
        repeat {
            recovered = await runner.recognize(input: input, timeoutMs: 100)
            if !recovered.timedOut { break }
            try await Task.sleep(for: .milliseconds(5))
        } while ContinuousClock.now < deadline
        XCTAssertFalse(recovered.timedOut)
        XCTAssertEqual(recovered.recognizedLines.map(\.text), ["recovered synthetic text"])
        XCTAssertEqual(perform.calls, 2, "No extra work may queue behind a timed-out perform")
    }

    private final class BlockingPerform: @unchecked Sendable {
        let started = XCTestExpectation(description: "Synchronous OCR entered")
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var count = 0

        var calls: Int { lock.withLock { count } }

        func run(_ input: OCREngineInput, _ languages: [String]) -> OCRResult {
            let ordinal = lock.withLock {
                count += 1
                return count
            }
            if ordinal == 1 {
                started.fulfill()
                release.wait()
            }
            return OCRResult(recognizedLines: [OCRLine(
                text: ordinal == 1 ? "late synthetic text" : "recovered synthetic text",
                boundingBox: input.roi,
                confidence: 1
            )], durationMs: 0, timedOut: false)
        }
    }
}
