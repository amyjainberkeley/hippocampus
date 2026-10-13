import XCTest
@testable import OnboardingKit

/// The Automation permission and the Full Disk Access snapshot the view
/// model keeps for the panels: the browser extension panel's Safari flow
/// raises the Automation prompt, and app access asks for Full Disk Access.
/// The four screens never ask for either.
@MainActor
final class PreflightOverviewTests: XCTestCase {

    func testThePanelsReachAutomationAndFullDiskAccessThroughTheFlow() {
        let vm = makeVM(sr: .notRequested, ax: .notRequested, am: .notRequested)
        XCTAssertEqual(vm.automationPermission.kind, .automation)
        XCTAssertEqual(vm.automationPermission.status, .notRequested)
        XCTAssertEqual(vm.fullDiskAccessStatus, .notRequested)
        XCTAssertEqual(OnboardingFlowViewModel.rowSurfaces, [.screenRecording, .accessibility],
                       "setup asks for two permissions only")
    }

    /// `probeAutomation()` is the on-demand hook called from
    /// `BrowserExtensionSlide` after the Safari click. If it stops
    /// returning the current status, the denial banner won't render.
    func testProbeAutomationReflectsCurrentStatus() {
        let vm = makeVM(sr: .granted, ax: .granted, am: .notRequested)
        let am = vm.automationPermission as! StubTCCPermission

        XCTAssertEqual(vm.probeAutomation(), .notRequested)
        am.simulateDeny()
        XCTAssertEqual(vm.probeAutomation(), .denied)
        am.simulateGrant()
        XCTAssertEqual(vm.probeAutomation(), .granted)
    }

    /// Automation status survives a full `refreshPermissions()` sweep.
    func testRefreshPermissionsDoesNotClobberAutomation() {
        let vm = makeVM(sr: .granted, ax: .granted, am: .granted)
        vm.refreshPermissions()
        XCTAssertEqual(vm.automationPermission.status, .granted)
        XCTAssertEqual(vm.screenRecordingPermission.status, .granted)
        XCTAssertEqual(vm.accessibilityPermission.status, .granted)
    }

    // MARK: - FDA snapshot

    /// FDA status is snapshot from the actor into a synchronous
    /// @Published so a panel can show it without awaiting.
    func testRefreshFullDiskAccessStatusSnapshotsFromActor() async {
        let fda = StubFullDiskAccessPermission(initial: .notRequested)
        let vm = OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
            automation: StubTCCPermission(kind: .automation, status: .notRequested),
            fullDiskAccess: fda,
            stateStore: InMemoryOnboardingStateStore()
        )

        await vm.refreshFullDiskAccessStatus()
        XCTAssertEqual(vm.fullDiskAccessStatus, .notRequested)

        await fda.setStatus(.requested)
        await vm.refreshFullDiskAccessStatus()
        XCTAssertEqual(vm.fullDiskAccessStatus, .requested)

        await fda.setStatus(.granted)
        await vm.refreshFullDiskAccessStatus()
        XCTAssertEqual(vm.fullDiskAccessStatus, .granted)
    }

    /// No FDA injected → snapshot no-ops rather than crashing.
    func testRefreshFullDiskAccessStatusWithNoInjectionNoOps() async {
        let vm = makeVM(sr: .granted, ax: .granted, am: .granted)
        await vm.refreshFullDiskAccessStatus()
        XCTAssertEqual(vm.fullDiskAccessStatus, .notRequested)
    }

    // MARK: - Helpers

    private func makeVM(
        sr: TCCStatus,
        ax: TCCStatus,
        am: TCCStatus
    ) -> OnboardingFlowViewModel {
        OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: sr),
            accessibility: StubTCCPermission(kind: .accessibility, status: ax),
            automation: StubTCCPermission(kind: .automation, status: am),
            fullDiskAccess: nil,
            stateStore: InMemoryOnboardingStateStore()
        )
    }
}
