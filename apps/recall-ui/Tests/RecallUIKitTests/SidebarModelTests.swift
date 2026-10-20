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
}
