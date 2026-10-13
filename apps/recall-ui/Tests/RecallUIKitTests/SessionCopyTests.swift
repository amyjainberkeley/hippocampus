import Foundation
import XCTest
@testable import RecallUIKit

/// "Copy for your AI" on a session copies that session's own moments, never a
/// search of everything remembered (RULINGS I13), and the selected session's
/// detail says what the overview holds in the person's own format.
final class SessionCopyTests: XCTestCase {
    private func hit(_ id: UInt64, _ ts: UInt64, app: String? = "com.apple.Notes", title: String? = "Draft",
                     text: String = "text") -> Hit {
        Hit(eventId: id, tsUs: ts, appBundleId: app, windowTitle: title, url: nil, ocrTextSnippet: text,
            source: "timeline", score: nil, sourceKind: "screen_ocr")
    }

    func testACopyHoldsTheSessionsOwnMomentsOldestFirstWithoutSystemApps() {
        let hits = [
            hit(5, 500, title: "Plan"),
            hit(1, 100, title: "Draft"),
            hit(9, 900, title: "After"),         // after the session
            hit(0, 50, title: "Before"),         // before it
            hit(3, 300, app: "com.apple.dock", title: "Dock"),
            hit(1, 100, title: "Draft"),         // the same moment twice
            hit(2, 200, app: "com.apple.Safari", title: "Docs"),
        ]
        let moments = SessionCopy.moments(hits, in: 100...500)
        XCTAssertEqual(moments.map(\.eventId), [1, 2, 5])
    }

    func testOneMomentStandsForARunOfTheSameWindowTheNewest() {
        let hits = [
            hit(1, 100, title: "Draft", text: "first words"),
            hit(2, 200, title: "Draft", text: "more words"),
            hit(3, 300, app: "com.apple.Safari", title: "Docs"),
            hit(4, 400, title: "Draft", text: "back again"),
        ]
        XCTAssertEqual(SessionCopy.moments(hits, in: 0...1_000).map(\.eventId), [2, 3, 4])
    }

    func testALongSessionIsSpreadEvenlyKeepingItsFirstAndLast() {
        let hits = (1...100).map { hit(UInt64($0), UInt64($0) * 10, title: "Window \($0)") }
        let moments = SessionCopy.moments(hits, in: 0...10_000, limit: 5)
        XCTAssertEqual(moments.map(\.eventId), [1, 26, 51, 75, 100])
        XCTAssertEqual(SessionCopy.moments(hits, in: 0...10_000).count, SessionCopy.maxMoments)
        XCTAssertEqual(SessionCopy.moments(hits, in: 0...10_000, limit: 1).map(\.eventId), [100])
        XCTAssertEqual(SessionCopy.moments(hits, in: 0...10_000, limit: 0), [])
    }

