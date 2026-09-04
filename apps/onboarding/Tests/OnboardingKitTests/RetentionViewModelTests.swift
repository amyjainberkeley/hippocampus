import XCTest
@testable import OnboardingKit

@MainActor
final class RetentionViewModelTests: XCTestCase {

    func testDefaultPolicyIsForever() async {
        let vm = RetentionViewModel(store: StubRetentionStore())
        await vm.load()
        XCTAssertEqual(vm.selectedPolicy, .forever)
        XCTAssertFalse(vm.isLoading)
    }

    func testSetPolicyPersistsViaStore() async {
        let store = StubRetentionStore()
        let vm = RetentionViewModel(store: store)
        vm.selectedPolicy = .thirtyDays
        let didSave = await vm.save()
        XCTAssertTrue(didSave)
        let saved = await store.currentPolicy()
        XCTAssertEqual(saved, .thirtyDays)
    }

    func testCustomDaysSavedWhenCustom() async {
        let store = StubRetentionStore()
        let vm = RetentionViewModel(store: store)
        vm.selectedPolicy = .custom
        vm.customDays = 42
        let didSave = await vm.save()
        XCTAssertTrue(didSave)
        let days = await store.currentCustomDays()
        XCTAssertEqual(days, 42)
    }

    func testNonCustomPolicySavesNilDays() async {
        let store = StubRetentionStore()
        let vm = RetentionViewModel(store: store)
        vm.selectedPolicy = .sevenDays
        let didSave = await vm.save()
        XCTAssertTrue(didSave)
        let days = await store.currentCustomDays()
        XCTAssertNil(days)
    }

    func testAllPoliciesHaveDisplayNames() {
        for policy in RetentionPolicy.allCases {
            XCTAssertFalse(policy.displayName.isEmpty)
        }
    }

    func testForeverDaysIsNil() {
        XCTAssertNil(RetentionPolicy.forever.days)
    }

    func testThirtyDaysPolicyReturns30() {
        XCTAssertEqual(RetentionPolicy.thirtyDays.days, 30)
    }

    func testSevenDaysPolicyReturns7() {
        XCTAssertEqual(RetentionPolicy.sevenDays.days, 7)
    }

    func testSaveFailureIsVisibleAndBlocksAdvance() async {
        let vm = RetentionViewModel(store: FailingRetentionStore())
        vm.selectedPolicy = .thirtyDays
        var advanced = false

        let saved = await vm.saveThen { advanced = true }

        XCTAssertFalse(saved)
        XCTAssertFalse(advanced)
        XCTAssertNotNil(vm.saveError)
        XCTAssertFalse(vm.isSaving)
    }
}

private actor FailingRetentionStore: RetentionStore {
    func currentPolicy() -> RetentionPolicy { .forever }
    func currentCustomDays() -> Int? { nil }
    func setPolicy(_ policy: RetentionPolicy, customDays: Int?) throws {
        _ = (policy, customDays)
        throw CocoaError(.fileWriteNoPermission)
    }
}
