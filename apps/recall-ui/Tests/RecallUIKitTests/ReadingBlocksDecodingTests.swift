import XCTest
@testable import RecallUIKit

/// A moment's text as blocks, as the FFI's reading carries them (SPEC 4.2):
/// every block the brain writes reads whole here, and Copy Text copies what
/// the brain's own `plain_text` gives, byte for byte.
final class ReadingBlocksDecodingTests: XCTestCase {
    /// The brain's golden blocks (`core/brain/tests/fixtures/reading/blocks/`).
    static let goldens = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // RecallUIKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // recall-ui
        .deletingLastPathComponent() // apps
        .deletingLastPathComponent() // the repository
        .appendingPathComponent("core/brain/tests/fixtures/reading/blocks")

    func testEveryGoldenReadsWholeAndCopiesAsTheBrainCopiesIt() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.goldens.path)
            .filter { $0.hasSuffix(".blocks.json") }
            .sorted()
        XCTAssertGreaterThanOrEqual(names.count, 26)
        for name in names {
            let blocks = try JSONDecoder().decode([ReadingBlock].self,
                                                  from: Data(contentsOf: Self.goldens.appendingPathComponent(name)))
            XCTAssertFalse(blocks.isEmpty, name)
            for block in blocks {
                if case let .other(kind, _) = block { XCTFail("\(name): a \(kind) block did not read") }
            }
            let plain = try String(contentsOf: Self.goldens.appendingPathComponent(
                name.replacingOccurrences(of: ".blocks.json", with: ".plain.txt")), encoding: .utf8)
            XCTAssertEqual(ReadingBlocks.plainText(blocks) + "\n", plain, name)
        }
    }

    func testEachKindReadsAsTheBrainWritesIt() throws {
        let json = #"""
        [{"kind": "label", "text": "MONEY & ROUNDING"},
         {"kind": "heading", "level": 1, "text": "Rounding half to even"},
         {"kind": "byline", "text": "Priya Raman · Oct 12, 2026"},
         {"kind": "paragraph", "text": "Round half up looks fair."},
         {"kind": "list", "items": [{"marker": "☑", "text": "Merged", "checked": true},
                                    {"marker": "-", "text": "Nested", "depth": 1}]},
         {"kind": "code", "text": "let x = 1;"},
         {"kind": "terminal", "text": "$ ls\nfile", "prompts": [0]},
         {"kind": "table", "rows": [["Plan", "Price"], ["Ride", "$0"]], "numeric": [false, true]},
         {"kind": "lines", "lines": ["Breakfast", "Lunch"]},
         {"kind": "lines", "lines": ["1042 $1,240.00"], "table": true},
         {"kind": "turn", "speaker": "Jordan Lee", "time": "2:14 PM", "text": "staging is green"},
         {"kind": "quote", "text": "> looks right"},
         {"kind": "meta", "text": "to me"}]
        """#
        let blocks = try JSONDecoder().decode([ReadingBlock].self, from: Data(json.utf8))
        XCTAssertEqual(blocks, [
            .label("MONEY & ROUNDING"),
            .heading(level: 1, text: "Rounding half to even"),
            .byline("Priya Raman · Oct 12, 2026"),
            .paragraph("Round half up looks fair."),
            .list([ReadingListItem(marker: "☑", text: "Merged", checked: true),
                   ReadingListItem(marker: "-", text: "Nested", depth: 1)]),
            .code("let x = 1;"),
            .terminal(text: "$ ls\nfile", prompts: [0]),
            .table(rows: [["Plan", "Price"], ["Ride", "$0"]], numeric: [false, true]),
            .lines(["Breakfast", "Lunch"], table: false),
            .lines(["1042 $1,240.00"], table: true),
            .turn(speaker: "Jordan Lee", time: "2:14 PM", text: "staging is green"),
            .quote("> looks right"),
            .meta("to me"),
        ])
        XCTAssertEqual(blocks[4].plain, "☑ Merged\n  - Nested")
        XCTAssertEqual(blocks[7].plain, "Plan\tPrice\nRide\t$0")
        XCTAssertEqual(blocks[10].plain, "Jordan Lee 2:14 PM\nstaging is green")
    }

    func testAKindThisWindowDoesNotKnowKeepsItsText() throws {
        let block = try JSONDecoder().decode(ReadingBlock.self, from: Data(#"{"kind": "poem", "text": "staging is green"}"#.utf8))
        XCTAssertEqual(block, .other(kind: "poem", text: "staging is green"))
        XCTAssertEqual(block.text, "staging is green", "nothing that was read is dropped")
    }

    func testABlockMissingItsPartsKeepsWhatTextItHasAndNeverCostsTheReading() throws {
        let json = #"[{"kind": "list", "text": "• Merged"}, {"kind": "turn", "text": "hello"}, {"kind": "heading", "text": "Goals"}]"#
        let blocks = try JSONDecoder().decode([ReadingBlock].self, from: Data(json.utf8))
        XCTAssertEqual(blocks, [.other(kind: "list", text: "• Merged"), .other(kind: "turn", text: "hello"),
                                .heading(level: 2, text: "Goals")])
    }

    func testAReadingWithoutBlocksIsOneBlockOfItsText() {
        XCTAssertEqual(ReadingBlocks.fallback(main: "Plans\nPick the plan that fits your rides."),
                       [.paragraph("Plans\nPick the plan that fits your rides.")])
        let code = "func main() {\n    let x = 1\n}"
        XCTAssertEqual(ReadingBlocks.fallback(main: code), [.code(code)], "code, as the detail always drew it")
        XCTAssertEqual(ReadingBlocks.fallback(main: ""), [])
        XCTAssertEqual(ReadingBlocks.fallback(main: " \n\t"), [])
    }

    func testTheReadingCarriesItsBlocksAndCopyTextKeepsTheirStructure() throws {
        let json = #"""
        {"event_id":42,"ts_us":1791841000000000,"app_bundle_id":"com.google.Chrome","source_kind":"screen_ocr",
         "main":"Rounding half to even\nRound half up looks fair.\n• Ties go down\n• Ties go up","rest":"Dev Notes",
         "truncated":false,
         "blocks":[{"kind":"heading","level":1,"text":"Rounding half to even"},
                   {"kind":"paragraph","text":"Round half up looks fair."},
                   {"kind":"list","items":[{"marker":"•","text":"Ties go down"},{"marker":"•","text":"Ties go up"}]}]}
        """#
        let reading = try XCTUnwrap(FFIBrainReader.decodeEventReading(Data(json.utf8), eventId: 42))
        XCTAssertEqual(reading.blocks.count, 3)
        XCTAssertEqual(reading.text(includingRest: false),
                       "Rounding half to even\nRound half up looks fair.\n\n• Ties go down\n• Ties go up",
                       "blocks set apart by blank lines, markers as read, no Markdown symbol")
        XCTAssertEqual(reading.text(includingRest: true),
                       "Rounding half to even\nRound half up looks fair.\n\n• Ties go down\n• Ties go up\n\nDev Notes")
    }

    func testBlocksThatCannotBeReadLeaveTheReadingItsText() throws {
        let json = #"""
        {"event_id":42,"ts_us":1,"app_bundle_id":null,"source_kind":"screen_ocr","main":"Launch plan",
         "rest":"","truncated":false,"blocks":"not blocks"}
        """#
        let reading = try XCTUnwrap(FFIBrainReader.decodeEventReading(Data(json.utf8), eventId: 42))
        XCTAssertEqual(reading.blocks, [])
        XCTAssertEqual(reading.text(includingRest: false), "Launch plan")
    }

    func testNoBlockEverShowsTheSeparator() throws {
        let reading = try EventReading(eventId: 7, tsUs: 5, appBundleId: nil, sourceKind: "screen_ocr",
                                       main: "Plans", rest: "", isTruncated: false,
                                       blocks: [.paragraph("Plans\u{1E}Pricing"), .lines(["a\u{1E}b"], table: false)])
        XCTAssertEqual(reading.blocks, [.paragraph("Plans Pricing"), .lines(["a b"], table: false)])
        let empty = try EventReading(eventId: 7, tsUs: 5, appBundleId: nil, sourceKind: "screen_ocr",
                                     main: "", rest: "", isTruncated: false, blocks: [.paragraph("x")])
        XCTAssertEqual(empty.blocks, [], "no main, no blocks")
    }

    /// The FFI's reading repeats `main` in its blocks, with the structure it
    /// adds: the bound the window accepts covers both at their largest, and
    /// mirrors the brain's own limits.
    func testTheReadingBoundCoversItsBlocksAsTheBrainBoundsThem() throws {
        let escapedMain = (EventText.maxUTF8Bytes + 1024) * 6
        XCTAssertGreaterThanOrEqual(EventReading.maxJSONBytes,
                                    escapedMain * 2 + ReadingBlocks.maxStructureBytes + 512 + 2048)
        let rust = try String(contentsOf: Self.goldens
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("src/reading_blocks.rs"), encoding: .utf8)
        XCTAssertTrue(rust.contains("pub const MAX_ELEMENTS: usize = 2_000;"))
        XCTAssertTrue(rust.contains("pub const MAX_STRUCTURE_BYTES: usize = MAX_ELEMENTS * 64 + 1024;"))
        XCTAssertEqual(ReadingBlocks.maxElements, 2_000)
        XCTAssertEqual(ReadingBlocks.maxStructureBytes, 2_000 * 64 + 1024)
    }
}
