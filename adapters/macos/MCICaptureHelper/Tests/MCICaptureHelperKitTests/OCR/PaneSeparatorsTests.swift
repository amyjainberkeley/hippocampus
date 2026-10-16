import CoreGraphics
import CoreVideo
@testable import MCICaptureHelperKit
import XCTest

/// `PaneSeparators` is a port of the OCR worker's `pane_separators`
/// (tools/ocr/worker.py). Every expected separator here is what the worker
/// returns for the same picture: flat grey rectangles, whose grey level
/// OpenCV and vImage both read as the rectangle's value.
final class PaneSeparatorsTests: XCTestCase {
    /// A top band, a hairline, a hairline broken for 3 pixels (closed) and one
    /// broken for 5 (not closed, so only its longer part counts).
    private static let panes = Picture(width: 400, height: 300, background: 255, rects: [
        (0, 0, 400, 60, 240), (100, 0, 1, 300, 200), (300, 0, 1, 150, 200), (300, 153, 1, 147, 200),
        (350, 0, 1, 100, 200), (350, 105, 1, 195, 200),
    ])

    func testSeparatorsAreTheWorkersForTheSamePicture() throws {
        let buffer = try Self.panes.pixelBuffer()
        let (gray, region) = try XCTUnwrap(PaneSeparators.gray(buffer, roi: CGRect(x: 0, y: 0, width: 1, height: 1)))
        XCTAssertEqual(region, CGRect(x: 0, y: 0, width: 1, height: 1))
        let edges = PaneSeparators.edges(gray, half: false)
        let separators = PaneSeparators.separators(edges, boxes: [], width: 400, height: 300)
        // worker.pane_separators(image, [], half=False)
        assertEqual(separators, [
            CGRect(x: 0.0, y: 0.8, width: 1.0, height: 0.0),
            CGRect(x: 0.25, y: 0.0, width: 0.0, height: 1.0),
            CGRect(x: 0.75, y: 0.0, width: 0.0, height: 1.0),
            CGRect(x: 0.875, y: 0.0, width: 0.0, height: 0.6466666666666666),
        ])
    }

    func testAnEdgeATextBoxCrossesIsNoSeparator() throws {
        let buffer = try Self.panes.pixelBuffer()
        let (gray, _) = try XCTUnwrap(PaneSeparators.gray(buffer, roi: CGRect(x: 0, y: 0, width: 1, height: 1)))
        let boxes = [CGRect(x: 90, y: 200, width: 30, height: 20), CGRect(x: 10, y: 55, width: 40, height: 15)]
        let separators = PaneSeparators.separators(PaneSeparators.edges(gray, half: false), boxes: boxes,
                                                   width: 400, height: 300)
        // worker.pane_separators(image, [[90, 200, 120, 220], [10, 55, 50, 70]], half=False)
        assertEqual(separators, [
            CGRect(x: 0.75, y: 0.0, width: 0.0, height: 1.0),
            CGRect(x: 0.875, y: 0.0, width: 0.0, height: 0.6466666666666666),
        ])
    }

    func testARetinaFrameIsExaminedAtHalfSizeAndATwoPixelRuleIsOneSeparator() throws {
        let picture = Picture(width: 1200, height: 800, background: 255,
                              rects: [(0, 0, 300, 800, 245), (300, 100, 900, 2, 220)])
        let (gray, _) = try XCTUnwrap(PaneSeparators.gray(try picture.pixelBuffer(),
                                                          roi: CGRect(x: 0, y: 0, width: 1, height: 1)))
        let separators = PaneSeparators.separators(PaneSeparators.edges(gray, half: true), boxes: [],
                                                   width: 1200, height: 800)
        // worker.pane_separators(image, [], half=True)
        assertEqual(separators, [
            CGRect(x: 0.25166666666666665, y: 0.875, width: 0.7483333333333333, height: 0.0),
            CGRect(x: 0.25, y: 0.0, width: 0.0, height: 1.0),
        ])
    }

