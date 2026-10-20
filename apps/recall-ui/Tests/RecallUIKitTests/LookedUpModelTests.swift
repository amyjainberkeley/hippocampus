import XCTest
@testable import RecallUIKit

/// Looked Up (SPEC 3.6): one row per query, engine and day, "searched 3
/// times"; the pages opened next in the same browser; Search Again with the
/// query only; and Forget covering every time it was searched that day.
@MainActor
final class LookedUpModelTests: XCTestCase {
    private func record(_ query: String, _ tsUs: UInt64, _ id: UInt64, engine: String = "google",
                        url: String? = nil) -> SearchRecord {
        SearchRecord(query: query, engine: engine, tsUs: tsUs, app: "Chrome",
                     url: url ?? "https://www.google.com/search?q=\(query.replacingOccurrences(of: " ", with: "+"))",
                     eventId: id)
    }

    func testTheSameQueryOnOneDayIsOneRowWithItsTimes() {
        let records = [
            record("bike shop pricing page examples", WorkClock.us(3, 15, 12), 83_512),
            record("Bike shop pricing page examples", WorkClock.us(3, 14, 59), 83_499),
            record("bike shop pricing page examples", WorkClock.us(3, 15, 5), 83_512),
            record("bike shop pricing page examples", WorkClock.us(4, 10), 84_100),
            record("bike shop pricing page examples", WorkClock.us(3, 16), 83_600, engine: "bing"),
            record("per seat vs tiered pricing", WorkClock.us(0, 14, 6), 81_206),
        ]
        let rows = LookedUpModel.rows(from: records, calendar: WorkClock.calendar)
        XCTAssertEqual(rows.map(\.record.query), ["per seat vs tiered pricing", "bike shop pricing page examples",
                                                  "bike shop pricing page examples", "bike shop pricing page examples"])
        XCTAssertEqual(rows.map(\.record.engine), ["google", "bing", "google", "google"])
        let friday = rows[2]
        XCTAssertEqual(friday.times, 3, "case doesn't make it another search")
        XCTAssertEqual(friday.record.tsUs, WorkClock.us(3, 15, 12), "the row is its newest time")
        XCTAssertEqual(friday.eventIds, [83_512, 83_499], "each moment once, newest first")
        XCTAssertEqual(rows[3].times, 1)
        XCTAssertEqual(rows[3].eventIds, [84_100])
        XCTAssertEqual(friday.origin, "Google \u{00B7} Chrome")
        XCTAssertEqual(rows[1].engine, "Bing")
    }

    func testOpenedNextIsFivePagesInTheSameBrowserWithinFiveMinutes() async {
        let search = workMoment(10, WorkClock.us(0, 14, 6), title: "per seat vs tiered pricing - Google Search",
                                url: "https://www.google.com/search?q=per+seat+vs+tiered+pricing")
        var hits = [search]
        hits.append(workMoment(11, WorkClock.us(0, 14, 7), title: "Per-seat or tiered? How to price a team plan",
                               url: "https://pricingnotes.example/team-plans"))
        hits.append(workMoment(12, WorkClock.us(0, 14, 7) + 20_000_000, title: "Per-seat or tiered? How to price a team plan",
                               url: "https://pricingnotes.example/team-plans#pricing"))
        hits.append(workMoment(13, WorkClock.us(0, 14, 8), title: "tiered pricing - Google Search",
                               url: "https://www.google.com/search?q=tiered+pricing"))
        hits.append(workMoment(14, WorkClock.us(0, 14, 8), app: "com.apple.Safari", title: "In another browser",
                               url: "https://other.example/"))
        hits.append(workMoment(15, WorkClock.us(0, 14, 9), app: "com.microsoft.VSCode", title: "tax.rs"))
        for index in 0..<6 {
            hits.append(workMoment(20 + UInt64(index), WorkClock.us(0, 14, 9) + UInt64(index) * 1_000_000,
                                   title: "Page \(index)", url: "https://pages.example/\(index)"))
        }
        hits.append(workMoment(30, WorkClock.us(0, 14, 12), title: "Too late", url: "https://late.example/"))
        let reader = WorkMomentsReader(hits)
        let model = LookedUpModel(searches: PreviewSearchesReader(records: [
            record("per seat vs tiered pricing", WorkClock.us(0, 14, 6), 10),
        ]), reader: reader, calendar: WorkClock.calendar, now: { WorkClock.now })
        await model.reload()
        XCTAssertEqual(model.state, .loaded)
        let row = try? XCTUnwrap(model.rows.first)
        XCTAssertEqual(row?.page?.id, 10, "the row reads its results page")
        await model.select(row?.id)
        XCTAssertEqual(model.openedNext.map(\.id), [11, 20, 21, 22, 23],
                       "oldest first, each page once, never another results page, another browser or app")
        XCTAssertEqual(reader.searches.last?.appFilter, "com.google.Chrome")
        await model.select(nil)
        XCTAssertTrue(model.openedNext.isEmpty)
    }

