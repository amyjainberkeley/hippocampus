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

    func testTheShortcutsSheetSaysCommandReturnAsksWithTheSelectionOrTheQuestion() throws {
        let key = try XCTUnwrap(WindowKeys.all.first { $0.keys == ["\u{2318}\u{21A9}"] })
        XCTAssertEqual(key.group, .actions)
        XCTAssertTrue(key.does.contains("selection"))
        XCTAssertTrue(key.does.contains("typed question"))
    }
}
