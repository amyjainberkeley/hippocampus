import XCTest
@testable import RecallUIKit

/// Back and Forward between pages, and where the window opens (SPEC 2.10,
/// 2.16).
final class WindowNavigationTests: XCTestCase {
    private let today = WindowLocation(page: .place(.today))
    private let history = WindowLocation(page: .place(.history), selectedMoment: 90_269)
    private let item = WindowLocation(page: .item("w_trailhead"))

    func testBackReturnsToThePageAndRowYouCameFrom() {
        var navigation = NavigationHistory()
        XCTAssertFalse(navigation.canGoBack)
        navigation.leave(history)
        navigation.leave(today)
        XCTAssertEqual(navigation.goBack(from: item), today)
        XCTAssertEqual(navigation.goBack(from: today), history, "the selected moment comes back with History")
        XCTAssertNil(navigation.goBack(from: history))
        XCTAssertEqual(navigation.goForward(from: history), today)
        XCTAssertEqual(navigation.goForward(from: today), item)
        XCTAssertNil(navigation.goForward(from: item))
    }

    func testANewPageClearsForward() {
        var navigation = NavigationHistory()
        navigation.leave(today)
        _ = navigation.goBack(from: history)
        XCTAssertTrue(navigation.canGoForward)
        navigation.leave(today)
        XCTAssertFalse(navigation.canGoForward)
    }

    func testBackRemembersFiftyPages() {
        var navigation = NavigationHistory()
        for index in 0..<80 {
            navigation.leave(WindowLocation(page: .place(.history), query: "q\(index)"))
        }
        XCTAssertEqual(navigation.back.count, NavigationHistory.limit)
        XCTAssertEqual(navigation.back.first?.query, "q30")
    }

    func testAnItemThatIsGoneIsNeverReturnedTo() {
        var navigation = NavigationHistory()
        navigation.leave(item)
        navigation.leave(today)
        navigation.forget(item: "w_trailhead")
        XCTAssertEqual(navigation.back, [today])
    }

    func testEachPageKnowsItsSidebarRowAndItsField() {
        XCTAssertEqual(WindowPage.place(.workingOn).sidebarRow(listing: []), .showAll)
        XCTAssertEqual(WindowPage.place(.history).sidebarRow(listing: []), .place(.history))
        XCTAssertEqual(WindowPage.item("w_1").sidebarRow(listing: ["w_1"]), .workItem("w_1"))
        XCTAssertNil(WindowPage.item("w_2").sidebarRow(listing: ["w_1"]), "an item not in the sidebar selects nothing")
        XCTAssertEqual(WindowPage(row: .showAll), .place(.workingOn))
        XCTAssertEqual(WindowPage(row: .place(.lookedUp)), .place(.lookedUp))
        XCTAssertTrue(WindowPage.item("w_1").hasField)
        XCTAssertTrue(WindowPage.item("w_1").isWorkingOn)
        XCTAssertFalse(WindowPage.place(.privacy).hasField)
        for place in SidebarPlace.allCases {
            XCTAssertEqual(WindowPage(row: .place(place)).sidebarRow(listing: []), .place(place))
        }
    }

    // MARK: Opening the window

    private func opening() -> (WindowOpening, UserDefaults, String) {
        let suite = "dev.hippocampus.tests.window-opening.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (WindowOpening(defaults: defaults), defaults, suite)
    }

    func testTheWindowOpensWhereItWasLeftWithinTheHour() {
        let (opening, defaults, suite) = opening()
        defer { defaults.removePersistentDomain(forName: suite) }
        let left = Date(timeIntervalSince1970: 1_791_841_260)
        XCTAssertEqual(opening.page(now: left), .place(.today), "nothing kept: Today")
        opening.remember(.place(.lookedUp), now: left)
        XCTAssertEqual(opening.page(now: left.addingTimeInterval(59 * 60)), .place(.lookedUp))
        XCTAssertEqual(opening.page(now: left.addingTimeInterval(61 * 60)), .place(.today), "an hour later: Today")
        opening.remember(.item("w_trailhead"), now: left)
        XCTAssertEqual(opening.page(now: left.addingTimeInterval(60)), .item("w_trailhead"))
        XCTAssertEqual(defaults.string(forKey: "window.lastPage"), "item:w_trailhead", "an id, never a name")
    }

    func testAKeptPageThatIsNotAPageOpensToday() {
        let (opening, defaults, suite) = opening()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_791_841_260)
        defaults.set("item:trailhead shop", forKey: "window.lastPage")
        defaults.set(now.timeIntervalSince1970, forKey: "window.lastPageLeftAt")
        XCTAssertEqual(opening.page(now: now), .place(.today))
        defaults.set("place:overview", forKey: "window.lastPage")
        XCTAssertEqual(opening.page(now: now), .place(.today))
        XCTAssertEqual(WindowOpening(defaults: nil).page(now: now), .place(.today))
    }
}
