import XCTest
@testable import RecallUIKit

/// The person's tidying of the sidebar (SPEC 2.11): kept with the window's
/// settings, by id only, never a project's name.
final class SidebarHidesTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "dev.hippocampus.tests.sidebar-hides.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testAnItemIsKeptByItsIdAndANameIsRefused() throws {
        let hides = SidebarHides(defaults: defaults)
        XCTAssertTrue(hides.hide(item: "w_9c41e2"))
        XCTAssertFalse(hides.hide(item: "trailhead shop"), "a name is never kept")
        XCTAssertFalse(hides.hide(item: "Q4 planning"))
        XCTAssertFalse(hides.hide(item: "--json"))
        XCTAssertEqual(hides.choices.hiddenItems, ["w_9c41e2"])

        // Nothing in the settings holds a name: only ids and plain flags.
        let stored = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("window.") }
        let text = String(describing: stored)
        for name in ["trailhead", "Q4", "planning", "shop"] {
            XCTAssertFalse(text.contains(name), name)
        }
        XCTAssertEqual(defaults.stringArray(forKey: "window.sidebar.hiddenItems"), ["w_9c41e2"])
    }

    func testHidingAndShowingSurviveANewWindow() {
        let hides = SidebarHides(defaults: defaults)
        hides.hide(item: "w_1")
        hides.hide(kind: .lookedUp)
        hides.show(kind: .code)
        hides.setWorkingOnHidden(true)
        let later = SidebarHides(defaults: defaults).choices
        XCTAssertEqual(later.hiddenItems, ["w_1"])
        XCTAssertEqual(later.hiddenKinds, [.lookedUp])
        XCTAssertEqual(later.shownKinds, [.code])
        XCTAssertTrue(later.workingOnHidden)

        hides.show(item: "w_1")
        hides.show(kind: .lookedUp)
        XCTAssertTrue(hides.choices.hiddenItems.isEmpty)
        XCTAssertEqual(hides.choices.shownKinds, [.code, .lookedUp])
        XCTAssertTrue(hides.choices.hiddenKinds.isEmpty)
    }

    func testOnlyLibrarysKindsCanBeHidden() {
        let hides = SidebarHides(defaults: defaults)
        hides.hide(kind: .today)
        hides.hide(kind: .privacy)
        hides.hide(kind: .history)
        XCTAssertTrue(hides.choices.hiddenKinds.isEmpty, "Today, History and the pinned group always show")
    }

    func testShowInSidebarKeepsTheItemsIdAndHideTakesItBack() {
        let hides = SidebarHides(defaults: defaults)
        hides.show(item: "w_personal")
        XCTAssertEqual(hides.choices.shownItems, ["w_personal"])
        XCTAssertTrue(hides.choices.hiddenItems.isEmpty)
        hides.hide(item: "w_personal")
        XCTAssertTrue(hides.choices.shownItems.isEmpty, "Hide from Sidebar takes back a show")
        XCTAssertEqual(hides.choices.hiddenItems, ["w_personal"])
        hides.show(item: "Taxes 2026 for Sam")
        XCTAssertTrue(hides.choices.shownItems.isEmpty, "a name is never kept, only an id")
    }

    func testResetSidebarClearsEveryHideAndShow() {
        let hides = SidebarHides(defaults: defaults)
        hides.show(item: "w_2")
        hides.hide(item: "w_1")
        hides.hide(kind: .webPages)
        hides.setWorkingOnHidden(true)
        hides.reset()
        XCTAssertEqual(hides.choices, SidebarHides.Choices())
    }

    func testThingsSaidOnceAreSaidOnce() {
        let hides = SidebarHides(defaults: defaults)
        XCTAssertTrue(hides.takeFootnote())
        XCTAssertFalse(hides.takeFootnote())
        XCTAssertFalse(SidebarHides(defaults: defaults).takeFootnote())
        XCTAssertTrue(hides.sidebarLineDue)
        hides.sidebarLineSaid()
        XCTAssertFalse(hides.sidebarLineDue)
        XCTAssertTrue(hides.firstForgetDue)
        hides.firstForgetSaid()
        XCTAssertFalse(SidebarHides(defaults: defaults).firstForgetDue)
    }

    /// A kind that has appeared stays, per memory, keyed by a hash of the
    /// memory's path; the path itself is never written.
    func testAppearedKindsAreKeptPerMemoryByAHash() {
        let hides = SidebarHides(defaults: defaults)
        let path = "/Users/sam/Library/Application Support/MCI/mci.sqlite"
        XCTAssertEqual(hides.noteAppeared([.webPages], memory: path), [.webPages])
        XCTAssertEqual(hides.noteAppeared([.lookedUp, .today], memory: path), [.webPages, .lookedUp])
        XCTAssertEqual(hides.appearedKinds(memory: "/elsewhere/demo.sqlite"), [])
        let text = String(describing: defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("window.") })
        XCTAssertFalse(text.contains("sam"))
        XCTAssertFalse(text.contains("mci.sqlite"))
    }

    func testNothingIsKeptAnywhereWithoutDefaults() {
        let hides = SidebarHides()
        hides.hide(item: "w_1")
        XCTAssertEqual(hides.choices.hiddenItems, ["w_1"])
        XCTAssertTrue(SidebarHides().choices.hiddenItems.isEmpty)
    }
}
