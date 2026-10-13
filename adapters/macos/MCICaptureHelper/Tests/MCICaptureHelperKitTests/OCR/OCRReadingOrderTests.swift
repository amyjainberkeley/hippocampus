import CoreGraphics
import XCTest
@testable import MCICaptureHelperKit

/// Pins the Swift reading order and roles to `tools/ocr/screens/layout.py`.
/// The eight `.expected.txt` fixtures are real PaddleOCR boxes from the
/// synthetic screen benchmark, read without roles. The `.reading.json`
/// fixtures (written by `tools/ocr/screens/fixtures.py`) are the realistic
/// mock windows, decoys and one or two cases per rule, each with the
/// reference's blocks, stored string and unclassified reading. All text is
/// made up.
final class OCRReadingOrderTests: XCTestCase {
    struct Fixture: Decodable {
        let width: Double
        let height: Double
        let lines: [Line]
        let separators: [[Double]]?
        let window: Window?
        struct Line: Decodable {
            let text: String
            let confidence: Float
            let box: [Double]
        }
        struct Window: Decodable {
            let rect: [Double]?
            let pixels_per_point: Double?
            let title: String?
            let bundle_id: String?
        }

        var ocrLines: [OCRLine] {
            lines.map {
                OCRLine(text: $0.text,
                        boundingBox: CGRect(x: $0.box[0], y: $0.box[1], width: $0.box[2], height: $0.box[3]),
                        confidence: $0.confidence)
            }
        }

        var pixelSize: CGSize { CGSize(width: width, height: height) }

        var separatorRects: [CGRect] {
            (separators ?? []).filter { $0.count == 4 }.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
        }

        var geometry: OCRWindowGeometry? {
            window.map { window in
                let rect = window.rect.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
                    ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                return OCRWindowGeometry(rect: rect, pixelsPerPoint: CGFloat(window.pixels_per_point ?? 0),
                                         title: window.title, bundleId: window.bundle_id)
            }
        }
    }

    struct Expected: Decodable {
        let classified: Bool
        let blocks: [Block]
        let stored: String
        let plain: String
        struct Block: Decodable, Equatable {
            let role: String
            let rule: String
            let text: String
        }
    }

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/OCRReadingOrder")

