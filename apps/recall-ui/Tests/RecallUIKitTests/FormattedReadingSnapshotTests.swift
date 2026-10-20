import AppKit
import XCTest
@testable import RecallUIKit

/// A moment's formatted text as the reading view draws it (SPEC 4.6): one
/// string, every paragraph with the typography of its block, from design
/// tokens only; code and terminal output in their box; what a selection
/// copies is what was read.
final class FormattedReadingSnapshotTests: XCTestCase {
    private func golden(_ name: String) throws -> [ReadingBlock] {
        try JSONDecoder().decode([ReadingBlock].self, from: Data(contentsOf: ReadingBlocksDecodingTests.goldens
            .appendingPathComponent("\(name).blocks.json")))
    }

    /// The token a color is, by name.
    private func token(_ color: Any?) -> String {
        guard let color = color as? NSColor else { return "none" }
        let named: [(String, NSColor)] = [
            ("foreground", ReadingStyle.foreground), ("secondary", ReadingStyle.secondary),
            ("muted", ReadingStyle.muted), ("accent", ReadingStyle.accent), ("accentDim", ReadingStyle.accentDim),
        ]
        return named.first { $0.1 === color }?.0 ?? "other"
    }

    /// One line per paragraph: its text, then its font, color, line height,
    /// space above and below, and the box or rule it draws.
    private func snapshot(_ built: ReadingAttributedText.Built) -> [String] {
        let string = built.string
        let text = string.string as NSString
        var out: [String] = []
        var location = 0
        while location < text.length {
            let range = text.paragraphRange(for: NSRange(location: location, length: 0))
            let attributes = string.attributes(at: range.location, effectiveRange: nil)
            let font = attributes[.font] as? NSFont
            let style = attributes[.paragraphStyle] as? NSParagraphStyle
            let weight = font.map { NSFontManager.shared.weight(of: $0) >= 8 ? " semibold" : "" } ?? ""
            let mono = font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true ? " mono" : ""
            var line = text.substring(with: range).trimmingCharacters(in: .newlines)
            if line.count > 24 { line = String(line.prefix(24)) + "…" }
            var described = "\(line) | \(Int(font?.pointSize ?? 0))\(weight)\(mono) \(token(attributes[.foregroundColor]))"
            described += " h\(Int(style?.minimumLineHeight ?? 0)) +\(Int(style?.paragraphSpacingBefore ?? 0))"
            described += "/\(Int(style?.paragraphSpacing ?? 0))"
            if let box = attributes[.readingBox] as? String { described += " box:\(box)" }
            if attributes[.readingRule] != nil { described += " rule" }
            if let level = attributes[.readingHeading] as? Int { described += " heading:\(level)" }
            out.append(described)
            location = NSMaxRange(range)
        }
        return out
    }

    func testTheArticleIsDrawnAsTheSpecAndThePrototypeDrawIt() throws {
        let built = ReadingAttributedText.make(try golden("article.new"))
        XCTAssertEqual(snapshot(built), [
            "MONEY & ROUNDING | 11 semibold muted h19 +0/0",
            "Rounding half to even | 17 semibold foreground h21 +2/0 heading:1",
            "Why banker’s rounding ke… | 14 foreground h19 +4/0",
            "Priya Raman · Oct 12, 20… | 12 secondary h16 +4/0",
            "Round half up looks fair… | 14 foreground h19 +10/0",
            "Round half to even sends… | 14 foreground h19 +10/0",
            "round_half_even(2.5)   /… | 12 mono foreground h18 +20/0 box:first",
            "round_half_even(3.5)   /… | 12 mono foreground h18 +0/10 box:last",
            "Most payment processors … | 14 foreground h19 +10/0",
            "Next: Currency math with… | 14 foreground h19 +10/0",
        ])
        XCTAssertEqual(built.topInset, 0)
    }

    func testCodeIsColoredAsCodeAndCopiesByteForByte() throws {
        let built = ReadingAttributedText.make([.code("round_half_even(2.5)   // 2.0")])
        let string = built.string
        let text = string.string as NSString
        let number = text.range(of: "2.5")
        let comment = text.range(of: "// 2.0")
        XCTAssertEqual(token(string.attribute(.foregroundColor, at: number.location, effectiveRange: nil)), "accentDim")
        XCTAssertEqual(token(string.attribute(.foregroundColor, at: comment.location, effectiveRange: nil)), "muted")
        XCTAssertEqual(built.topInset, 10, "a reading that opens with a box keeps the box's padding above it")
        XCTAssertEqual(ReadingAttributedText.copiedText(of: string, in: NSRange(location: 0, length: string.length)),
                       "round_half_even(2.5)   // 2.0")
        let rust = ReadingAttributedText.make([.code("pub fn total() -> Money {\n    let tax = 1;\n}")]).string
        let let_ = (rust.string as NSString).range(of: "let")
        XCTAssertEqual(token(rust.attribute(.foregroundColor, at: let_.location, effectiveRange: nil)), "accent",
                       "a block's language is told from all of it, so every line's keywords color")
    }

