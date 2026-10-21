import AppKit
import SwiftUI
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

    /// Show All has no symbol, and its words start where every row's name
    /// does (SPEC 2.2, "aligned with the labels"). A fixed indent put it
    /// about 9 pt to their left.
    @MainActor
    func testShowAllStartsWhereTheRowNamesStart() throws {
        let named = try wordsStart(Label("History", systemImage: "clock"), afterSymbol: true)
        let showAll = try wordsStart(SidebarTextRow("Show All"), afterSymbol: false)
        XCTAssertEqual(showAll, named, accuracy: 1, "points from the list's edge")
    }

    /// Where a sidebar row's words start, in points from the list's edge:
    /// the row alone in a sidebar list, drawn offscreen as the window's
    /// pictures are (a window never ordered in), its ink found column by
    /// column. A symbol is the first run of ink, and the words the next.
    /// Ink is anything clearly darker than the list behind it: a list in a
    /// window that isn't key draws its words grey.
    @MainActor
    private func wordsStart(_ row: some View, afterSymbol: Bool) throws -> CGFloat {
        // As the window's renderer does: no Dock icon, nothing ever on screen.
        NSApplication.shared.setActivationPolicy(.prohibited)
        let size = NSSize(width: 220, height: 44)
        let hosting = NSHostingView(rootView: List { row }.listStyle(.sidebar).frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .aqua)
        hosting.appearance = window.appearance
        window.contentView = hosting
        defer { window.contentView = nil }
        for _ in 0..<10 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        // How light a pixel looks over white.
        func lightness(_ x: Int, _ y: Int) -> CGFloat {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 1 }
            let alpha = color.alphaComponent
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3 * alpha + (1 - alpha)
        }
        let behind = lightness(2, 2)
        var starts: [Int] = []
        var inkBefore = false
        for x in 0..<rep.pixelsWide {
            let ink = (0..<rep.pixelsHigh).contains { y in lightness(x, y) < behind - 0.15 }
            if ink, !inkBefore { starts.append(x) }
            inkBefore = ink
        }
        guard !starts.isEmpty else { throw XCTSkip("nothing was drawn offscreen") }
        let index = afterSymbol ? 1 : 0
        XCTAssertGreaterThan(starts.count, index, "a symbol, then words")
        guard starts.count > index else { return 0 }
        return CGFloat(starts[index]) / scale
    }
}
