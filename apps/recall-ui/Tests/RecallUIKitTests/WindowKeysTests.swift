import SwiftUI
import XCTest
@testable import RecallUIKit

/// ⌘↩ has one meaning everywhere (SPEC 2.10): Ask {Tool} with the typed
/// question, or with what the page has selected. The field comes before
/// every page in the window, and of two ⌘↩ buttons the first drawn takes
/// the key, so the field's own ⌘↩ is on only while it holds a question.
final class WindowKeysTests: XCTestCase {
    func testTheFieldTakesCommandReturnOnlyWhileItHoldsAQuestion() {
        XCTAssertFalse(WindowKeys.fieldTakesCommandReturn(""),
                       "an empty field leaves ⌘↩ to the page: History's picked row, Today's card")
        XCTAssertFalse(WindowKeys.fieldTakesCommandReturn("   "))
        XCTAssertFalse(WindowKeys.fieldTakesCommandReturn("\n\t "))
        XCTAssertTrue(WindowKeys.fieldTakesCommandReturn("rounding half to even"))
        XCTAssertTrue(WindowKeys.fieldTakesCommandReturn("  tax  "))
    }

    /// The row menu's keys work on the list itself (SPEC 2.10): they used to
    /// live only on the menu's items, which are no keys at all while the
    /// menu is closed.
    func testTheRowMenusKeysActOnThePickedRowsFromTheList() {
        XCTAssertEqual(MomentKey(character: "c", modifiers: .command), .copyText)
        XCTAssertEqual(MomentKey(character: "C", modifiers: [.command, .shift]), .copyForYourAI)
        XCTAssertEqual(MomentKey(character: "c", modifiers: [.command, .shift]), .copyForYourAI)
        XCTAssertEqual(MomentKey(character: "o", modifiers: .command), .openLink)
        XCTAssertEqual(MomentKey(character: "R", modifiers: [.command, .shift]), .showRelated)
        XCTAssertEqual(MomentKey(character: "c", modifiers: [.command, .capsLock]), .copyText, "Caps Lock doesn't count")
        XCTAssertNil(MomentKey(character: "c", modifiers: []), "typing goes on to the list")
        XCTAssertNil(MomentKey(character: "c", modifiers: [.command, .option]))
        XCTAssertNil(MomentKey(character: "r", modifiers: .command), "⌘R is Refresh, the window's")
        XCTAssertNil(MomentKey(character: "o", modifiers: [.command, .shift]))
        XCTAssertNil(MomentKey(character: "k", modifiers: .command), "⌘K is the command bar")
    }

    func testTheShortcutsSheetListsEveryRowKey() {
        let chips = Set(WindowKeys.all.flatMap(\.keys))
        for key in MomentKey.allCases {
            XCTAssertTrue(chips.contains(key.chip), "\(key) is in the Keyboard Shortcuts sheet")
        }
    }

    func testTheShortcutsSheetSaysCommandReturnAsksWithTheSelectionOrTheQuestion() throws {
        let key = try XCTUnwrap(WindowKeys.all.first { $0.keys == ["\u{2318}\u{21A9}"] })
        XCTAssertEqual(key.group, .actions)
        XCTAssertTrue(key.does.contains("selection"))
        XCTAssertTrue(key.does.contains("typed question"))
    }
}
