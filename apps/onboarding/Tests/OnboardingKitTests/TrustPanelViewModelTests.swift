import XCTest
@testable import OnboardingKit

@MainActor
final class TrustPanelViewModelTests: XCTestCase {

    private func makeVM(
        allowlist: AllowlistStore = StubAllowlistStore(),
        denylist: DenylistEditorStore = StubDenylistEditorStore()
    ) -> TrustPanelViewModel {
        TrustPanelViewModel(allowlistStore: allowlist, denylistStore: denylist)
    }

    func testLoadPopulatesAllowlist() async {
        let vm = makeVM()
        await vm.load()
        XCTAssertEqual(vm.allowlistEntries.count, 10)
        XCTAssertFalse(vm.isLoading)
    }

    func testAllowlistContainsExpected10BundleIds() async {
        let vm = makeVM()
        await vm.load()

        let ids = Set(vm.allowlistEntries.map(\.bundleId))
        let expected: Set<String> = [
            "com.apple.Safari",
            "com.apple.Terminal",
            "com.microsoft.VSCode",
            "com.google.Chrome",
            "com.tinyspeck.slackmacgap",
            "notion.id",
            "com.linear.LinearMac",
            "com.apple.dt.Xcode",
            "company.thebrowser.Browser",
            "com.figma.Desktop",
        ]
        XCTAssertEqual(ids, expected)
    }

    func testCascadeStepsAre7InOrder() {
        let vm = makeVM()
        XCTAssertEqual(vm.cascadeSteps.count, 7)
        XCTAssertEqual(vm.cascadeSteps.first?.section, 1)
        XCTAssertEqual(vm.cascadeSteps.last?.section, 7)
    }

    func testDenylistCategoriesAre3() {
        let vm = makeVM()
        XCTAssertEqual(vm.denylistCategories.count, 3)
    }

    func testDenylistCategoriesAreContentFree() {
        let vm = makeVM()
        for cat in vm.denylistCategories {
            XCTAssertFalse(cat.name.isEmpty)
            XCTAssertFalse(cat.description.isEmpty)
        }
    }

    func testCustomStoreEntries() async {
        let custom = StubAllowlistStore(entries: [
            AllowlistEntry(bundleId: "com.test.app", rationale: "test"),
        ])
        let vm = makeVM(allowlist: custom)
        await vm.load()
        XCTAssertEqual(vm.allowlistEntries.count, 1)
    }

    func testLoadPopulatesDenylist() async {
        let deny = StubDenylistEditorStore(cso: [
            DenylistEntry(type: .bundleId, value: "com.bad.app", source: .csoRatified),
        ])
        let vm = makeVM(denylist: deny)
        await vm.load()
        XCTAssertEqual(vm.denylistEntries.count, 1)
    }

    func testAddDenyEntry() async {
        let vm = makeVM()
        await vm.load()
        vm.newDenyType = .bundleId
        vm.newDenyValue = "com.block.this"
        await vm.addDenyEntry()
        XCTAssertEqual(vm.denylistEntries.count, 1)
        XCTAssertTrue(vm.newDenyValue.isEmpty)
    }

    func testAddDenyEntryEmptyValueNoop() async {
        let vm = makeVM()
        await vm.load()
        vm.newDenyValue = "   "
        await vm.addDenyEntry()
        XCTAssertEqual(vm.denylistEntries.count, 0)
    }
}
