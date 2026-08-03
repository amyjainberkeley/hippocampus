// ViewModelsTests.swift — state-machine tests for SearchViewModel,
// TimelineViewModel, and PrivacyMomentsViewModel. The view models are
// the binding contract between the SwiftUI views and the BrainReader
// surface; SwiftUI snapshot rendering is out of scope per the PR scope.

import XCTest
@testable import RecallUIKit

/// A failing reader so the error-path can be exercised without
/// destabilizing StubBrainReader (which the canned-data tests rely on).
private struct FailingReader: BrainReader {
    func search(_ opts: SearchOptions) async throws -> [Hit] {
        throw BrainReaderError.queryFailed("boom")
    }
    func recentEvents(limit: Int) async throws -> [Hit] {
        throw BrainReaderError.queryFailed("timeline boom")
    }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] {
        throw BrainReaderError.queryFailed("moments boom")
    }
    func listObservedApps(
        limit: Int, timeFromUs: UInt64?
    ) async throws -> [ObservedApp] {
        throw BrainReaderError.queryFailed("apps boom")
    }
    func listEpisodes(limit: Int) async throws -> [Episode] {
        throw BrainReaderError.queryFailed("episodes boom")
    }
    func briefForDate(_ dateLocal: String) async throws -> Brief? {
        throw BrainReaderError.queryFailed("brief boom")
    }
    func latestBrief() async throws -> Brief? {
        throw BrainReaderError.queryFailed("latest-brief boom")
    }
    func briefDates(limit: Int) async throws -> [String] {
        throw BrainReaderError.queryFailed("brief-dates boom")
    }
    // Added when BrainReader grew these; the stub was never updated, so the
    // conformance broke. `timelineEvents` is not listed because the protocol
    // extension supplies a default.
    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] {
        throw BrainReaderError.queryFailed("fetch-by-ids boom")
    }
    func summaryStats() async throws -> SummaryStats {
        throw BrainReaderError.queryFailed("summary-stats boom")
    }
}

