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

    func testCaptureStatusIsVisibleFromNowDestination() {
        let now = MCI.Workspace.primaryDestinations.first { $0.title == "Now" }
        XCTAssertEqual(now?.showsCaptureStatus, true)
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
}
