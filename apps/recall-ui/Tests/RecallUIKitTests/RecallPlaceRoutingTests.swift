import Foundation
import XCTest
@testable import RecallUIKit

/// Every way the window is asked to show something lands on one of its
/// pages (SPEC 2.16, RULINGS X9), and a request reads the same at launch and
/// while the window is open (critique-recall-engineering finding 5).
final class RecallPlaceRoutingTests: XCTestCase {
    private let allTabs: [RecallTab] = [
        .now, .search, .timeline, .episodes, .brief, .privacy, .settings, .privacyDashboard, .timelineStrip, .you,
        .webPages, .lookedUp, .work, .aboutYou, .aiTools, .documents, .code, .conversations,
    ]

    func testEveryTabOpensOneOfThePagesAndSettingsOpensPreferences() {
        let places: [RecallTab: RecallPlace] = [
            .now: .today, .brief: .today, .episodes: .today,
            .search: .history, .timeline: .history, .timelineStrip: .history,
            .you: .aboutYou, .aboutYou: .aboutYou, .privacy: .privacy, .privacyDashboard: .privacy,
            .webPages: .webPages, .lookedUp: .lookedUp, .work: .workingOn, .aiTools: .aiTools,
            .documents: .documents, .code: .code, .conversations: .conversations,
        ]
        for tab in allTabs where tab != .settings {
            XCTAssertEqual(tab.place, places[tab], "\(tab)")
        }
        XCTAssertNil(RecallTab.settings.place, "Settings opens Preferences; the window stays where it is")
        XCTAssertEqual(RecallPlace.allCases, [.today, .history, .webPages, .documents, .code, .conversations,
                                              .lookedUp, .workingOn, .aboutYou, .aiTools, .privacy])
    }

    func testOnlyTheOldHistoryNamesEmptyTheFieldAndOnlyThePrivacyNamesOpenIt() {
        XCTAssertEqual(allTabs.filter(\.opensHistory), [.timeline, .timelineStrip])
        XCTAssertEqual(allTabs.filter(\.opensPrivacy), [.privacy, .privacyDashboard])
    }

    func testTheWindowsOldPlaceNamesOpenTheirNewPages() {
        XCTAssertEqual(RecallTab.from(deepLinkValue: "you"), .you)
        XCTAssertEqual(RecallRoute(tab: "overview"), RecallRoute(place: .today))
        XCTAssertEqual(RecallRoute(tab: "ask"), RecallRoute(place: .history, focusesField: true))
        XCTAssertEqual(RecallRoute(tab: "you"), RecallRoute(place: .aboutYou))
        XCTAssertEqual(RecallRoute(tab: " You "), RecallRoute(place: .aboutYou))
        // Code written before the sidebar still reads.
        XCTAssertEqual(RecallPlace.overview, .today)
        XCTAssertEqual(RecallPlace.ask, .history)
        XCTAssertEqual(RecallPlace.you, .aboutYou)
    }

    /// SPEC 2.16, row by row.
    func testEveryOlderNameKeepsWorking() {
        let routes: [String: RecallRoute] = [
            "today": RecallRoute(place: .today), "now": RecallRoute(place: .today),
            "daily": RecallRoute(place: .today), "overview": RecallRoute(place: .today),
            "brief": RecallRoute(place: .today), "briefs": RecallRoute(place: .today),
            "episodes": RecallRoute(place: .today), "sessions": RecallRoute(place: .today),
            "search": RecallRoute(place: .history, focusesField: true),
            "ask": RecallRoute(place: .history, focusesField: true),
            "timeline": RecallRoute(place: .history, clearsField: true),
            "history": RecallRoute(place: .history, clearsField: true),
            "timeline-strip": RecallRoute(place: .history, clearsField: true),
            "strip": RecallRoute(place: .history, clearsField: true),
            "you": RecallRoute(place: .aboutYou),
            "settings": RecallRoute(opensPreferences: true),
            "privacy": RecallRoute(place: .privacy),
            "dashboard": RecallRoute(place: .privacy),
            "privacy-dashboard": RecallRoute(place: .privacy),
            "web-pages": RecallRoute(place: .webPages), "pages": RecallRoute(place: .webPages),
            "looked-up": RecallRoute(place: .lookedUp), "searches": RecallRoute(place: .lookedUp),
            "work": RecallRoute(place: .workingOn),
            "about-you": RecallRoute(place: .aboutYou), "ai-tools": RecallRoute(place: .aiTools),
            "documents": RecallRoute(place: .documents), "code": RecallRoute(place: .code),
            "conversations": RecallRoute(place: .conversations),
        ]
        for (name, route) in routes {
            XCTAssertEqual(RecallRoute(tab: name), route, name)
            XCTAssertEqual(RecallRoute(tab: name.uppercased()), route, name)
            XCTAssertNotNil(RecallTab.from(deepLinkValue: name), "\(name) still opens the window")
            let link = try? XCTUnwrap(URL(string: "hippocampus://recall?tab=\(name)"))
            XCTAssertEqual(link.flatMap(RecallRoute.init(url:)), route, name)
            XCTAssertEqual(RecallRoute(environment: ["MCI_INITIAL_TAB": name]), route, name)
            XCTAssertEqual(RecallRoute(userInfo: ["tab": name, "open_popup": false]), route, name)
        }
    }

