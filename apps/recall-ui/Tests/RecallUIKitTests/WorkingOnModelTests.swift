import XCTest
@testable import RecallUIKit

/// Working On's groups and the sidebar's section (SPEC 2.3, 3.3,
/// SPEC-DELTA 2): the read's order, the person's hides, and personal names
/// they chose to show.
@MainActor
final class WorkingOnModelTests: XCTestCase {
    private func item(_ id: String, _ name: String, kind: WorkItem.Kind = .document, week: Int = 60,
                      inSidebar: Bool = true, recent: Bool? = nil, personal: Bool = false,
                      thumbnail: UInt64? = nil) -> WorkItem {
        WorkItem(id: id, kind: kind, name: name, apps: ["com.apple.Notes"], lastUs: WorkClock.us(0, 10),
                 weekMinutes: week, daysThisWeek: week > 0 ? 1 : 0, inSidebar: inSidebar, recent: recent,
                 hiddenReason: personal ? "personal" : nil, thumbnailMoment: thumbnail,
                 totalMinutes: max(week, 45))
    }

    func testShowAllGroupsThisWeekEarlierAndWhatIsNotShown() {
        let items = [
            item("w_a", "trailhead-shop", kind: .code),
            item("w_b", "Launch checklist"),
            item("w_c", "bike-api", kind: .code, week: 0, inSidebar: false),
            item("w_d", "Mortgage refinance", kind: .spreadsheet, inSidebar: false, recent: true, personal: true),
        ]
        let groups = WorkingOnModel.groups(items, hidden: ["w_b"])
        XCTAssertEqual(groups.map(\.kind), [.thisWeek, .earlier, .notShown])
        XCTAssertEqual(groups.map { $0.items.map(\.name) },
                       [["trailhead-shop"], ["bike-api"], ["Launch checklist", "Mortgage refinance"]])
        XCTAssertEqual(groups.map(\.title), [WorkCopy.thisWeek, WorkCopy.earlier, WorkCopy.notShownInSidebar(count: 2)])
        XCTAssertEqual(WorkingOnModel.whyNotShown(items[1], hidden: ["w_b"]), WorkCopy.youHidIt)
        XCTAssertEqual(WorkingOnModel.whyNotShown(items[3], hidden: []), WorkCopy.looksPersonal)
        XCTAssertNil(WorkingOnModel.whyNotShown(items[0], hidden: []))
        XCTAssertEqual(WorkingOnModel.groups([], hidden: []), [], "no empty groups")
        XCTAssertEqual(WorkingOnModel.groups(Array(items.prefix(1)), hidden: []).map(\.kind), [.thisWeek])
    }

    func testAPersonalNameTheyShowedJoinsTheSidebarWhileItHasTheTime() {
        let personal = item("w_d", "Mortgage refinance", inSidebar: false, recent: true, personal: true)
        let old = item("w_e", "Tax return", week: 0, inSidebar: false, recent: false, personal: true)
        let snapshot = WorkSnapshot(items: [item("w_a", "trailhead-shop"), personal, old])
        XCTAssertEqual(WorkingOnSidebar(snapshot).ids, ["w_a"], "a personal name stays out")
        XCTAssertEqual(WorkingOnSidebar(snapshot, shown: ["w_d", "w_e"]).ids, ["w_a", "w_d"],
                       "shown, it joins; without the sidebar's time it can't")
        XCTAssertEqual(WorkingOnSidebar(snapshot, hidden: ["w_d"], shown: ["w_d"]).ids, ["w_a"], "a hide wins")

        let groups = WorkingOnModel.groups(snapshot.items, hidden: [], shown: ["w_d", "w_e"])
        XCTAssertEqual(groups.map(\.kind), [.thisWeek, .earlier], "nothing left under Not shown")
        XCTAssertEqual(groups.last?.items.map(\.name), ["Tax return"])
        XCTAssertNil(WorkingOnModel.whyNotShown(personal, hidden: [], shown: ["w_d"]))
        XCTAssertTrue(personal.isKeptOut(hidden: [], shown: []))
        XCTAssertFalse(personal.isKeptOut(hidden: [], shown: ["w_d"]))
        XCTAssertTrue(personal.isKeptOut(hidden: ["w_d"], shown: ["w_d"]))
        XCTAssertEqual(WorkingOnModel.whyNotShown(personal, hidden: ["w_d"], shown: ["w_d"]), WorkCopy.youHidIt)
    }