    func testATerminalsPromptLinesAreBrightItsOutputQuietAndItsMarkersCopyAsRead() {
        let read = "dev@studio shop % claude\n\u{23FA} Update(src/tax.rs)\n  \u{23BF} Updated src/tax.rs"
        let built = ReadingAttributedText.make([.terminal(text: read, prompts: [0])])
        let string = built.string
        XCTAssertEqual(token(string.attribute(.foregroundColor, at: 0, effectiveRange: nil)), "foreground")
        let output = (string.string as NSString).range(of: "Update")
        XCTAssertEqual(token(string.attribute(.foregroundColor, at: output.location, effectiveRange: nil)), "secondary")
        XCTAssertTrue(string.string.contains("\u{2022} Update"), "drawn as a plain bullet")
        XCTAssertEqual(ReadingAttributedText.copiedText(of: string, in: NSRange(location: 0, length: string.length)), read,
                       "copied as read")
    }

    func testAChecklistIsDrawnBoxesThatCopyAsTheMarkersRead() throws {
        let built = ReadingAttributedText.make([.list([
            ReadingListItem(marker: "[x]", text: "Rounding fix merged", checked: true),
            ReadingListItem(marker: "\u{2610}", text: "Gift card copy reviewed", checked: false),
            ReadingListItem(marker: "\u{2022}", text: "Wrapped\nunder it"),
        ])])
        let string = built.string
        XCTAssertNotNil(string.attribute(.attachment, at: 0, effectiveRange: nil), "a drawn box")
        XCTAssertEqual(ReadingAttributedText.copiedText(of: string, in: NSRange(location: 0, length: string.length)),
                       "[x] Rounding fix merged\n\u{2610} Gift card copy reviewed\n\u{2022} Wrapped\nunder it")
        let style = try XCTUnwrap(string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.headIndent, 18, "a hanging indent: wrapped lines line up under the text")
        XCTAssertEqual(style.firstLineHeadIndent, 0)
        let group = string.attribute(.readingGroup, at: 0, effectiveRange: nil) as? String
        XCTAssertEqual(group, "list:0:3", "VoiceOver's rotor reads it as a list of three")
        XCTAssertEqual(ReadingCopy.list(items: 3), "List, 3 items")
    }

    func testALongQuoteIsClosedUntilItIsOpened() {
        let quote = (1...8).map { "> line \($0)" }.joined(separator: "\n")
        let blocks: [ReadingBlock] = [.paragraph("Thanks."), .quote(quote)]
        let closed = ReadingAttributedText.make(blocks).string.string
        XCTAssertTrue(closed.contains(ReadingCopy.earlierInThread))
        XCTAssertFalse(closed.contains("line 1"), "longer than six lines: closed")
        let open = ReadingAttributedText.make(blocks, expandedQuotes: [1]).string
        XCTAssertTrue(open.string.contains("line 8"))
        XCTAssertFalse(open.string.contains("> line"), "drawn with a rule, not the marks")
        let first = (open.string as NSString).range(of: "line 1")
        XCTAssertEqual(open.attribute(.readingQuote, at: first.location, effectiveRange: nil) as? String, "first")
        let copied = ReadingAttributedText.copiedText(of: open, in: NSRange(location: 0, length: open.length))
        XCTAssertTrue(copied.contains("> line 1\n> line 2"), "copied with its marks: \(copied)")
        XCTAssertFalse(copied.contains(ReadingCopy.earlierInThread))
        let short = ReadingAttributedText.make([.quote("> one\n> two")]).string.string
        XCTAssertFalse(short.contains(ReadingCopy.earlierInThread), "six lines or fewer stay open")
        XCTAssertEqual(ReadingAttributedText.quoteIndex(of: ReadingAttributedText.quoteLink(1)), 1)
        XCTAssertNil(ReadingAttributedText.quoteIndex(of: URL(string: "https://devnotes.example/rounding")!))
    }

    func testATableSetsItsColumnsOnTabStopsWithNumbersToTheRight() throws {
        let built = ReadingAttributedText.make([.table(rows: [["Plan", "Price"], ["Ride", "$0"], ["Tour", "$18"]],
                                                        numeric: [false, true])])
        let string = built.string
        let style = try XCTUnwrap(string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.tabStops.map(\.alignment), [.right])
        XCTAssertNotNil(string.attribute(.readingRule, at: 0, effectiveRange: nil), "a hairline under the first row")
        let last = (string.string as NSString).range(of: "Tour")
        XCTAssertNil(string.attribute(.readingRule, at: last.location, effectiveRange: nil), "none under the last")
        XCTAssertEqual(ReadingAttributedText.copiedText(of: string, in: NSRange(location: 0, length: string.length)),
                       "Plan\tPrice\nRide\t$0\nTour\t$18")
    }