    func testTheCopyReadsTheSessionsTimeAndReadsAsAPlainExport() async throws {
        let reader = RecordingBrainReader(hits: [
            hit(7, 1_791_837_700_000_000, app: "com.apple.Safari", title: "Pricing · Velo Cycles",
                text: "Annual plans save two months."),
            hit(8, 1_791_838_000_000_000, title: "Pricing page draft", text: "Ride, Tour and Club."),
        ])
        let text = try await SessionCopy.markdown(title: "Competitor pricing tables",
                                                  range: 1_791_837_660_000_000...1_791_839_120_000_000,
                                                  reader: reader)
        let asked = await reader.options
        let options = try XCTUnwrap(asked.first)
        XCTAssertTrue(options.browse)
        XCTAssertEqual(options.text, "")
        XCTAssertEqual(options.timeFromUs, 1_791_837_660_000_000)
        XCTAssertEqual(options.timeToUs, 1_791_839_120_000_000)
        XCTAssertEqual(options.limit, SessionCopy.readLimit)
        XCTAssertGreaterThanOrEqual(SessionCopy.readLimit, 1_800, "a whole 30-minute session at a moment a second")

        XCTAssertTrue(text.hasPrefix("# Competitor pricing tables\n"))
        XCTAssertTrue(text.contains("Pricing · Velo Cycles"))
        XCTAssertTrue(text.contains("Ride, Tour and Club."))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "Velo Cycles")).lowerBound,
                          try XCTUnwrap(text.range(of: "Pricing page draft")).lowerBound)
        for machine in ["Truth status", "Retrieval", "Generated at", "About the user", "Recent work", "\u{001E}", "[app="] {
            XCTAssertFalse(text.contains(machine), "the copy says \(machine)")
        }
    }

    func testTheDetailSaysWhatTheSessionHeldInThePersonsFormat() throws {
        let overview = try UnderstandingFixture.overview()
        let block = try XCTUnwrap(overview.blocks.first { $0.title == "Competitor pricing tables" })
        let detail = SessionDetail(block: block, locale: Locale(identifier: "en_US"),
                                   timeZone: TimeZone(secondsFromGMT: -25_200)!)
        XCTAssertEqual(detail.title, "Competitor pricing tables")
        XCTAssertTrue(detail.time.hasPrefix("1:41"), detail.time)
        XCTAssertTrue(detail.time.hasSuffix("2:05\u{202F}PM") || detail.time.hasSuffix("2:05 PM"), detail.time)
        XCTAssertEqual(detail.length, "24m")
        XCTAssertEqual(detail.kind, .research)
        XCTAssertEqual(detail.kindLine, "Mostly Research, some Writing")
        XCTAssertEqual(detail.apps.map(\.label), ["Safari \u{00B7} 12m", "Notes \u{00B7} 10m", "Slack \u{00B7} 3m"])
        XCTAssertEqual(detail.sentences, ["You reworded a search twice."])
        XCTAssertEqual(detail.noticed?.caption, "Written on this Mac by Apple Intelligence")
        XCTAssertEqual(detail.searches, ["bike shop pricing page examples", "bike shop pricing tiers examples",
                                         "bike rental pricing tiers"])
        XCTAssertEqual(detail.screenshotEventId, 90_243)
        XCTAssertEqual(detail.reopen, .page(URL(string: "https://www.velocycles.example/pricing")!))
        XCTAssertEqual(detail.reopen?.label, "Open Page")
        XCTAssertEqual(detail.copyRange, 1_791_837_660_000_000...1_791_839_120_000_000)
        XCTAssertEqual(detail.history, .history(of: detail.copyRange, selecting: 90_251))
    }

    func testASessionOfOneKindSaysItsKindAndAMeasuredOneHasNothingNoticed() throws {
        let overview = try UnderstandingFixture.overview()
        let now = try XCTUnwrap(overview.blocks.last)
        let detail = SessionDetail(block: now, locale: Locale(identifier: "en_US"),
                                   timeZone: TimeZone(secondsFromGMT: -25_200)!)
        XCTAssertEqual(detail.kindLine, "Design")
        XCTAssertNil(detail.noticed)
        XCTAssertEqual(detail.reopen?.label, "Open Notes")
        XCTAssertEqual(detail.sentences, ["You switched between Figma and Notes five times."])
    }

    func testAFinishedSessionOpensTheAppItSpentMostTimeIn() throws {
        let overview = try UnderstandingFixture.overview()
        let zone = TimeZone(secondsFromGMT: -25_200)!
        func detail(_ title: String) throws -> SessionDetail {
            let block = try XCTUnwrap(overview.blocks.first { $0.title == title })
            return SessionDetail(block: block, locale: Locale(identifier: "en_US"), timeZone: zone)
        }
        // Mostly Notes, last seen in Slack: Notes, not Slack.
        XCTAssertEqual(try detail("Pricing page copy").reopen, .app(bundleId: "com.apple.Notes", name: "Notes"))
        XCTAssertEqual(try detail("Weekly design review").reopen?.label, "Open Zoom")
        // Mostly Safari, and the agent's page is in Safari: the page.
        XCTAssertEqual(try detail("Competitor pricing tables").reopen?.label, "Open Page")
        // Still going: where the person is now.
        XCTAssertEqual(try detail("Trailhead pricing v3").reopen, .app(bundleId: "com.apple.Notes", name: "Notes"))
    }

    func testARowOnYouNamesItsDayAndTime() {
        let text = SessionDetail.dayAndTime(startUs: 1_791_837_660_000_000, endUs: 1_791_839_120_000_000,
                                            locale: Locale(identifier: "en_US"),
                                            timeZone: TimeZone(secondsFromGMT: -25_200)!)
        XCTAssertTrue(text.hasPrefix("Oct 12, 1:41"), text)
    }
}

/// A brain reader that answers a browse from a list and records what it was asked.
actor RecordingBrainReader: BrainReader {
    private let hits: [Hit]
    private(set) var options: [SearchOptions] = []

    init(hits: [Hit]) {
        self.hits = hits
    }

    func search(_ opts: SearchOptions) async throws -> [Hit] {
        options.append(opts)
        return hits.filter { hit in
            (opts.timeFromUs.map { hit.tsUs >= $0 } ?? true) && (opts.timeToUs.map { hit.tsUs <= $0 } ?? true)
        }.sorted { $0.tsUs > $1.tsUs }
    }

    func recentEvents(limit: Int) async throws -> [Hit] { [] }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }
    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] { hits.filter { ids.contains($0.eventId) } }
    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }
    func summaryStats() async throws -> SummaryStats { throw BrainReaderError.queryFailed("test") }
}
