import XCTest
@testable import RecallUIKit

final class ReadableTextTests: XCTestCase {
    private let capture = "[app=com.apple.Notes | title=Pricing page draft | url=? | ts=2026-10-12T16:41:05.000Z]\n"
    private let transcript = "[app=claude-code | title=Pricing · user | url=/work#main | session=abc | src=/tmp/s.jsonl:4]\n"
    private let revision = "[MCP_RESOURCE revision_sha256=" + String(repeating: "ab", count: 32) + "]\n"
    private let classified = "Plans\nPick the plan that fits your rides.\n\n\u{1E}\nFile Edit View Window Help"

    func testEveryHeaderTheStoreWritesIsRemoved() {
        XCTAssertEqual(ReadableText.body(capture + "Plans"), "Plans")
        XCTAssertEqual(ReadableText.body(transcript + "Ship it"), "Ship it")
        XCTAssertEqual(ReadableText.body(revision + capture + "Resource text"), "Resource text")
        let wrapped = "[app=com.apple.Safari | title=Line one\nline two | url=https://example.invalid | ts=now]\nBody"
        XCTAssertEqual(ReadableText.body(wrapped), "Body")
        XCTAssertEqual(ReadableText.body(String(capture.dropLast())), "", "a header with nothing after it leaves nothing")
        let long = "[app=Safari | title=" + String(repeating: "Metadata", count: 1_500) + " | url=? | ts=now]\nBody"
        XCTAssertEqual(ReadableText.body(long), "Body")
    }

    func testTextThatOnlyLooksLikeAHeaderIsLeftAlone() {
        let texts = [
            "Plans\n" + capture + "more",
            "[app=" + String(repeating: "x", count: 200),
            "[app=Notes] is how the store writes it",
            revision + "No header follows",
            "[MCP_RESOURCE revision_sha256=short]\n" + capture + "Body",
        ]
        for text in texts {
            XCTAssertEqual(ReadableText.body(text), text)
        }
    }

    func testTheSeparatorNeverReachesAPerson() {
        XCTAssertEqual(ReadableText.guarded(capture + classified),
                       "Plans\nPick the plan that fits your rides.\n\nFile Edit View Window Help")
        XCTAssertEqual(ReadableText.guarded("tab\u{1E}bar"), "tab bar")
        XCTAssertEqual(ReadableText.guarded("Plain text"), "Plain text")
    }

    func testStoredTextIsCutWhereTheStoreMarkedItAndNoWordIsLost() {
        let parts = ReadableText.parts(stored: capture + classified + "\n", sourceKind: "screen_ocr")
        XCTAssertEqual(parts.main, "Plans\nPick the plan that fits your rides.")
        XCTAssertEqual(parts.rest, "File Edit View Window Help")
        let old = ReadableText.parts(stored: capture + "Old text\nwith lines", sourceKind: nil)
        XCTAssertEqual(old.main, "Old text\nwith lines")
        XCTAssertEqual(old.rest, "")
        let browser = "Page text\n\n[VISIBLE-OCR]\n" + classified
        let both = ReadableText.parts(stored: capture + browser, sourceKind: "browser_page_with_ocr")
        XCTAssertEqual(both.main, "Page text")
        XCTAssertEqual(both.rest, "Plans\nPick the plan that fits your rides.\n\nFile Edit View Window Help")
        let page = ReadableText.parts(stored: browser, sourceKind: "browser_page")
        XCTAssertTrue(page.main.contains("[VISIBLE-OCR]"), "the marker is cut only for a page read both ways")
    }

    func testListSnippetsFromTheFFINeverCarryAHeaderOrTheSeparator() throws {
        let stored = (capture + classified).replacingOccurrences(of: "\u{1E}", with: "\\u001e")
            .replacingOccurrences(of: "\n", with: "\\n")
        let hits = """
        [{"event_id":7,"ts_us":5,"app_bundle_id":"com.apple.Notes","window_title":"Pricing page draft","url":null,\
        "ocr_text_snippet":"\(stored)","source":"timeline","score":null}]
        """
        let hit = try XCTUnwrap(try JSONDecoder().decode([HitWire].self, from: Data(hits.utf8)).first?.toHit())
        let timeline = """
        [{"event_id":7,"ts_us":5,"app_bundle_id":"com.apple.Notes","snippet":"\(stored)","thumbnail_path":null,"source_kind":"screen_ocr"}]
        """
        let event = try XCTUnwrap(try JSONDecoder().decode([TimelineEventWire].self, from: Data(timeline.utf8)).first?.toTimelineEvent())
        for text in [hit.ocrTextSnippet, event.snippet] {
            XCTAssertFalse(text.contains("\u{1E}"), text)
            XCTAssertFalse(text.hasPrefix("[app="), text)
            XCTAssertTrue(text.hasPrefix("Plans\n"), text)
        }
    }

