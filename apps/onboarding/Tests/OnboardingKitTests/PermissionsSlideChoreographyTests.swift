import XCTest
@testable import OnboardingKit

/// Cotypist peer-study P0 pattern #2 — deferred-permission choreography.
///
/// Kit-layer coverage for the sub-step sequencing exposed on the
/// `OnboardingFlowViewModel`. Slide rendering lives in the executable
/// target and is not exercised here; instead these tests assert the
/// underlying state that `PermissionsSlide` binds to:
///
///   - `permissionSequenceIndex` starts at 0 (or auto-advances past
///     already-granted / not-applicable surfaces at init).
///   - `currentPermissionSurface` returns the surface at `sequenceIndex`,
///     `nil` when the sequence is complete.
///   - `recordPermissionOutcome(_:_:)` writes the outcome and advances
///     the index past any non-pending following surfaces.
///   - `permissionChoreographyComplete` flips true when no surface is
///     still `.pending`.
///   - `markPermissionApplicable(_:)` un-skips a `.notApplicable` surface.
///   - `refreshPermissions()` auto-syncs `.pending → .granted` when the
///     underlying TCC probe transitions grant (out-of-band grant flow).
@MainActor
final class PermissionsSlideChoreographyTests: XCTestCase {

    private func makeVM(
        srStatus: TCCStatus = .notRequested,
        axStatus: TCCStatus = .notRequested,
        amStatus: TCCStatus = .notRequested
    ) -> OnboardingFlowViewModel {
        OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: srStatus),
            accessibility: StubTCCPermission(kind: .accessibility, status: axStatus),
            automation: StubTCCPermission(kind: .automation, status: amStatus),
            stateStore: InMemoryOnboardingStateStore()
        )
    }

    // MARK: - Initial state

    func testColdStartSequenceStartsAtScreenRecording() {
        let vm = makeVM()
        XCTAssertEqual(vm.permissionSequenceIndex, 0)
        XCTAssertEqual(vm.currentPermissionSurface, .screenRecording,
            "Cold-start choreography must open with Screen Recording (only required surface).")
    }

    func testColdStartAutomationAndFDAAreNotApplicable() {
        let vm = makeVM()
        XCTAssertEqual(vm.permissionResults[.automation], .notApplicable,
            "Automation is contextual — deferred to BrowserExtensionSlide by default.")
        XCTAssertEqual(vm.permissionResults[.fullDiskAccess], .notApplicable,
            "FDA is contextual — deferred to AllowlistSlide by default.")
    }

    func testInitWithAlreadyGrantedAdvancesPastThoseSurfaces() {
        let vm = makeVM(srStatus: .granted, axStatus: .granted)
        // Both required surfaces already granted, others notApplicable →
        // sequence should be at the end.
        XCTAssertEqual(vm.permissionResults[.screenRecording], .granted)
        XCTAssertEqual(vm.permissionResults[.accessibility], .granted)
        XCTAssertNil(vm.currentPermissionSurface,
            "Fully-granted init must land past the last sequence index.")
        XCTAssertTrue(vm.permissionChoreographyComplete)
    }

    func testInitWithDeniedSurfaceStillAdvancesPast() {
        // Denied is a terminal outcome — the slide will render its
        // recovery banner (SwiftUI-side), the sequence itself moves on.
        let vm = makeVM(srStatus: .denied, axStatus: .granted)
        XCTAssertEqual(vm.permissionResults[.screenRecording], .denied)
        XCTAssertTrue(vm.permissionChoreographyComplete)
    }

    // MARK: - Grant / deny / skip transitions

    func testGrantScreenRecordingAdvancesToAccessibility() {
        let vm = makeVM()
        vm.recordPermissionOutcome(.screenRecording, .granted)
        XCTAssertEqual(vm.currentPermissionSurface, .accessibility,
            "Recording SR outcome must move the pointer to AX (next pending surface).")
        XCTAssertEqual(vm.permissionResults[.screenRecording], .granted)
    }

    func testSkipAdvancesSequence() {
        let vm = makeVM()
        vm.recordPermissionOutcome(.screenRecording, .skipped)
        XCTAssertEqual(vm.permissionResults[.screenRecording], .skipped)
        XCTAssertEqual(vm.currentPermissionSurface, .accessibility,
            "Skip is a valid terminal outcome — sequence must not stall on it.")
    }

    func testDenyAdvancesSequence() {
        let vm = makeVM()
        vm.recordPermissionOutcome(.screenRecording, .denied)
        XCTAssertEqual(vm.permissionResults[.screenRecording], .denied)
        XCTAssertEqual(vm.currentPermissionSurface, .accessibility,
            "Denial is a terminal outcome from the choreography's POV — user has already seen the recovery banner and clicked Continue.")
    }

    func testFullChoreographyWalkAllGrants() {
        let vm = makeVM()
        // Mark Automation + FDA applicable so they participate.
        vm.markPermissionApplicable(.automation)
        vm.markPermissionApplicable(.fullDiskAccess)

        vm.recordPermissionOutcome(.screenRecording, .granted)
        XCTAssertEqual(vm.currentPermissionSurface, .accessibility)
        vm.recordPermissionOutcome(.accessibility, .granted)
        XCTAssertEqual(vm.currentPermissionSurface, .automation)
        vm.recordPermissionOutcome(.automation, .granted)
        XCTAssertEqual(vm.currentPermissionSurface, .fullDiskAccess)
        vm.recordPermissionOutcome(.fullDiskAccess, .granted)
        XCTAssertNil(vm.currentPermissionSurface,
            "After the last surface is resolved, the sequence must be complete.")
        XCTAssertTrue(vm.permissionChoreographyComplete)
    }

    func testMixedGrantAndSkip() {
        let vm = makeVM()
        vm.recordPermissionOutcome(.screenRecording, .granted)
        vm.recordPermissionOutcome(.accessibility, .skipped)
        XCTAssertTrue(vm.permissionChoreographyComplete,
            "Skipping soft-fail surfaces must complete the choreography.")
    }

    func testMixedGrantAndDeny() {
        let vm = makeVM()
        vm.recordPermissionOutcome(.screenRecording, .granted)
        vm.recordPermissionOutcome(.accessibility, .denied)
        XCTAssertEqual(vm.permissionResults[.accessibility], .denied)
        XCTAssertTrue(vm.permissionChoreographyComplete,
            "Denied AX is a soft-fail — user saw recovery banner + clicked Continue.")
    }

    // MARK: - Applicability toggle

    func testMarkApplicableFlipsFromNotApplicableToPending() {
        let vm = makeVM(srStatus: .granted, axStatus: .granted)
        XCTAssertTrue(vm.permissionChoreographyComplete)
        vm.markPermissionApplicable(.automation)
        XCTAssertEqual(vm.permissionResults[.automation], .pending,
            "markPermissionApplicable(.automation) must un-skip the surface.")
        XCTAssertFalse(vm.permissionChoreographyComplete,
            "A new pending surface must un-complete the choreography.")
    }

    func testMarkApplicableIsIdempotent() {
        let vm = makeVM()
        vm.markPermissionApplicable(.automation)
        vm.markPermissionApplicable(.automation)
        XCTAssertEqual(vm.permissionResults[.automation], .pending)
    }

    func testMarkApplicableDoesNotOverwriteResolvedOutcome() {
        let vm = makeVM()
        vm.recordPermissionOutcome(.screenRecording, .granted)
        vm.markPermissionApplicable(.screenRecording)
        XCTAssertEqual(vm.permissionResults[.screenRecording], .granted,
            "markPermissionApplicable must NOT clobber a resolved grant / deny / skip.")
    }

    // MARK: - Refresh auto-sync (out-of-band grant flow)

    func testRefreshPermissionsAutoSyncsGrantIntoChoreography() {
        let vm = makeVM(srStatus: .notRequested)
        XCTAssertEqual(vm.permissionResults[.screenRecording], .pending)
        // Simulate the user granting SR via System Settings while the
        // slide's poll timer is ticking.
        let sr = vm.screenRecordingPermission as! StubTCCPermission
        sr.simulateGrant()
        vm.refreshPermissions()
        XCTAssertEqual(vm.permissionResults[.screenRecording], .granted,
            "refreshPermissions() must sync the out-of-band grant into the choreography.")
        XCTAssertEqual(vm.currentPermissionSurface, .accessibility,
            "Auto-sync must also advance the sequence pointer.")
    }

    func testRefreshDoesNotClobberSkippedOutcome() {
        let vm = makeVM()
        vm.recordPermissionOutcome(.accessibility, .skipped)
        // User then grants AX via Settings — but the choreography has
        // already moved on; don't retroactively replay the sub-step.
        let ax = vm.accessibilityPermission as! StubTCCPermission
        ax.simulateGrant()
        vm.refreshPermissions()
        XCTAssertEqual(vm.permissionResults[.accessibility], .skipped,
            "refreshPermissions() must NOT overwrite an explicit .skipped outcome — the user already moved past this sub-step.")
    }

    func testRefreshDoesNotClobberDeniedOutcome() {
        let vm = makeVM()
        vm.recordPermissionOutcome(.accessibility, .denied)
        let ax = vm.accessibilityPermission as! StubTCCPermission
        ax.simulateGrant()
        vm.refreshPermissions()
        XCTAssertEqual(vm.permissionResults[.accessibility], .denied,
            "refreshPermissions() must NOT overwrite an explicit .denied outcome — the user already saw the banner and clicked Continue.")
    }

    // MARK: - Sequence order invariant

    func testPermissionSequenceIsRequiredFirst() {
        // Order is load-bearing — Screen Recording must come first (only
        // required surface); soft-fail surfaces trail.
        XCTAssertEqual(OnboardingFlowViewModel.permissionSequence,
                       [.screenRecording, .accessibility, .automation, .fullDiskAccess])
    }

    // MARK: - Idempotent past-end

    func testRecordingOutcomePastEndIsSafe() {
        let vm = makeVM(srStatus: .granted, axStatus: .granted)
        XCTAssertNil(vm.currentPermissionSurface)
        // Advancing past the end is a no-op — no crash, no wraparound.
        vm.advancePermissionSequence()
        XCTAssertNil(vm.currentPermissionSurface)
        XCTAssertEqual(vm.permissionSequenceIndex,
                       OnboardingFlowViewModel.permissionSequence.count)
    }

    // MARK: - canAdvance interplay

    func testCanAdvancePreservesSRRequirement() {
        let vm = makeVM(srStatus: .notRequested)
        vm.goTo(.permissions)
        XCTAssertFalse(vm.canAdvance,
            "canAdvance must still gate on SR granted (PR #44 invariant).")
        vm.recordPermissionOutcome(.screenRecording, .skipped)
        XCTAssertFalse(vm.canAdvance,
            "Skipping SR is not enough — SR is the only hard-required surface.")
    }

    func testCanAdvanceAllowsPartialChoreographyWhenSRGranted() {
        // Cotypist "skip and re-enable later" — a user with SR granted
        // but AX still pending can exit via the nav bar. The slide
        // choreography drives them through AX first; the flow VM only
        // enforces the SR invariant.
        let vm = makeVM(srStatus: .granted, axStatus: .notRequested)
        vm.goTo(.permissions)
        XCTAssertTrue(vm.canAdvance,
            "SR granted must unblock advance regardless of AX outcome (soft-fail).")
    }
}