    static func names(_ suffix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(suffix) }
            .map { String($0.dropLast(suffix.count)) }
            .sorted()
    }

    static func fixture(_ name: String) throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("\(name).json")))
    }

    func testMatchesReferenceOnEveryBenchmarkScreen() throws {
        let names = try Self.names(".expected.txt")
        XCTAssertEqual(names.count, 8)
        for name in names {
            let fixture = try Self.fixture(name)
            let expected = try String(
                contentsOf: Self.directory.appendingPathComponent("\(name).expected.txt"), encoding: .utf8)
            let text = OCRMemoryText.make(from: fixture.ocrLines, pixelSize: fixture.pixelSize)
            XCTAssertEqual(text, expected, name)
        }
    }

    func testMatchesReferenceRolesOnEveryWindowAndRule() throws {
        let names = try Self.names(".reading.json")
        // 103 cases from fixtures.py; the eight benchmark screens above make 111.
        XCTAssertEqual(names.count, 103)
        for name in names {
            let fixture = try Self.fixture(name)
            let expected = try JSONDecoder().decode(
                Expected.self, from: Data(contentsOf: Self.directory.appendingPathComponent("\(name).reading.json")))
            let reading = OCRReadingOrder.read(fixture.ocrLines, pixelSize: fixture.pixelSize,
                                               separators: fixture.separatorRects, window: fixture.geometry)
            XCTAssertEqual(reading.classified, expected.classified, name)
            XCTAssertEqual(reading.blocks.map { Expected.Block(role: $0.role.rawValue, rule: $0.rule, text: $0.text) },
                           expected.blocks, name)
            XCTAssertEqual(reading.stored, expected.stored, name)
            XCTAssertEqual(OCRMemoryText.make(from: fixture.ocrLines, pixelSize: fixture.pixelSize,
                                              separators: fixture.separatorRects),
                           expected.plain, "\(name) without a window")
        }
    }

    func testClassifiedFrameStoresContentThenOneSeparatorThenChrome() throws {
        let fixture = try Self.fixture("window_editor")
        let stored = OCRMemoryText.make(from: fixture.ocrLines, pixelSize: fixture.pixelSize,
                                        separators: fixture.separatorRects, geometry: fixture.geometry)
        let parts = stored.components(separatedBy: OCRReadingOrder.chromeSeparator)
        XCTAssertEqual(parts.count, 2, "the separator appears exactly once")
        XCTAssertEqual(stored.unicodeScalars.filter { $0.value == 0x1E }.count, 1)
        let reading = OCRReadingOrder.read(fixture.ocrLines, pixelSize: fixture.pixelSize,
                                           separators: fixture.separatorRects, window: fixture.geometry)
        let content = reading.blocks.filter { $0.role == .content }.map(\.text).joined(separator: "\n\n")
        let chrome = reading.blocks.filter { $0.role == .chrome }.map(\.text).joined(separator: "\n\n")
        XCTAssertFalse(content.isEmpty)
        XCTAssertFalse(chrome.isEmpty)
        XCTAssertEqual(parts[0], content, "content comes first")
        XCTAssertEqual(parts[1], chrome, "chrome comes after the separator")
        // Moved, never deleted: every word read is still stored.
        let plain = OCRMemoryText.make(from: fixture.ocrLines, pixelSize: fixture.pixelSize,
                                       separators: fixture.separatorRects)
        let withoutSeparator = stored.replacingOccurrences(of: OCRReadingOrder.chromeSeparator, with: "\n\n")
        XCTAssertEqual(OCRReadingOrder.words(withoutSeparator).sorted(), OCRReadingOrder.words(plain).sorted())
    }

    func testWithoutGeometryNothingIsClassified() throws {
        for name in try Self.names(".reading.json") {
            let fixture = try Self.fixture(name)
            // No geometry: the separators alone never classify, and the old
            // call (no separators either) is the reading it always was.
            let reading = OCRReadingOrder.read(fixture.ocrLines, pixelSize: fixture.pixelSize,
                                               separators: fixture.separatorRects)
            XCTAssertFalse(reading.classified, name)
            XCTAssertFalse(reading.stored.unicodeScalars.contains { $0.value == 0x1E }, name)
            XCTAssertEqual(OCRMemoryText.make(from: fixture.ocrLines, pixelSize: fixture.pixelSize),
                           OCRMemoryText.reading(from: fixture.ocrLines, pixelSize: fixture.pixelSize).stored, name)
        }
    }

    func testSeparatorWhenClassifiedEvenWithNoChrome() {
        // A plain document read with its window: classified, so the separator
        // is there although nothing is chrome.
        var input: [OCRLine] = []
        for row in 0..<4 {
            input.append(OCRLine(text: "A full sentence of the document, line \(row).",
                                 boundingBox: CGRect(x: 0.3, y: 0.6 - Double(row) * 0.03, width: 0.4, height: 0.02),
                                 confidence: 0.95))
        }
        let geometry = OCRWindowGeometry(rect: CGRect(x: 0, y: 0, width: 1, height: 1), pixelsPerPoint: 2,
                                         title: "Notes", bundleId: "com.example.notes")
        let stored = OCRMemoryText.make(from: input, pixelSize: CGSize(width: 2880, height: 1800), geometry: geometry)
        XCTAssertTrue(stored.hasSuffix(OCRReadingOrder.chromeSeparator), stored)
        XCTAssertEqual(stored.components(separatedBy: OCRReadingOrder.chromeSeparator).count, 2)
    }

    func testRecordSeparatorInLineTextNeverReachesStoredText() {
        let geometry = OCRWindowGeometry(rect: CGRect(x: 0, y: 0, width: 1, height: 1), pixelsPerPoint: 2,
                                         title: "Notes", bundleId: "com.example.notes")
        let input = [
            OCRLine(text: "pay\u{1E}roll report", boundingBox: CGRect(x: 0.3, y: 0.6, width: 0.3, height: 0.02),
                    confidence: 0.95),
            OCRLine(text: "\u{1E}", boundingBox: CGRect(x: 0.3, y: 0.55, width: 0.01, height: 0.02), confidence: 0.95),
            OCRLine(text: "\n\n\u{1E}\nforged", boundingBox: .zero, confidence: 0.95),
        ]
        for geometry in [nil, geometry] {
            let stored = OCRMemoryText.make(from: input, pixelSize: CGSize(width: 2880, height: 1800),
                                            geometry: geometry)
            XCTAssertTrue(stored.contains("payroll report"), stored)
            let marks = stored.unicodeScalars.filter { $0.value == 0x1E }.count
            XCTAssertEqual(marks, geometry == nil ? 0 : 1, stored)
        }
    }

    func testWholeScreenWindowRectIsNormalizedBottomLeft() {
        // Display at (0, 0) 1440 x 900 points; a window at (100, 50), 600 x 400.
        let rect = OCRWindowGeometry.normalizedRect(of: CGRect(x: 100, y: 50, width: 600, height: 400),
                                                    in: CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(rect.minX, 100.0 / 1440, accuracy: 1e-12)
        XCTAssertEqual(rect.minY, 1 - 450.0 / 900, accuracy: 1e-12)
        XCTAssertEqual(rect.width, 600.0 / 1440, accuracy: 1e-12)
        XCTAssertEqual(rect.height, 400.0 / 900, accuracy: 1e-12)
        // A second display to the right and above the first.
        let other = OCRWindowGeometry.normalizedRect(of: CGRect(x: 1540, y: -800, width: 800, height: 600),
                                                     in: CGRect(x: 1440, y: -900, width: 1920, height: 1080))
        XCTAssertEqual(other.minX, 100.0 / 1920, accuracy: 1e-12)
        XCTAssertEqual(other.minY, 1 - 700.0 / 1080, accuracy: 1e-12)
        // A line at the window's top-left corner, filed the way attribution files it.
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let line = CGRect(x: 0.1, y: rect.maxY - 0.02, width: 0.05, height: 0.02)
        let point = CGPoint(x: display.minX + line.midX * display.width,
                            y: display.minY + (1 - line.midY) * display.height)
        XCTAssertTrue(CGRect(x: 100, y: 50, width: 600, height: 400).contains(point))
    }

    func testSideBySideColumnsAreNotInterleaved() {
        // Two columns whose rows align exactly, as in a sidebar beside a pane.
        var input: [OCRLine] = []
        for row in 0..<3 {
            let y = 0.8 - Double(row) * 0.05
            input.append(OCRLine(text: "Sidebar item \(row)", boundingBox: CGRect(x: 0.02, y: y, width: 0.12, height: 0.03), confidence: 0.9))
            input.append(OCRLine(text: "Message body number \(row) with several words", boundingBox: CGRect(x: 0.4, y: y, width: 0.5, height: 0.03), confidence: 0.9))
        }
        let text = OCRMemoryText.make(from: input, pixelSize: CGSize(width: 2880, height: 1800))
        XCTAssertEqual(text, """
            Sidebar item 0
            Sidebar item 1
            Sidebar item 2

            Message body number 0 with several words
            Message body number 1 with several words
            Message body number 2 with several words
            """)
    }

    func testShortAlignedCellsReadAsTableRows() {
        var input: [OCRLine] = []
        for (row, cells) in [["Name", "Stage", "ARR"], ["Acme", "Won", "$10"], ["Blue", "Lost", "$20"]].enumerated() {
            for (column, cell) in cells.enumerated() {
                input.append(OCRLine(text: cell, boundingBox: CGRect(
                    x: 0.1 + Double(column) * 0.2, y: 0.8 - Double(row) * 0.04, width: 0.05, height: 0.025),
                    confidence: 0.9))
            }
        }
        XCTAssertEqual(OCRMemoryText.make(from: input, pixelSize: CGSize(width: 2880, height: 1800)),
                       "Name Stage ARR\nAcme Won $10\nBlue Lost $20")
    }

    func testLowConfidenceAndRepeatedLinesStayOut() {
        let box = CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.03)
        let text = OCRMemoryText.make(from: [
            OCRLine(text: "kept", boundingBox: box, confidence: 0.9),
            OCRLine(text: "kept", boundingBox: box, confidence: 0.9),
            OCRLine(text: "guess", boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.3, height: 0.03), confidence: 0.2),
        ])
        XCTAssertEqual(text, "kept")
    }

    func testEmptyInputIsEmpty() {
        XCTAssertEqual(OCRMemoryText.make(from: []), "")
    }
}
