// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import HippocampusKit

/// The status menu's one hook for items from elsewhere in the app, such as
/// Demo Memory's while Option is held (SPEC-DELTA 6): a group of their own
/// above Quit, and nothing at all when there are none.
final class StatusMenuExtraItemsTests: XCTestCase {
    private let row = StatusRow(title: "Remembering", detail: "Last saved 8s ago", action: .pause)

    func testWithoutExtraItemsTheMenuIsUnchanged() {
        let plain = StatusMenuModel.items(row: row, setupComplete: true, askLabel: "⇧⇧", aiToolsConnected: false)
        let none = StatusMenuModel.items(row: row, setupComplete: true, askLabel: "⇧⇧", aiToolsConnected: false,
                                         extraItems: [])
        XCTAssertEqual(none, plain)
    }

    func testExtraItemsAreTheirOwnGroupAboveQuit() {
        let extra = StatusMenuModel.Item(role: .extra("demo.use"), title: "Use Demo Memory…")
        let plain = StatusMenuModel.items(row: row, setupComplete: true, askLabel: "⇧⇧", aiToolsConnected: false)
        let items = StatusMenuModel.items(row: row, setupComplete: true, askLabel: "⇧⇧", aiToolsConnected: false,
                                          extraItems: [extra])
        XCTAssertEqual(items.count, plain.count + 2)
        XCTAssertEqual(Array(items.suffix(4).map(\.role)),
                       [.separator, .extra("demo.use"), .separator, .quit])
        XCTAssertEqual(Array(items.prefix(plain.count - 2)), Array(plain.prefix(plain.count - 2)),
                       "everything above stays where it was")
    }

    func testDemoMemoryAddsNothingYet() {
        XCTAssertEqual(DemoMemory.menuItems(optionHeld: true), [])
    }
}
