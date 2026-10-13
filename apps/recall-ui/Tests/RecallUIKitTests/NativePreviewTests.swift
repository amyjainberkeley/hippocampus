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
        XCTAssertEqual(NativePreviewConfiguration(arguments: ["--synthetic-preview", "--preview-tab=you"])?.tab, .you)
        XCTAssertEqual(NativePreviewConfiguration(arguments: ["--synthetic-preview", "--preview-tab=ask"])?.tab, .search)
        XCTAssertEqual(NativePreviewConfiguration(arguments: ["--synthetic-preview", "--preview-tab=overview"])?.tab, .now)
    }

    func testSyntheticNativeReaderSupportsSearchHistoryAndCanonicalText() async throws {
        let reader = NativePreviewReader()
        let recent = try await reader.recentEvents(limit: 50)
        // Three apps, and the recent moment the Right now card needs
        // (critique-recall-engineering finding 13).
        XCTAssertEqual(Set(recent.compactMap(\.appBundleId)).count, 3)
        XCTAssertEqual(recent.first?.id, NativePreviewReader.recentEventId)
        XCTAssertTrue(recent.allSatisfy { ($0.thumbnailPath ?? "").isEmpty }, "the preview has no screenshots")
        let hits = try await reader.search(SearchOptions(text: "launch", mode: .text))
        XCTAssertFalse(hits.isEmpty)
        for hit in hits {
            let text = try await reader.eventText(eventId: hit.id)
            XCTAssertTrue(text?.matches(hit) == true)
        }
        let sessions = try await reader.listEpisodes(limit: 20)
        XCTAssertFalse(sessions.isEmpty)
    }

    func testSyntheticEmptyAndUnavailableReadNothing() async {
        let empty = NativePreviewReader(scenario: .empty)
        let none = try? await empty.recentEvents(limit: 50)
        XCTAssertEqual(none?.isEmpty, true)
        do {
            _ = try await NativePreviewReader(scenario: .unavailable).recentEvents(limit: 50)
            XCTFail("the unavailable preview must fail like an unreachable memory")
        } catch {}
    }
}
#endif