    func testARegionsSeparatorsAreInTheFramesSpace() throws {
        let picture = Picture(width: 400, height: 300, background: 255, rects: [(200, 0, 1, 300, 200)])
        let input = OCREngineInput(pixelBuffer: try picture.pixelBuffer(),
                                   roi: CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        let layout = try XCTUnwrap(PaneLayout(input: input))
        XCTAssertEqual(layout.region, CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        // The worker, sent the same crop, finds [0.5, 0, 0, 1] in it.
        assertEqual(layout.separators(crossing: []), [CGRect(x: 0.5, y: 0, width: 0, height: 1)])
    }

    func testPanesCutAtEdgesThatSpanWhatTheyDivideBarsFirst() throws {
        let (gray, _) = try XCTUnwrap(PaneSeparators.gray(try Self.panes.pixelBuffer(),
                                                          roi: CGRect(x: 0, y: 0, width: 1, height: 1)))
        let panes = PaneSeparators.panes(PaneSeparators.edges(gray, half: false), width: 400, height: 300,
                                         minimum: 24)
        // The band splits off first; both halves split at the full-height
        // hairlines. The broken one spans too little of either to cut.
        XCTAssertEqual(panes, [
            CGRect(x: 0, y: 0, width: 100, height: 60), CGRect(x: 100, y: 0, width: 200, height: 60),
            CGRect(x: 300, y: 0, width: 100, height: 60),
            CGRect(x: 0, y: 60, width: 100, height: 240), CGRect(x: 100, y: 60, width: 200, height: 240),
            CGRect(x: 300, y: 60, width: 100, height: 240),
        ])
    }

    func testAVisionReadCarriesTheSeparatorsNoLineCrosses() async throws {
        // One line straddles the hairline at x = 100 (0.25 of the width).
        let line = OCRLine(text: "spans two panes", boundingBox: CGRect(x: 0.2, y: 0.3, width: 0.1, height: 0.05),
                           confidence: 0.9)
        let runner = VisionOCRRunner(synchronousRegionPerform: { _, _, _ in [line] })
        let result = await runner.recognize(
            input: OCREngineInput(pixelBuffer: try Self.panes.pixelBuffer(),
                                  roi: CGRect(x: 0, y: 0, width: 1, height: 1)),
            timeoutMs: 30_000)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.recognizedLines, [line])
        assertEqual(result.separators, [
            CGRect(x: 0.0, y: 0.8, width: 1.0, height: 0.0),
            CGRect(x: 0.75, y: 0.0, width: 0.0, height: 1.0),
            CGRect(x: 0.875, y: 0.0, width: 0.0, height: 0.6466666666666666),
        ])
    }

    func testAnEmptyReadCarriesNoSeparators() async throws {
        let runner = VisionOCRRunner(synchronousRegionPerform: { _, _, _ in [] })
        let result = await runner.recognize(
            input: OCREngineInput(pixelBuffer: try Self.panes.pixelBuffer(),
                                  roi: CGRect(x: 0, y: 0, width: 1, height: 1)),
            timeoutMs: 30_000)
        XCTAssertEqual(result.recognizedLines, [])
        XCTAssertEqual(result.separators, [])
    }

    private func assertEqual(_ actual: [CGRect], _ expected: [CGRect], file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "\(actual)", file: file, line: line)
        for (a, e) in zip(actual, expected) {
            for (x, y) in [(a.minX, e.minX), (a.minY, e.minY), (a.width, e.width), (a.height, e.height)] {
                XCTAssertEqual(x, y, accuracy: 1e-12, "\(actual)", file: file, line: line)
            }
        }
    }
}

/// A BGRA picture of flat grey rectangles on a background.
private struct Picture {
    let width: Int
    let height: Int
    let background: UInt8
    let rects: [(x: Int, y: Int, w: Int, h: Int, value: UInt8)]

    func pixelBuffer() throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &made)
            == kCVReturnSuccess, let buffer = made else { throw PictureError.buffer }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        func fill(_ x: Int, _ y: Int, _ value: UInt8) {
            let pixel = base + y * rowBytes + x * 4
            pixel[0] = value
            pixel[1] = value
            pixel[2] = value
            pixel[3] = 255
        }
        for y in 0..<height { for x in 0..<width { fill(x, y, background) } }
        for rect in rects {
            for y in rect.y..<(rect.y + rect.h) { for x in rect.x..<(rect.x + rect.w) { fill(x, y, rect.value) } }
        }
        return buffer
    }

    enum PictureError: Error { case buffer }
}
