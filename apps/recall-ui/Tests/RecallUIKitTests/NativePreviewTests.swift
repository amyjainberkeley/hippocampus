import XCTest
@testable import RecallUIKit

#if DEBUG
@MainActor
final class NativePreviewTests: XCTestCase {
    func testPreviewIsExplicitAndRestrictsRoutesToMemory() {
        XCTAssertNil(NativePreviewConfiguration(arguments: []))
        let config = NativePreviewConfiguration(arguments: ["--synthetic-preview", "--preview-tab=sessions", "--preview-query=launch"])
        XCTAssertEqual(config?.tab, .episodes)
        XCTAssertEqual(config?.query, "launch")
        XCTAssertEqual(NativePreviewConfiguration(arguments: ["--synthetic-preview", "--preview-tab=privacy"])?.tab, .now)
    }

    func testSyntheticNativeReaderSupportsReviewSearchHistoryAndCanonicalText() async throws {
        let reader = NativePreviewReader()
        let model = DailyMemoryViewModel(reader: reader, selectedDate: reader.date,
                                        healthLoader: { nil }, now: { reader.now })
        await model.reload()
        XCTAssertEqual(model.review.resumePoints.count, 3)
        XCTAssertNotNil(model.activitySummary)
        XCTAssertTrue(model.review.events.allSatisfy { !$0.hasScreenshot })
        let hits = try await reader.search(SearchOptions(text: "launch", mode: .text))
        XCTAssertFalse(hits.isEmpty)
        for hit in hits {
            let text = try await reader.eventText(eventId: hit.id)
            XCTAssertTrue(text?.matches(hit) == true)
        }
        let sessions = try await reader.listEpisodes(limit: 20)
        XCTAssertFalse(sessions.isEmpty)
        let packet = try await model.exportSummary()
        XCTAssertTrue(packet.contains("focus="))
        XCTAssertFalse(packet.contains("measured hours"))
    }

    func testSyntheticEmptyAndUnavailableHaveNoChart() async {
        for scenario in [NativePreviewConfiguration.Scenario.empty, .unavailable] {
            let reader = NativePreviewReader(scenario: scenario)
            let model = DailyMemoryViewModel(reader: reader, selectedDate: reader.date,
                                            healthLoader: { nil }, now: { reader.now })
            await model.reload()
            XCTAssertTrue(model.events.isEmpty)
            XCTAssertNil(model.activitySummary)
            XCTAssertEqual(model.errorMessage != nil, scenario == .unavailable)
        }
    }
}
#endif
