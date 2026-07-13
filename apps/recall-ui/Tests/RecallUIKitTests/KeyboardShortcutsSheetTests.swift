// KeyboardShortcutsSheetTests.swift — enumeration + auto-update
// coverage for the ⌘/ help sheet (cycle 8.51 PR #74 follow-up).
//
// The sheet's SwiftUI view lives in the `RecallUI` exec target, but its
// content is a pure function of the registry — `groupedByCategory()`
// — which is testable from `RecallUIKit` directly. We assert here that:
//
//   1. Every registered command surfaces in the grouped output.
//   2. Groups appear in canonical order (Search → Hit → App → Debug),
//      empty groups omitted.
//   3. Adding a new command to the registry at runtime is reflected in
//      the next `groupedByCategory()` call — i.e., no hardcoded list.
//   4. `showHelp()` / `hideHelp()` flip the observable sheet flag.

import XCTest
@testable import RecallUIKit

@MainActor
final class KeyboardShortcutsSheetTests: XCTestCase {
    func testEnumeratesAllRegisteredCommands() {
        let r = ActionPanelRegistry()
        r.register(.init(id: "s.a", title: "Search Alpha", shortcut: "⌘1", category: .search) {})
        r.register(.init(id: "h.b", title: "Hit Bravo", shortcut: "⌘2", category: .hit) {})
        r.register(.init(id: "a.c", title: "App Charlie", shortcut: "⌘3", category: .app) {})
        r.register(.init(id: "d.d", title: "Debug Delta", shortcut: "⌘4", category: .debug) {})

        let groups = r.groupedByCategory()
        let allIds = groups.flatMap { $0.commands.map(\.id) }.sorted()
        XCTAssertEqual(allIds, ["a.c", "d.d", "h.b", "s.a"])
    }

    func testGroupsInCanonicalOrder() {
        let r = ActionPanelRegistry()
        // Register in reverse order — canonical order should still hold.
        r.register(.init(id: "d.a", title: "Debug", shortcut: "", category: .debug) {})
        r.register(.init(id: "a.a", title: "App", shortcut: "", category: .app) {})
        r.register(.init(id: "h.a", title: "Hit", shortcut: "", category: .hit) {})
        r.register(.init(id: "s.a", title: "Search", shortcut: "", category: .search) {})

        let cats = r.groupedByCategory().map(\.category)
        XCTAssertEqual(cats, [.search, .hit, .app, .debug])
    }

    func testEmptyCategoriesOmitted() {
        let r = ActionPanelRegistry()
        r.register(.init(id: "a.only", title: "Only App", shortcut: "", category: .app) {})
        let cats = r.groupedByCategory().map(\.category)
        XCTAssertEqual(cats, [.app])
    }

    func testCommandsInsideGroupSortedByTitle() {
        let r = ActionPanelRegistry()
        r.register(.init(id: "1", title: "Zebra", shortcut: "", category: .app) {})
        r.register(.init(id: "2", title: "Alpha", shortcut: "", category: .app) {})
        r.register(.init(id: "3", title: "Middle", shortcut: "", category: .app) {})

        let titles = r.groupedByCategory().first?.commands.map(\.title) ?? []
        XCTAssertEqual(titles, ["Alpha", "Middle", "Zebra"])
    }

    func testAutoUpdatesWhenNewCommandRegistered() {
        // This is THE Single-Source-of-Truth guarantee: register a
        // brand-new command and it appears in the next grouping snapshot
        // without touching the sheet code.
        let r = ActionPanelRegistry()
        r.register(.init(id: "app.existing", title: "Existing", shortcut: "", category: .app) {})
        XCTAssertEqual(r.groupedByCategory().flatMap { $0.commands.map(\.id) }, ["app.existing"])

        r.register(.init(id: "app.new", title: "Newly Added", shortcut: "⌘X", category: .app) {})
        let ids = r.groupedByCategory().flatMap { $0.commands.map(\.id) }.sorted()
        XCTAssertEqual(ids, ["app.existing", "app.new"])
    }

    func testShowHideHelpFlipsBinding() {
        let r = ActionPanelRegistry()
        XCTAssertFalse(r.isHelpVisible)
        r.showHelp()
        XCTAssertTrue(r.isHelpVisible)
        r.hideHelp()
        XCTAssertFalse(r.isHelpVisible)
    }

    func testBeginEndRefreshFlipsBinding() {
        let r = ActionPanelRegistry()
        XCTAssertFalse(r.isRefreshing)
        r.beginRefresh()
        XCTAssertTrue(r.isRefreshing)
        r.endRefresh()
        XCTAssertFalse(r.isRefreshing)
    }

    func testCommandDescriptionRoundTrips() {
        // The help sheet reads `cmd.description` — ensure the field
        // survives register/round-trip.
        let r = ActionPanelRegistry()
        r.register(.init(
            id: "app.q",
            title: "Quit",
            shortcut: "⌘Q",
            category: .app,
            description: "Quit the recall app."
        ) {})
        XCTAssertEqual(r.commands.first?.description, "Quit the recall app.")
    }
}
