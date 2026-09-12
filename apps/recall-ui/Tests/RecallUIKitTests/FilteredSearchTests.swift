import XCTest
@testable import RecallUIKit

@MainActor
final class FilteredSearchTests: XCTestCase {
    private func model(_ reader: FilterRecordingReader) -> SearchViewModel {
        SearchViewModel(
            reader: reader,
            persistence: QueryPersistence(environment: ["MCI_EPHEMERAL_UI_STATE": "1"]),
            userDictionaryLoader: { .empty }
        )
    }

    func testBlankQueryWithFiltersRemainsSearchEntryWithoutReadingEvidence() async throws {
        let reader = FilterRecordingReader()
        let model = model(reader)
        defer { model.clear() }
        model.mode = .related
        model.filters = FilterState(appBundleIds: ["test.b", "test.a"], dateRange: .none, hasUrl: true)
        model.query = " \n "
        await model.runSearch()
        await model.refresh()
        let recorded = await reader.options
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertNil(model.selectedHitId)
        XCTAssertFalse(model.isSearching)
        XCTAssertTrue(model.filters.anyActive)
        XCTAssertNil(model.filterLimitationMessage)
        let recentCalls = await reader.recentCalls
        XCTAssertEqual(recentCalls, 0)
    }

    func testTextPassesAllConstraintsThroughWireBeforeLimit() async throws {
        let reader = FilterRecordingReader()
        let model = model(reader)
        defer { model.clear() }
        model.query = "needle"
        model.filters = FilterState(appBundleIds: ["test.b", "test.a"], dateRange: .yesterday, hasUrl: true)
        await model.runSearch()
        let recorded = await reader.options
        let options = try XCTUnwrap(recorded.last)
        let payload = QueryPayload(options: options)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertEqual(json["app_filters"] as? [String], ["test.a", "test.b"])
        XCTAssertEqual(json["has_url"] as? Bool, true)
        XCTAssertEqual(json["browse"] as? Bool, false)
        XCTAssertEqual(json["mode"] as? String, "text")
        XCTAssertEqual(options.timeToUs, model.filters.timeWindowUs().toUs.map { $0 - 1 })
    }

    func testOversizedRestoredSelectionIsNotSilentlyTruncatedForQuery() async throws {
        let selected = Set((0..<33).map { "mcp:source-\($0)" })
        let persisted = PersistedQueryState(query: "needle", filters: FilterState(
            appBundleIds: selected, dateRange: .none, hasUrl: false
        ))
        let restored = try JSONDecoder().decode(
            PersistedQueryState.self, from: JSONEncoder().encode(persisted)
        )
        let reader = FilterRecordingReader()
        let model = model(reader)
        defer { model.clear() }
        model.query = restored.query
        model.filters = restored.filters
        XCTAssertNotNil(model.filters.appSelectionValidationMessage)
        await model.runSearch()
        let recorded = await reader.options
        let options = try XCTUnwrap(recorded.last)
        XCTAssertEqual(options.appFilters, selected.sorted(),
                       "The FFI rejects oversized selections; do not silently narrow the query")
    }

