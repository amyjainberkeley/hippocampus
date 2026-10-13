import Foundation
import XCTest

// Source contracts cover the executable's composition without launching the app
// or opening a brain. Native focus and layout still require the UI proof pass.
final class NativeWorkspacePresentationTests: XCTestCase {
    func testNativePreviewBypassesProductionStartupAndUsesIsolatedModels() throws {
        let app = try source("MCIRecallApp.swift")
        XCTAssertTrue(app.contains("NativePreviewConfiguration(arguments: CommandLine.arguments)"))
        let preview = try source("NativeRecallPreview.swift")
        XCTAssertTrue(preview.contains("healthLoader: { nil }"))
        XCTAssertTrue(preview.contains("userDictionaryLoader: { .empty }"))
        XCTAssertTrue(preview.contains("MemoryWorkspaceView("))
        XCTAssertTrue(preview.contains("isSyntheticPreview: true"))
        XCTAssertFalse(preview.contains("ProcessInfo.processInfo.environment"))
        XCTAssertFalse(preview.contains("ContextHandoffExporter"))
        XCTAssertTrue(preview.contains("PreviewUnderstandingReader("),
                      "the preview reads fixtures, never the agent (critique-recall-engineering finding 12)")
    }

    func testEachPlaceShowsItsOwnViewWithoutASharedRecentFeed() throws {
        let source = try source("MemoryWorkspaceView.swift")
        for (place, view) in [("overview", "PendingPlace"), ("ask", "AskPlace"), ("you", "PendingPlace")] {
            XCTAssertNotNil(source.range(
                of: "case \\.\(place):\\s*\(view)\\(",
                options: .regularExpression
            ), "Place \(place) must show \(view)")
        }
        for gone in ["DisclosureGroup(", "Picker(\"History view\"", "reader.recentEvents(",
                     "DailyMemoryView(", "EpisodesView(", "SourcesWorkspaceView", "WorkspaceSettingsView"] {
            XCTAssertFalse(source.contains(gone), gone)
        }
        XCTAssertTrue(source.contains("@StateObject private var ask: AskViewModel"),
                      "The shell owns Ask's model, so it survives a change of place")
        XCTAssertTrue(source.contains("WindowHiMarkView("))
        XCTAssertTrue(source.contains("SidebarStatus("))
    }

    func testTheWindowHasNoPopupOfItsOwnAndNoNewWindow() throws {
        let app = try source("MCIRecallApp.swift")
        XCTAssertFalse(app.contains("GlobalRecallPopupController"))
        XCTAssertTrue(app.contains("CommandGroup(replacing: .newItem) {}"))
        XCTAssertTrue(app.contains("CommandGroup(replacing: .appSettings)"))
        XCTAssertTrue(app.contains(".defaultSize(width: 1100, height: 720)"))
        XCTAssertTrue(app.contains("QueryPersistence.defaultKey"), "the old saved query is cleared at launch")
        let ask = try source("Places/AskPlace.swift")
        XCTAssertTrue(ask.contains(".keyboardShortcut(.return, modifiers: .command)"))
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

    private func source(_ file: String) throws -> String {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: package.appendingPathComponent("Sources/RecallUI/\(file)"),
                          encoding: .utf8)
    }
}
