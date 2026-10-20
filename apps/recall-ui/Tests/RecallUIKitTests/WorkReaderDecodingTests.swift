import XCTest
@testable import RecallUIKit

/// The window reads `mci-agent work --json` as SPEC 3.12.2 writes it, with
/// each item's thumbnail moment (SPEC-DELTA 2), and the agent's empty
/// answer as no work at all.
final class WorkReaderDecodingTests: XCTestCase {
    private let sample = """
        {
          "generated_us": 1760305025000000,
          "items": [
            {
              "id": "w_9c41e2",
              "kind": "code", "name": "trailhead-shop",
              "apps": ["com.microsoft.VSCode", "com.apple.Terminal"],
              "last_us": 1760304000000000,
              "week_minutes": 160, "days_this_week": 3,
              "in_sidebar": true, "hidden_reason": null,
              "files": [{"name": "tax.rs", "last_us": 1760304000000000, "moment": 4790}],
              "alongside": [{"kind": "page", "title": "Rounding half to even", "host": "devnotes.example",
                              "app": "com.google.Chrome", "moment": 4812, "last_us": 1760300400000000}],
              "folder_guess": "~/dev/trailhead-shop",
              "moments": [4812, 4790, 4777],
              "thumbnail_moment": 4790
            }
          ],
          "pages": [
            {"title": "Rounding half to even", "host": "devnotes.example", "path": "/rounding",
             "app": "com.google.Chrome", "days": 3, "last_us": 1760305000000000, "moments": [4812, 4401]}
          ],
          "moment_items": {"4812": "w_9c41e2"}
        }
        """

    func testTheSpecsSampleReadsWhole() throws {
        let work = try JSONDecoder().decode(WorkSnapshot.self, from: Data(sample.utf8))
        XCTAssertEqual(work.generatedUs, 1_760_305_025_000_000)
        let item = try XCTUnwrap(work.items.first)
        XCTAssertEqual(item.id, "w_9c41e2")
        XCTAssertEqual(item.kind, .code)
        XCTAssertEqual(item.name, "trailhead-shop")
        XCTAssertEqual(item.apps, ["com.microsoft.VSCode", "com.apple.Terminal"])
        XCTAssertEqual(item.weekMinutes, 160)
        XCTAssertEqual(item.daysThisWeek, 3)
        XCTAssertTrue(item.inSidebar)
        XCTAssertNil(item.hiddenReason)
        XCTAssertEqual(item.files, [WorkFile(name: "tax.rs", lastUs: 1_760_304_000_000_000, moment: 4790)])
        XCTAssertEqual(item.alongside.first?.host, "devnotes.example")
        XCTAssertEqual(item.folderGuess, "~/dev/trailhead-shop")
        XCTAssertEqual(item.moments, [4812, 4790, 4777])
        XCTAssertEqual(item.thumbnailMoment, 4790)
        XCTAssertEqual(work.pages.first?.path, "/rounding")
        XCTAssertEqual(work.pages.first?.days, 3)
        XCTAssertEqual(work.momentItems, [4812: "w_9c41e2"])
    }

