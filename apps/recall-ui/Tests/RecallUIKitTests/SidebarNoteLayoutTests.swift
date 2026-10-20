import AppKit
import XCTest
@testable import RecallUIKit

/// Working On's footnote is never cut off (SPEC 2.3): a sidebar list gives a
/// row one line unless the row says how tall it is, so the note's row is as
/// tall as its lines at every width the sidebar can be.
final class SidebarNoteLayoutTests: XCTestCase {
    private let note = NavigationCopy.workingOnFootnote

    private func oneLineWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: SidebarNoteLayout.fontSize)]).width
    }

    func testTheFootnoteGetsEveryLineItNeedsAtEveryWidth() {
        for width in stride(from: CGFloat(180), through: 260, by: 10) {
            let wrapWidth = SidebarNoteLayout.textWidth(sidebarWidth: width)
            let lines = SidebarNoteLayout.lines(note, sidebarWidth: width)
            // The fewest lines the words could take at that width.
            let fewest = Int((oneLineWidth(note) / wrapWidth).rounded(.up))
            XCTAssertGreaterThanOrEqual(lines, fewest, "every line is counted at \(width) points")
            XCTAssertGreaterThan(lines, 1, "the note wraps instead of being cut to one line at \(width)")
            // A view sets 11-point lines 14 points apart, a little more than
            // the font's own line height: each line has that room.
            let height = SidebarNoteLayout.height(note, sidebarWidth: width)
            XCTAssertGreaterThanOrEqual(height, CGFloat(lines) * 14, "room for every line at \(width)")
        }
    }

    func testANarrowerSidebarNeverGivesTheNoteLessRoom() {
        var previous = CGFloat.greatestFiniteMagnitude
        for width in stride(from: CGFloat(180), through: 260, by: 10) {
            let height = SidebarNoteLayout.height(note, sidebarWidth: width)
            XCTAssertLessThanOrEqual(height, previous, "wider never needs more room (\(width) points)")
            previous = height
        }
    }

    func testTheWordsWrapInsideTheRowsInsets() {
        for width in [CGFloat(180), 200, 260] {
            let wrap = SidebarNoteLayout.textWidth(sidebarWidth: width)
            XCTAssertLessThanOrEqual(wrap + SidebarNoteLayout.labelInset + SidebarNoteLayout.listInsets, width + 0.5)
            XCTAssertGreaterThanOrEqual(wrap, 80)
        }
    }

    func testAShortNoteIsOneLine() {
        XCTAssertEqual(SidebarNoteLayout.lines("Short.", sidebarWidth: 200), 1)
        let height = SidebarNoteLayout.height("Short.", sidebarWidth: 200)
        XCTAssertGreaterThanOrEqual(height, 14)
        XCTAssertLessThan(height, 28)
    }
}
