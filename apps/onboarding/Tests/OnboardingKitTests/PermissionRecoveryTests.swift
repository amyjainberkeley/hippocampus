import XCTest
@testable import OnboardingKit

@MainActor
final class PermissionRecoveryTests: XCTestCase {
    func testResumingWithDeniedRequiredPermissionKeepsRecoveryVisible() {
        for surface in [PermissionSurface.screenRecording, .accessibility] {
            let sr = StubTCCPermission(kind: .screenRecording, status: surface == .screenRecording ? .denied : .granted)
            let ax = StubTCCPermission(kind: .accessibility, status: surface == .accessibility ? .denied : .granted)
            let vm = OnboardingFlowViewModel(screenRecording: sr, accessibility: ax,
                                            stateStore: InMemoryOnboardingStateStore(), initialStep: .permissions)
            XCTAssertEqual(vm.currentPermissionSurface, surface)
            XCTAssertFalse(vm.permissionChoreographyComplete)
            XCTAssertFalse(vm.canAdvance)
            vm.advance()
            XCTAssertEqual(vm.currentStep, .permissions)
        }
    }

    func testSettingsGrantClearsDeniedOutcomeAndRevocationReopensRecovery() {
        let sr = StubTCCPermission(kind: .screenRecording, status: .denied)
        let ax = StubTCCPermission(kind: .accessibility, status: .granted)
        let vm = OnboardingFlowViewModel(screenRecording: sr, accessibility: ax,
                                        stateStore: InMemoryOnboardingStateStore(), initialStep: .permissions)
        sr.simulateGrant()
        vm.refreshPermissions()
        XCTAssertEqual(vm.permissionResults[.screenRecording], .granted)
        XCTAssertNil(vm.currentPermissionSurface)
        XCTAssertTrue(vm.canAdvance)

        ax.simulateDeny()
        vm.refreshPermissions()
        XCTAssertEqual(vm.currentPermissionSurface, .accessibility)
        XCTAssertEqual(vm.permissionResults[.accessibility], .denied)
        XCTAssertFalse(vm.permissionChoreographyComplete)
        XCTAssertFalse(vm.canAdvance)
        XCTAssertEqual(sr.status, .granted)
        XCTAssertEqual(ax.status, .denied)
    }
}
