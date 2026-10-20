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

    /// Each page shows its own place's view (SPEC 2.2 with SPEC-DELTA 1),
    /// the shell owns every model, and nothing from the preview reaches the
    /// person's own files.
    func testEachPageShowsItsOwnViewWithoutASharedRecentFeed() throws {
        let source = try source("MemoryWorkspaceView.swift")
        for (page, view) in [("place\\(\\.today\\)", "OverviewPlace"), ("place\\(\\.history\\)", "HistoryView"),
                             ("place\\(\\.webPages\\)", "WebPagesPlace"), ("place\\(\\.documents\\)", "DocumentsPlace"),
                             ("place\\(\\.code\\)", "CodePlace"), ("place\\(\\.conversations\\)", "ConversationsPlace"),
                             ("place\\(\\.lookedUp\\)", "LookedUpPlace"), ("place\\(\\.workingOn\\)", "WorkingOnPlace"),
                             ("let \\.item\\(id\\)", "WorkingOnItemPlace"), ("place\\(\\.aiTools\\)", "AIToolsPlace"),
                             ("place\\(\\.aboutYou\\)", "NavigationStack\\(path: \\$youPath\\)\\s*\\{\\s*YouPlace")] {
            XCTAssertNotNil(source.range(
                of: "case \\.?\(page):\\s*\(view)\\(",
                options: .regularExpression
            ), "Page \(page) must show \(view)")
        }
        for gone in ["DisclosureGroup(", "Picker(\"History view\"", "reader.recentEvents(", "PendingPlace",
                     "DailyMemoryView(", "EpisodesView(", "SourcesWorkspaceView", "WorkspaceSettingsView",
                     "preferredColorScheme(.light)"] {
            XCTAssertFalse(source.contains(gone), gone)
        }
        for model in ["ask: AskViewModel", "overview: OverviewViewModel", "you: UserModelViewModel"] {
            XCTAssertTrue(source.contains("@StateObject private var \(model)"),
                          "The shell owns every place's model, so each survives a change of place")
        }
        XCTAssertTrue(source.contains("PrivacyDashboard(reader: reader, mutator: reader as? PrivacyMutator)"),
                      "Privacy is its own page")
        XCTAssertTrue(source.contains("if isSyntheticPreview || drawsWindowControls {"),
                      "the preview and pictures never open Privacy's activity log")
        XCTAssertTrue(source.contains("UserDictionaryEditor()"), "The names page is pushed inside About You")
        XCTAssertTrue(source.contains("isSyntheticPreview ? VerdictInbox(directory: nil) : .shared"),
                      "The preview's verdicts never reach the folder the agent applies")
        XCTAssertTrue(source.contains("mutator: isSyntheticPreview ? nil : reader as? PrivacyMutator"),
                      "nothing in the preview deletes anything")
        XCTAssertTrue(source.contains("StatusBanner("))
        XCTAssertTrue(source.contains("WindowTopBar("))
        let sidebar = try self.source("Sidebar/SidebarView.swift")
        XCTAssertTrue(sidebar.contains("WindowHiMarkView("))
        XCTAssertTrue(sidebar.contains(".accessibilityLabel(NavigationCopy.hiMarkLabel(status.title))"),
                      "the hi mark is a button VoiceOver names (SPEC 2.6.1)")
    }

    func testTheWindowHasNoPopupOfItsOwnAndNoNewWindow() throws {
        let app = try source("MCIRecallApp.swift")
        XCTAssertFalse(app.contains("GlobalRecallPopupController"))
        XCTAssertTrue(app.contains("CommandGroup(replacing: .newItem) {}"))
        XCTAssertTrue(app.contains("CommandGroup(replacing: .appSettings)"))
        XCTAssertTrue(app.contains(".defaultSize(width: 1100, height: 720)"))
        XCTAssertTrue(app.contains("QueryPersistence.defaultKey"), "the old saved query is cleared at launch")
        let ask = try source("Places/AskPlace.swift")
        XCTAssertTrue(ask.contains(".keyboardShortcut(.return, modifiers: .option)"), "⌥↩ asks on this Mac")
        XCTAssertFalse(ask.contains(".keyboardShortcut(.return, modifiers: .command)"),
                       "⌘↩ is Ask {Tool} everywhere (SPEC 2.10)")
    }

    /// The sidebar's rows stay the system's own selectable list rows, in the
    /// system's sidebar style, with no extra focus stops inside a row.
    func testSidebarRowsKeepNativeListSelectionWithoutExtraFocusTargets() throws {
        let source = try source("Sidebar/SidebarView.swift")
        XCTAssertTrue(source.contains("List(selection: selectionBinding)"))
        XCTAssertTrue(source.contains(".tag(row)"))
        XCTAssertTrue(source.contains(".listStyle(.sidebar)"))
        let rowStart = try XCTUnwrap(source.range(of: "private struct PlaceRow: View"))
        let rowEnd = source.range(of: "\n/// ", range: rowStart.upperBound..<source.endIndex)
        let row = String(source[rowStart.lowerBound..<(rowEnd?.lowerBound ?? source.endIndex)])
        XCTAssertFalse(row.contains(".focusable("),
                       "A plain label must not add a second keyboard stop inside a selectable row")
        XCTAssertTrue(row.contains(".accessibilityLabel(accessibilityLabel)"))
        XCTAssertTrue(row.contains(".help(NavigationCopy.rowTooltip(place.title, key: place.key))"))
        XCTAssertFalse(source.contains(".focusEffectDisabled("),
                       "Native keyboard focus must stay visible on actual controls")
        XCTAssertFalse(source.contains("sparkles"), "no sparkles in the sidebar (SPEC 2.2)")
        XCTAssertTrue(source.contains("SidebarFootnote(text: NavigationCopy.workingOnFootnote, sidebarWidth: width)"),
                      "Working On's footnote is as tall as its lines, so the list never cuts it off")
        XCTAssertTrue(source.contains("minHeight: SidebarNoteLayout.height(text, sidebarWidth: sidebarWidth)"))
        let noteStart = try XCTUnwrap(source.range(of: "struct SidebarFootnote: View"))
        let noteEnd = source.range(of: "\n/// ", range: noteStart.upperBound..<source.endIndex)
        let note = String(source[noteStart.lowerBound..<(noteEnd?.lowerBound ?? source.endIndex)])
        XCTAssertTrue(note.contains(".lineLimit(nil)"), "a sidebar row is one line unless it says otherwise")
        XCTAssertTrue(source.contains("size: SidebarMetrics.thumbnailSize"))
        XCTAssertTrue(source.contains(".offset(x: SidebarMetrics.thumbnailNudge)"),
                      "a Working On item's screenshot sits inside the selection (SidebarThumbnailLayout)")
    }

    func testRootKeepsKeyboardAndDeepLinkRouting() throws {
        let source = try source("MCIRecallApp.swift")
        XCTAssertTrue(source.contains(".focusable(true, interactions: .automatic)"))
        XCTAssertTrue(source.contains(".onKeyPress("))
        XCTAssertTrue(source.contains("MCI.Workspace.allDestinations.compactMap"))
        XCTAssertTrue(source.contains(".windowStyle(.hiddenTitleBar)"))
        XCTAssertFalse(source.contains(".preferredColorScheme(.light)"), "the window follows the Mac (SPEC 2.14)")
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
