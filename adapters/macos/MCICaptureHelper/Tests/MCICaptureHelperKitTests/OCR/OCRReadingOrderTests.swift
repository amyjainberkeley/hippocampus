import CoreGraphics
import XCTest
@testable import MCICaptureHelperKit

/// Pins the Swift reading-order assembly to `tools/ocr/screens/layout.py`.
/// Fixtures are real PaddleOCR boxes from the synthetic screen benchmark
/// (fabricated text only); `.expected.txt` is the reference output.
final class OCRReadingOrderTests: XCTestCase {
    private struct Fixture: Decodable {
        let width: Double
        let height: Double
        let lines: [Line]
        struct Line: Decodable {
            let text: String
            let confidence: Float
            let box: [Double]
        }
    }

    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/OCRReadingOrder")

    private func lines(_ fixture: Fixture) -> [OCRLine] {
        fixture.lines.map {
            OCRLine(text: $0.text,
                    boundingBox: CGRect(x: $0.box[0], y: $0.box[1], width: $0.box[2], height: $0.box[3]),
                    confidence: $0.confidence)
        }
    }

    func testMatchesReferenceOnEveryBenchmarkScreen() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path)
            .filter { $0.hasSuffix(".expected.txt") }
            .map { String($0.dropLast(".expected.txt".count)) }
            .sorted()
        XCTAssertEqual(names.count, 8)
        for name in names {
            let fixture = try JSONDecoder().decode(
                Fixture.self, from: Data(contentsOf: Self.directory.appendingPathComponent("\(name).json")))
            let expected = try String(
                contentsOf: Self.directory.appendingPathComponent("\(name).expected.txt"), encoding: .utf8)
            let text = OCRMemoryText.make(
                from: lines(fixture), pixelSize: CGSize(width: fixture.width, height: fixture.height))
            XCTAssertEqual(text, expected, name)
        }
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
