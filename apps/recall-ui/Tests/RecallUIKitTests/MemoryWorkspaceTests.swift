import XCTest

@testable import RecallUIKit

final class MemoryWorkspaceTests: XCTestCase {
    func testPrimaryNavigationDestinationsMatchNativeMemoryWorkspace() {
        let destinations = MCI.Workspace.primaryDestinations
        XCTAssertEqual(destinations.map(\.title), ["Now", "Search", "Timeline", "Episodes", "Briefs"])
        XCTAssertEqual(destinations.map(\.systemImage), [
            "sparkle.magnifyingglass",
            "magnifyingglass",
            "clock",
            "rectangle.stack",
            "doc.text",
        ])
    }

    func testPrimaryEvidenceDestinationsExposeSourceAccess() {
        let sourceBacked = MCI.Workspace.primaryDestinations.filter(\.requiresSourceAccess)
        XCTAssertEqual(sourceBacked.map(\.title), ["Search", "Timeline", "Episodes", "Briefs"])
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

    func testWorkspaceShortcutMapIsUniqueAndResolvesSourcesToCommandSix() {
        let destinations = MCI.Workspace.primaryDestinations + MCI.Workspace.secondaryDestinations
        XCTAssertEqual(destinations.map(\.keyboardShortcut), ["1", "2", "3", "4", "5", "6", "7", "8"])
        XCTAssertEqual(Set(destinations.map(\.keyboardShortcut)).count, destinations.count)
        XCTAssertEqual(MCI.Workspace.destination(forKeyboardShortcut: "6")?.id, "sources")
        XCTAssertEqual(MCI.Workspace.destination(forKeyboardShortcut: "8")?.id, "settings")
    }

    func testUtilityAndPlaceholderSurfacesAreNotPrimaryDestinations() {
        let primaryTitles = Set(MCI.Workspace.primaryDestinations.map(\.title))
        XCTAssertFalse(primaryTitles.contains("Privacy"))
        XCTAssertFalse(primaryTitles.contains("Settings"))
        XCTAssertFalse(primaryTitles.contains("Strip"))
        XCTAssertFalse(primaryTitles.contains("Chat"))
        XCTAssertEqual(MCI.Workspace.secondaryDestinations.map(\.title), [
            "Sources", "Privacy", "Settings",
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