    func testTheAgentsEmptyAnswerIsNoWork() throws {
        let work = try JSONDecoder().decode(
            WorkSnapshot.self,
            from: Data(#"{"generated_us": 1, "items": [], "pages": [], "moment_items": {}}"#.utf8)
        )
        XCTAssertEqual(work, WorkSnapshot(generatedUs: 1))
        XCTAssertEqual(try JSONDecoder().decode(WorkSnapshot.self, from: Data("{}".utf8)), .empty)
    }

    func testAnItemWithoutAScreenshotHasNoThumbnail() throws {
        let item = try JSONDecoder().decode(WorkItem.self, from: Data(#"""
            {"id": "w_1", "kind": "document", "name": "Q4 planning", "last_us": 5}
            """#.utf8))
        XCTAssertNil(item.thumbnailMoment)
        XCTAssertEqual(item.moments, [])
        XCTAssertTrue(item.inSidebar)
    }

    func testPagesAndSearchesAreNeverItems() {
        for kind in ["page", "search", "ai_chat", ""] {
            XCTAssertThrowsError(try JSONDecoder().decode(WorkItem.self, from: Data(#"""
                {"id": "w_1", "kind": "\#(kind)", "name": "Rounding", "last_us": 5}
                """#.utf8)), kind)
        }
        XCTAssertEqual(WorkItem.Kind.allCases, [.code, .document, .design, .spreadsheet])
    }

    func testAMomentKeyThatIsNotAnIDIsDropped() throws {
        let work = try JSONDecoder().decode(
            WorkSnapshot.self, from: Data(#"{"moment_items": {"4812": "w_1", "x": "w_2", "012": "w_3", "12": "w_4"}}"#.utf8)
        )
        XCTAssertEqual(work.momentItems[4812], "w_1")
        XCTAssertEqual(work.momentItems.count, 2, "a key that reads as no id is dropped; two that read as one keep one")
    }

    func testAnItemsPageReadsItsSitesTimeConversationsAndSessions() throws {
        let item = try JSONDecoder().decode(WorkItem.self, from: Data(#"""
            {"id": "w_0e6d2a9f8c3b7154de22", "kind": "document", "name": "Q4 planning",
             "apps": ["com.google.Chrome"], "hosts": ["docs.google.com"], "last_us": 1791839940000000,
             "week_minutes": 90, "days_this_week": 3, "total_minutes": 150,
             "in_sidebar": true, "recent": true, "hidden_reason": null,
             "conversations": [{"name": "#launch", "app": "com.tinyspeck.slackmacgap", "moment": 81228,
                                "last_us": 1791841680000000}],
             "sessions": [{"start_us": 1791839700000000, "end_us": 1791840600000000}]}
            """#.utf8))
        XCTAssertEqual(item.hosts, ["docs.google.com"])
        XCTAssertEqual(item.totalMinutes, 150)
        XCTAssertEqual(item.conversations, [WorkConversation(name: "#launch", app: "com.tinyspeck.slackmacgap",
                                                             moment: 81_228, lastUs: 1_791_841_680_000_000)])
        XCTAssertEqual(item.sessions, [WorkSession(startUs: 1_791_839_700_000_000, endUs: 1_791_840_600_000_000)])
        XCTAssertTrue(item.recent)
        XCTAssertEqual(WorkFormat.placesSentence(item, appName: { _ in "Chrome" }), "Google Docs in Chrome")
    }

    func testAnOlderAgentsItemReadsWithItsWeekAsItsTotal() throws {
        let item = try JSONDecoder().decode(WorkItem.self, from: Data(#"""
            {"id": "w_1", "kind": "spreadsheet", "name": "Mortgage refinance", "last_us": 5, "week_minutes": 40,
             "in_sidebar": false, "hidden_reason": "personal"}
            """#.utf8))
        XCTAssertEqual(item.totalMinutes, 40)
        XCTAssertFalse(item.recent, "without the field, it is what the sidebar says")
        XCTAssertTrue(item.looksPersonal)
        XCTAssertEqual(item.conversations, [])
        XCTAssertEqual(item.sessions, [])
        XCTAssertEqual(item.hosts, [])
    }

    func testThePreviewReaderReadsNothingButItsFixtures() async throws {
        let empty = PreviewWorkReader()
        let snapshot = try await empty.work(days: 90)
        XCTAssertEqual(snapshot, .empty)
        let item = try await empty.item(id: "w_1", before: nil)
        XCTAssertNil(item)
        let lookups = try await empty.items(forMoments: [1, 2])
        XCTAssertEqual(lookups, [:])

        let fixture = try JSONDecoder().decode(WorkSnapshot.self, from: Data(sample.utf8))
        let reader = PreviewWorkReader(snapshot: fixture)
        let found = try await reader.item(id: "w_9c41e2", before: nil)
        XCTAssertEqual(found?.name, "trailhead-shop")
        let asked = try await reader.items(forMoments: [4812, 1])
        XCTAssertEqual(asked, [4812: "w_9c41e2"])
    }
}
