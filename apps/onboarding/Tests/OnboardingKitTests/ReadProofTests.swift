import XCTest
@testable import OnboardingKit

final class ReadProofTests: XCTestCase {
    private let names: (String) -> String = { bundle in
        ["com.apple.Notes": "Notes", "com.apple.TextEdit": "TextEdit", "com.tinyspeck.slackmacgap": "Slack"][bundle]
            ?? "Other"
    }

    private func row(
        _ ts: UInt64, _ app: String?, title: String? = "Launch plan",
        kind: String = "screen_ocr", text: String = "We agreed to ship the pricing page next week."
    ) -> ReadRow {
        ReadRow(tsUs: ts, appBundleId: app, windowTitle: title, text: text, sourceKind: kind)
    }

    // MARK: - Lines

    func testOnlySentenceLikeLinesSurviveTheFilter() {
        let text = """
        [app=com.apple.Notes | title=Launch plan | url=? | ts=2026-10-12T21:05:00.000Z]
        com.apple.Notes
        File Edit View Window Help
        Home | Products | Pricing | Contact
        Search
        12:04 PM Today
        Back Forward
        We agreed to ship the pricing page next week.
        Ask Dana about the annual discount before Friday.
        Open com.apple.Safari to see the draft
        \u{1E}
        Sidebar notes about the weekly plan here
        """
        let lines = ReadProof.lines(from: text, windowTitle: "Launch plan")
        XCTAssertEqual(lines, [
            "Ask Dana about the annual discount before Friday.",
            "We agreed to ship the pricing page next week.",
        ])
    }

