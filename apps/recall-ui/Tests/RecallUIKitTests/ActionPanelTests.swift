// ActionPanelTests.swift — pure-logic coverage for the ⌘K Action
// Panel core. SwiftUI view is integration-tested via the app.

import XCTest
@testable import RecallUIKit

@MainActor
final class ActionPanelViewModelTests: XCTestCase {
    func testRegisterAndUnregister() {
        let r = ActionPanelRegistry()
        r.register(.init(id: "a", title: "Alpha", shortcut: "", category: .app) {})
        XCTAssertEqual(r.commands.count, 1)
        r.unregister(id: "a")
        XCTAssertEqual(r.commands.count, 0)
    }

    func testRegisterReplacesSameId() {
        let r = ActionPanelRegistry()
        r.register(.init(id: "x", title: "First", shortcut: "", category: .app) {})
        r.register(.init(id: "x", title: "Second", shortcut: "", category: .app) {})
        XCTAssertEqual(r.commands.count, 1)
        XCTAssertEqual(r.commands.first?.title, "Second")
    }

    func testEmptyQueryReturnsAllEnabled() {
        let vm = ActionPanelViewModel(registry: ActionPanelRegistry())
        let list: [ActionPanelCommand] = [
            .init(id: "a", title: "Alpha", shortcut: "", category: .app) {},
            .init(id: "b", title: "Beta", shortcut: "", category: .app) {},
        ]
        XCTAssertEqual(vm.filtered(from: list).count, 2)
    }

    func testDisabledCommandsGatedOut() {
        let vm = ActionPanelViewModel(registry: ActionPanelRegistry())
        let list: [ActionPanelCommand] = [
            .init(id: "a", title: "Alpha", shortcut: "", category: .app, isEnabled: { false }) {},
            .init(id: "b", title: "Beta", shortcut: "", category: .app) {},
        ]
        XCTAssertEqual(vm.filtered(from: list).map(\.id), ["b"])
    }

    func testFuzzyQueryMatches() {
        let vm = ActionPanelViewModel(registry: ActionPanelRegistry())
        vm.query = "clr"
        let list: [ActionPanelCommand] = [
            .init(id: "a", title: "Clear Query", shortcut: "", category: .app) {},
            .init(id: "b", title: "Open Settings", shortcut: "", category: .app) {},
        ]
        XCTAssertEqual(vm.filtered(from: list).map(\.id), ["a"])
    }

    func testInvokeFiresActionAndHides() {
        let r = ActionPanelRegistry()
        r.show()
        let vm = ActionPanelViewModel(registry: r)
        var fired = false
        vm.invoke(from: [.init(id: "a", title: "A", shortcut: "", category: .app) { fired = true }])
        XCTAssertTrue(fired)
        XCTAssertFalse(r.isVisible)
    }

    /// A view's list registers as one group and follows it as it changes:
    /// Working On loads after the window appears, and an item can leave.
    func testAGroupFollowsItsListAsItChanges() {
        let r = ActionPanelRegistry()
        func goTo(_ id: String, _ name: String) -> ActionPanelCommand {
            .init(id: "go.item.\(id)", title: name, shortcut: "", category: .goTo) {}
        }
        r.register(.init(id: "app.refreshBrain", title: "Refresh", shortcut: "", category: .actions) {})
        r.register(group: "window", [])
        XCTAssertEqual(r.commands.map(\.id), ["app.refreshBrain"], "the window appears before Working On loads")
        r.register(group: "window", [goTo("w_1", "trailhead-shop"), goTo("w_2", "Q4 planning")])
        XCTAssertEqual(r.commands.map(\.id), ["app.refreshBrain", "go.item.w_1", "go.item.w_2"])
        r.register(group: "window", [goTo("w_2", "Q4 planning v2"), goTo("w_3", "Launch checklist")])
        XCTAssertEqual(Set(r.commands.map(\.id)), ["app.refreshBrain", "go.item.w_2", "go.item.w_3"])
        XCTAssertEqual(r.commands.first { $0.id == "go.item.w_2" }?.title, "Q4 planning v2")
        r.unregister(group: "window")
        XCTAssertEqual(r.commands.map(\.id), ["app.refreshBrain"], "another view's own command stays")
    }

