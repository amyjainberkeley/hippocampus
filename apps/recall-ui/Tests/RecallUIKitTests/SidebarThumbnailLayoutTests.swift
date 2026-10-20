import XCTest
@testable import RecallUIKit

/// A Working On item's little screenshot (SPEC-DELTA 2) sits inside the
/// selection with room on both sides, and its name stays in line with every
/// other row's.
final class SidebarThumbnailLayoutTests: XCTestCase {
    func testTheScreenshotIsAboutTwentySixBySixteen() {
        let size = SidebarThumbnailLayout.size
        XCTAssertEqual(size.width, 26, accuracy: 26 * 0.1, "about 26 pt wide")
        XCTAssertEqual(size.height, 16, accuracy: 16 * 0.1, "about 16 pt tall")
        XCTAssertEqual(size.width / size.height, 26.0 / 16.0, accuracy: 0.05, "a screenshot's shape")
    }

    func testItNeverTouchesTheSelectionsEdge() {
        XCTAssertGreaterThanOrEqual(SidebarThumbnailLayout.insetFromSelection, 3)
    }

    func testItsNameHasRoom() {
        XCTAssertGreaterThanOrEqual(SidebarThumbnailLayout.gapToName, 5)
        XCTAssertGreaterThan(SidebarThumbnailLayout.gapToName, SidebarThumbnailLayout.insetFromSelection,
                             "words need more room than an edge")
    }

    func testItFitsTheRowsHeight() {
        // A medium sidebar row is 28 pt.
        XCTAssertLessThanOrEqual(SidebarThumbnailLayout.size.height, 28 - 2 * 6)
    }
}