    func testAddressesAreLinksInTheAccentAndHeadingsAreMarkedForVoiceOver() throws {
        let built = ReadingAttributedText.make([.heading(level: 2, text: "Read more"),
                                                .paragraph("See https://devnotes.example/rounding for the rest.")])
        let string = built.string
        let address = (string.string as NSString).range(of: "https://devnotes.example/rounding")
        XCTAssertEqual(string.attribute(.link, at: address.location, effectiveRange: nil) as? URL,
                       URL(string: "https://devnotes.example/rounding"))
        XCTAssertEqual(token(string.attribute(.foregroundColor, at: address.location, effectiveRange: nil)), "accent")
        XCTAssertEqual(string.attribute(.readingHeading, at: 0, effectiveRange: nil) as? Int, 2)
        XCTAssertEqual(ReadingCopy.code, "Code")
    }

    func testVoiceOversRotorsListTheHeadingsTheCodeAndTheLists() throws {
        let string = ReadingAttributedText.make(try golden("google-docs.new")).string
        XCTAssertEqual(ReadingAttributedText.rotorItems(.headings, in: string).map(\.label),
                       ["Q4 planning", "Goals", "Owners"])
        XCTAssertEqual(ReadingAttributedText.rotorItems(.lists, in: string).map(\.label), ["List, 4 items"])
        let article = ReadingAttributedText.make(try golden("article.new")).string
        let code = ReadingAttributedText.rotorItems(.code, in: article)
        XCTAssertEqual(code.map(\.label), ["Code"])
        XCTAssertEqual((article.string as NSString).substring(with: code[0].range)
            .trimmingCharacters(in: .newlines), "round_half_even(2.5)   // 2.0\nround_half_even(3.5)   // 4.0")
    }

    func testLinesSplitAsComponentsSplitThem() {
        for text in ["", "a", "a\n", "\n", "\n\n", "a\r\nb", "caf\u{E9}\nna\u{EF}ve\n\n", "one\u{2028}two\nthree",
                     "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\nx", "e\u{301}\n\u{301}x"] {
            XCTAssertEqual(ReadingAttributedText.lines(of: text), text.components(separatedBy: "\n"), text)
        }
    }

    func testEveryColorIsADesignToken() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: ReadingBlocksDecodingTests.goldens.path)
            .filter { $0.hasSuffix(".blocks.json") }
        for name in names {
            let blocks = try JSONDecoder().decode([ReadingBlock].self, from: Data(contentsOf: ReadingBlocksDecodingTests.goldens
                .appendingPathComponent(name)))
            let string = ReadingAttributedText.make(blocks, expandedQuotes: Set(blocks.indices)).string
            string.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: string.length)) { color, range, _ in
                guard color != nil else { return }
                XCTAssertNotEqual(self.token(color), "other", "\(name) at \(range)")
            }
        }
        // The tokens' own values: no yellow, and the window's palette.
        for name in ["foreground", "foregroundSecondary", "foregroundMuted", "accent", "accentDim", "border",
                     "borderStrong", "background"] {
            XCTAssertNotNil(MCI.Color.allTokens.first { $0.name == name }, name)
        }
    }

    func testEveryGoldenSelectedWholeCopiesEveryWordItHolds() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: ReadingBlocksDecodingTests.goldens.path)
            .filter { $0.hasSuffix(".blocks.json") }
        for name in names {
            let blocks = try JSONDecoder().decode([ReadingBlock].self, from: Data(contentsOf: ReadingBlocksDecodingTests.goldens
                .appendingPathComponent(name)))
            let string = ReadingAttributedText.make(blocks, expandedQuotes: Set(blocks.indices)).string
            let copied = ReadingAttributedText.copiedText(of: string, in: NSRange(location: 0, length: string.length))
            let words = { (text: String) in text.split(whereSeparator: \.isWhitespace).map(String.init) }
            let shown = words(copied).filter { $0 != "\u{203A}" && $0 != "\u{2304}" }
            XCTAssertEqual(shown, words(ReadingBlocks.plainText(blocks)), name)
        }
    }

    func testBuildingA64KBReadingStaysWithinItsBudget() throws {
        // SPEC 4.11: the string under 8 ms for a 64 KB reading on an M1, in
        // a release build; a debug build is about ten times slower. The best
        // of three keeps a busy machine from failing it.
        var blocks: [ReadingBlock] = []
        let article = try golden("article.new")
        var size = 0
        while size < 64 * 1024 {
            blocks += article
            size += ReadingBlocks.plainText(article).utf8.count
        }
        let started = { () -> TimeInterval in
            let start = Date()
            _ = ReadingAttributedText.make(blocks)
            return Date().timeIntervalSince(start)
        }
        let best = (0..<3).map { _ in started() }.min() ?? 0
        print("ReadingAttributedText.make of \(size / 1024) KB: best of three \(best * 1000) ms")
        #if DEBUG
        let budget = 0.25
        #else
        let budget = 0.008
        #endif
        XCTAssertLessThan(best, budget, "64 KB took \(best * 1000) ms")
    }
}
