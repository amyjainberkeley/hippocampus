import CoreGraphics
import XCTest
@testable import MCICaptureHelperKit

final class BackgroundCapturePolicyTests: XCTestCase {
    /// A 1000x600-point display at the global origin.
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let denylist = SensitiveCaptureDenylist(entries: [])

    /// A line centred at a global point (top-left origin), as OCR reports it:
    /// normalized to the display, bottom-left origin.
    private func line(_ text: String, at point: CGPoint) -> OCRLine {
        let w: CGFloat = 0.1, h: CGFloat = 0.02
        let cx = point.x / display.width, cy = 1 - point.y / display.height
        return OCRLine(text: text, boundingBox: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h), confidence: 0.9)
    }

    private func window(_ id: CGWindowID, _ bundle: String?, _ title: String?, _ rect: CGRect,
                        layer: Int = 0, pid: pid_t = 0) -> VisibleWindow {
        VisibleWindow(windowId: id, ownerPid: pid, bundleId: bundle, title: title, bounds: rect, layer: layer)
    }

    private func attribute(_ lines: [OCRLine], _ windows: [VisibleWindow], focused: CGWindowID? = nil,
                           excluded: Set<String> = []) -> [(String?, [String])] {
        BackgroundCapturePolicy.attribute(lines: lines, displayBounds: display, windows: windows,
                                          excludedBundleIds: excluded, focusedWindowId: focused, denylist: denylist)
            .map { ($0.window.bundleId, $0.lines.map(\.text)) }
    }

    func testEachLineIsFiledUnderTheWindowItSitsIn() {
        let windows = [
            window(1, "com.apple.TextEdit", "Notes", CGRect(x: 0, y: 30, width: 500, height: 570)),
            window(2, "com.tinyspeck.slackmacgap", "general", CGRect(x: 500, y: 30, width: 500, height: 570)),
        ]
        let result = attribute([line("note", at: CGPoint(x: 100, y: 100)),
                                line("chat", at: CGPoint(x: 700, y: 100))], windows)
        XCTAssertEqual(result.map(\.0), ["com.apple.TextEdit", "com.tinyspeck.slackmacgap"])
        XCTAssertEqual(result.map(\.1), [["note"], ["chat"]])
    }

    func testTheFocusedWindowIsLeftToItsOwnStream() {
        let windows = [window(7, "com.microsoft.VSCode", "main.rs", CGRect(x: 0, y: 30, width: 1000, height: 570))]
        XCTAssertTrue(attribute([line("code", at: CGPoint(x: 300, y: 300))], windows, focused: 7).isEmpty)
    }

    func testTheFrontmostWindowOwnsAnOverlappingPoint() {
        let windows = [
            window(1, "com.apple.Notes", "Front", CGRect(x: 200, y: 100, width: 300, height: 300)),
            window(2, "com.apple.TextEdit", "Back", CGRect(x: 0, y: 30, width: 1000, height: 570)),
        ]
        let result = attribute([line("front", at: CGPoint(x: 300, y: 200)),
                                line("back", at: CGPoint(x: 800, y: 500))], windows)
        XCTAssertEqual(result.map(\.0), ["com.apple.Notes", "com.apple.TextEdit"])
    }

    func testAnExcludedAppIsNotInThePixelsSoTheWindowBehindItOwnsThePoint() {
        let windows = [
            window(1, "com.1password.1password", "Vault", CGRect(x: 0, y: 30, width: 500, height: 300)),
            window(2, "com.apple.TextEdit", "Notes", CGRect(x: 0, y: 30, width: 1000, height: 570)),
        ]
        let result = attribute([line("visible", at: CGPoint(x: 100, y: 100))], windows,
                               excluded: ["com.1password.1password"])
        XCTAssertEqual(result.map(\.0), ["com.apple.TextEdit"])
    }

    func testMenuBarDesktopPrivateAndDeniedWindowsAreDropped() {
        let windows = [
            window(1, "com.apple.controlcenter", "Menubar", CGRect(x: 0, y: 0, width: 1000, height: 24), layer: 24),
            window(2, "com.example.app", "Private Browsing", CGRect(x: 0, y: 30, width: 400, height: 300)),
            window(3, "com.apple.systempreferences", "Settings", CGRect(x: 600, y: 30, width: 400, height: 300)),
        ]
        let result = attribute([
            line("menu", at: CGPoint(x: 500, y: 10)),
            line("private", at: CGPoint(x: 100, y: 100)),
            line("settings", at: CGPoint(x: 700, y: 100)),
            line("desktop", at: CGPoint(x: 500, y: 500)),
        ], windows)
        XCTAssertTrue(result.isEmpty, "\(result)")
    }

    func testAnExcludedAppTheFilterMissedOwnsItsPixelsAndYieldsNothing() {
        // 1Password launched after the stream's filter was built: its window
        // is in the pixels. Its text must not be filed under the window behind.
        let windows = [
            window(1, "com.1password.1password", "Vault", CGRect(x: 0, y: 30, width: 500, height: 300), pid: 42),
            window(2, "com.apple.TextEdit", "Notes", CGRect(x: 0, y: 30, width: 1000, height: 570), pid: 7),
        ]
        let excluded: Set<String> = ["com.1password.1password"]
        XCTAssertTrue(BackgroundCapturePolicy.filterIsStale(windows: windows, excludedBundleIds: excluded, filteredPids: []))
        XCTAssertTrue(BackgroundCapturePolicy.filterIsStale(windows: windows, excludedBundleIds: excluded, filteredPids: [41]),
                      "a relaunched app has a new process")
        XCTAssertFalse(BackgroundCapturePolicy.filterIsStale(windows: windows, excludedBundleIds: excluded, filteredPids: [42]))
        XCTAssertFalse(BackgroundCapturePolicy.filterIsStale(windows: [windows[1]], excludedBundleIds: excluded, filteredPids: []))
    }

    func testAnExcludedAppNeverOwnsALine() {
        let vault = window(1, "com.1password.1password", "Vault", CGRect(x: 0, y: 30, width: 500, height: 300))
        XCTAssertFalse(BackgroundCapturePolicy.isEligible(
            vault, focusedWindowId: nil, excludedBundleIds: ["com.1password.1password"], denylist: denylist))
    }

    func testExclusionsCoverPasswordManagersBrowsersBannersAndItself() {
        let excluded = BackgroundCapturePolicy.excludedBundleIds(
            userEntries: [DenylistEntry(kind: .appBundle, pattern: "com.example.secret")])
        for bundle in ["com.1password.1password", "com.google.Chrome", "com.apple.Safari",
                       "com.apple.notificationcenterui", "ai.hippocampus", "com.apple.systempreferences",
                       "com.example.secret"] {
            XCTAssertTrue(excluded.contains(bundle), bundle)
        }
    }
}
