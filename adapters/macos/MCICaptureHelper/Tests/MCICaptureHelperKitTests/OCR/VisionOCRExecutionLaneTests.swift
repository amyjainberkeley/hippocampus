import CoreVideo
import XCTest
@testable import MCICaptureHelperKit

final class VisionOCRExecutionLaneTests: XCTestCase {
    /// The lane once woke the caller before freeing itself, so the caller's
    /// very next job found it occupied and failed as an instant timeout. Live,
    /// that lost nearly every frame after the first.
    func testBackToBackJobsNeverSeeAnOccupiedLane() async throws {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA, nil, &created)
        let input = OCREngineInput(pixelBuffer: try XCTUnwrap(created), roi: CGRect(x: 0, y: 0, width: 1, height: 1))
        let lane = VisionOCRExecutionLane(label: "test.lane") { _, _, _ in
            OCRResult(recognizedLines: [OCRLine(text: "ok", boundingBox: .zero, confidence: 1)],
                      durationMs: 0, timedOut: false)
        }
        for attempt in 0..<200 {
            let result = await lane.recognize(input: input, languages: [], timeoutMs: 5_000)
            XCTAssertFalse(result.timedOut, "attempt \(attempt) found the lane occupied")
            XCTAssertEqual(result.recognizedLines.map(\.text), ["ok"])
        }
    }
}
