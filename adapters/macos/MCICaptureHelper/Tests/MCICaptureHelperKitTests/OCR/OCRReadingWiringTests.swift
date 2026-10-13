import CoreGraphics
import Foundation
import XCTest

@testable import MCICaptureHelperKit

/// How the reading gets its inputs: the worker's pane separators, the
/// whole-screen window's place in the frame, and what assembly costs.
final class OCRReadingWiringTests: XCTestCase {
    private static let line = #"{"text": "Weekly review", "confidence": 0.95, "box": [0.1, 0.5, 0.4, 0.05]}"#

    func testWorkerSeparatorsAreMappedFromTheReadRegionToTheFrame() throws {
        let reply = Data(#"{"version": 1, "lines": [\#(Self.line)], "separators": [[0.5, 0.0, 0.0, 1.0], [0.0, 0.25, 1.0, 0.0]]}"#.utf8)
        let region = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        let result = try XCTUnwrap(PaddleOCRRunner.decode(reply, region: region))
        XCTAssertEqual(result.recognizedLines.count, 1)
        XCTAssertEqual(result.separators, [CGRect(x: 0.75, y: 0, width: 0, height: 0.5),
                                           CGRect(x: 0.5, y: 0.125, width: 0.5, height: 0)])
    }

    func testAWorkerWithoutSeparatorsStillReads() throws {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let plain = try XCTUnwrap(PaddleOCRRunner.decode(Data(#"{"version": 1, "lines": [\#(Self.line)]}"#.utf8),
                                                         region: unit))
        XCTAssertEqual(plain.recognizedLines.map(\.text), ["Weekly review"])
        XCTAssertEqual(plain.separators, [])
        // A malformed list or entry costs the separators, never the lines.
        for separators in [#""edges""#, #"[[0.5, 0.0, 0.0]]"#, #"[[0.5, 0.0, 0.3, 0.4]]"#, #"[[0.5, 0.0, 0.0, 0.0]]"#] {
            let reply = Data(#"{"version": 1, "lines": [\#(Self.line)], "separators": \#(separators)}"#.utf8)
            let result = try XCTUnwrap(PaddleOCRRunner.decode(reply, region: unit), separators)
            XCTAssertEqual(result.recognizedLines.map(\.text), ["Weekly review"], separators)
            XCTAssertEqual(result.separators, [], separators)
        }
    }

    func testOnlyAWindowWithNothingInFrontOwnsTheFramesSeparators() {
        func window(_ id: CGWindowID, _ bundle: String, _ rect: CGRect) -> VisibleWindow {
            VisibleWindow(windowId: id, bundleId: bundle, title: nil, bounds: rect, layer: 0)
        }
        let front = window(1, "com.example.notes", CGRect(x: 0, y: 0, width: 800, height: 600))
        let behind = window(2, "com.example.mail", CGRect(x: 400, y: 300, width: 800, height: 600))
        let beside = window(3, "com.example.chat", CGRect(x: 1300, y: 0, width: 400, height: 400))
        let touching = window(4, "com.example.files", CGRect(x: 800, y: 0, width: 200, height: 200))
        let browser = window(5, "com.example.browser", CGRect(x: 1250, y: 0, width: 800, height: 800))
        let windows = [front, browser, behind, beside, touching]
        let excluded: Set<String> = ["com.example.browser"]
        XCTAssertFalse(BackgroundCapturePolicy.isCovered(front, windows: windows, excludedBundleIds: excluded))
        XCTAssertTrue(BackgroundCapturePolicy.isCovered(behind, windows: windows, excludedBundleIds: excluded))
        // A browser left out of the pixels covers nothing.
        XCTAssertFalse(BackgroundCapturePolicy.isCovered(beside, windows: windows, excludedBundleIds: excluded))
        // Sharing an edge is not covering.
        XCTAssertFalse(BackgroundCapturePolicy.isCovered(touching, windows: [front, touching], excludedBundleIds: []))
        // Not listed: when unsure, no separators.
        XCTAssertTrue(BackgroundCapturePolicy.isCovered(touching, windows: [front], excludedBundleIds: []))
    }

    /// Assembly beside recognition: recognition of a window costs hundreds of
    /// milliseconds to seconds of CPU. Debug builds, as tests run, are several
    /// times slower than the shipped helper.
    func testAssemblyCostOnLargeFramesStaysSmallBesideRecognition() throws {
        // The largest fixture frame: the realistic editor window.
        let fixture = try OCRReadingOrderTests.fixture("window_editor")
        let editor = Self.timed {
            _ = OCRReadingOrder.read(fixture.ocrLines, pixelSize: fixture.pixelSize,
                                     separators: fixture.separatorRects, window: fixture.geometry)
        }
        // 4,096 boxes, the worker's limit: a dense sheet on a 5K display with a
        // sidebar, rows of short cells and a status bar.
        var lines: [OCRLine] = []
        let width = 5120.0, height = 2880.0
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double = 20) -> CGRect {
            CGRect(x: x / width, y: 1 - (y + h) / height, width: w / width, height: h / height)
        }
        for row in 0..<63 {
            lines.append(OCRLine(text: "Sheet \(row + 1)", boundingBox: box(20, 120 + Double(row) * 42, 120),
                                 confidence: 0.95))
            for column in 0..<64 where lines.count < 4_090 {
                lines.append(OCRLine(text: "\(row * 64 + column)", boundingBox: box(300 + Double(column) * 74,
                                                                                   120 + Double(row) * 42, 50),
                                     confidence: 0.95))
            }
        }
        for (i, item) in ["Ready", "Sum: 1,284", "Count: 12", "Average: 3.4", "100%", "Sheet1"].enumerated() {
            lines.append(OCRLine(text: item, boundingBox: box(300 + Double(i) * 600, 2850, 140), confidence: 0.95))
        }
        XCTAssertEqual(lines.count, 4_096)
        let geometry = OCRWindowGeometry(rect: CGRect(x: 0, y: 0, width: 1, height: 1), pixelsPerPoint: 2,
                                         title: "Budget", bundleId: "com.example.sheets")
        var reading: OCRReadingOrder.Reading?
        let dense = Self.timed {
            reading = OCRReadingOrder.read(lines, pixelSize: CGSize(width: width, height: height), window: geometry)
        }
        XCTAssertEqual(reading?.classified, true)
        // Every number is still stored, in place or as chrome.
        let stored = reading?.stored ?? ""
        XCTAssertTrue(stored.contains("3967"))
        // Content-free: sizes and times only.
        print("ocr-reading cost: window_editor \(fixture.lines.count) boxes \(Int(editor * 1_000)) ms; "
            + "dense sheet \(lines.count) boxes \(Int(dense * 1_000)) ms (debug build)")
        XCTAssertLessThan(editor, 0.5)
        XCTAssertLessThan(dense, 8)
    }

    /// The best of three runs, in seconds of wall time.
    static func timed(_ work: () -> Void) -> Double {
        (0..<3).map { _ in
            let start = DispatchTime.now().uptimeNanoseconds
            work()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        }.min() ?? 0
    }
}
