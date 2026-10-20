import XCTest

@testable import RecallUIKit

final class MemoryWorkspaceTests: XCTestCase {
    /// The sidebar's places with a key, in key order (SPEC 2.2 with
    /// SPEC-DELTA 1): ⌘1 Today to ⌘9 AI Tools.
    func testTheSidebarsKeyedPlacesAreTodayToAITools() {
        let destinations = MCI.Workspace.primaryDestinations
        XCTAssertEqual(destinations.map(\.title), [
            "Today", "History", "Web Pages", "Documents", "Code", "Conversations", "Looked Up", "About You", "AI Tools",
        ])
        XCTAssertEqual(destinations.map(\.systemImage), [
            "sun.max", "clock", "globe", "doc.text", "chevron.left.forwardslash.chevron.right",
            "bubble.left.and.bubble.right", "text.magnifyingglass", "person.crop.circle", "cable.connector",
        ])
        XCTAssertEqual(MCI.Workspace.allDestinations.last?.title, "Privacy", "Privacy is a row with no key")
    }

    func testHistoryAndItsKindsReadMoments() {
        let sourceBacked = MCI.Workspace.primaryDestinations.filter(\.requiresSourceAccess)
        XCTAssertEqual(sourceBacked.map(\.title), ["History", "Web Pages", "Documents", "Code", "Conversations",
                                                    "Looked Up"])
    }

    func testNowMetricDescribesHistoricalRowsWithoutClaimingLiveCaptureState() {
        let summary = SummaryStats(
            totalEvents: 42,
            oldestTsUs: 1_000,
            newestTsUs: 2_000,
            diskBytes: 4_096
        )

        let metric = MCI.Workspace.historicalEventMetric(for: summary)

        XCTAssertEqual(metric.title, "Stored events")
        XCTAssertEqual(metric.value, "42")
        XCTAssertEqual(metric.detail, "Historical memory rows")
    }

    func testRecentKeyframesRequireANonemptyThumbnailPath() {
        let hits = [
            makeHit(id: 1, ocr: "OCR only", thumbnailPath: nil),
            makeHit(id: 2, ocr: "OCR only", thumbnailPath: ""),
            makeHit(id: 3, ocr: "OCR only", thumbnailPath: "   "),
            makeHit(id: 4, ocr: "", thumbnailPath: "/tmp/keyframe-4.bin"),
            makeHit(id: 5, ocr: "Visible text", thumbnailPath: "/tmp/keyframe-5.bin"),
        ]

        XCTAssertEqual(MCI.Workspace.recentKeyframes(from: hits).map(\.eventId), [4, 5])
    }

    func testFilmstripCountUsesKeyframeUnit() {
        XCTAssertEqual(MCI.Workspace.keyframeCountLabel(0), "0 keyframes")
        XCTAssertEqual(MCI.Workspace.keyframeCountLabel(1), "1 keyframe")
        XCTAssertEqual(MCI.Workspace.keyframeCountLabel(12), "12 keyframes")
    }

    func testEvidenceFilmstripCompactsToPreservePrimaryContentInShortWindows() {
        XCTAssertEqual(MCI.Workspace.evidenceFilmstripHeight(availableHeight: 599), 136)
        XCTAssertEqual(MCI.Workspace.evidenceFilmstripHeight(availableHeight: 600), 200)
    }

    func testEvidenceSummaryStripsCaptureHeaderAndNormalizesWhitespace() {
        let hit = Hit(
            eventId: 9,
            tsUs: 9,
            appBundleId: "com.apple.Safari",
            windowTitle: "Architecture",
            url: "https://hippocampus.local/architecture",
            ocrTextSnippet: "[app=Safari | title=Architecture | url=https://hippocampus.local/architecture | ts=2026-09-02T10:00:00Z]\nLocal   memory\nkeeps exact evidence.",
            source: "timeline",
            score: nil
        )

        XCTAssertEqual(
            Formatters.evidenceSummary(hit),
            "Local memory keeps exact evidence."
        )
    }

    func testEvidenceSummaryNamesAKeyframeWithNoText() {
        XCTAssertEqual(
            Formatters.evidenceSummary(makeHit(id: 4, ocr: "", thumbnailPath: "/tmp/4.bin")),
            "Visual evidence"
        )
    }

    /// ⌘1 to ⌘9 never move; Privacy opens from its row and the status menu.
    func testThePlacesAreCommandOneToNineAndPrivacyHasNone() {
        let destinations = MCI.Workspace.allDestinations
        XCTAssertEqual(destinations.count, 10)
        XCTAssertEqual(destinations.map(\.keyboardShortcut), ["1", "2", "3", "4", "5", "6", "7", "8", "9", ""])
        XCTAssertEqual(MCI.Workspace.destination(forKeyboardShortcut: "1")?.id, "today")
        XCTAssertEqual(MCI.Workspace.destination(forKeyboardShortcut: "2")?.id, "history")
        XCTAssertEqual(MCI.Workspace.destination(forKeyboardShortcut: "8")?.id, "aboutYou")
        XCTAssertEqual(MCI.Workspace.destination(forKeyboardShortcut: "9")?.id, "aiTools")
        XCTAssertNil(MCI.Workspace.destination(forKeyboardShortcut: "0"))
        XCTAssertNil(MCI.Workspace.destination(forKeyboardShortcut: ""))
    }

    /// The old places' names go (SPEC 2.2: Overview, Ask and You).
    func testOldPlacesAreNotInTheSidebar() {
        let titles = Set(MCI.Workspace.allDestinations.map(\.title))
        for old in ["Overview", "Ask", "You", "Search", "Sessions", "Connections", "Settings", "Strip", "Chat"] {
            XCTAssertFalse(titles.contains(old), old)
        }
    }

    private func makeHit(
        id: UInt64,
        ocr: String,
        thumbnailPath: String?
    ) -> Hit {
        Hit(
            eventId: id,
            tsUs: id,
            appBundleId: "com.example.app",
            windowTitle: "Window",
            url: nil,
            ocrTextSnippet: ocr,
            source: "timeline",
            score: nil,
            thumbnailPath: thumbnailPath
        )
    }
}
