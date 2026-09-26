import XCTest

@testable import RecallUIKit

final class MemoryWorkspaceTests: XCTestCase {
    func testPrimaryNavigationDestinationsMatchNativeMemoryWorkspace() {
        let destinations = MCI.Workspace.primaryDestinations
        XCTAssertEqual(destinations.map(\.title), ["Today", "Search", "History"])
        XCTAssertEqual(destinations.map(\.systemImage), [
            "calendar",
            "magnifyingglass",
            "clock",
        ])
    }

    func testPrimaryEvidenceDestinationsExposeSourceAccess() {
        let sourceBacked = MCI.Workspace.primaryDestinations.filter(\.requiresSourceAccess)
        XCTAssertEqual(sourceBacked.map(\.title), ["Search", "History"])
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

    func testWorkspaceShortcutMapIsUniqueAndResolvesSourcesToCommandSix() {
        let destinations = MCI.Workspace.allDestinations
        XCTAssertEqual(destinations.map(\.keyboardShortcut), ["1", "2", "3", "4", "6", "7", "8"])
        XCTAssertEqual(Set(destinations.map(\.keyboardShortcut)).count, destinations.count)
        XCTAssertEqual(MCI.Workspace.destination(forKeyboardShortcut: "6")?.id, "sources")
        XCTAssertEqual(MCI.Workspace.destination(forKeyboardShortcut: "8")?.id, "settings")
        XCTAssertEqual(MCI.Workspace.destination(forKeyboardShortcut: "5")?.id, "now")
    }

    func testUtilityAndPlaceholderSurfacesAreNotPrimaryDestinations() {
        let primaryTitles = Set(MCI.Workspace.primaryDestinations.map(\.title))
        XCTAssertFalse(primaryTitles.contains("Privacy"))
        XCTAssertFalse(primaryTitles.contains("Settings"))
        XCTAssertFalse(primaryTitles.contains("Strip"))
        XCTAssertFalse(primaryTitles.contains("Chat"))
        XCTAssertEqual(MCI.Workspace.secondaryDestinations.map(\.title), [
            "Connections", "Privacy", "Settings",
        ])
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
