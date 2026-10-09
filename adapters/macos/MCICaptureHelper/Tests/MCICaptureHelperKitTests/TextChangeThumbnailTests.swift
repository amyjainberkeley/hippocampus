import CoreVideo
import XCTest
@testable import MCICaptureHelperKit

final class TextChangeThumbnailTests: XCTestCase {
    /// A white 2880×1800 BGRA frame with dark rectangles, standing in for text.
    private func frame(_ ink: [(x: Int, y: Int, w: Int, h: Int)]) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2880, 1800, kCVPixelFormatType_32BGRA, nil, &created),
                       kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, 0xFF, stride * 1800)
        for rect in ink {
            for y in rect.y..<(rect.y + rect.h) {
                memset(base + y * stride + rect.x * 4, 0x20, rect.w * 4)
            }
        }
        return buffer
    }

    func testThumbnailIsQuarterScaleLuma() throws {
        let thumbnail = try XCTUnwrap(TextChangeThumbnail.make(from: try frame([(0, 0, 8, 8)])))
        XCTAssertEqual(thumbnail.width, 720)
        XCTAssertEqual(thumbnail.height, 450)
        XCTAssertEqual(thumbnail.luma[0], 0x20)
        XCTAssertEqual(thumbnail.luma[1], 0x20)
        XCTAssertEqual(thumbnail.luma[2], 0xFF)
    }

    func testTypedWordsCrossTheThresholdAndACaretBlinkDoesNot() throws {
        let page = [(200, 200, 1600, 28), (200, 260, 1400, 28)]
        let baseline = try XCTUnwrap(TextChangeThumbnail.make(from: try frame(page)))
        // Two new 14 pt words at Retina scale on the next line.
        let typed = try XCTUnwrap(TextChangeThumbnail.make(from: try frame(page + [(200, 320, 90, 28), (310, 320, 120, 28)])))
        // A caret: 2 px wide, a line tall.
        let caret = try XCTUnwrap(TextChangeThumbnail.make(from: try frame(page + [(1604, 260, 2, 28)])))
        let words = try XCTUnwrap(typed.changedPixels(since: baseline))
        let blink = try XCTUnwrap(caret.changedPixels(since: baseline))
        XCTAssertGreaterThanOrEqual(words, TextCatchUpPolicy.changedPixelThreshold)
        XCTAssertLessThan(blink, TextCatchUpPolicy.changedPixelThreshold)
        XCTAssertTrue(TextCatchUpPolicy.shouldRead(changedPixels: words, sinceBaselineUs: 3_000_000))
        XCTAssertFalse(TextCatchUpPolicy.shouldRead(changedPixels: blink, sinceBaselineUs: 60_000_000))
    }

    func testCatchUpIsSpacedAndNeedsComparableFrames() {
        XCTAssertFalse(TextCatchUpPolicy.shouldRead(changedPixels: 10_000, sinceBaselineUs: 2_999_999))
        XCTAssertFalse(TextCatchUpPolicy.shouldRead(changedPixels: nil, sinceBaselineUs: 60_000_000))
        let small = TextChangeThumbnail(width: 2, height: 1, luma: [0, 0])
        let large = TextChangeThumbnail(width: 1, height: 2, luma: [0, 0])
        XCTAssertNil(small.changedPixels(since: large))
        XCTAssertEqual(small.changedPixels(since: small), 0)
    }

    func testOtherPixelFormatsAreNotSampled() throws {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &created)
        XCTAssertNil(TextChangeThumbnail.make(from: try XCTUnwrap(created)))
    }
}
