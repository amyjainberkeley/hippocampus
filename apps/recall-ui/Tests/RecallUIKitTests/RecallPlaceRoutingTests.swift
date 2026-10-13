import Foundation
import XCTest
@testable import RecallUIKit

/// Every way the window is asked to show something lands in one of three
/// places (RULINGS G5, X9), and a request reads the same at launch and while
/// the window is open (critique-recall-engineering finding 5).
final class RecallPlaceRoutingTests: XCTestCase {
    private let allTabs: [RecallTab] = [
        .now, .search, .timeline, .episodes, .brief, .privacy, .settings, .privacyDashboard, .timelineStrip, .you,
    ]

    func testEveryTabOpensOneOfTheThreePlaces() {
        let places: [RecallTab: RecallPlace] = [
            .now: .overview, .brief: .overview,
            .search: .ask, .timeline: .ask, .timelineStrip: .ask, .episodes: .ask,
            .you: .you, .privacy: .you, .privacyDashboard: .you, .settings: .you,
        ]
        XCTAssertEqual(Set(places.keys), Set(allTabs))
        for tab in allTabs {
            XCTAssertEqual(tab.place, places[tab], "\(tab)")
        }
        XCTAssertEqual(RecallPlace.allCases, [.overview, .ask, .you])
    }

    func testOnlyTheOldHistoryNamesOpenHistoryAndOnlyThePrivacyNamesOpenIt() {
        XCTAssertEqual(allTabs.filter(\.opensHistory), [.timeline, .episodes, .timelineStrip])
        XCTAssertEqual(allTabs.filter(\.opensPrivacy), [.privacy, .privacyDashboard])
    }

    func testTheAppsThreeNamesOpenTheThreePlaces() {
        XCTAssertEqual(RecallTab.from(deepLinkValue: "you"), .you)
        XCTAssertEqual(RecallRoute(tab: "overview"), RecallRoute(place: .overview))
        XCTAssertEqual(RecallRoute(tab: "ask"), RecallRoute(place: .ask))
        XCTAssertEqual(RecallRoute(tab: "you"), RecallRoute(place: .you))
        XCTAssertEqual(RecallRoute(tab: " You "), RecallRoute(place: .you))
    }

    func testEveryOlderNameKeepsWorking() {
        let routes: [String: RecallRoute] = [
            "today": RecallRoute(place: .overview), "now": RecallRoute(place: .overview),
            "daily": RecallRoute(place: .overview), "brief": RecallRoute(place: .overview),
            "briefs": RecallRoute(place: .overview), "search": RecallRoute(place: .ask),
            "timeline": RecallRoute(place: .ask, clearsField: true),
            "history": RecallRoute(place: .ask, clearsField: true),
            "episodes": RecallRoute(place: .ask, clearsField: true),
            "sessions": RecallRoute(place: .ask, clearsField: true),
            "timeline-strip": RecallRoute(place: .ask, clearsField: true),
            "strip": RecallRoute(place: .ask, clearsField: true),
            "settings": RecallRoute(place: .you),
            "privacy": RecallRoute(place: .you, youPath: [.privacy]),
            "dashboard": RecallRoute(place: .you, youPath: [.privacy]),
            "privacy-dashboard": RecallRoute(place: .you, youPath: [.privacy]),
        ]
        for (name, route) in routes {
            XCTAssertEqual(RecallRoute(tab: name), route, name)
            XCTAssertEqual(RecallRoute(tab: name.uppercased()), route, name)
            XCTAssertNotNil(RecallTab.from(deepLinkValue: name), "\(name) still opens today's window")
            let link = try? XCTUnwrap(URL(string: "hippocampus://recall?tab=\(name)"))
            XCTAssertEqual(link.flatMap(RecallRoute.init(url:)), route, name)
            XCTAssertEqual(RecallRoute(environment: ["MCI_INITIAL_TAB": name]), route, name)
            XCTAssertEqual(RecallRoute(userInfo: ["tab": name, "open_popup": false]), route, name)
        }
    }

    func testUnknownNamesAreIgnored() {
        for name in ["", "nope", "0", "overview2", "you2"] {
            XCTAssertNil(RecallRoute(tab: name), name)
            XCTAssertEqual(RecallRoute(environment: ["MCI_INITIAL_TAB": name]), RecallRoute(), name)
        }
    }

    func testAWindowThatIsOnlyOpeningShowsOverviewAndAnOpenOneStaysPut() {
        let route = RecallRoute(environment: [:])
        XCTAssertEqual(route, RecallRoute())
        XCTAssertNil(route.place)
        XCTAssertEqual(route.place(keeping: .overview), .overview)
        XCTAssertEqual(route.place(keeping: .you), .you)
        XCTAssertEqual(RecallRoute(tab: "ask")?.place(keeping: .you), .ask)
    }

    func testAFocusedMemoryLandsInAskShowingItWhateverTheNameSays() throws {
        let expected = RecallRoute(place: .ask, clearsField: true, focusEventId: 42)
        XCTAssertEqual(RecallRoute(environment: ["MCI_INITIAL_TAB": "now", "MCI_INITIAL_FOCUS_EVENT_ID": "42"]), expected)
        XCTAssertEqual(RecallRoute(url: try XCTUnwrap(URL(string: "hippocampus://recall?tab=search&focus=42"))), expected)
        XCTAssertEqual(RecallRoute(userInfo: ["tab": "you", "focus_event_id": NSNumber(value: 42)]), expected)
        XCTAssertEqual(RecallRoute(userInfo: ["focus_event_id": "42"]), expected)
        XCTAssertEqual(RecallRoute(environment: ["MCI_INITIAL_FOCUS_EVENT_ID": "0"]), RecallRoute())
        XCTAssertNil(RecallRoute(place: .ask, focusEventId: 0).focusEventId)
    }