    /// The new link forms (SPEC 2.16): an item, a session, Forget Recent.
    func testAnItemASessionAndForgetRecentArriveFromEveryDoor() throws {
        let item = RecallRoute.item("w_9c41e2")
        XCTAssertEqual(item.workItem, "w_9c41e2")
        XCTAssertFalse(item.showsResume)
        XCTAssertEqual(RecallRoute(url: try XCTUnwrap(URL(string: "hippocampus://recall?tab=work&item=w_9c41e2"))), item)
        XCTAssertEqual(RecallRoute(environment: ["MCI_INITIAL_TAB": "work:w_9c41e2"]), item)
        XCTAssertEqual(RecallRoute(userInfo: ["tab": "work:w_9c41e2"]), item)
        XCTAssertEqual(RecallRoute(environment: ["MCI_INITIAL_TAB": "work:trailhead shop"]), RecallRoute(),
                       "a name never names an item")

        let start: Int64 = 1_791_839_523_000_000
        let session = RecallRoute.session(startUs: start)
        XCTAssertEqual(session.place, .today)
        XCTAssertEqual(session.timeRange, start...start)
        XCTAssertEqual(RecallRoute(url: try XCTUnwrap(URL(string: "hippocampus://recall?tab=today&session=\(start)"))),
                       session)
        XCTAssertEqual(RecallRoute(environment: ["MCI_INITIAL_TAB": "session:\(start)"]), session)
        XCTAssertEqual(RecallRoute(environment: ["MCI_INITIAL_TAB": "session:-4"]), RecallRoute())

        for choice in ForgetRecentChoice.allCases {
            let route = RecallRoute(forgetRecent: choice)
            XCTAssertEqual(RecallRoute(url: try XCTUnwrap(URL(string: "hippocampus://recall?forget=\(choice.rawValue)"))),
                           route)
            XCTAssertEqual(RecallRoute(environment: ["MCI_INITIAL_TAB": "forget:\(choice.rawValue)"]), route)
            XCTAssertNil(route.place, "the sheet opens over the page on screen")
        }
        XCTAssertNil(RecallRoute(environment: ["MCI_INITIAL_TAB": "forget:1d"]).forgetRecent)
    }

