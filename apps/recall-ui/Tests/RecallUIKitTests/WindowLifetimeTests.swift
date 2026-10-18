import XCTest

/// The window's process ends with its window (Oct 18). A process left
/// running without one took "open the window" from the menu-bar app, from
/// Ask and from opening Hippocampus again, with nothing to show it in: the
/// app looked like it did nothing. Ending with the window, the next request
/// starts a fresh window on the place asked for.
final class WindowLifetimeTests: XCTestCase {
    private func appSource() throws -> String {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: package.appendingPathComponent("Sources/RecallUI/MCIRecallApp.swift"),
                          encoding: .utf8)
    }

    func testTheProcessEndsWhenItsLastWindowCloses() throws {
        let source = try appSource()
        let start = try XCTUnwrap(source.range(of: "final class MCIRecallAppDelegate"))
        let end = try XCTUnwrap(source.range(of: "struct MCIRecallApp: App"))
        let delegate = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(delegate.contains(
            "func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {\n        true\n    }"
        ))
        // Ending still stops the window's children first (RULINGS G7).
        XCTAssertTrue(delegate.contains("ChildProcesses.shared.terminateAll()"))
    }

    /// One window: a second would be a second reader of the memory, and no
    /// menu offers one.
    func testThereIsNoNewWindowCommand() throws {
        XCTAssertTrue(try appSource().contains("CommandGroup(replacing: .newItem) {}"))
    }
}
