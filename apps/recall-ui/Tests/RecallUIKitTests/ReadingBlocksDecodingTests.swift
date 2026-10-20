import XCTest
@testable import RecallUIKit

/// A moment's text as blocks, as the FFI's reading carries them (SPEC 4.2),
/// and a reading that carries none drawn as one paragraph of its text.
final class ReadingBlocksDecodingTests: XCTestCase {
    func testBlocksReadAsTheFFIWritesThem() throws {
        let json = #"[{"kind": "paragraph", "text": "Round half up looks fair."}, {"kind": "heading", "level": 1, "text": "Rounding"}]"#
        let blocks = try JSONDecoder().decode([ReadingBlock].self, from: Data(json.utf8))
        XCTAssertEqual(blocks, [.paragraph("Round half up looks fair."), .other(kind: "heading", text: "Rounding")])
        XCTAssertEqual(blocks.map(\.text), ["Round half up looks fair.", "Rounding"])
    }

    func testAKindThisWindowDoesNotDrawYetKeepsItsText() throws {
        let block = try JSONDecoder().decode(ReadingBlock.self, from: Data(#"{"kind": "turn", "text": "staging is green"}"#.utf8))
        XCTAssertEqual(block.text, "staging is green", "nothing that was read is dropped")
    }

    func testAReadingWithoutBlocksIsOneParagraphOfItsText() {
        XCTAssertEqual(ReadingBlocks.fallback(main: "Plans\nPick the plan that fits your rides."),
                       [.paragraph("Plans\nPick the plan that fits your rides.")])
        XCTAssertEqual(ReadingBlocks.fallback(main: ""), [])
        XCTAssertEqual(ReadingBlocks.fallback(main: " \n\t"), [])
    }

    /// The FFI's reading now repeats `main` in its blocks: the bound on the
    /// reading the window accepts covers both at their largest.
    func testTheReadingBoundCoversMainAgainInItsBlocks() {
        let escapedMain = (EventText.maxUTF8Bytes + 1024) * 6
        XCTAssertGreaterThanOrEqual(EventReading.maxJSONBytes, escapedMain * 2 + 512 + 2048)
    }
}