    func testAListsSignatureChangesWithWhatItShows() {
        func command(_ id: String, _ title: String) -> ActionPanelCommand {
            .init(id: id, title: title, shortcut: "", category: .goTo) {}
        }
        let list = [command("go.item.w_1", "trailhead-shop")]
        XCTAssertEqual(list.panelSignature, [command("go.item.w_1", "trailhead-shop")].panelSignature)
        XCTAssertNotEqual(list.panelSignature, [command("go.item.w_1", "trailhead-shop v2")].panelSignature)
        XCTAssertNotEqual(list.panelSignature, (list + [command("go.item.w_2", "Q4 planning")]).panelSignature)
    }

    /// Every view's ⌘K list follows its changes, not only the one it had
    /// when it appeared (SPEC 2.2: Working On items have no key because ⌘K
    /// finds them).
    func testRegisteredListsFollowTheirChanges() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("Sources/RecallUI/ActionPanel/ActionPanel.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains(".onChange(of: commands.panelSignature) { _, _ in registry.register(group: group, commands) }"))
        XCTAssertTrue(source.contains(".onDisappear { registry.unregister(group: group) }"))
    }

    /// With nothing typed, ⌘K shows its groups in order, so Working On items
    /// registered after the window's own actions still come under Go To.
    func testWithNothingTypedCommandsComeInTheirGroups() {
        let vm = ActionPanelViewModel(registry: ActionPanelRegistry())
        let list: [ActionPanelCommand] = [
            .init(id: "go.today", title: "Today", shortcut: "\u{2318}1", category: .goTo) {},
            .init(id: "app.showHelp", title: "Keyboard Shortcuts", shortcut: "\u{2318}/", category: .help) {},
            .init(id: "app.forgetRecent", title: "Forget the Last 10 Minutes\u{2026}", shortcut: "", category: .actions) {},
            .init(id: "go.item.w_1", title: "trailhead-shop", shortcut: "", category: .goTo) {},
            .init(id: "app.status", title: "Pause", shortcut: "", category: .actions) {},
        ]
        XCTAssertEqual(vm.filtered(from: list).map(\.id),
                       ["go.today", "go.item.w_1", "app.forgetRecent", "app.status", "app.showHelp"])
        vm.query = "trail"
        XCTAssertEqual(vm.filtered(from: list).map(\.id), ["go.item.w_1"])
    }

    func testSelectNextAndPrevClamp() {
        let vm = ActionPanelViewModel(registry: ActionPanelRegistry())
        let list: [ActionPanelCommand] = (0..<3).map { i in
            .init(id: "\(i)", title: "C\(i)", shortcut: "", category: .app) {}
        }
        vm.selectNext(in: list); vm.selectNext(in: list); vm.selectNext(in: list)
        XCTAssertEqual(vm.selectedIndex, 2)
        vm.selectPrev(); vm.selectPrev(); vm.selectPrev(); vm.selectPrev()
        XCTAssertEqual(vm.selectedIndex, 0)
    }
}

final class FuzzyMatcherTests: XCTestCase {
    func testEmptyQueryScoresZero() {
        XCTAssertEqual(FuzzyMatcher.score(query: "", candidate: "anything"), 0)
    }

    func testExactSubstringMatches() {
        XCTAssertNotNil(FuzzyMatcher.score(query: "clear", candidate: "Clear Query"))
    }

    func testMissingCharacterFailsMatch() {
        XCTAssertNil(FuzzyMatcher.score(query: "xyz", candidate: "Clear Query"))
    }

    func testConsecutiveMatchOutranksScattered() {
        let consecutive = FuzzyMatcher.score(query: "opn", candidate: "Open Note")!
        let scattered = FuzzyMatcher.score(query: "opn", candidate: "Overpass Notebook")!
        XCTAssertGreaterThan(consecutive, scattered)
    }

    func testWordStartBonusApplies() {
        let atStart = FuzzyMatcher.score(query: "s", candidate: "Open Settings")!
        let midWord = FuzzyMatcher.score(query: "s", candidate: "Cases")!
        XCTAssertGreaterThan(atStart, midWord)
    }

    func testCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatcher.score(query: "OPEN", candidate: "open settings"))
    }
}
