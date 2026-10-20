import XCTest
@testable import RecallUIKit

/// `hippocampus://resume?item=<id>` opens the window on a Working On item
/// with Resume's sheet over it (SPEC-DELTA 3). The app passes it as the tab
/// `resume:<id>`, so it arrives the way every request does: at launch, as a
/// command to an open window, or as a link the window is handed itself. A
/// route only shows the sheet; nothing opens until the person clicks.
final class ResumeRouteTests: XCTestCase {
    func testTheAppsTabNamesTheItemAtLaunchAndWhileOpen() throws {
        let launch = RecallLaunchRequest(environment: ["MCI_INITIAL_TAB": "resume:w_9c41e2"])
        XCTAssertEqual(launch.resumeItem, "w_9c41e2")
        XCTAssertNil(launch.tab)
        XCTAssertTrue(launch.bringsWindowForward)

        let command = try XCTUnwrap(RecallLaunchRequest(userInfo: ["tab": "resume:w_9c41e2"]))
        XCTAssertEqual(command.resumeItem, "w_9c41e2")
        XCTAssertTrue(command.bringsWindowForward)

        XCTAssertEqual(RecallLaunchRequest.resumeTabPrefix, "resume:",
                       "the app's HippocampusURLRoute.resumeTab writes this exact form")
    }

    func testTheRouteShowsTheSheetForTheItemAndKeepsThePlace() {
        let route = RecallRoute(environment: ["MCI_INITIAL_TAB": "resume:w_9c41e2"])
        XCTAssertEqual(route, .resume(item: "w_9c41e2"))
        XCTAssertEqual(route.workItem, "w_9c41e2")
        XCTAssertTrue(route.showsResume)
        XCTAssertNil(route.place)
        XCTAssertNil(route.focusEventId)
        XCTAssertFalse(route.opensAskPanel)
    }

    func testTheLinkItselfIsReadExactly() throws {
        let link = try XCTUnwrap(URL(string: "hippocampus://resume?item=w_9c41e2"))
        XCTAssertEqual(RecallLaunchRequest(url: link)?.resumeItem, "w_9c41e2")
        XCTAssertEqual(RecallRoute(url: link), .resume(item: "w_9c41e2"))
        for text in [
            "hippocampus://resume", "hippocampus://resume?item=", "hippocampus://resume?id=w_1",
            "hippocampus://resume?item=w_1&item=w_2", "hippocampus://resume?item=w_1&open=1",
            "hippocampus://resume/w_1?item=w_1", "hippocampus://resume?item=w_1#now",
            "hippocampus://user@resume?item=w_1", "hippocampus://resume:80?item=w_1",
            "hippocampus://resume?item=trailhead%20shop", "hippocampus://resume?item=../x",
            "hippocampus://resume?item=" + String(repeating: "a", count: 65),
        ] {
            let url = try XCTUnwrap(URL(string: text), text)
            XCTAssertNil(RecallLaunchRequest(url: url), text)
        }
    }

    func testOnlyAnIdCanNameAnItem() {
        for id in ["w_9c41e2", "W-1", "a", String(repeating: "a", count: 64)] {
            XCTAssertTrue(RecallLaunchRequest.isWorkItemId(id), id)
        }
        for id in ["", "--json", "-w1", "trailhead shop", "a/b", "é", "a.b", String(repeating: "a", count: 65)] {
            XCTAssertFalse(RecallLaunchRequest.isWorkItemId(id), id)
            XCTAssertNil(RecallLaunchRequest(environment: ["MCI_INITIAL_TAB": "resume:" + id]).resumeItem, id)
            XCTAssertFalse(RecallRoute.resume(item: id).showsResume, id)
            XCTAssertNil(RecallRoute(workItem: id).workItem, id)
        }
    }

    func testEveryOtherRequestIsUnchanged() throws {
        XCTAssertNil(RecallLaunchRequest(environment: ["MCI_INITIAL_TAB": "history"]).resumeItem)
        XCTAssertNil(RecallLaunchRequest(environment: [:]).resumeItem)
        XCTAssertEqual(RecallRoute(environment: ["MCI_INITIAL_TAB": "you"]),
                       RecallRoute(place: .you))
        let recall = try XCTUnwrap(URL(string: "hippocampus://recall?tab=history"))
        XCTAssertEqual(RecallRoute(url: recall), RecallRoute(place: .ask, clearsField: true))
        XCTAssertFalse(RecallRoute.showHistory.showsResume)
        XCTAssertNil(RecallRoute.showHistory.workItem)
    }
}
