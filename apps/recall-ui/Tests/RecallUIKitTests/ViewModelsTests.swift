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