    func testCustomDayConvertsExclusiveMidnightAndDefensivelyRejectsNextDay() async throws {
        let day = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 2)))
        let filters = FilterState(appBundleIds: [], dateRange: .custom(from: day, to: day), hasUrl: false)
        let window = filters.timeWindowUs()
        let midnight = try XCTUnwrap(window.toUs)
        let reader = FilterRecordingReader(hits: [hit(1, midnight - 1), hit(2, midnight)])
        let model = model(reader)
        defer { model.clear() }
        model.filters = filters
        for query in ["needle", "needle again"] {
            model.query = query
            await model.runSearch()
            let recorded = await reader.options
            let options = try XCTUnwrap(recorded.last)
            XCTAssertEqual(options.timeFromUs, window.fromUs)
            XCTAssertEqual(options.timeToUs, midnight - 1)
            XCTAssertEqual(model.hits.map(\.id), [1])
        }
        // Direct reader callers keep the inclusive FFI contract.
        XCTAssertEqual(SearchOptions(text: "needle", timeToUs: midnight).timeToUs, midnight)
    }

    func testZeroOrInvertedExclusiveWindowDoesNotUnderflowOrQuery() async {
        let reader = FilterRecordingReader()
        let model = model(reader)
        defer { model.clear() }
        model.query = "needle"
        for (from, to) in [(-300_000.0, -200_000.0), (300_000.0, 100_000.0)] {
            model.filters.dateRange = .custom(
                from: Date(timeIntervalSince1970: from), to: Date(timeIntervalSince1970: to)
            )
            await model.runSearch()
            XCTAssertTrue(model.hits.isEmpty)
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isSearching)
        }
        let recorded = await reader.options
        XCTAssertTrue(recorded.isEmpty)
    }

    func testUnsupportedRelatedFiltersNeverFallBackToTextOrReturnNoMatches() async {
        let reader = FilterRecordingReader()
        let model = model(reader)
        defer { model.clear() }
        model.query = "needle"
        model.mode = .related
        for filters in [
            FilterState(appBundleIds: ["test.a", "test.b"], dateRange: .none, hasUrl: false),
            FilterState(appBundleIds: [], dateRange: .none, hasUrl: true),
        ] {
            model.filters = filters
            await model.runSearch()
            XCTAssertTrue(model.hasUnsupportedRelatedFilters)
            XCTAssertTrue(model.filterLimitationMessage?.contains("Text") == true)
            XCTAssertEqual(model.mode, .related)
            XCTAssertNil(model.errorMessage)
            XCTAssertTrue(model.hits.isEmpty)
            XCTAssertFalse(model.isSearching)
        }
        let recorded = await reader.options
        XCTAssertTrue(recorded.isEmpty)
        model.mode = .text
        XCTAssertTrue(model.hasUnsupportedRelatedFilters)
        XCTAssertNil(model.filterLimitationMessage)
        await model.runSearch()
        let text = await reader.options
        XCTAssertEqual(text.last?.mode, .text)
    }

    func testRelatedSingleAppAndDateKeepsModeAndDisclosesCandidateLimit() async {
        let reader = FilterRecordingReader()
        let model = model(reader)
        defer { model.clear() }
        model.query = "needle"
        model.mode = .related
        model.filters = FilterState(appBundleIds: ["test.a"], dateRange: .yesterday, hasUrl: false)
        await model.runSearch()
        XCTAssertFalse(model.hasUnsupportedRelatedFilters)
        XCTAssertTrue(model.filterLimitationMessage?.contains("limited") == true)
        let recorded = await reader.options
        XCTAssertEqual(recorded.last?.mode, .related)
        XCTAssertEqual(recorded.last?.appFilter, "test.a")
    }

    func testStubPreservesLegacyEmptyAndExplicitBrowseFilters() async throws {
        let reader = StubBrainReader()
        let empty = try await reader.search(SearchOptions(text: ""))
        XCTAssertTrue(empty.isEmpty)
        let hits = try await reader.search(SearchOptions(
            text: "", limit: 2, browse: true, appFilters: ["com.apple.Safari"], hasUrl: true
        ))
        XCTAssertFalse(hits.isEmpty)
        XCTAssertLessThanOrEqual(hits.count, 2)
        XCTAssertTrue(hits.allSatisfy { $0.appBundleId == "com.apple.Safari" && $0.url?.isEmpty == false })
    }

    private func hit(_ id: UInt64, _ timestamp: UInt64) -> Hit {
        Hit(eventId: id, tsUs: timestamp, appBundleId: "test.a", windowTitle: nil,
            url: nil, ocrTextSnippet: "needle", source: "lexical", score: 1)
    }
}

private actor FilterRecordingReader: BrainReader {
    var options: [SearchOptions] = []
    var recentCalls = 0
    let hits: [Hit]
    init(hits: [Hit] = []) { self.hits = hits }
    func search(_ options: SearchOptions) async throws -> [Hit] { self.options.append(options); return hits }
    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] { [] }
    func recentEvents(limit: Int) async throws -> [Hit] { recentCalls += 1; return [] }
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