    /// A link can open Forget Recent's sheet, but its time is fixed only at
    /// the click, and nothing is forgotten without one (SPEC 2.6.4, 3.11).
    func testForgetRecentStartsAtTheClick() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let click = Date(timeIntervalSince1970: 1_791_841_000)
        XCTAssertEqual(ForgetRecentChoice.tenMinutes.start(at: click, calendar: calendar),
                       click.addingTimeInterval(-600))
        XCTAssertEqual(ForgetRecentChoice.hour.start(at: click, calendar: calendar), click.addingTimeInterval(-3_600))
        XCTAssertEqual(ForgetRecentChoice.today.start(at: click, calendar: calendar), calendar.startOfDay(for: click))
        XCTAssertTrue(ForgetRecentChoice.today.needsTypedWord)
        XCTAssertFalse(ForgetRecentChoice.hour.needsTypedWord)
        let request = ForgetRequest.recent(.tenMinutes, now: click, calendar: calendar)
        XCTAssertEqual(request.spans, [ForgetRequest.Span(startUs: 1_791_840_400_000_000, endUs: 1_791_841_000_000_000)])
        XCTAssertTrue(request.momentIds.isEmpty)
    }

    func testUnknownNamesAreIgnored() {
        for name in ["", "nope", "0", "overview2", "you2"] {
            XCTAssertNil(RecallRoute(tab: name), name)
            XCTAssertEqual(RecallRoute(environment: ["MCI_INITIAL_TAB": name]), RecallRoute(), name)
        }
    }

    func testAWindowThatIsOnlyOpeningShowsTodayAndAnOpenOneStaysPut() {
        let route = RecallRoute(environment: [:])
        XCTAssertEqual(route, RecallRoute())
        XCTAssertNil(route.place)
        XCTAssertEqual(route.place(keeping: .today), .today)
        XCTAssertEqual(route.place(keeping: .aboutYou), .aboutYou)
        XCTAssertEqual(RecallRoute(tab: "ask")?.place(keeping: .aboutYou), .history)
    }

    func testAFocusedMemoryLandsInHistoryOrOnTodayWhenTheNameSaysToday() throws {
        let expected = RecallRoute(place: .history, clearsField: true, focusEventId: 42)
        XCTAssertEqual(RecallRoute(environment: ["MCI_INITIAL_TAB": "now", "MCI_INITIAL_FOCUS_EVENT_ID": "42"]),
                       RecallRoute(place: .today, focusEventId: 42))
        XCTAssertEqual(RecallRoute(url: try XCTUnwrap(URL(string: "hippocampus://recall?tab=search&focus=42"))), expected)
        XCTAssertEqual(RecallRoute(userInfo: ["tab": "you", "focus_event_id": NSNumber(value: 42)]), expected)
        XCTAssertEqual(RecallRoute(userInfo: ["focus_event_id": "42"]), expected)
        XCTAssertEqual(RecallRoute(environment: ["MCI_INITIAL_FOCUS_EVENT_ID": "0"]), RecallRoute())
        XCTAssertNil(RecallRoute(place: .history, focusEventId: 0).focusEventId)
    }

    func testAPopupRequestOpensAskFromTheMenuBarAndLeavesTheWindowWhereItIs() throws {
        XCTAssertEqual(RecallRoute.askPanelURL.absoluteString, "hippocampus://ask")
        let launch = RecallRoute(environment: ["MCI_OPEN_GLOBAL_POPUP": "1"])
        XCTAssertTrue(launch.opensAskPanel)
        XCTAssertNil(launch.place)
        XCTAssertEqual(launch.place(keeping: .today), .today)
        let link = try XCTUnwrap(RecallRoute(url: try XCTUnwrap(URL(string: "hippocampus://recall?popup=1"))))
        XCTAssertEqual(link, RecallRoute(opensAskPanel: true))
        let running = try XCTUnwrap(RecallRoute(userInfo: ["open_popup": true]))
        XCTAssertEqual(running, RecallRoute(opensAskPanel: true))
        XCTAssertEqual(running.place(keeping: .aboutYou), .aboutYou)
        XCTAssertEqual(RecallRoute(userInfo: ["tab": "history", "open_popup": NSNumber(value: true)]),
                       RecallRoute(place: .history, clearsField: true, opensAskPanel: true))
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
        XCTAssertEqual(route.place, .history)
        XCTAssertTrue(route.clearsField)
        XCTAssertFalse(route.focusesField)
        XCTAssertEqual(route.timeRange, range)
        XCTAssertEqual(route.focusEventId, 90_269)
        XCTAssertEqual(route.day, Date(timeIntervalSince1970: 1_791_839_523))
        XCTAssertNil(RecallRoute.history(of: range, selecting: -4).focusEventId)
        XCTAssertNil(RecallRoute.history(of: range).focusEventId)
    }

    func testASessionOnAboutYouOpensTodayOnItsDay() {
        let range: ClosedRange<Int64> = 1_791_823_265_000_000...1_791_825_055_000_000
        let route = RecallRoute.overview(showing: range)
        XCTAssertEqual(route, RecallRoute(place: .today, day: Date(timeIntervalSince1970: 1_791_823_265),
                                          timeRange: range))
    }

    /// ⌘N and ⌘F keep the page (a page without a field goes to History's,
    /// in the window); Show History empties the field.
    func testTheWindowsOwnCommandsAreRoutes() {
        XCTAssertEqual(RecallRoute.newQuestion, RecallRoute(clearsField: true, focusesField: true))
        XCTAssertEqual(RecallRoute.showHistory, RecallRoute(place: .history, clearsField: true))
        XCTAssertEqual(RecallRoute.findInAsk, RecallRoute(focusesField: true))
        XCTAssertEqual(RecallRoute.names, RecallRoute(place: .aboutYou, youPath: [.names]))
        XCTAssertFalse(RecallPlace.aboutYou.hasField)
        XCTAssertFalse(RecallPlace.aiTools.hasField)
        XCTAssertFalse(RecallPlace.privacy.hasField)
        XCTAssertTrue(RecallPlace.today.hasField)
        XCTAssertTrue(RecallPlace.workingOn.hasField)
    }

    func testTheOldNamesStillParseToTheirTabs() {
        XCTAssertEqual(RecallTab.from(deepLinkValue: "overview"), .now)
        XCTAssertEqual(RecallTab.from(deepLinkValue: "ask"), .search)
        XCTAssertEqual(RecallTab.from(deepLinkValue: "YOU"), .you)
        XCTAssertEqual(RecallTab.you.workspaceTab, .you)
        XCTAssertEqual(RecallLaunchRequest(environment: ["MCI_INITIAL_TAB": "ask"]).initialTab, .search)
        XCTAssertEqual(RecallLaunchRequest(environment: ["MCI_INITIAL_TAB": "you"]).navigationTab, .you)
    }
}
