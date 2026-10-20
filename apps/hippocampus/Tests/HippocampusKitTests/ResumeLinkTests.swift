// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import HippocampusKit

/// `hippocampus://resume?item=<id>` opens the window on a Working On item with
/// Resume's sheet over it (SPEC-DELTA 3). A link only shows the sheet:
/// nothing opens until the person clicks in it. Ids, never names, travel in
/// links.
final class ResumeLinkTests: XCTestCase {
    func testTheExactLinkNamesAnItem() throws {
        let url = try XCTUnwrap(URL(string: "hippocampus://resume?item=w_9c41e2"))
        XCTAssertEqual(HippocampusURLRoute.parse(url), .resume(item: "w_9c41e2"))
    }

    func testAnythingElseIsUnknown() throws {
        for link in [
            "hippocampus://resume", "hippocampus://resume?item=", "hippocampus://resume?id=w_1",
            "hippocampus://resume?item=w_1&item=w_2", "hippocampus://resume?item=w_1&open=1",
            "hippocampus://resume/w_1?item=w_1", "hippocampus://resume?item=w_1#now",
            "hippocampus://user@resume?item=w_1", "hippocampus://resume:80?item=w_1",
            "hippocampus://resume?item=trailhead%20shop", "hippocampus://resume?item=../x",
            "hippocampus://resume?item=" + String(repeating: "a", count: 65),
        ] {
            XCTAssertEqual(HippocampusURLRoute.parse(try XCTUnwrap(URL(string: link))), .unknown, link)
        }
    }

    func testTheWindowIsAskedForTheSheetByTheTabItAlreadyReads() {
        XCTAssertEqual(HippocampusURLRoute.resumeTab(item: "w_9c41e2"), "resume:w_9c41e2",
                       "RecallUIKit's RecallLaunchRequest reads this exact form")
    }

    func testOnlyAnIdCanBeAnItem() {
        for id in ["w_9c41e2", "W-1", "a", String(repeating: "a", count: 64)] {
            XCTAssertTrue(HippocampusURLRoute.isWorkItemId(id), id)
        }
        for id in ["", "--json", "-w1", "trailhead shop", "a/b", "é", "a.b", String(repeating: "a", count: 65)] {
            XCTAssertFalse(HippocampusURLRoute.isWorkItemId(id), id)
        }
    }

    func testTheAppSendsTheLinkThroughItsOneWayToTheWindow() throws {
        let app = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Hippocampus/HippocampusApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(app.contains("case .resume(let item):"))
        XCTAssertTrue(app.contains("openWindow(tab: HippocampusURLRoute.resumeTab(item: item))"),
                      "through openWindow, so setup comes forward until it is done")
    }
}
