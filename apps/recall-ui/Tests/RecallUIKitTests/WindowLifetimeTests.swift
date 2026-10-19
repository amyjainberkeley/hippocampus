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

    /// A command answers only when the window will show itself: the process
    /// says so once it quits, and checks for a window it can bring forward
    /// (minimized included), which it does before answering, at once even
    /// while it is in the background.
    func testACommandIsAnsweredOnlyWhenTheWindowShowsItself() throws {
        let source = try appSource()
        let start = try XCTUnwrap(source.range(of: "final class MCIRecallAppDelegate"))
        let end = try XCTUnwrap(source.range(of: "struct MCIRecallApp: App"))
        let delegate = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(delegate.contains("func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {"))
        XCTAssertTrue(delegate.contains("terminating = true"))
        let handler = try XCTUnwrap(delegate.range(of: "private func receiveRecallCommand("))
        let body = String(delegate[handler.lowerBound...])
        let decide = try XCTUnwrap(body.range(of: "RecallCommandAnswer.decide(terminating: self.terminating"))
        let deminiaturize = try XCTUnwrap(body.range(of: "window.deminiaturize(nil)"))
        let answer = try XCTUnwrap(body.range(of: "RecallLaunchRequest.acknowledgementName"))
        XCTAssertLessThan(decide.lowerBound, deminiaturize.lowerBound)
        XCTAssertLessThan(deminiaturize.lowerBound, answer.lowerBound)
        XCTAssertTrue(body.contains("deliverImmediately: true"))
        XCTAssertTrue(delegate.contains("suspensionBehavior: .deliverImmediately"))
    }

    /// One window: a second would be a second reader of the memory, and no
    /// menu offers one.
    func testThereIsNoNewWindowCommand() throws {
        XCTAssertTrue(try appSource().contains("CommandGroup(replacing: .newItem) {}"))
    }
}
