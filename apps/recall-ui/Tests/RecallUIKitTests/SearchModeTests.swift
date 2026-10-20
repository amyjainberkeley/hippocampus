import XCTest
@testable import RecallUIKit

@MainActor
final class SearchModeTests: XCTestCase {
    /// The window searches as the Ask panel does, by meaning, so the same
    /// words find the same things (SPEC 2.8). Exact Words is a switch.
    func testSearchIsByMeaningByDefaultAndExactWordsIsASwitch() async throws {
        let reader = ModeRecordingReader()
        let model = SearchViewModel(
            reader: reader,
            persistence: QueryPersistence(environment: ["MCI_EPHEMERAL_UI_STATE": "1"]),
            userDictionaryLoader: { .empty }
        )
        XCTAssertEqual(model.mode, .related)
        model.query = "rounding at checkout"
        await model.runSearch()
        let meaning = await reader.lastOptions
        XCTAssertEqual(meaning?.mode, .related)
        XCTAssertEqual(meaning?.text, "rounding at checkout")
        model.mode = .text
        await model.runSearch()
        let exact = await reader.lastOptions
        XCTAssertEqual(exact?.mode, .text)
        model.clear()
    }

    /// Words in quotes match exactly, straight quotes or curly, and the
    /// quotes themselves are not searched for.
    func testWordsInQuotesMatchExactly() async throws {
        let reader = ModeRecordingReader()
        let model = SearchViewModel(
            reader: reader,
            persistence: QueryPersistence(environment: ["MCI_EPHEMERAL_UI_STATE": "1"]),
            userDictionaryLoader: { .empty }
        )
        model.query = "\"cache_key_123\""
        await model.runSearch()
        let straight = await reader.lastOptions
        XCTAssertEqual(straight?.mode, .text)
        XCTAssertEqual(straight?.text, "cache_key_123")
        XCTAssertEqual(model.effectiveMode, .text)

        model.query = "tax \u{201C}round half\u{201D}"
        await model.runSearch()
        let curly = await reader.lastOptions
        XCTAssertEqual(curly?.mode, .text)
        XCTAssertEqual(curly?.text, "tax round half")

        XCTAssertEqual(SearchViewModel.request("it\u{2019}s 5\" wide", mode: .related).mode, .related,
                       "an apostrophe or one inch mark is no quote")
        XCTAssertEqual(SearchViewModel.request("\"\" empty", mode: .related).mode, .related,
                       "quotes around nothing are no quote")
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
