import XCTest
@testable import RecallUIKit

final class DailyReviewRoutingTests: XCTestCase {
    func testPopupOnlyAndForwardedEmptyCommandsPreserveTheCurrentWorkspace() throws {
        let popup = try XCTUnwrap(RecallLaunchRequest(userInfo: ["open_popup": true]))
        let forwarded = RecallLaunchRequest(tab: popup.tab, focusEventId: popup.focusEventId, openPopup: false)
        for current in [RecallTab.search, .timeline, .episodes, .settings] {
            XCTAssertEqual(popup.navigationTab ?? current, current)
            XCTAssertEqual(forwarded.navigationTab ?? current, current)
        }
        XCTAssertNil(popup.navigationTab)
        XCTAssertNil(forwarded.navigationTab)
        XCTAssertEqual(RecallLaunchRequest(tab: .now, focusEventId: nil, openPopup: false).navigationTab, .now)
        XCTAssertEqual(RecallLaunchRequest(tab: .brief, focusEventId: 42, openPopup: true).navigationTab, .search)
    }

    func testNoRouteOpensDailyReviewButExplicitSearchAndFocusedEventsWin() throws {
        XCTAssertEqual(RecallLaunchRequest(environment: [:]).initialTab, .now)
        XCTAssertEqual(RecallLaunchRequest(environment: ["MCI_INITIAL_TAB": "search"]).initialTab, .search)
        XCTAssertEqual(RecallLaunchRequest(environment: ["MCI_INITIAL_TAB": "timeline"]).initialTab, .timeline)
        XCTAssertEqual(RecallLaunchRequest(environment: ["MCI_INITIAL_TAB": "now", "MCI_INITIAL_FOCUS_EVENT_ID": "42"]).initialTab, .search)
        let popup = RecallLaunchRequest(environment: ["MCI_OPEN_GLOBAL_POPUP": "1"])
        XCTAssertTrue(popup.openPopup)
        XCTAssertEqual(popup.initialTab, .search)
    }

    func testOldAndNewRoutesResolveToTheSameVisibleDestinations() {
        for route in ["today", "now", "brief", "briefs", "daily"] {
            XCTAssertEqual(RecallTab.from(deepLinkValue: route)?.workspaceTab, .now)
        }
        for route in ["timeline", "history", "strip"] {
            XCTAssertEqual(RecallTab.from(deepLinkValue: route)?.workspaceTab, .timeline)
        }
        for route in ["episodes", "sessions"] {
            XCTAssertEqual(RecallTab.from(deepLinkValue: route)?.workspaceTab, .episodes)
        }
    }
}
