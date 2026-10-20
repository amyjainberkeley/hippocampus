import Foundation
import XCTest
@testable import RecallUIKit

/// The field's scope, Mail-style (SPEC 2.8): on a page that offers one the
/// bar shows with the page chosen, matches are kept to it, and a scope with
/// nothing in it offers Search Everything.
@MainActor
final class SearchScopeTests: XCTestCase {
    private func afternoon() -> [Hit] {
        [
            MomentFactory.hit(1, "com.microsoft.VSCode", title: "tax.rs \u{2014} trailhead-shop", minutesAgo: 1),
            MomentFactory.hit(2, "com.google.Chrome", title: "Rounding half to even",
                              url: "https://devnotes.example/rounding", minutesAgo: 2),
            MomentFactory.hit(3, "com.google.Chrome", title: "rounding half even - Google Search",
                              url: "https://www.google.com/search?q=rounding+half+even", minutesAgo: 3),
            MomentFactory.hit(4, "com.apple.Notes", title: "Launch checklist", minutesAgo: 4),
            MomentFactory.hit(5, "com.apple.Notes", title: "Rounding notes", url: "notes://x", minutesAgo: 5),
        ]
    }

    func testEachScopeKeepsItsOwnMatches() async {
        let hits = afternoon()
        let work = PreviewWorkReader(snapshot: WorkSnapshot(momentItems: [1: "w_shop", 2: "w_shop", 4: "w_launch"]))
        let shop = SearchScope(kind: .item("w_shop"), name: "trailhead-shop")
        let kept = await shop.keep(hits, work: work)
        XCTAssertEqual(kept.map(\.id), [1, 2])
        let none = await shop.keep(hits, work: nil)
        XCTAssertTrue(none.isEmpty, "without the work read nothing can be told apart")
        let pages = await SearchScope.webPages.keep(hits, work: nil)
        XCTAssertEqual(pages.map(\.id), [2, 3], "web pages are pages in a browser")
        let searches = await SearchScope.lookedUp.keep(hits, work: nil)
        XCTAssertEqual(searches.map(\.id), [3])
        let documents = await SearchScope.lens(.documents).keep(hits, work: nil)
        XCTAssertEqual(documents.map(\.id), [4, 5])
        XCTAssertEqual(SearchScope.webPages.name, "Web Pages")
        XCTAssertEqual(SearchScope.lens(.code).name, "Code")
    }

    func testAResultsPageIsOneWithItsWords() {
        XCTAssertTrue(SearchScope.isResultsPage("https://www.google.com/search?q=tax"))
        XCTAssertTrue(SearchScope.isResultsPage("https://www.google.co.uk/search?q=tax"))
        XCTAssertTrue(SearchScope.isResultsPage("https://duckduckgo.com/?q=tax"))
        XCTAssertTrue(SearchScope.isResultsPage("https://www.youtube.com/results?search_query=tax"))
        XCTAssertTrue(SearchScope.isResultsPage("https://github.com/search?q=round_half_even"))
        XCTAssertFalse(SearchScope.isResultsPage("https://www.google.com/search?q="))
        XCTAssertFalse(SearchScope.isResultsPage("https://www.google.com/maps?q=tax"))
        XCTAssertFalse(SearchScope.isResultsPage("https://devnotes.example/search?q=tax"))
        XCTAssertFalse(SearchScope.isResultsPage(nil))
    }

    func testAPageOffersItsScopeChosenAndEverythingIsOneClickAway() async {
        let reader = MomentsSearchReader(afternoon())
        let model = SearchViewModel(reader: reader,
                                    persistence: QueryPersistence(environment: ["MCI_EPHEMERAL_UI_STATE": "1"]),
                                    userDictionaryLoader: { .empty })
        model.pageScope = .webPages
        XCTAssertTrue(model.isScoped, "the bar shows with the page chosen")
        model.query = "rounding"
        await model.runSearch()
        XCTAssertEqual(model.hits.map(\.id), [2, 3])
        let read = await reader.last
        XCTAssertEqual(read?.limit, 200, "a scope reads more, then keeps its own")

        model.searchEverything()
        XCTAssertNil(model.activeScope)
        await model.runSearch()
        XCTAssertEqual(model.hits.map(\.id), [1, 2, 3, 4, 5])
        let everything = await reader.last
        XCTAssertEqual(everything?.limit, 50)

        model.scopeToPage()
        XCTAssertEqual(model.activeScope, .webPages)
        model.pageScope = nil
        XCTAssertFalse(model.isScoped, "a page without a scope searches everything")
        model.scopeToPage()
        XCTAssertNil(model.activeScope)
    }

    func testAScopeWithNothingSaysSoAndOffersEverything() {
        XCTAssertEqual(LibraryCopy.Search.nothingIn("trailhead-shop"), "Nothing in trailhead-shop matched.")
        XCTAssertEqual(LibraryCopy.Search.matches(9, in: "trailhead-shop"), "9 matches in trailhead-shop")
        XCTAssertEqual(LibraryCopy.Search.matches(1, in: "Web Pages"), "1 match in Web Pages")
        XCTAssertEqual(LibraryCopy.Search.searchEverything, "Search Everything")
    }
}

/// Every moment matches; the read is counted.
private actor MomentsSearchReader: BrainReader {
    let moments: [Hit]
    var last: SearchOptions?

    init(_ moments: [Hit]) { self.moments = moments }

    func search(_ options: SearchOptions) async throws -> [Hit] {
        last = options
        return Array(moments.prefix(options.limit))
    }

    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] { [] }
    func recentEvents(limit: Int) async throws -> [Hit] { [] }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }
    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }
    func summaryStats() async throws -> SummaryStats {
        SummaryStats(totalEvents: 0, oldestTsUs: nil, newestTsUs: nil, diskBytes: 0)
    }
}
