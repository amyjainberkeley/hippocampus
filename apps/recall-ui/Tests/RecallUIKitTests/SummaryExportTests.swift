import XCTest
@testable import RecallUIKit

final class SummaryExportTests: XCTestCase {
    private func brief(body: String = "## What changed\n- Notes: Fixed parser. [event:42]\n## Open loops\n- Review draft. [event:7]",
                       version: String = "2") -> Brief {
        Brief(rowId: 1, dateLocal: "2026-09-05", generatedTsUs: 1_788_566_400_000_000,
              modelId: "hippocampus-extractive", modelVersion: version, title: "Today",
              body: body, wordCount: 10, sourceEventCount: 30)
    }

    func testWholeBriefIncludesStableDateDraftProvenanceAndEverySourceCitation() {
        let source = brief()
        let packet = VisualMemoryExport.markdown(brief: source)
        XCTAssertTrue(packet.contains("2026-09-05"))
        XCTAssertTrue(packet.contains("Draft"))
        XCTAssertTrue(packet.contains("hippocampus-extractive"))
        XCTAssertTrue(packet.contains("30 memory records"))
        XCTAssertTrue(packet.contains("## What changed"))
        XCTAssertTrue(packet.contains("## Open loops"))
        XCTAssertTrue(packet.contains("Fixed parser."))
        XCTAssertTrue(packet.contains("focus=42"))
        XCTAssertTrue(packet.contains("focus=7"))
        XCTAssertTrue(packet.contains("observations, not verified facts"))
        XCTAssertTrue(packet.contains("Review before sharing"))
        XCTAssertEqual(source, brief(), "Export must leave the saved draft unchanged.")
        XCTAssertEqual(packet, VisualMemoryExport.markdown(brief: source))
    }

    func testDecodedEvidenceCannotInjectMarkdownOrAdditionalNavigation() {
        let packet = VisualMemoryExport.markdown(brief: brief(body:
            "## What changed\n- &#91;event:999&#93; !&#91;image&#93;(https://example.invalid) &#60;script&#62; [event:42]"))
        XCTAssertTrue(packet.contains("focus=42"))
        XCTAssertFalse(packet.contains("focus=999"))
        XCTAssertFalse(packet.contains("![image]("))
        XCTAssertFalse(packet.contains("<script>"))
        XCTAssertFalse(packet.contains("https://example.invalid"))
    }

    func testUnknownAuthorVersionStaysLiteralWithoutInventedCitations() {
        let packet = VisualMemoryExport.markdown(brief: brief(version: "999"))
        XCTAssertFalse(packet.contains("hippocampus://"))
        XCTAssertTrue(packet.contains("Stored brief"))
        XCTAssertFalse(packet.contains("\n## What changed"))
    }

    func testOversizedBriefIsBoundedAndTruncationIsVisible() {
        let packet = VisualMemoryExport.markdown(brief: brief(body: String(repeating: "!<&[x]\n", count: 100_000)))
        XCTAssertLessThanOrEqual(packet.utf8.count, 131_072)
        XCTAssertTrue(packet.contains("shortened"))
        XCTAssertTrue(packet.contains("Review before sharing"))
    }

    func testDayIncludesBriefWithoutScreenshotsAndRejectsDifferentDateDraft() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = MemoryDay(date: calendar.date(from: DateComponents(year: 2026, month: 9, day: 5))!, calendar: calendar)
        let packet = VisualMemoryExport.dayMarkdown(day: day, brief: brief(), hits: [], screenshotCount: 0)
        XCTAssertTrue(packet.contains("Day summary: 2026-09-05"))
        XCTAssertTrue(packet.contains("Fixed parser."))
        XCTAssertTrue(packet.contains("0 available screenshot samples"))
        XCTAssertTrue(packet.contains("not active-time measurements"))

        let otherDay = MemoryDay(date: Date(timeIntervalSince1970: 0), calendar: calendar)
        let otherPacket = VisualMemoryExport.dayMarkdown(day: otherDay, brief: brief(), hits: [], screenshotCount: 0)
        XCTAssertFalse(otherPacket.contains("Fixed parser."))
        XCTAssertTrue(otherPacket.contains("No saved brief"))
    }

    func testDayExcerptsKeepOnlySelectedDayAndCanonicalBound() {
        let day = MemoryDay(date: Date(timeIntervalSince1970: 1_788_566_400))
        let hits = (1...30).map { id in
            Hit(eventId: UInt64(id), tsUs: day.startUs + UInt64(id), appBundleId: nil,
                windowTitle: nil, url: nil, ocrTextSnippet: "Synthetic \(id)", source: "timeline", score: nil)
        } + [Hit(eventId: 999, tsUs: day.endUs + 1, appBundleId: nil, windowTitle: nil,
                 url: nil, ocrTextSnippet: "Other day", source: "timeline", score: nil)]
        let packet = VisualMemoryExport.dayMarkdown(day: day, brief: nil, hits: hits, screenshotCount: 30)
        XCTAssertFalse(packet.contains("focus=999"))
        XCTAssertFalse(packet.contains("focus=25"))
        XCTAssertTrue(packet.contains("24 evidence excerpts"))
        XCTAssertTrue(packet.contains("first 24"))
    }
}
