// SPDX-License-Identifier: Apache-2.0
//
// The window's new link forms (SPEC 2.16): an item by its id, a session by
// its start, and Forget Recent's sheet, carried to the window as the tab
// forms it reads (`work:`, `session:`, `forget:`). A link can open the sheet
// but never confirm it; ids, never names, travel in links.

import XCTest
@testable import HippocampusKit

final class WindowLinkRouteTests: XCTestCase {
    private func tab(_ text: String) -> String? {
        guard let url = URL(string: text), case let .openRecall(tab, _, _)? = HippocampusURLRoute.parse(url) else {
            return "not a recall route"
        }
        return tab
    }

    func testAnItemsLinkNamesItsIdOnly() {
        XCTAssertEqual(tab("hippocampus://recall?tab=work&item=w_9c41e2"), "work:w_9c41e2")
        XCTAssertEqual(tab("hippocampus://recall?tab=working-on&item=w_1"), "work:w_1")
        XCTAssertEqual(tab("hippocampus://recall?tab=work&item=trailhead%20shop"), "work",
                       "a name is never passed on")
        XCTAssertEqual(tab("hippocampus://recall?tab=work"), "work")
    }

    func testASessionsLinkNamesItsStart() {
        XCTAssertEqual(tab("hippocampus://recall?tab=today&session=1791839523000000"), "session:1791839523000000")
        XCTAssertEqual(tab("hippocampus://recall?session=-4"), nil)
        XCTAssertEqual(tab("hippocampus://recall?session=abc&tab=history"), "history")
    }

    func testAForgetLinkOpensTheSheetOnly() {
        XCTAssertEqual(tab("hippocampus://recall?forget=10m"), "forget:10m")
        XCTAssertEqual(tab("hippocampus://recall?forget=1h"), "forget:1h")
        XCTAssertEqual(tab("hippocampus://recall?forget=today"), "forget:today")
        XCTAssertNil(tab("hippocampus://recall?forget=everything"))
    }

    func testEveryOtherLinkIsUnchanged() {
        XCTAssertEqual(tab("hippocampus://recall?tab=history"), "history")
        XCTAssertEqual(tab("hippocampus://recall?tab=web-pages"), "web-pages")
        XCTAssertNil(tab("hippocampus://recall"))
    }
}
