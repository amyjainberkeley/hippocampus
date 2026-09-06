import CoreMedia
import CoreVideo
import XCTest
@testable import MCICaptureHelperKit

final class CaptureActivityWiringTests: XCTestCase {
    private struct Activity: UserActivityReading {
        let seconds: TimeInterval?
        func secondsSinceLastInput() -> TimeInterval? { seconds }
    }

    func testExtractorSuppressesIdleAndUnavailableReadingsWithoutInventingActivity() throws {
        let buffer = try makeBuffer()
        for seconds: TimeInterval? in [60, 600, nil, -1, .infinity, .nan] {
            let sample = try XCTUnwrap(SCStreamCaptureSession.extractSynchronously(
                from: buffer, activityReader: Activity(seconds: seconds)
            ))
            XCTAssertTrue(sample.userIdle)
        }
    }

    func testFreshInputReopensTheExistingFilterButDoesNotAssertAttention() throws {
        let buffer = try makeBuffer()
        for seconds in [0.0, 59.99] {
            let sample = try XCTUnwrap(SCStreamCaptureSession.extractSynchronously(
                from: buffer, activityReader: Activity(seconds: seconds)
            ))
            XCTAssertFalse(sample.userIdle)
        }
    }

    private func makeBuffer() throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, 9, 8, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
        ), kCVReturnSuccess)
        let pixels = try XCTUnwrap(pixelBuffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixels, []), kCVReturnSuccess)
        memset(CVPixelBufferGetBaseAddress(pixels), 0, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &description
        ), noErr)
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels,
            formatDescription: try XCTUnwrap(description), sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ), noErr)
        return try XCTUnwrap(sampleBuffer)
    }
}
