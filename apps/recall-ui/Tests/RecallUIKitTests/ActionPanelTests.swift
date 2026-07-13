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
