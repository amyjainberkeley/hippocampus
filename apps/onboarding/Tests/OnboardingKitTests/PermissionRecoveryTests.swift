import XCTest
@testable import OnboardingKit

/// A permission that is off, or turned off during setup, keeps its row
/// asking for help and Continue off; turning it on clears that.
@MainActor
final class PermissionRecoveryTests: XCTestCase {
    func testResumingWithAPermissionOffShowsItsHelpAndHoldsContinue() {
        for surface in PermissionSurface.allCases {
            let sr = StubTCCPermission(kind: .screenRecording, status: surface == .screenRecording ? .denied : .granted)
            let ax = StubTCCPermission(kind: .accessibility, status: surface == .accessibility ? .denied : .granted)
            let vm = OnboardingFlowViewModel(screenRecording: sr, accessibility: ax, initialScreen: .permissions)
            XCTAssertEqual(vm.rowState(surface), .needsHelp, "\(surface)")
            XCTAssertFalse(vm.canAdvance)
            vm.advance()
            XCTAssertEqual(vm.screen, .permissions)
        }
    }

    func testOnlyTheAsyncRefreshSeesAPermissionTurnedOffDuringSetup() async {
        let fixture = ScreenRecordingFixture(inProcess: true, freshProcessSays: nil)
        let vm = OnboardingFlowViewModel(
            screenRecording: fixture.permission,
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
            initialScreen: .permissions
        )
        XCTAssertTrue(vm.canAdvance)
        fixture.inProcess = false
        vm.refreshPermissions()
        XCTAssertTrue(vm.canAdvance, "the quick check never turns a permission off")
        await vm.refreshPermissionsAsync()
        XCTAssertFalse(vm.canAdvance)
        XCTAssertEqual(vm.rowState(.screenRecording), .needsHelp)
    }

    func testTurningItOnInSystemSettingsTurnsTheRowOnAndTurningOneOffAsksAgain() async {
        let sr = StubTCCPermission(kind: .screenRecording, status: .denied)
        let ax = StubTCCPermission(kind: .accessibility, status: .granted)
        let vm = OnboardingFlowViewModel(screenRecording: sr, accessibility: ax, initialScreen: .permissions)
        sr.simulateGrant()
        vm.refreshPermissions()
        XCTAssertEqual(vm.rowState(.screenRecording), .granted)
        XCTAssertTrue(vm.canAdvance)

        ax.simulateDeny()
        await vm.refreshPermissionsAsync()
        XCTAssertEqual(vm.rowState(.accessibility), .needsHelp)
        XCTAssertFalse(vm.canAdvance)
        XCTAssertEqual(sr.status, .granted)
    }
}