    func testAPopupRequestOpensAskFromTheMenuBarAndLeavesTheWindowWhereItIs() throws {
        XCTAssertEqual(RecallRoute.askPanelURL.absoluteString, "hippocampus://ask")
        let launch = RecallRoute(environment: ["MCI_OPEN_GLOBAL_POPUP": "1"])
        XCTAssertTrue(launch.opensAskPanel)
        XCTAssertNil(launch.place)
        XCTAssertEqual(launch.place(keeping: .overview), .overview)
        let link = try XCTUnwrap(RecallRoute(url: try XCTUnwrap(URL(string: "hippocampus://recall?popup=1"))))
        XCTAssertEqual(link, RecallRoute(opensAskPanel: true))
        let running = try XCTUnwrap(RecallRoute(userInfo: ["open_popup": true]))
        XCTAssertEqual(running, RecallRoute(opensAskPanel: true))
        XCTAssertEqual(running.place(keeping: .you), .you)
        XCTAssertEqual(RecallRoute(userInfo: ["tab": "history", "open_popup": NSNumber(value: true)]),
                       RecallRoute(place: .ask, clearsField: true, opensAskPanel: true))
        XCTAssertFalse(RecallRoute(environment: ["MCI_OPEN_GLOBAL_POPUP": "0"]).opensAskPanel)
    }

    func testARequestReadsTheSameAtLaunchAndWhileTheWindowIsOpen() throws {
        let cases: [(environment: [String: String], userInfo: [AnyHashable: Any], link: String)] = [
            (["MCI_INITIAL_TAB": "privacy"], ["tab": "privacy"], "hippocampus://recall?tab=privacy"),
            (["MCI_INITIAL_TAB": "timeline"], ["tab": "timeline"], "hippocampus://recall?tab=timeline"),
            (["MCI_INITIAL_TAB": "search", "MCI_INITIAL_FOCUS_EVENT_ID": "7"],
             ["tab": "search", "focus_event_id": NSNumber(value: 7)], "hippocampus://recall?tab=search&focus=7"),
            (["MCI_OPEN_GLOBAL_POPUP": "1"], ["open_popup": true], "hippocampus://recall?popup=1"),
        ]
        for item in cases {
            let launch = RecallRoute(environment: item.environment)
            XCTAssertEqual(RecallRoute(userInfo: item.userInfo), launch, item.link)
            XCTAssertEqual(RecallRoute(url: try XCTUnwrap(URL(string: item.link))), launch, item.link)
            XCTAssertEqual(RecallRoute(RecallLaunchRequest(environment: item.environment)), launch, item.link)
        }
    }

    func testOtherLinksAreNotTheWindows() throws {
        XCTAssertNil(RecallRoute(url: try XCTUnwrap(URL(string: "hippocampus://ask?tab=you"))))
        XCTAssertNil(RecallRoute(url: try XCTUnwrap(URL(string: "https://recall?tab=you"))))
        XCTAssertNil(RecallRoute(userInfo: nil))
    }

    func testShowInHistoryLoadsTheSessionsOwnTimeWithItsNewestMomentSelected() {
        let range: ClosedRange<Int64> = 1_791_839_523_000_000...1_791_841_000_000_000
        let route = RecallRoute.history(of: range, selecting: 90_269)
        XCTAssertEqual(route.place, .ask)
        XCTAssertTrue(route.clearsField)
        XCTAssertFalse(route.focusesField)
        XCTAssertEqual(route.timeRange, range)
        XCTAssertEqual(route.focusEventId, 90_269)
        XCTAssertEqual(route.day, Date(timeIntervalSince1970: 1_791_839_523))
        XCTAssertNil(RecallRoute.history(of: range, selecting: -4).focusEventId)
        XCTAssertNil(RecallRoute.history(of: range).focusEventId)
    }

    func testASessionOnYouOpensOverviewOnItsDay() {
        let range: ClosedRange<Int64> = 1_791_823_265_000_000...1_791_825_055_000_000
        let route = RecallRoute.overview(showing: range)
        XCTAssertEqual(route, RecallRoute(place: .overview, day: Date(timeIntervalSince1970: 1_791_823_265),
                                          timeRange: range))
    }

    func testTheWindowsOwnCommandsAreRoutes() {
        XCTAssertEqual(RecallRoute.newQuestion, RecallRoute(place: .ask, clearsField: true, focusesField: true))
        XCTAssertEqual(RecallRoute.showHistory, RecallRoute(place: .ask, clearsField: true))
        XCTAssertEqual(RecallRoute.findInAsk, RecallRoute(place: .ask, focusesField: true))
        XCTAssertEqual(RecallRoute.names, RecallRoute(place: .you, youPath: [.names]))
    }

    func testTodaysWindowOpensOverviewAskAndYouByTheirNewNames() {
        XCTAssertEqual(RecallTab.from(deepLinkValue: "overview"), .now)
        XCTAssertEqual(RecallTab.from(deepLinkValue: "ask"), .search)
        XCTAssertEqual(RecallTab.from(deepLinkValue: "YOU"), .you)
        XCTAssertEqual(RecallTab.you.workspaceTab, .you)
        XCTAssertEqual(RecallLaunchRequest(environment: ["MCI_INITIAL_TAB": "ask"]).initialTab, .search)
        XCTAssertEqual(RecallLaunchRequest(environment: ["MCI_INITIAL_TAB": "you"]).navigationTab, .you)
    }
}