    func testTheFFIsReadingDecodesAsTheContractWritesIt() throws {
        let json = """
        {"event_id":42,"ts_us":1791841000000000,"app_bundle_id":"com.apple.Notes","source_kind":"screen_ocr",\
        "main":"Plans\\nPick the plan that fits your rides.","rest":"File Edit View Window Help",\
        "match_in":"rest","truncated":false}
        """
        let reading = try XCTUnwrap(FFIBrainReader.decodeEventReading(Data(json.utf8), eventId: 42))
        XCTAssertEqual(reading.main, "Plans\nPick the plan that fits your rides.")
        XCTAssertEqual(reading.rest, "File Edit View Window Help")
        XCTAssertEqual(reading.sourceKind, "screen_ocr")
        XCTAssertEqual(reading.matchIn, .rest)
        XCTAssertFalse(reading.isTruncated)
        let hit = Hit(eventId: 42, tsUs: 1_791_841_000_000_000, appBundleId: "com.apple.Notes", windowTitle: nil,
                      url: nil, ocrTextSnippet: "", source: "timeline", score: nil)
        XCTAssertTrue(reading.matches(hit))
        let reused = Hit(eventId: 42, tsUs: 1, appBundleId: "com.apple.Notes", windowTitle: nil,
                         url: nil, ocrTextSnippet: "", source: "timeline", score: nil)
        XCTAssertFalse(reading.matches(reused), "ids are reused after a delete")

        let unmatched = json.replacingOccurrences(of: #""match_in":"rest""#, with: #""match_in":null"#)
        XCTAssertNil(try FFIBrainReader.decodeEventReading(Data(unmatched.utf8), eventId: 42)?.matchIn)
        XCTAssertNil(try FFIBrainReader.decodeEventReading(Data("null".utf8), eventId: 42))
        XCTAssertThrowsError(try FFIBrainReader.decodeEventReading(Data(json.utf8), eventId: 43),
                             "another moment's reading is never shown for this one")
        XCTAssertThrowsError(try FFIBrainReader.decodeEventReading(Data(#"{"main":"private words"}"#.utf8), eventId: 42)) { error in
            XCTAssertFalse("\(error)".contains("private words"), "a decode error never echoes the text")
        }
        XCTAssertThrowsError(try EventReading(eventId: 42, tsUs: 1, appBundleId: nil, sourceKind: nil,
                                              main: String(repeating: "a", count: EventReading.maxUTF8Bytes + 1),
                                              rest: "", isTruncated: false))
    }

    func testTheWindowAsksTheFFIForTheReadingWithTheSearch() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("Sources/RecallUIKit/FFIBrainReader.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("public func eventReading(eventId: UInt64, query: String?)"))
        XCTAssertTrue(source.contains("mci_brain_ffi_event_reading(h, eventId, $0)"))
        XCTAssertTrue(source.contains("mci_brain_ffi_event_reading(h, eventId, nil)"))
        let model = try String(contentsOf: package.appendingPathComponent("Sources/RecallUIKit/EventTextViewModel.swift"),
                               encoding: .utf8)
        XCTAssertTrue(model.contains("reader.eventReading(eventId: hit.id, query: query)"))
        XCTAssertFalse(model.contains("reader.eventText("), "a person reads the reading, never the stored text")
    }

    func testTheDetailReadsTheWindowNotTheStoredText() async throws {
        let reader = StoredTextReader(stored: capture + classified, sourceKind: "screen_ocr")
        let read = try await reader.eventReading(eventId: 7)
        let reading = try XCTUnwrap(read)
        XCTAssertEqual(reading.main, "Plans\nPick the plan that fits your rides.")
        XCTAssertEqual(reading.rest, "File Edit View Window Help")
        XCTAssertEqual(reading.sourceKind, "screen_ocr")
        XCTAssertNil(reading.matchIn)
        let stored = try await reader.eventText(eventId: 7)
        XCTAssertEqual(stored?.text, capture + classified, "the stored text is kept as it is, for audits")
    }

    @MainActor
    func testCopyNeverCarriesAHeaderOrTheSeparator() async {
        let reader = StoredTextReader(stored: capture + classified, sourceKind: "screen_ocr")
        let model = EventTextViewModel()
        await model.load(hit: reader.hit, reader: reader)
        XCTAssertEqual(model.copyText(for: reader.hit, includingRest: true),
                       "Plans\nPick the plan that fits your rides.\n\nFile Edit View Window Help")
        XCTAssertEqual(model.copyText(for: reader.hit), "Plans\nPick the plan that fits your rides.",
                       "with \u{201C}Also in this window\u{201D} closed, Copy Text copies what is shown")
        let other = Hit(eventId: 8, tsUs: 6, appBundleId: nil, windowTitle: nil, url: nil,
                        ocrTextSnippet: capture + "Snippet\u{1E}text", source: "timeline", score: nil)
        XCTAssertEqual(model.copyText(for: other), "Snippet text")
    }

    func testTheExportForAnAICarriesTheReadingThenTheRestOfTheWindow() throws {
        let reader = StoredTextReader(stored: capture + classified, sourceKind: "screen_ocr")
        let reading = EventReading(stored: try EventText(eventId: 7, tsUs: 5, appBundleId: "com.apple.Notes",
                                                         text: capture + classified, isTruncated: false),
                                   sourceKind: "screen_ocr")
        let context = ScreenshotInspectorContext.markdown(hit: reader.hit, text: reading)
        XCTAssertTrue(context.contains("## Text\n\n```text\nPlans\nPick the plan that fits your rides.\n```\n"))
        XCTAssertTrue(context.contains("## Also in this window\n\n```text\nFile Edit View Window Help\n```\n"))
        XCTAssertFalse(context.contains("[app="))
        XCTAssertFalse(context.contains("\u{1E}"))
    }

    func testAlsoInThisWindowCountsTheLinesThatHoldText() throws {
        func reading(rest: String) throws -> EventReading {
            try EventReading(eventId: 7, tsUs: 5, appBundleId: nil, sourceKind: "screen_ocr",
                             main: "Plans", rest: rest, isTruncated: false)
        }
        XCTAssertEqual(try reading(rest: "File Edit View\n\nRoadmap\n   \nSearch\r\nRecently Deleted 3").restLineCount, 4)
        XCTAssertEqual(try reading(rest: "").restLineCount, 0)
        XCTAssertEqual(UserFacingCopy.lineCount(1), "1 line")
        XCTAssertEqual(UserFacingCopy.lineCount(4), "4 lines")
    }

    func testTheWordsAroundAMomentsTextAreThePlainOnes() throws {
        XCTAssertEqual(UserFacingCopy.momentTextHeading(sourceKind: "screen_ocr"), "On screen")
        XCTAssertEqual(UserFacingCopy.momentTextHeading(sourceKind: "browser_page"), "On the page")
        XCTAssertEqual(UserFacingCopy.momentTextHeading(sourceKind: "browser_page_with_ocr"), "On the page")
        XCTAssertEqual(UserFacingCopy.momentTextHeading(sourceKind: "transcript_import"), "Text")
        XCTAssertEqual(UserFacingCopy.momentTextHeading(sourceKind: nil), "Text")
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/RecallUI/DetailPaneView.swift", "Sources/RecallUI/ScreenshotViewer.swift",
                     "Sources/RecallUIKit/EventTextViewModel.swift"] {
            let source = try String(contentsOf: package.appendingPathComponent(file), encoding: .utf8)
            for old in ["\"Stored text", "\"OCR text", "\"Saved OCR text", "\"Loading stored text", "\"No stored text",
                        "Showing saved snippet", "128 KiB text limit", "\"Copy Snippet", "\"Copy Full Text",
                        "\"Copy Shown Text", "Text(\"Event \\(", "No text preview is available"] {
                XCTAssertFalse(source.contains(old), "\(file) still says \(old) (RULINGS T17)")
            }
        }
    }
}

/// One stored moment, as the FFI hands it over today: header, content, separator, chrome.
private struct StoredTextReader: BrainReader {
    let stored: String
    let sourceKind: String
    var hit: Hit {
        Hit(eventId: 7, tsUs: 5, appBundleId: "com.apple.Notes", windowTitle: "Pricing page draft", url: nil,
            ocrTextSnippet: ReadableText.guarded(stored), source: "timeline", score: nil, sourceKind: sourceKind)
    }

    func eventText(eventId: UInt64) async throws -> EventText? {
        guard eventId == 7 else { return nil }
        return try EventText(eventId: 7, tsUs: 5, appBundleId: "com.apple.Notes", text: stored, isTruncated: false)
    }

    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] { ids.contains(7) ? [hit] : [] }
    func search(_ opts: SearchOptions) async throws -> [Hit] { [] }
    func recentEvents(limit: Int) async throws -> [Hit] { [hit] }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }
    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }
    func summaryStats() async throws -> SummaryStats {
        SummaryStats(totalEvents: 1, oldestTsUs: 5, newestTsUs: 5, diskBytes: 0)
    }
}