    func testTheSidebarListsFiveInTheReadsOrderWithoutHiddenOnes() {
        let items = (1...7).map { item("w_\($0)", "Item \($0)") }
        let sidebar = WorkingOnSidebar(WorkSnapshot(items: items), hidden: ["w_2"])
        XCTAssertEqual(sidebar.ids, ["w_1", "w_3", "w_4", "w_5", "w_6"])
        XCTAssertEqual(sidebar.items.count, SidebarModel.maxWorkingOnRows)
        XCTAssertTrue(sidebar.showsAll)
        XCTAssertEqual(sidebar.total, 7)

        let two = Array(items.prefix(2))
        XCTAssertFalse(WorkingOnSidebar(WorkSnapshot(items: two)).showsAll, "everything is in the sidebar")
        XCTAssertTrue(WorkingOnSidebar(WorkSnapshot(items: two), hidden: ["w_1"]).showsAll,
                      "Show All holds what was hidden")
        let withOld = WorkingOnSidebar(WorkSnapshot(items: [item("w_1", "A"), item("w_9", "Old", week: 0, inSidebar: false)]))
        XCTAssertEqual(withOld.ids, ["w_1"])
        XCTAssertTrue(withOld.showsAll, "Show All holds what is only on the Working On page")
        XCTAssertEqual(WorkingOnSidebar(.empty).ids, [])
        XCTAssertFalse(WorkingOnSidebar(.empty).showsAll)
    }

    func testTheFieldFiltersNamesIgnoringCaseAndAccents() async {
        let model = WorkingOnModel(reader: PreviewWorkReader(snapshot: WorkSnapshot(items: [
            item("w_a", "Café menu"), item("w_b", "trailhead-shop", kind: .code),
        ])))
        XCTAssertEqual(model.state, .loading)
        await model.reload()
        XCTAssertEqual(model.state, .loaded)
        model.filter = "CAFE"
        XCTAssertEqual(model.groups(hidden: []).flatMap(\.items).map(\.name), ["Café menu"])
        model.filter = "  "
        XCTAssertEqual(model.groups(hidden: []).flatMap(\.items).count, 2, "spaces filter nothing")
        model.filter = "nothing like it"
        XCTAssertTrue(model.groups(hidden: []).isEmpty)
    }

    func testAFailedReadKeepsWhatWasShownAndSaysSoOnlyWhenNothingWas() async {
        let reader = SwitchingWorkReader(snapshot: WorkSnapshot(items: [item("w_a", "trailhead-shop")]))
        let model = WorkingOnModel(reader: reader)
        await model.reload()
        reader.fail()
        await model.reload()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.snapshot.items.map(\.name), ["trailhead-shop"])

        let nothing = WorkingOnModel(reader: UnavailableWorkReader())
        await nothing.reload()
        XCTAssertEqual(nothing.state, .failed)
    }

    func testCardsAndRowsSayTheTimeTheWayScreenTimeDoes() {
        let thisWeek = item("w_a", "trailhead-shop", kind: .code, week: 160)
        XCTAssertEqual(WorkFormat.time(thisWeek), "2 hr 40 min")
        XCTAssertEqual(WorkFormat.weekLine(thisWeek), "On 1 day this week \u{00B7} 2 hr 40 min")
        let before = WorkItem(id: "w_c", kind: .code, name: "bike-api", lastUs: WorkClock.us(10, 11),
                              inSidebar: false, totalMinutes: 180)
        XCTAssertEqual(WorkFormat.time(before), "3 hr")
        XCTAssertEqual(WorkFormat.weekLine(before), "3 hr in all")
    }
}
