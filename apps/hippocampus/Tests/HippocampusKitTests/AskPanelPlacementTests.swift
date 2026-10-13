// SPDX-License-Identifier: TBD-private
//
// Where Ask hangs (spec-shell S1), in AppKit's bottom-left screen
// coordinates: under the bar, centred, never past 60% of the space below.

import CoreGraphics
import XCTest
@testable import HippocampusKit

final class AskPanelPlacementTests: XCTestCase {
    /// A 1512 × 982 built-in display with a 37 pt menu bar.
    private let builtIn = AskPanelPlacement.Screen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945),
        safeAreaTop: 32
    )

    func testItHangsUnderAVisibleMenuBar() {
        let placement = AskPanelPlacement(screen: builtIn)
        XCTAssertEqual(placement.top, 982 - 37 - 8)
        XCTAssertEqual(placement.width, 700)
        XCTAssertEqual(placement.x, 1512 / 2 - 350)
        XCTAssertEqual(placement.maxHeight, 555, "floor((937 − 0 − 12) × 0.6), under the 616 cap")
        let frame = placement.frame(height: 300)
        XCTAssertEqual(frame, CGRect(x: 406, y: 937 - 300, width: 700, height: 300))
        XCTAssertEqual(frame.maxY, placement.top, "it hangs from the top edge")
    }

    func testItHangsUnderTheNotchWhenTheBarIsHidden() {
        let hiddenBar = AskPanelPlacement.Screen(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 32
        )
        XCTAssertEqual(AskPanelPlacement(screen: hiddenBar).top, 982 - 32 - 8)
    }

    func testWithNoBarAndNoNotchItDropsFromTheTopEdge() {
        let fullScreen = AskPanelPlacement.Screen(
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )
        let placement = AskPanelPlacement(screen: fullScreen)
        XCTAssertEqual(placement.top, 1440 - 8)
        XCTAssertEqual(placement.maxHeight, 616, "the cap on a tall display")
    }

    func testADisplayBelowAndLeftOfTheMainOneKeepsItsOwnPlace() {
        let below = AskPanelPlacement.Screen(
            frame: CGRect(x: -1920, y: -1080, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: -1080, width: 1920, height: 1055)
        )
        let placement = AskPanelPlacement(screen: below)
        XCTAssertEqual(placement.top, -1080 + 1055 - 8, "a negative top is a real place, not 'unset'")
        XCTAssertEqual(placement.x, -1920 + 960 - 350)
        XCTAssertEqual(placement.maxHeight, 616, "floor((−33 + 1080 − 12) × 0.6) = 621, so the cap")
        XCTAssertEqual(placement.frame(height: 200).maxY, placement.top)
        XCTAssertEqual(placement.frame(height: 200).minY, placement.top - 200)
    }

    func testANarrowDisplayClampsTheWidthAndKeepsItInside() {
        let narrow = AskPanelPlacement.Screen(
            frame: CGRect(x: 100, y: 0, width: 600, height: 800),
            visibleFrame: CGRect(x: 100, y: 0, width: 600, height: 775)
        )
        let placement = AskPanelPlacement(screen: narrow)
        XCTAssertEqual(placement.width, 576)
        XCTAssertEqual(placement.x, 112, "12 pt from the visible edge")
        // A Dock on the left narrows the visible area: still inside it.
        let dockLeft = AskPanelPlacement.Screen(
            frame: CGRect(x: 0, y: 0, width: 800, height: 800),
            visibleFrame: CGRect(x: 120, y: 0, width: 680, height: 775)
        )
        let clamped = AskPanelPlacement(screen: dockLeft)
        XCTAssertEqual(clamped.width, 656)
        XCTAssertEqual(clamped.x, 132)
        XCTAssertLessThanOrEqual(clamped.x + clamped.width, dockLeft.visibleFrame.maxX - 12)
    }

    func testTheHeightIsCappedAtSixtyPercentAndNeverShorterThanTheSearchRow() {
        let placement = AskPanelPlacement(screen: builtIn)
        XCTAssertEqual(placement.frame(height: 10_000).height, placement.maxHeight)
        XCTAssertEqual(placement.frame(height: 10).height, 60)
        XCTAssertEqual(placement.maxContentHeight, placement.maxHeight - 96)
        let short = AskPanelPlacement.Screen(
            frame: CGRect(x: 0, y: 0, width: 1024, height: 400),
            visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 375)
        )
        XCTAssertEqual(AskPanelPlacement(screen: short).maxContentHeight, 160, "the content never gets less than 160")
    }

    func testItOpensOnTheDisplayThePointerIsOn() {
        let left = AskPanelPlacement.Screen(
            frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        )
        let screens = [builtIn, left]
        XCTAssertEqual(AskPanelPlacement.screen(containing: CGPoint(x: -500, y: 500), in: screens, main: builtIn), left)
        XCTAssertEqual(AskPanelPlacement.screen(containing: CGPoint(x: 700, y: 400), in: screens, main: left), builtIn)
        // The pointer in the menu bar, on the very top row.
        XCTAssertEqual(AskPanelPlacement.screen(containing: CGPoint(x: -500, y: 1080), in: screens, main: builtIn), left)
        // Nowhere: the main display, then the first.
        XCTAssertEqual(AskPanelPlacement.screen(containing: CGPoint(x: 9_000, y: 9_000), in: screens, main: left), left)
        XCTAssertEqual(AskPanelPlacement.screen(containing: CGPoint(x: 9_000, y: 9_000), in: screens, main: nil), builtIn)
        XCTAssertNil(AskPanelPlacement.screen(containing: .zero, in: [], main: nil))
    }

    func testThePointerIsInARectTheWayNSMouseInRectSaysSo() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(AskPanelPlacement.mouse(CGPoint(x: 0, y: 100), isIn: rect), "the top edge counts")
        XCTAssertFalse(AskPanelPlacement.mouse(CGPoint(x: 0, y: 0), isIn: rect), "the bottom edge belongs below")
        XCTAssertFalse(AskPanelPlacement.mouse(CGPoint(x: 100, y: 50), isIn: rect))
        XCTAssertTrue(AskPanelPlacement.mouse(CGPoint(x: 0, y: 50), isIn: rect))
    }

    func testTheEntranceDropsTwelvePointsOrFadesWithReduceMotion() {
        let frame = CGRect(x: 10, y: 500, width: 700, height: 300)
        let drop = AskPanelEntrance(reduceMotion: false)
        XCTAssertEqual(drop.duration, 0.16)
        XCTAssertEqual(drop.start(for: frame), frame.offsetBy(dx: 0, dy: 12))
        let fade = AskPanelEntrance(reduceMotion: true)
        XCTAssertEqual(fade.duration, 0.10)
        XCTAssertEqual(fade.start(for: frame), frame, "no slide")
    }

    func testClosingAskHidesTheAppOnlyWhenNoWindowOfItIsInUse() {
        let preferences = AskPanelDismissal.Window(isVisible: true, isTitled: true)
        let statusItem = AskPanelDismissal.Window(isVisible: true, isTitled: false)
        let closed = AskPanelDismissal.Window(isVisible: false, isTitled: true)
        XCTAssertFalse(
            AskPanelDismissal.shouldHideApp(appIsActive: true, otherWindows: [statusItem, preferences]),
            "Preferences cannot become main, and it is still in use"
        )
        XCTAssertTrue(AskPanelDismissal.shouldHideApp(appIsActive: true, otherWindows: [statusItem, closed]))
        XCTAssertFalse(AskPanelDismissal.shouldHideApp(appIsActive: false, otherWindows: [statusItem]))
    }
}
