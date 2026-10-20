import XCTest
@testable import RecallUIKit

/// The sidebar's rows and keys (SPEC 2.2 with SPEC-DELTA 1): Today, Working
/// On, Library with History first and then the kinds people already know,
/// and the pinned About You, AI Tools and Privacy. Keys never move.
final class SidebarModelTests: XCTestCase {
    func testTheKeysAreFixed() {
        let keys = SidebarPlace.allCases.compactMap { place in place.key.map { (String($0), place) } }
        XCTAssertEqual(keys.map { $0.0 }, ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        XCTAssertEqual(keys.map { $0.1 }, [.today, .history, .webPages, .documents, .code, .conversations,
                                       .lookedUp, .aboutYou, .aiTools])
        XCTAssertNil(SidebarPlace.privacy.key, "Privacy opens from its row and the status menu")
    }

    func testEveryKeyOpensItsPlaceShownOrNot() {
        let empty = SidebarModel()
        let shown = Set(empty.groups.flatMap(\.rows))
        for place in SidebarPlace.allCases {
            guard let key = place.key else { continue }
            XCTAssertEqual(SidebarPlace(key: key), place)
            if place.isLibraryKind {
                XCTAssertFalse(shown.contains(.place(place)), "\(place) has no row before it holds something")
            }
        }
        XCTAssertNil(SidebarPlace(key: "0"))
    }

    func testDayOneShowsFiveRows() {
        let rows = SidebarModel().groups.flatMap(\.rows)
        XCTAssertEqual(rows, [.place(.today), .place(.history), .place(.aboutYou), .place(.aiTools), .place(.privacy)])
    }

    func testAKindsRowAppearsOnlyOnceItHasSomethingAndInItsOwnPlace() {
        let model = SidebarModel(kindsWithMoments: [.lookedUp, .webPages, .code])
        let library = model.groups.first { $0.section == .library }
        XCTAssertEqual(library?.rows, [.place(.history), .place(.webPages), .place(.code), .place(.lookedUp)])
        let all = SidebarModel(kindsWithMoments: Set(SidebarPlace.libraryKinds))
        XCTAssertEqual(all.groups.first { $0.section == .library }?.rows,
                       [.place(.history)] + SidebarPlace.libraryKinds.map(SidebarRow.place))
    }

    func testOnlyLibrarysKindsAreLenses() {
        XCTAssertEqual(SidebarPlace.libraryKinds, [.webPages, .documents, .code, .conversations, .lookedUp])
        for place in [SidebarPlace.today, .history, .aboutYou, .aiTools, .privacy] {
            XCTAssertFalse(place.isLibraryKind, "\(place)")
        }
        let model = SidebarModel(kindsWithMoments: [.today, .privacy])
        XCTAssertEqual(model.groups.first { $0.section == .library }?.rows, [.place(.history)])
    }

    func testWorkingOnAppearsWithItsFirstItemAndShowsFiveAtMost() {
        XCTAssertNil(SidebarModel().groups.first { $0.section == .workingOn })
        let one = SidebarModel(workingOn: ["w_1"])
        XCTAssertEqual(one.groups.map(\.section), [.top, .workingOn, .library, .pinned])
        XCTAssertEqual(one.groups[1].rows, [.workItem("w_1")])
        let seven = SidebarModel(workingOn: (1...7).map { "w_\($0)" })
        XCTAssertEqual(seven.groups[1].rows, (1...5).map { .workItem("w_\($0)") } + [.showAll])
        let hidden = SidebarModel(workingOn: ["w_1"], hasMoreWorkingOn: true)
        XCTAssertEqual(hidden.groups[1].rows, [.workItem("w_1"), .showAll])
    }

    func testThePinnedGroupIsAlwaysAboutYouAIToolsAndPrivacy() {
        for model in [SidebarModel(), SidebarModel(kindsWithMoments: Set(SidebarPlace.libraryKinds), workingOn: ["w_1"])] {
            XCTAssertEqual(model.groups.last, SidebarGroup(section: .pinned,
                                                           rows: [.place(.aboutYou), .place(.aiTools), .place(.privacy)]))
        }
    }

    func testRowNamesAreTheSidebarsPlainWords() {
        XCTAssertEqual(SidebarPlace.allCases.map(\.title), [
            "Today", "History", "Web Pages", "Documents", "Code", "Conversations", "Looked Up",
            "About You", "AI Tools", "Privacy",
        ])
        let words = SidebarPlace.allCases.map(\.title)
            + [NavigationCopy.workingOn, NavigationCopy.showAll, NavigationCopy.library]
        for word in words {
            XCTAssertNil(CopyStyleValidator.containsMarketingSpeak(word), word)
            XCTAssertNil(CopyStyleValidator.containsJargon(word), word)
            XCTAssertFalse(CopyStyleValidator.containsExclamation(word), word)
        }
        XCTAssertFalse(SidebarPlace.allCases.map(\.systemImage).contains("sparkles"),
                       "no sparkles in the sidebar (SPEC 2.2)")
    }

    func testRowIDsNeverCarryAName() {
        XCTAssertEqual(SidebarRow.workItem("w_9c41e2").id, "item:w_9c41e2")
        XCTAssertEqual(SidebarRow.place(.webPages).id, "place:webPages")
        XCTAssertEqual(SidebarRow.showAll.id, "showAll")
    }

    // MARK: From the work read and the person's tidying

    private func item(_ id: String, _ kind: WorkItem.Kind = .document, inSidebar: Bool = true,
                      thumbnail: UInt64? = nil) -> WorkItem {
        WorkItem(id: id, kind: kind, name: "Item \(id)", lastUs: 1_000, inSidebar: inSidebar,
                 thumbnailMoment: thumbnail)
    }

    func testTheSidebarListsWhatTheAgentPutsThereWithoutWhatThePersonHid() {
        let snapshot = WorkSnapshot(items: [item("w_1", .code, thumbnail: 7), item("w_2"), item("w_3"),
                                            item("w_4", inSidebar: false)])
        let model = SidebarModel.make(snapshot: snapshot, kinds: [],
                                      hides: SidebarHides.Choices(hiddenItems: ["w_2"]))
        XCTAssertEqual(model.workingOn, ["w_1", "w_3"])
        XCTAssertTrue(model.hasMoreWorkingOn, "Show All while any are hidden")
        XCTAssertEqual(model.groups[1].rows, [.workItem("w_1"), .workItem("w_3"), .showAll])
        XCTAssertEqual(model.items["w_1"]?.thumbnailMoment, 7)
        XCTAssertEqual(model.items["w_1"]?.systemImage, "chevron.left.forwardslash.chevron.right")
        XCTAssertNil(model.items["w_2"], "a hidden item's name is not even drawn")
        XCTAssertEqual(model.allItemCount, 4)
    }

    func testANameThatLooksPersonalJoinsTheSidebarOnlyOnceThePersonShowsIt() {
        let personal = WorkItem(id: "w_p", kind: .document, name: "Item w_p", lastUs: 1_000, inSidebar: false,
                                recent: true, hiddenReason: "personal")
        let snapshot = WorkSnapshot(items: [item("w_1"), personal])
        let before = SidebarModel.make(snapshot: snapshot, kinds: [], hides: SidebarHides.Choices())
        XCTAssertEqual(before.workingOn, ["w_1"])
        XCTAssertTrue(before.hasMoreWorkingOn, "it waits on Show All")
        let after = SidebarModel.make(snapshot: snapshot, kinds: [],
                                      hides: SidebarHides.Choices(shownItems: ["w_p"]))
        XCTAssertEqual(after.workingOn, ["w_1", "w_p"])
        XCTAssertFalse(after.hasMoreWorkingOn)
        let hiddenAgain = SidebarModel.make(snapshot: snapshot, kinds: [],
                                            hides: SidebarHides.Choices(hiddenItems: ["w_p"], shownItems: ["w_p"]))
        XCTAssertEqual(hiddenAgain.workingOn, ["w_1"], "a hide wins over a show")
    }

    func testWithNothingHiddenAndFiveOrFewerShowAllStaysAway() {
        let snapshot = WorkSnapshot(items: (1...5).map { item("w_\($0)") })
        let model = SidebarModel.make(snapshot: snapshot, kinds: [], hides: SidebarHides.Choices())
        XCTAssertFalse(model.groups[1].rows.contains(.showAll))
        let six = SidebarModel.make(snapshot: WorkSnapshot(items: (1...6).map { item("w_\($0)") }), kinds: [],
                                    hides: SidebarHides.Choices())
        XCTAssertEqual(six.groups[1].rows.last, .showAll)
        XCTAssertEqual(six.workingOn.count, 5)
    }

    func testAKindShownFromTheViewMenuAppearsAndAHiddenOneGoes() {
        let model = SidebarModel.make(snapshot: .empty, kinds: [.webPages, .code],
                                      hides: SidebarHides.Choices(hiddenKinds: [.code], shownKinds: [.lookedUp]))
        XCTAssertEqual(model.groups.first { $0.section == .library }?.rows,
                       [.place(.history), .place(.webPages), .place(.lookedUp)])
    }

    func testOnlyAboutYouAndAIToolsCarryABadge() {
        let model = SidebarModel(badges: [.aiTools, .history, .aboutYou, .today])
        XCTAssertEqual(model.badges, [.aiTools, .aboutYou])
    }

    // MARK: Nothing moves under the pointer (SPEC 2.3, 2.13)

    func testANewReadWaitsWhileThePointerIsInTheSidebarAndIsDrawnWhenItLeaves() {
        var updates = SidebarUpdates()
        let first = SidebarModel(workingOn: ["w_1", "w_2"])
        XCTAssertTrue(updates.receive(first), "drawn at once while the pointer is elsewhere")
        updates.pointer(inside: true)
        let reordered = SidebarModel(workingOn: ["w_2", "w_1", "w_3"])
        XCTAssertFalse(updates.receive(reordered))
        XCTAssertEqual(updates.shown, first, "no row moves under the pointer")
        XCTAssertEqual(updates.waiting, reordered)
        let newest = SidebarModel(workingOn: ["w_3", "w_2", "w_1"])
        XCTAssertFalse(updates.receive(newest))
        XCTAssertEqual(updates.waiting, newest, "only the newest read waits")
        XCTAssertTrue(updates.pointer(inside: false))
        XCTAssertEqual(updates.shown, newest)
        XCTAssertNil(updates.waiting)
    }

    func testANewReadWaitsWhileARowHasKeyboardFocus() {
        var updates = SidebarUpdates(shown: SidebarModel(workingOn: ["w_1"]))
        updates.focus(inside: true)
        updates.receive(SidebarModel(workingOn: ["w_1", "w_2"]))
        XCTAssertEqual(updates.shown.workingOn, ["w_1"])
        updates.pointer(inside: true)
        updates.focus(inside: false)
        XCTAssertEqual(updates.shown.workingOn, ["w_1"], "the pointer is still in")
        updates.pointer(inside: false)
        XCTAssertEqual(updates.shown.workingOn, ["w_1", "w_2"])
    }

    func testThePersonsOwnChangeIsDrawnAtOnce() {
        var updates = SidebarUpdates(shown: SidebarModel(workingOn: ["w_1", "w_2"]))
        updates.pointer(inside: true)
        updates.apply(SidebarModel(workingOn: ["w_2"]))
        XCTAssertEqual(updates.shown.workingOn, ["w_2"], "Hide from Sidebar acts where the person clicked")
    }

    func testTheSameReadChangesNothing() {
        var updates = SidebarUpdates(shown: SidebarModel(workingOn: ["w_1"]))
        XCTAssertFalse(updates.receive(SidebarModel(workingOn: ["w_1"])))
        XCTAssertNil(updates.waiting)
    }

    // MARK: Which kinds hold something

    func testKindsComeFromTheAppsHistoryHoldsAndWorkingOn() {
        let apps = [ObservedApp(appBundleId: "com.google.Chrome", count: 40),
                    ObservedApp(appBundleId: "com.microsoft.VSCode", count: 12),
                    ObservedApp(appBundleId: "com.tinyspeck.slackmacgap", count: 3),
                    ObservedApp(appBundleId: "com.apple.Notes", count: 0)]
        XCTAssertEqual(LibraryKinds.kinds(apps: apps), [.webPages, .code, .conversations],
                       "an app with no moments makes no kind")
        let snapshot = WorkSnapshot(items: [WorkItem(id: "w_1", kind: .design, name: "x", lastUs: 1)])
        XCTAssertEqual(LibraryKinds.kinds(apps: [], snapshot: snapshot), [.documents])
        XCTAssertEqual(LibraryKinds.kinds(apps: [], sawSearch: true), [.lookedUp])
        XCTAssertEqual(LibraryKinds.kinds(apps: [ObservedApp(appBundleId: "com.jetbrains.goland", count: 1)]),
                       [.code])
        XCTAssertTrue(LibraryKinds.kinds(apps: [ObservedApp(appBundleId: "com.example.unknown", count: 9)]).isEmpty)
    }
}