@MainActor
final class SearchViewModelTests: XCTestCase {
    func testEmptyQueryProducesEmptyHits() async {
        let vm = SearchViewModel(reader: StubBrainReader())
        vm.query = "   "
        await vm.runSearch()
        XCTAssertTrue(vm.hits.isEmpty)
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isSearching)
    }

    func testMatchingQueryPopulatesHits() async {
        let vm = SearchViewModel(reader: StubBrainReader())
        vm.query = "privacy"
        await vm.runSearch()
        XCTAssertEqual(vm.hits.count, 1)
        XCTAssertEqual(vm.hits.first?.eventId, 101)
        XCTAssertFalse(vm.isSearching)
    }

    func testNonMatchingQueryProducesEmpty() async {
        let vm = SearchViewModel(reader: StubBrainReader())
        vm.query = "zzz-no-such-token-zzz"
        await vm.runSearch()
        XCTAssertTrue(vm.hits.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    func testReaderErrorIsSurfacedAndHitsCleared() async {
        let vm = SearchViewModel(reader: FailingReader())
        vm.query = "anything"
        await vm.runSearch()
        XCTAssertTrue(vm.hits.isEmpty)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isSearching)
    }

    func testClearResetsState() async {
        let vm = SearchViewModel(reader: StubBrainReader())
        vm.query = "privacy"
        await vm.runSearch()
        XCTAssertFalse(vm.hits.isEmpty)
        vm.clear()
        XCTAssertEqual(vm.query, "")
        XCTAssertTrue(vm.hits.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    // Regression: pre-fix, empty query + active filter sent `text: "*"`
    // to FTS5, which the store rejects with
    // `unknown special query`. With the fix, the view model takes a
    // recentEvents path and applies the filter client-side.
    // (CEO-reported dogfood crash, 2026-05-23.)
    func testEmptyQueryWithActiveFilterDoesNotSendWildcard() async {
        let vm = SearchViewModel(reader: StubBrainReader())
        vm.query = ""
        vm.filters.toggleApp("com.apple.Safari")
        await vm.runSearch()
        XCTAssertNil(
            vm.errorMessage,
            "Empty query + active app filter must not surface an FTS5 wildcard error"
        )
        XCTAssertFalse(vm.isSearching)
        XCTAssertFalse(vm.hits.isEmpty, "stub has Safari demo hits")
        XCTAssertTrue(
            vm.hits.allSatisfy { $0.appBundleId == "com.apple.Safari" },
            "client-side app filter should narrow to Safari only"
        )
    }

    func testEmptyQueryWithMultipleAppsAppliesClientSideFilter() async {
        let vm = SearchViewModel(reader: StubBrainReader())
        vm.query = ""
        vm.filters.toggleApp("com.apple.Safari")
        vm.filters.toggleApp("com.microsoft.VSCode")
        await vm.runSearch()
        XCTAssertNil(vm.errorMessage)
        let bundles = Set(vm.hits.compactMap { $0.appBundleId })
        XCTAssertTrue(
            bundles.isSubset(of: ["com.apple.Safari", "com.microsoft.VSCode"]),
            "Multi-app filter should only return hits from selected apps; got \(bundles)"
        )
    }

    func testEmptyQueryWithHasUrlFilterReturnsUrlOnly() async {
        let vm = SearchViewModel(reader: StubBrainReader())
        vm.query = ""
        vm.filters.toggleHasUrl()
        await vm.runSearch()
        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(
            vm.hits.allSatisfy { $0.url != nil && !$0.url!.isEmpty },
            "Has-URL filter should drop hits with nil/empty URLs"
        )
    }
}

@MainActor
final class TimelineViewModelTests: XCTestCase {
    func testReloadPopulatesHitsMostRecentFirst() async {
        let vm = TimelineViewModel(reader: StubBrainReader())
        await vm.reload()
        XCTAssertEqual(vm.hits.count, 3)
        XCTAssertEqual(vm.hits.first?.eventId, 103)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
    }

    func testReloadErrorClearsHits() async {
        let vm = TimelineViewModel(reader: FailingReader())
        await vm.reload()
        XCTAssertTrue(vm.hits.isEmpty)
        XCTAssertNotNil(vm.errorMessage)
    }
}

@MainActor
final class TimelineSelectionTests: XCTestCase {
    func testMoveSelectionDownFromNilSelectsFirst() async {
        let vm = TimelineViewModel(reader: StubBrainReader())
        await vm.reload()
        vm.moveSelectionDown()
        XCTAssertEqual(vm.selectedHitId, vm.hits.first?.id)
    }

    func testMoveSelectionDownAdvances() async {
        let vm = TimelineViewModel(reader: StubBrainReader())
        await vm.reload()
        vm.selectedHitId = vm.hits[0].id
        vm.moveSelectionDown()
        XCTAssertEqual(vm.selectedHitId, vm.hits[1].id)
    }

    func testMoveSelectionDownAtEndStaysAtEnd() async {
        let vm = TimelineViewModel(reader: StubBrainReader())
        await vm.reload()
        vm.selectedHitId = vm.hits.last?.id
        vm.moveSelectionDown()
        XCTAssertEqual(vm.selectedHitId, vm.hits.first?.id)
    }

    func testMoveSelectionUpFromNilSelectsFirst() async {
        let vm = TimelineViewModel(reader: StubBrainReader())
        await vm.reload()
        vm.moveSelectionUp()
        XCTAssertEqual(vm.selectedHitId, vm.hits.first?.id)
    }

    func testMoveSelectionUpRetreats() async {
        let vm = TimelineViewModel(reader: StubBrainReader())
        await vm.reload()
        vm.selectedHitId = vm.hits[1].id
        vm.moveSelectionUp()
        XCTAssertEqual(vm.selectedHitId, vm.hits[0].id)
    }

    func testMoveSelectionUpAtTopStaysAtTop() async {
        let vm = TimelineViewModel(reader: StubBrainReader())
        await vm.reload()
        vm.selectedHitId = vm.hits[0].id
        vm.moveSelectionUp()
        XCTAssertEqual(vm.selectedHitId, vm.hits.first?.id)
    }

    func testFocusDetailWhenSelected() async {
        let vm = TimelineViewModel(reader: StubBrainReader())
        await vm.reload()
        vm.selectedHitId = vm.hits[0].id
        vm.focusDetail()
        XCTAssertTrue(vm.isDetailFocused)
    }

    func testFocusDetailWhenNilSelectionDoesNothing() {
        let vm = TimelineViewModel(reader: StubBrainReader())
        vm.focusDetail()
        XCTAssertFalse(vm.isDetailFocused)
    }

    func testDismissDetail() async {
        let vm = TimelineViewModel(reader: StubBrainReader())
        await vm.reload()
        vm.selectedHitId = vm.hits[0].id
        vm.focusDetail()
        vm.dismissDetail()
        XCTAssertFalse(vm.isDetailFocused)
    }

    func testSelectedHitReturnsCorrectHit() async {
        let vm = TimelineViewModel(reader: StubBrainReader())
        await vm.reload()
        vm.selectedHitId = vm.hits[1].id
        XCTAssertEqual(vm.selectedHit?.id, vm.hits[1].id)
    }
}

@MainActor
final class SearchSelectionTests: XCTestCase {
    func testMoveSelectionDownFromNilSelectsFirst() async {
        let vm = SearchViewModel(reader: StubBrainReader())
        vm.query = "privacy"
        await vm.runSearch()
        vm.moveSelectionDown()
        XCTAssertEqual(vm.selectedHitId, vm.hits.first?.id)
    }

    func testClearResetsFilters() async {
        let vm = SearchViewModel(reader: StubBrainReader())
        vm.filters.toggleApp("com.apple.Safari")
        vm.query = "test"
        vm.clear()
        XCTAssertFalse(vm.filters.anyActive)
        XCTAssertEqual(vm.query, "")
    }
}

@MainActor
final class PrivacyMomentsViewModelTests: XCTestCase {
    func testReloadPopulatesMomentsMostRecentFirst() async {
        let vm = PrivacyMomentsViewModel(reader: StubBrainReader())
        await vm.reload()
        XCTAssertEqual(vm.moments.count, 3)
        XCTAssertEqual(vm.moments.first?.reasonCode, 7)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
    }

    func testReloadErrorClearsMoments() async {
        let vm = PrivacyMomentsViewModel(reader: FailingReader())
        await vm.reload()
        XCTAssertTrue(vm.moments.isEmpty)
        XCTAssertNotNil(vm.errorMessage)
    }
}