    func testTheFilterNeverYieldsABundleIdAHeaderOrAShortLine() {
        let hostile = [
            "[app=com.apple.Notes | title=Plan | url=? | ts=2026-10-12T21:05:00.000Z]",
            "the [app=com.apple.Notes | title=x] header inside a line",
            "com.apple.Notes", "com.google.Chrome.canary", "ai.hippocampus",
            "open the com.apple.Notes app now", "three short words",
            "two words", "one", "", "   ", "a b c", "1 2 3 4 5 6",
            "!!! ??? ... ---", "File Edit View Window Help", "OK Cancel Apply Done",
            "version 1.2.3 is out today", "\u{1E} chrome after a record separator here",
        ]
        for combination in [hostile, hostile.reversed(), hostile.shuffled()] {
            let text = combination.joined(separator: "\n")
            for line in ReadProof.lines(from: text, windowTitle: nil) {
                XCTAssertFalse(line.contains("[app="), line)
                XCTAssertFalse(line.split(separator: " ").contains { ReadProof.isDottedIdentifier($0) }, line)
                let words = line.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) }
                XCTAssertGreaterThanOrEqual(words.count, 4, line)
            }
        }
        XCTAssertTrue(ReadProof.lines(from: hostile.joined(separator: "\n"), windowTitle: nil).isEmpty)
    }

    func testTheLongestLinesComeFirstAtMostThreeAndShortened() {
        let long = "This sentence keeps going with more and more words so that it runs well past the ninety character limit for a card"
        let text = [
            "Short but still four words",
            long,
            "A medium sentence with several words in it",
            "Another medium line that has enough words",
            "Short but still four words",
        ].joined(separator: "\n")
        let lines = ReadProof.lines(from: text, windowTitle: nil)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("…"))
        XCTAssertLessThanOrEqual(lines[0].count, ReadProof.maximumLineLength)
        XCTAssertTrue(long.hasPrefix(String(lines[0].dropLast())))
        XCTAssertEqual(lines[1], "A medium sentence with several words in it")
        XCTAssertEqual(lines[2], "Another medium line that has enough words")
    }

    func testTheTitleIsNotRepeatedAsALine() {
        XCTAssertEqual(ReadProof.lines(from: "Notes about the launch plan\n", windowTitle: "Notes about the launch plan"), [])
    }

    // MARK: - Rows

    func testWhenNoLinePassesTheCardShowsTheAppAndTitleAlone() throws {
        let proof = try XCTUnwrap(ReadProof.choose(
            from: [row(5, "com.apple.TextEdit", title: "Untitled", text: "File Edit\nOK")],
            lastActivatedApp: nil, nameFor: names
        ))
        XCTAssertEqual(proof.appName, "TextEdit")
        XCTAssertEqual(proof.windowTitle, "Untitled")
        XCTAssertEqual(proof.lines, [])
        XCTAssertEqual(OnboardingCopy.proofHeading(proof), "TextEdit · Untitled")
    }

    func testTheAppNameIsNeverTheBundleId() throws {
        let proof = try XCTUnwrap(ReadProof.choose(
            from: [row(5, "com.example.QuarterlyPlanner")], lastActivatedApp: nil
        ))
        XCTAssertNotEqual(proof.appName, "com.example.QuarterlyPlanner")
        XCTAssertFalse(proof.appName.contains("."))
    }

    func testRowsFromTheAppLastBroughtForwardComeFirst() throws {
        let rows = [
            row(30, "com.tinyspeck.slackmacgap", title: "general"),
            row(10, "com.apple.Notes"),
            row(20, "com.apple.Notes", text: "The newest note about the plan is here."),
        ]
        let proof = try XCTUnwrap(ReadProof.choose(from: rows, lastActivatedApp: "com.apple.Notes", nameFor: names))
        XCTAssertEqual(proof.appName, "Notes")
        XCTAssertEqual(proof.tsUs, 20)
        XCTAssertEqual(proof.lines, ["The newest note about the plan is here."])
    }

    func testAWindowNobodyClickedIsNotShownWithoutTheFrontApp() throws {
        let rows = [
            row(50, "com.tinyspeck.slackmacgap", kind: "screen_context"),
            row(40, "com.apple.Notes"),
        ]
        let proof = try XCTUnwrap(ReadProof.choose(from: rows, lastActivatedApp: nil, nameFor: names))
        XCTAssertEqual(proof.appName, "Notes")
        XCTAssertNil(ReadProof.choose(from: [rows[0]], lastActivatedApp: "com.apple.TextEdit", nameFor: names))
    }

    func testOtherSourcesAndHippocampusItselfAreNeverAProof() {
        let rows = [
            row(1, "com.apple.Notes", kind: "transcript_import"),
            row(2, "com.apple.Notes", kind: "mcp_resource"),
            row(3, "ai.hippocampus"),
            row(4, nil, text: "No header and no app on this row at all."),
        ]
        XCTAssertNil(ReadProof.choose(from: rows, lastActivatedApp: nil, nameFor: names))
    }

    func testAnOldHeaderSuppliesTheAppAndTitle() throws {
        let text = "[app=com.apple.Notes | title=Launch plan | url=? | ts=2026-10-12T21:05:00.000Z]\nWe agreed to ship the pricing page next week."
        let proof = try XCTUnwrap(ReadProof.choose(
            from: [ReadRow(tsUs: 9, appBundleId: nil, windowTitle: nil, text: text, sourceKind: "screen_ocr")],
            lastActivatedApp: nil, nameFor: names
        ))
        XCTAssertEqual(proof.appBundleId, "com.apple.Notes")
        XCTAssertEqual(proof.windowTitle, "Launch plan")
        XCTAssertEqual(proof.lines, ["We agreed to ship the pricing page next week."])
    }

    func testRowsComeFromAnEventsSinceReply() throws {
        let reply = """
        {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"[]"}],"events":[
          {"event_id":1,"ts_us":1791234567000000,"app_bundle_id":"com.apple.Notes","window_title":"Plan","url":null,
           "text_snippet":"We agreed to ship the pricing page next week.","source_kind":"screen_ocr"}
        ],"isError":false}}
        """
        let rows = try XCTUnwrap(ReadProof.rows(fromReply: Data(reply.utf8)))
        XCTAssertEqual(rows, [ReadRow(tsUs: 1_791_234_567_000_000, appBundleId: "com.apple.Notes", windowTitle: "Plan",
                                      text: "We agreed to ship the pricing page next week.", sourceKind: "screen_ocr")])
        XCTAssertNil(ReadProof.rows(fromReply: Data(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32000,"message":"x"}}"#.utf8)))
    }
}
