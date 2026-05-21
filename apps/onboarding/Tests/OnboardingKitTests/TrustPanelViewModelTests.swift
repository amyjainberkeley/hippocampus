import XCTest
@testable import OnboardingKit

@MainActor
final class TrustPanelViewModelTests: XCTestCase {

    func testLoadPopulatesAllowlist() async {
        let vm = TrustPanelViewModel(store: StubAllowlistStore())
        await vm.load()
        XCTAssertEqual(vm.allowlistEntries.count, 10)
        XCTAssertFalse(vm.isLoading)
    }

    func testAllowlistContainsExpected10BundleIds() async {
        let vm = TrustPanelViewModel(store: StubAllowlistStore())
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
        let vm = TrustPanelViewModel(store: StubAllowlistStore())
        XCTAssertEqual(vm.cascadeSteps.count, 7)
        XCTAssertEqual(vm.cascadeSteps.first?.section, 1)
        XCTAssertEqual(vm.cascadeSteps.last?.section, 7)
    }

    func testDenylistCategoriesAre3() {
        let vm = TrustPanelViewModel(store: StubAllowlistStore())
        XCTAssertEqual(vm.denylistCategories.count, 3)
    }

    func testDenylistCategoriesAreContentFree() {
        let vm = TrustPanelViewModel(store: StubAllowlistStore())
        for cat in vm.denylistCategories {
            XCTAssertFalse(cat.name.isEmpty)
            XCTAssertFalse(cat.description.isEmpty)
        }
    }

    func testCustomStoreEntries() async {
        let custom = StubAllowlistStore(entries: [
            AllowlistEntry(bundleId: "com.test.app", rationale: "test"),
        ])
        let vm = TrustPanelViewModel(store: custom)
        await vm.load()
        XCTAssertEqual(vm.allowlistEntries.count, 1)
    }
}