    func testSearchAgainCarriesTheQueryAndNothingElse() throws {
        let row = LookedUpRow(id: "a", record: record(
            "rust round half to even", WorkClock.us(0, 11), 1,
            url: "https://user:secret@www.google.com/search?q=rust+round+half+to+even&ei=abc123&sca_esv=99#top"),
                              times: 1)
        XCTAssertEqual(LookedUpModel.searchAgainURL(row)?.absoluteString,
                       "https://www.google.com/search?q=rust+round+half+to+even")
        let youtube = LookedUpRow(id: "b", record: record(
            "bike fitting", WorkClock.us(0, 11), 2, engine: "youtube",
            url: "https://www.youtube.com/results?search_query=bike+fitting&sp=EgIQAQ"), times: 1)
        XCTAssertEqual(LookedUpModel.searchAgainURL(youtube)?.absoluteString,
                       "https://www.youtube.com/results?search_query=bike+fitting")
        let odd = LookedUpRow(id: "c", record: SearchRecord(query: "x", engine: "google", tsUs: 1, app: nil,
                                                             url: "javascript:alert(1)", eventId: 3), times: 1)
        XCTAssertNil(LookedUpModel.searchAgainURL(odd))
        let none = LookedUpRow(id: "d", record: SearchRecord(query: "x", engine: "google", tsUs: 1, app: nil,
                                                              url: nil, eventId: 4), times: 1)
        XCTAssertNil(LookedUpModel.searchAgainURL(none))
        XCTAssertEqual(none.eventIds, [4])
        XCTAssertEqual(none.origin, "Google")
    }

    func testSearchesListUnderDateSectionsAndAFailedReadSaysSo() async {
        let model = LookedUpModel(searches: PreviewSearchesReader(records: [
            record("per seat vs tiered pricing", WorkClock.us(0, 14, 6), 1),
            record("sales tax rounding rules by state", WorkClock.us(4, 15, 5), 2),
        ]), reader: WorkMomentsReader([]), calendar: WorkClock.calendar, now: { WorkClock.now })
        await model.reload()
        XCTAssertEqual(model.sections.map(\.title), [WorkCopy.today, WorkCopy.previous7Days])
        XCTAssertNil(model.rows.first?.page, "a results page that is gone leaves the row without its text")

        let failing = LookedUpModel(searches: FailingSearches(), reader: WorkMomentsReader([]),
                                    calendar: WorkClock.calendar, now: { WorkClock.now })
        await failing.reload()
        XCTAssertEqual(failing.state, .failed)
    }

    func testTheEmptyPageAndItsWordsAreCalm() {
        for text in [WorkCopy.lookedUpLead, WorkCopy.lookedUpEmptyTitle, WorkCopy.lookedUpEmptyBody,
                     WorkCopy.openedNext, WorkCopy.nothingOpenedNext, WorkCopy.searchAgain, WorkCopy.forgetThisSearch,
                     WorkCopy.searchedTimes(3)] {
            XCTAssertNil(CopyStyleValidator.containsJargon(text), text)
            XCTAssertNil(CopyStyleValidator.containsMarketingSpeak(text), text)
            XCTAssertFalse(CopyStyleValidator.containsExclamation(text), text)
        }
    }
}

private struct FailingSearches: SearchesReading {
    func searches(hours: Int, limit: Int) async throws -> [SearchRecord] {
        throw UnderstandingError.unavailable
    }
}
