import XCTest
@testable import RecallUIKit

@MainActor
final class SearchModeTests: XCTestCase {
    func testHumanSearchDefaultsToTextAndRelatedIsExplicit() async throws {
        let reader = ModeRecordingReader()
        let model = SearchViewModel(
            reader: reader,
            persistence: QueryPersistence(environment: ["MCI_EPHEMERAL_UI_STATE": "1"]),
            userDictionaryLoader: { .empty }
        )
        model.query = "cache_key_123"
        await model.runSearch()
        let text = await reader.lastOptions
        XCTAssertEqual(text?.mode, .text)
        model.mode = .related
        await model.runSearch()
        let related = await reader.lastOptions
        XCTAssertEqual(related?.mode, .related)
        model.clear()
    }

    func testWirePayloadCarriesModeWithoutChangingLiteralText() throws {
        let payload = QueryPayload(options: SearchOptions(text: "one OR two", mode: .text))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertEqual(value["text"] as? String, "one OR two")
        XCTAssertEqual(value["mode"] as? String, "text")
        XCTAssertEqual(SearchOptions(text: "legacy").mode, .related)
    }
}

private actor ModeRecordingReader: BrainReader {
    var lastOptions: SearchOptions?
    func search(_ options: SearchOptions) async throws -> [Hit] { lastOptions = options; return [] }
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
