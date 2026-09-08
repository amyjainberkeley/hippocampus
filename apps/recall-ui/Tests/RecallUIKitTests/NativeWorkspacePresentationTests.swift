import Foundation
import XCTest

// Source contracts cover the executable's composition without launching the app
// or opening a brain. Native focus and layout still require the UI proof pass.
final class NativeWorkspacePresentationTests: XCTestCase {
    func testSelectedDestinationOwnsItsEvidenceWithoutASharedRecentFeed() throws {
        let source = try source("MemoryWorkspaceView.swift")
        for (destination, view) in [
            ("now", "DailyMemoryView"), ("search", "SearchView"),
            ("timeline", "TimelineView"), ("episodes", "EpisodesView"),
            ("sources", "SourcesWorkspaceView"),
            ("privacy", "PrivacyDashboard"), ("settings", "WorkspaceSettingsView"),
        ] {
            XCTAssertNotNil(source.range(
                of: "case \\.\(destination):\\s*\(view)\\(",
                options: .regularExpression
            ), "Destination \(destination) must retain its native view")
        }
        XCTAssertFalse(source.contains("WorkspaceFilmstrip("),
                       "A shared feed duplicates each destination's own evidence")
        XCTAssertFalse(source.contains("reader.recentEvents("),
                       "The navigation shell must not fetch unrelated recent evidence")
    }

    func testSidebarLabelsKeepNativeListSelectionWithoutExtraFocusTargets() throws {
        let source = try source("MemoryWorkspaceView.swift")
        let rowStart = try XCTUnwrap(source.range(of: "private struct MemorySidebarRow: View"))
        let rowEnd = source.range(of: "\nprivate struct ", range: rowStart.upperBound..<source.endIndex)
        let row = String(source[rowStart.lowerBound..<(rowEnd?.lowerBound ?? source.endIndex)])

        XCTAssertTrue(source.contains("List(selection: $selection)"))
        XCTAssertTrue(source.contains(".tag(item)"))
        XCTAssertTrue(source.contains(".listStyle(.sidebar)"))
        XCTAssertFalse(row.contains(".focusable("),
                       "A plain label must not add a second keyboard stop inside a selectable row")
        XCTAssertTrue(row.contains(".accessibilityLabel(item.descriptor.title)"))
        XCTAssertFalse(source.contains(".focusEffectDisabled("),
                       "Native keyboard focus must stay visible on actual controls")
    }

    func testRootKeepsKeyboardAndDeepLinkRouting() throws {
        let source = try source("MCIRecallApp.swift")
        XCTAssertTrue(source.contains(".focusable(true, interactions: .automatic)"))
        XCTAssertTrue(source.contains(".onKeyPress("))
        XCTAssertTrue(source.contains("MCI.Workspace.allDestinations.compactMap"))
        XCTAssertTrue(source.contains(".onOpenURL"))
        XCTAssertTrue(source.contains("RecallLaunchRequest.localCommandName"))
        XCTAssertFalse(source.contains(".focusEffectDisabled("))
    }

    func testObservedSourcesUsePassiveIconsAndKeepPreferencesActions() throws {
        let source = try source("MemoryWorkspaceView.swift")
        let start = try XCTUnwrap(source.range(of: "private struct SourcesWorkspaceView: View"))
        let sources = String(source[start.lowerBound...])
        XCTAssertFalse(sources.contains("\"app.dashed\""),
                       "Observed sources are passive metadata, not dashed action placeholders")
        XCTAssertTrue(sources.contains("Image(systemName: \"app\")"))
        XCTAssertTrue(sources.contains("WorkspacePreferencesButton(title: \"App access\""))
        XCTAssertTrue(sources.contains("WorkspacePreferencesButton(title: \"AI context\""))
    }

    private func source(_ file: String) throws -> String {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: package.appendingPathComponent("Sources/RecallUI/\(file)"),
                          encoding: .utf8)
    }
}
