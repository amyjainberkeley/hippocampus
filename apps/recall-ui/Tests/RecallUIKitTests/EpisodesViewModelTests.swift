// EpisodesViewModelTests.swift — state-machine tests for the Episodes
// tab view model and the dynamic per-app reader endpoints.

import XCTest
@testable import RecallUIKit

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
}

/// Fixed-corpus reader so the tests pin the rendered episode order
/// without leaning on StubBrainReader's canned data.
private struct FixedEpisodesReader: BrainReader {
    let episodes: [Episode]
    let apps: [ObservedApp]

    func search(_ opts: SearchOptions) async throws -> [Hit] { [] }
    func recentEvents(limit: Int) async throws -> [Hit] { [] }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(
        limit: Int, timeFromUs: UInt64?
    ) async throws -> [ObservedApp] {
        Array(apps.prefix(max(0, limit)))
    }
    func listEpisodes(limit: Int) async throws -> [Episode] {
        Array(episodes.prefix(max(0, limit)))
    }
    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }
}

@MainActor
final class EpisodesViewModelTests: XCTestCase {
    private func makeEpisodes() -> [Episode] {
        [
            Episode(
                episodeId: 1, appBundleId: "com.apple.Safari",
                tsStartUs: 100, tsEndUs: 200, eventCount: 5
            ),
            Episode(
                episodeId: 2, appBundleId: "com.microsoft.VSCode",
                tsStartUs: 300, tsEndUs: 800, eventCount: 12
            ),
            Episode(
                episodeId: 3, appBundleId: nil,
                tsStartUs: 1_000, tsEndUs: 1_500, eventCount: 1
            ),
        ]
    }

    func testReloadPopulatesEpisodesFromReader() async {
        let reader = FixedEpisodesReader(
            episodes: makeEpisodes(),
            apps: []
        )
        let vm = EpisodesViewModel(reader: reader)
        await vm.reload()
        XCTAssertEqual(vm.episodes.count, 3)
        XCTAssertEqual(vm.episodes.first?.episodeId, 1)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
    }

    func testReloadErrorClearsEpisodes() async {
        let vm = EpisodesViewModel(reader: FailingReader())
        await vm.reload()
        XCTAssertTrue(vm.episodes.isEmpty)
        XCTAssertNotNil(vm.errorMessage)
    }

    func testDurationSecondsComputesFromTimestamps() {
        let ep = Episode(
            episodeId: 1, appBundleId: nil,
            tsStartUs: 2_000_000, tsEndUs: 5_000_000, eventCount: 1
        )
        XCTAssertEqual(ep.durationSeconds, 3.0, accuracy: 1e-6)
    }

    func testDurationSecondsClampsToZeroWhenInverted() {
        let ep = Episode(
            episodeId: 1, appBundleId: nil,
            tsStartUs: 5_000_000, tsEndUs: 2_000_000, eventCount: 1
        )
        XCTAssertEqual(ep.durationSeconds, 0.0, accuracy: 1e-6)
    }

    func testSelectedEpisodeReturnsCorrectRow() async {
        let reader = FixedEpisodesReader(episodes: makeEpisodes(), apps: [])
        let vm = EpisodesViewModel(reader: reader)
        await vm.reload()
        vm.selectedEpisodeId = vm.episodes[1].id
        XCTAssertEqual(vm.selectedEpisode?.episodeId, 2)
    }
}

@MainActor
final class ListObservedAppsTests: XCTestCase {
    func testStubObservedAppsRanksByCount() async throws {
        let stub = StubBrainReader()
        let out = try await stub.listObservedApps(limit: 10, timeFromUs: nil)
        // demoHits has one event each for Safari / VSCode / Slack.
        XCTAssertEqual(out.count, 3)
        XCTAssertTrue(out.allSatisfy { $0.count == 1 })
    }

    func testStubObservedAppsRespectsTimeWindow() async throws {
        let stub = StubBrainReader()
        let cutoff: UInt64 = 1_736_000_120_000_000 // VSCode + Slack only
        let out = try await stub.listObservedApps(limit: 10, timeFromUs: cutoff)
        XCTAssertEqual(out.map(\.appBundleId).sorted(), [
            "com.microsoft.VSCode",
            "com.tinyspeck.slackmacgap",
        ])
    }

    func testStubObservedAppsRespectsLimit() async throws {
        let stub = StubBrainReader()
        let out = try await stub.listObservedApps(limit: 1, timeFromUs: nil)
        XCTAssertEqual(out.count, 1)
    }
}

@MainActor
final class SearchViewModelFilterPropagationTests: XCTestCase {
    /// Reader that records the SearchOptions it received so a test can
    /// assert that FilterState was projected into the wire correctly.
    private final class CapturingReader: BrainReader, @unchecked Sendable {
        var lastOptions: SearchOptions?
        let hits: [Hit]
        init(hits: [Hit]) { self.hits = hits }
        func search(_ opts: SearchOptions) async throws -> [Hit] {
            lastOptions = opts
            return hits
        }
        func recentEvents(limit: Int) async throws -> [Hit] { [] }
        func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
        func listObservedApps(
            limit: Int, timeFromUs: UInt64?
        ) async throws -> [ObservedApp] { [] }
        func listEpisodes(limit: Int) async throws -> [Episode] { [] }
        func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
        func latestBrief() async throws -> Brief? { nil }
        func briefDates(limit: Int) async throws -> [String] { [] }
    }

    func testSingleAppPassesThroughAsWireFilter() async {
        let reader = CapturingReader(hits: [])
        let vm = SearchViewModel(reader: reader)
        vm.query = "x"
        vm.filters.toggleApp("com.apple.Safari")
        await vm.runSearch()
        XCTAssertEqual(reader.lastOptions?.appFilter, "com.apple.Safari")
    }

    func testMultiAppPostFiltersClientSide() async {
        // Reader returns events for several apps; vm should narrow to two.
        let hits = [
            Hit(
                eventId: 1, tsUs: 1, appBundleId: "com.apple.Safari",
                windowTitle: nil, url: nil, ocrTextSnippet: "a",
                source: "lexical", score: 1
            ),
            Hit(
                eventId: 2, tsUs: 2, appBundleId: "com.microsoft.VSCode",
                windowTitle: nil, url: nil, ocrTextSnippet: "b",
                source: "lexical", score: 1
            ),
            Hit(
                eventId: 3, tsUs: 3, appBundleId: "com.tinyspeck.slackmacgap",
                windowTitle: nil, url: nil, ocrTextSnippet: "c",
                source: "lexical", score: 1
            ),
        ]
        let reader = CapturingReader(hits: hits)
        let vm = SearchViewModel(reader: reader)
        vm.query = "x"
        vm.filters.toggleApp("com.apple.Safari")
        vm.filters.toggleApp("com.microsoft.VSCode")
        await vm.runSearch()
        XCTAssertNil(reader.lastOptions?.appFilter,
                     "two-app selection cannot use the single-app wire filter")
        XCTAssertEqual(Set(vm.hits.map(\.eventId)), [1, 2])
    }

    func testDateRangeProjectsIntoSearchOptionsTimeBounds() async {
        let reader = CapturingReader(hits: [])
        let vm = SearchViewModel(reader: reader)
        vm.query = "x"
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let to = Date(timeIntervalSince1970: 1_700_086_400)
        vm.filters.setDateRange(.custom(from: from, to: to))
        await vm.runSearch()
        XCTAssertNotNil(reader.lastOptions?.timeFromUs)
        XCTAssertNotNil(reader.lastOptions?.timeToUs)
    }
}
