import Combine
import XCTest
@testable import RecallUIKit

@MainActor
final class SearchFreshnessTests: XCTestCase {
    private func model(_ reader: BrainReader) -> SearchViewModel {
        SearchViewModel(
            reader: reader,
            persistence: QueryPersistence(environment: ["MCI_EPHEMERAL_UI_STATE": "1"]),
            userDictionaryLoader: { .empty }
        )
    }

    func testOlderSuccessCannotReplaceNewerSearch() async {
        let started = expectation(description: "old search started")
        let reader = DelayedSearchReader(started: started)
        let vm = model(reader)
        vm.query = "old"
        let old = Task { await vm.runSearch() }
        await fulfillment(of: [started], timeout: 2)
        vm.query = "new"
        await vm.runSearch()
        await reader.finishOld(failing: false)
        await old.value
        XCTAssertEqual(vm.hits.map(\.eventId), [102])
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isSearching)
    }

    func testOlderFailureCannotClearNewerSearch() async {
        let started = expectation(description: "old search started")
        let reader = DelayedSearchReader(started: started)
        let vm = model(reader)
        vm.query = "old"
        let old = Task { await vm.runSearch() }
        await fulfillment(of: [started], timeout: 2)
        vm.query = "new"
        await vm.runSearch()
        await reader.finishOld(failing: true)
        await old.value
        XCTAssertEqual(vm.hits.map(\.eventId), [102])
        XCTAssertNil(vm.errorMessage)
    }

    func testClearPreventsInFlightResultsFromReappearing() async {
        let started = expectation(description: "old search started")
        let reader = DelayedSearchReader(started: started)
        let vm = model(reader)
        vm.query = "old"
        let old = Task { await vm.runSearch() }
        await fulfillment(of: [started], timeout: 2)
        vm.clear()
        await reader.finishOld(failing: false)
        await old.value
        XCTAssertTrue(vm.hits.isEmpty)
        XCTAssertNil(vm.selectedHitId)
        XCTAssertFalse(vm.isSearching)
    }

    func testChangedFiltersRejectResultsFromOldSnapshot() async {
        let started = expectation(description: "old search started")
        let reader = DelayedSearchReader(started: started)
        let vm = model(reader)
        vm.query = "old"
        let old = Task { await vm.runSearch() }
        await fulfillment(of: [started], timeout: 2)
        vm.filters.toggleHasUrl()
        await reader.finishOld(failing: false)
        await old.value
        XCTAssertTrue(vm.hits.isEmpty, "old query results must not be relabeled with new filters")
        vm.clear()
    }

    func testExplicitSourceFocusWinsOverPendingSearch() async {
        let started = expectation(description: "old search started")
        let reader = DelayedSearchReader(started: started)
        let vm = model(reader)
        vm.query = "old"
        let old = Task { await vm.runSearch() }
        await fulfillment(of: [started], timeout: 2)
        await vm.focusEvent(id: 103)
        await reader.finishOld(failing: false)
        await old.value
        XCTAssertEqual(vm.hits.map(\.eventId), [103])
        XCTAssertEqual(vm.selectedHitId, 103)
        XCTAssertTrue(vm.isDetailFocused)
    }

    func testTypingRunsSearchWithoutEnterOrPeriodicRefresh() async {
        let vm = model(StubBrainReader())
        let populated = expectation(description: "typing populated results")
        let subscription = vm.$hits.sink { hits in
            if hits.map(\.eventId) == [101] { populated.fulfill() }
        }
        vm.query = "privacy"
        await fulfillment(of: [populated], timeout: 2)
        XCTAssertEqual(vm.hits.map(\.eventId), [101])
        subscription.cancel()
        vm.clear()
    }

    func testRefreshKeepsAnExplicitlyOpenedSourceInsteadOfRestoringOldQuery() async {
        let vm = model(StubBrainReader())
        vm.query = "privacy"
        await vm.focusEvent(id: 103)
        await vm.refresh()
        XCTAssertEqual(vm.hits.map(\.eventId), [103])
        XCTAssertEqual(vm.selectedHitId, 103)
        XCTAssertTrue(vm.isDetailFocused)
        vm.clear()
    }
}

// Only the asynchronous read is controlled; the production view model owns
// query state, filtering, cancellation and publication in every test.
private actor DelayedSearchReader: BrainReader {
    let started: XCTestExpectation
    var pending: CheckedContinuation<[Hit], Error>?

    init(started: XCTestExpectation) { self.started = started }

    func search(_ opts: SearchOptions) async throws -> [Hit] {
        if opts.text == "old" {
            return try await withCheckedThrowingContinuation {
                pending = $0
                started.fulfill()
            }
        }
        return [StubBrainReader.demoHits[1]]
    }

    func finishOld(failing: Bool) {
        if failing {
            pending?.resume(throwing: BrainReaderError.queryFailed("delayed fixture"))
        } else {
            pending?.resume(returning: [StubBrainReader.demoHits[0]])
        }
        pending = nil
    }

    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] {
        try await StubBrainReader().fetchEventsByIds(ids)
    }
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
