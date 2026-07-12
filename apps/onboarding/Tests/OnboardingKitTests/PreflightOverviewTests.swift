import XCTest
@testable import OnboardingKit

/// Tests for the newly-wired Automation TCC permission on
/// `OnboardingFlowViewModel` + the FDA snapshot that backs the
/// `TCCPreflightOverview` SwiftUI view (audit gap G1).
///
/// The SwiftUI view lives in the `Onboarding` executable target and is
/// exercised via manual QA (no snapshot harness in-toolchain). What we
/// CAN test hermetically is that the VM exposes all four TCC surfaces
/// so the view can render them upfront — i.e. no surface is silently
/// pending / hidden behind a later slide.
@MainActor
final class PreflightOverviewTests: XCTestCase {

    // MARK: - The 4-surface invariant

    /// Audit gap G1: all 4 TCC surfaces must be reachable from the
    /// flow VM so the pre-flight can render them upfront (Screen
    /// Recording, Accessibility, Automation, FDA). If a future
    /// refactor drops a surface, this fails loudly.
    func testAllFourTCCSurfacesAreReachableFromFlowVM() {
        let vm = makeVM(sr: .notRequested, ax: .notRequested, am: .notRequested)
        XCTAssertEqual(vm.screenRecordingPermission.kind, .screenRecording)
        XCTAssertEqual(vm.accessibilityPermission.kind, .accessibility)
        XCTAssertEqual(vm.automationPermission.kind, .automation)
        // FDA is not a TCCPermission (different actor-based protocol)
        // but its status is exposed as a @Published on the VM.
        XCTAssertEqual(vm.fullDiskAccessStatus, .notRequested)
    }

    /// Fresh install: every surface reads `.notRequested`.
    func testFreshInstallShowsAllSurfacesNotRequested() {
        let vm = makeVM(sr: .notRequested, ax: .notRequested, am: .notRequested)
        XCTAssertEqual(vm.screenRecordingPermission.status, .notRequested)
        XCTAssertEqual(vm.accessibilityPermission.status, .notRequested)
        XCTAssertEqual(vm.automationPermission.status, .notRequested)
        XCTAssertEqual(vm.fullDiskAccessStatus, .notRequested)
    }

    // MARK: - Row updates when one grant lands

    /// When Screen Recording lands `.granted`, only that surface flips;
    /// the other 3 stay `.notRequested`. Guards against a partial grant
    /// being masked by stale state.
    func testGrantOfScreenRecordingUpdatesOnlyThatSurface() {
        let vm = makeVM(sr: .notRequested, ax: .notRequested, am: .notRequested)
        let sr = vm.screenRecordingPermission as! StubTCCPermission

        sr.simulateGrant()
        vm.refreshPermissions()

        XCTAssertEqual(vm.screenRecordingPermission.status, .granted)
        XCTAssertEqual(vm.accessibilityPermission.status, .notRequested)
        XCTAssertEqual(vm.automationPermission.status, .notRequested)
    }

    /// Same isolation for Accessibility.
    func testGrantOfAccessibilityUpdatesOnlyThatSurface() {
        let vm = makeVM(sr: .notRequested, ax: .notRequested, am: .notRequested)
        let ax = vm.accessibilityPermission as! StubTCCPermission

        ax.simulateGrant()
        vm.refreshPermissions()

        XCTAssertEqual(vm.screenRecordingPermission.status, .notRequested)
        XCTAssertEqual(vm.accessibilityPermission.status, .granted)
    }

    // MARK: - Automation surface is not silently pending

    /// Audit gap G1 root cause: `RealAutomationPermission` existed but
    /// no slide surfaced it. This guards that `automationPermission`
    /// is now a real, non-nil TCCPermission that reports status —
    /// i.e. the surface is wired in, not silently pending.
    func testAutomationPermissionIsSurfaced() {
        let vm = makeVM(sr: .notRequested, ax: .notRequested, am: .notRequested)
        XCTAssertEqual(vm.automationPermission.kind, .automation)
        XCTAssertEqual(vm.automationPermission.status, .notRequested)
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
    /// @Published so the pre-flight overview can pill without awaiting.
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
