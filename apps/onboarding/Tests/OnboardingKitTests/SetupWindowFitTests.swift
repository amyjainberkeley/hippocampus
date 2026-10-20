import XCTest
@testable import OnboardingKit

/// Where setup's window opens and how tall it is (SPEC 7.7): centred on
/// the display with the pointer, 760 by 560, and on a short screen as tall
/// as the visible frame less 40 pt, its content scrolling inside.
final class SetupWindowFitTests: XCTestCase {
    func testTheWindowIs760By560WheneverItFits() {
        XCTAssertEqual(SetupWindowFit.width, 760)
        XCTAssertEqual(SetupWindowFit.height, 560)
        // A 13-inch MacBook Air at its default size, and larger screens.
        for visible in [600.0, 832, 875, 1_080, 1_415] {
            XCTAssertEqual(SetupWindowFit.height(visibleHeight: visible), 560, "\(visible)")
        }
    }

    func testOnAShortScreenItFitsTheVisibleFrameLess40Points() {
        // "Larger Text" on a 13-inch MacBook Air: about 520 pt to work with.
        XCTAssertEqual(SetupWindowFit.height(visibleHeight: 520), 480)
        XCTAssertEqual(SetupWindowFit.height(visibleHeight: 599), 559)
        // Never so short that the title, a row and the bar can't show.
        XCTAssertEqual(SetupWindowFit.height(visibleHeight: 300), SetupWindowFit.minimumHeight)
    }

    func testItOpensOnTheDisplayWithThePointer() {
        let laptop = (frame: SetupRect(x: 0, y: 0, width: 1_470, height: 956),
                      visible: SetupRect(x: 0, y: 70, width: 1_470, height: 853))
        let studio = (frame: SetupRect(x: 1_470, y: 0, width: 2_560, height: 1_440),
                      visible: SetupRect(x: 1_470, y: 0, width: 2_560, height: 1_415))
        XCTAssertEqual(SetupWindowFit.display(pointer: (2_000, 700), screens: [laptop, studio]), studio.visible)
        XCTAssertEqual(SetupWindowFit.display(pointer: (300, 200), screens: [laptop, studio]), laptop.visible)
        // A pointer on no screen (it just moved off one): the first.
        XCTAssertEqual(SetupWindowFit.display(pointer: (-50, -50), screens: [laptop, studio]), laptop.visible)
        XCTAssertNil(SetupWindowFit.display(pointer: (0, 0), screens: []))
    }

    func testItIsCentredInTheVisibleFrame() {
        let studio = SetupRect(x: 1_470, y: 0, width: 2_560, height: 1_415)
        XCTAssertEqual(SetupWindowFit.frame(in: studio),
                       SetupRect(x: 1_470 + 900, y: 428, width: 760, height: 560))
        let origin = SetupWindowFit.origin(width: 760, height: 588, in: studio)
        XCTAssertEqual(origin.x, 2_370)
        XCTAssertEqual(origin.y, 414, "a title bar's height is centred too")
        let short = SetupRect(x: 0, y: 40, width: 1_024, height: 520)
        XCTAssertEqual(SetupWindowFit.frame(in: short), SetupRect(x: 132, y: 60, width: 760, height: 480))
    }
}
