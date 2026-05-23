import XCTest
@testable import OnboardingKit

@MainActor
final class TCCDenialRecoveryTests: XCTestCase {

    private func makeVM(
        srStatus: TCCStatus = .notRequested,
        axStatus: TCCStatus = .notRequested
    ) -> (OnboardingFlowViewModel, StubTCCPermission, StubTCCPermission) {
        let sr = StubTCCPermission(kind: .screenRecording, status: srStatus)
        let ax = StubTCCPermission(kind: .accessibility, status: axStatus)
        let vm = OnboardingFlowViewModel(screenRecording: sr, accessibility: ax)
        return (vm, sr, ax)
    }

    // MARK: - Three-state detection

    func testNeverAskedBlocksAdvance() {
        let (vm, _, _) = makeVM(srStatus: .notRequested)
        vm.goTo(.permissions)
        XCTAssertFalse(vm.canAdvance, "Must verify grant before advancing past permissions")
    }

    func testGrantedAllowsAdvance() {
        let (vm, _, _) = makeVM(srStatus: .granted)
        vm.goTo(.permissions)
        XCTAssertTrue(vm.canAdvance)
    }

    func testDeniedBlocksAdvance() {
        let (vm, _, _) = makeVM(srStatus: .denied)
        vm.goTo(.permissions)
        XCTAssertFalse(vm.canAdvance)
    }

    func testAdvanceFromNotRequestedPermissionsIsNoop() {
        let (vm, _, _) = makeVM(srStatus: .notRequested)
        vm.goTo(.permissions)
        vm.advance()
        XCTAssertEqual(vm.currentStep, .permissions)
    }

    func testAdvanceFromDeniedPermissionsIsNoop() {
        let (vm, _, _) = makeVM(srStatus: .denied)
        vm.goTo(.permissions)
        vm.advance()
        XCTAssertEqual(vm.currentStep, .permissions)
    }

    func testDeniedThenGrantedAllowsAdvance() {
        let (vm, sr, _) = makeVM(srStatus: .denied)
        vm.goTo(.permissions)
        XCTAssertFalse(vm.canAdvance)
        sr.simulateGrant()
        XCTAssertTrue(vm.canAdvance)
    }

    // MARK: - Reset and retry

    func testResetAndRetrySucceeds() async {
        let sr = StubTCCPermission(kind: .screenRecording, status: .denied)
        sr.resetShouldSucceed = true

        let result = await sr.resetAndRetry()

        XCTAssertTrue(result)
        XCTAssertEqual(sr.status, .granted)
        XCTAssertEqual(sr.resetCallCount, 1)
    }

    func testResetAndRetryFails() async {
        let sr = StubTCCPermission(kind: .screenRecording, status: .denied)
        sr.resetShouldSucceed = false

        let result = await sr.resetAndRetry()

        XCTAssertFalse(result)
        XCTAssertEqual(sr.status, .denied)
    }

    func testResetAndRetryUnblocksAdvance() async {
        let (vm, sr, _) = makeVM(srStatus: .denied)
        sr.resetShouldSucceed = true
        vm.goTo(.permissions)
        XCTAssertFalse(vm.canAdvance)

        _ = await sr.resetAndRetry()

        XCTAssertTrue(vm.canAdvance)
        vm.advance()
        XCTAssertEqual(vm.currentStep, .browserExtension)
    }

    // MARK: - Accessibility denial (separate row, non-blocking)

    func testAccessibilityDeniedDoesNotBlockAdvance() {
        let (vm, _, _) = makeVM(srStatus: .granted, axStatus: .denied)
        vm.goTo(.permissions)
        XCTAssertTrue(vm.canAdvance)
    }

    func testAccessibilityResetAndRetry() async {
        let ax = StubTCCPermission(kind: .accessibility, status: .denied)
        ax.resetShouldSucceed = true

        let result = await ax.resetAndRetry()

        XCTAssertTrue(result)
        XCTAssertEqual(ax.status, .granted)
    }

    // MARK: - Open privacy settings fallback

    func testOpenPrivacySettingsCallsOpenSettings() {
        let sr = StubTCCPermission(kind: .screenRecording, status: .denied)
        sr.openPrivacySettings()
        XCTAssertEqual(sr.openSettingsCallCount, 1)
    }

    // MARK: - refreshPermissions triggers re-evaluation

    func testRefreshPermissionsIncrementsCounter() {
        let (vm, _, _) = makeVM(srStatus: .granted)
        let before = vm.permissionRefreshCount
        vm.refreshPermissions()
        XCTAssertEqual(vm.permissionRefreshCount, before + 1)
    }

    func testRefreshPermissionsUpdatesCanAdvance() {
        let (vm, sr, _) = makeVM(srStatus: .notRequested)
        vm.goTo(.permissions)
        XCTAssertFalse(vm.canAdvance)
        sr.simulateGrant()
        vm.refreshPermissions()
        XCTAssertTrue(vm.canAdvance)
    }

    // MARK: - Non-permission slides unaffected

    func testCanAdvanceOnOtherSlides() {
        let (vm, _, _) = makeVM(srStatus: .denied)
        for step in OnboardingStep.allCases where step != .permissions && step != .done {
            vm.goTo(step)
            XCTAssertTrue(vm.canAdvance, "Should be able to advance from \(step)")
        }
    }
}
