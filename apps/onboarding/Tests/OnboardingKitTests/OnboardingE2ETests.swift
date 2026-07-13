import XCTest
@testable import OnboardingKit

/// End-to-end integration tests for the first-run onboarding flow.
///
/// Unit tests cover each view-model + store in isolation; this suite
/// stitches them together and drives the whole `OnboardingFlowViewModel`
/// state machine from `.welcome` all the way to `.done`, using the
/// existing test doubles (`StubTCCPermission`, `StubBrowserDetector`,
/// `StubFullDiskAccessPermission`, `InMemoryOnboardingStateStore`).
///
/// Kit-layer scope: banner *rendering* lives in the `Onboarding`
/// SwiftUI target and is not exercised here. Instead, we assert the
/// underlying state that drives banner visibility (permission `.denied`
/// + `canAdvance == false` at Permissions, `probeAutomation()` reflecting
/// `.denied` after the browser-extension probe, etc.).
///
/// Actual step order (per `OnboardingStep.swift`, 12 cases):
///   welcome → howItWorks → trust → permissions → allowlist →
///   browserExtension → livePreview → retention → prepareBrain →
///   connectClaudeCode → mcpServers → done
@MainActor
final class OnboardingE2ETests: XCTestCase {

    /// The canonical step sequence, single source of truth for the whole
    /// suite. Kept in sync with `OnboardingStep.allCases` — the
    /// step-count assertion at the bottom fails loudly if a future PR
    /// inserts a step without updating the e2e walk.
    private static let allSteps: [OnboardingStep] = [
        .welcome, .howItWorks, .trust, .permissions, .allowlist,
        .browserExtension, .livePreview, .retention, .prepareBrain,
        .connectClaudeCode, .mcpServers, .done,
    ]

    // MARK: - Test 1: Happy path

    /// Walk every step, front to back, with every TCC granted and a
    /// two-browser detector fixture. Assert that:
    ///   - `canAdvance` is true at every non-`.done` step,
    ///   - `advance()` moves to the expected next step,
    ///   - the state store receives each step as we go (resume-safety),
    ///   - Automation `probeAutomation()` returns `.granted` at the
    ///     browser-extension step (drives the "no banner" UI path).
    func testHappyPathWalkFromWelcomeToDone() {
        let store = InMemoryOnboardingStateStore()
        let sr = StubTCCPermission(kind: .screenRecording, status: .granted)
        let ax = StubTCCPermission(kind: .accessibility, status: .granted)
        let am = StubTCCPermission(kind: .automation, status: .granted)
        let vm = OnboardingFlowViewModel(
            screenRecording: sr,
            accessibility: ax,
            automation: am,
            stateStore: store
        )

        for (idx, expected) in Self.allSteps.enumerated() {
            XCTAssertEqual(vm.currentStep, expected, "Step \(idx)")
            if expected == .done {
                XCTAssertFalse(vm.canAdvance, "canAdvance must be false at .done")
            } else {
                XCTAssertTrue(vm.canAdvance, "canAdvance must be true at \(expected)")
                vm.advance()
                XCTAssertEqual(store.load(), Self.allSteps[idx + 1],
                    "State store must persist \(Self.allSteps[idx + 1]) after advance")
            }
            if expected == .browserExtension {
                XCTAssertEqual(vm.probeAutomation(), .granted,
                    "Automation grant should surface at browser-extension step")
            }
        }
        XCTAssertEqual(vm.currentStep, .done)
    }

    // MARK: - Test 2: Screen-Recording denied path

    /// User grants Accessibility but denies Screen Recording. Assert the
    /// flow blocks at `.permissions` (canAdvance == false, advance() is
    /// a no-op) and that flipping SR to granted then advancing to
    /// `.allowlist` recovers — the same state that drives the SwiftUI
    /// denial-recovery banner + Reset-&-Retry affordance (cycle 8.39 PR #44).
    func testScreenRecordingDeniedBlocksAtPermissions() async {
        let sr = StubTCCPermission(kind: .screenRecording, status: .denied)
        let ax = StubTCCPermission(kind: .accessibility, status: .granted)
        let vm = OnboardingFlowViewModel(
            screenRecording: sr,
            accessibility: ax,
            stateStore: InMemoryOnboardingStateStore()
        )

        // Walk welcome → howItWorks → trust → permissions.
        vm.advance() // howItWorks
        vm.advance() // trust
        vm.advance() // permissions
        XCTAssertEqual(vm.currentStep, .permissions)
        XCTAssertFalse(vm.canAdvance,
            "SR denied must block advance (drives denial banner UI)")

        // No-op advance while denied.
        vm.advance()
        XCTAssertEqual(vm.currentStep, .permissions)

        // Reset & Retry succeeds -> banner clears -> flow advances.
        sr.resetShouldSucceed = true
        _ = await sr.resetAndRetry()
        vm.refreshPermissions()
        XCTAssertTrue(vm.canAdvance,
            "After reset-and-retry grants SR, advance must unblock")
        vm.advance()
        XCTAssertEqual(vm.currentStep, .allowlist)
    }

    // MARK: - Test 3: Resume-across-quit path

    /// User reaches `.permissions`, quits (app process ends), re-launches.
    /// A fresh VM constructed with the same store must load the resume
    /// step so the user does NOT re-walk Welcome → Trust.
    func testResumeAcrossQuitStartsAtPersistedStep() {
        let store = InMemoryOnboardingStateStore()

        // First session: walk to permissions.
        do {
            let vm = OnboardingFlowViewModel(
                screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
                accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
                stateStore: store
            )
            vm.advance() // howItWorks
            vm.advance() // trust
            vm.advance() // permissions
            XCTAssertEqual(vm.currentStep, .permissions)
            XCTAssertEqual(store.load(), .permissions)
        } // VM goes out of scope — simulate quit.

        // Second session: new VM instance, same store → resume.
        let resumed = OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
            stateStore: store
        )
        XCTAssertEqual(resumed.currentStep, .permissions,
            "Re-launch must resume at the persisted step, not .welcome")
    }

    // MARK: - Test 4: Rewind-migrator path

    /// A flow initialized with `migrationSource: .rewind` (cycle 8.39
    /// PR #42) must surface that source to the WelcomeSlide (drives the
    /// migrator sub-header) but otherwise walk the identical step
    /// sequence — no extra step, no reorder.
    func testRewindMigratorPathIsIdenticalExceptForMigrationSource() {
        let vm = OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
            stateStore: InMemoryOnboardingStateStore(),
            migrationSource: .rewind
        )
        XCTAssertEqual(vm.migrationSource, .rewind,
            "Rewind migrator source must be readable at .welcome so the slide sub-header renders")

        // Walk the whole flow; step sequence must be byte-identical to
        // the cold-start happy path.
        for (idx, expected) in Self.allSteps.enumerated() {
            XCTAssertEqual(vm.currentStep, expected, "Step \(idx)")
            if expected != .done { vm.advance() }
        }
        XCTAssertEqual(vm.currentStep, .done)
        XCTAssertEqual(vm.migrationSource, .rewind,
            "Migration source must persist across the full walk (not cleared mid-flow)")
    }

    // MARK: - Test 5: Automation-denial recovery

    /// At the browser-extension step, the user denies the Automation
    /// TCC prompt fired by the Safari-install ⌘, keystroke. Assert that
    /// `probeAutomation()` returns `.denied` (drives the inline
    /// denial-recovery banner + "Reset & Retry" affordance, PR #44 wiring)
    /// AND that automation denial does NOT block advancing past the
    /// browser-extension step — the extension install is a soft-fail.
    func testAutomationDeniedAtBrowserExtensionSurfacesDenialAndDoesNotBlock() async {
        let am = StubTCCPermission(kind: .automation, status: .notRequested)
        let vm = OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
            automation: am,
            stateStore: InMemoryOnboardingStateStore()
        )

        vm.goTo(.browserExtension)
        XCTAssertEqual(vm.probeAutomation(), .notRequested)

        // User clicks Safari install → OS prompt fires → user denies.
        am.simulateDeny()
        XCTAssertEqual(vm.probeAutomation(), .denied,
            "Denied automation must surface (drives banner)")
        XCTAssertTrue(vm.canAdvance,
            "Automation denial is a soft-fail at browser-extension; must not block")

        // "Reset & Retry" affordance -> user re-grants via reset flow.
        am.resetShouldSucceed = true
        let ok = await am.resetAndRetry()
        XCTAssertTrue(ok)
        XCTAssertEqual(am.status, .granted)
        XCTAssertEqual(vm.probeAutomation(), .granted,
            "After reset-and-retry, banner-driving status clears")
    }

    // MARK: - Test 6: Empty-allowlist path (skip Messages/Mail deep-hooks)

    /// User opts to skip Messages/Mail on the allowlist slide (no FDA
    /// prompt fires). Assert that PrepareBrain remains reachable, the
    /// flow completes to `.done`, and calling `clearResumeState()` at
    /// the end scrubs the resume file (so a future launch starts at
    /// `.welcome` if the sentinel is also cleared).
    func testEmptyAllowlistPathReachesPrepareBrainAndDone() async {
        // FDA permission is available on the VM but the user never
        // trips it because they skip all deep-hooks.
        let fda = StubFullDiskAccessPermission(initial: .notRequested)
        let store = InMemoryOnboardingStateStore()
        let vm = OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
            automation: StubTCCPermission(kind: .automation, status: .granted),
            fullDiskAccess: fda,
            stateStore: store
        )

        // Walk to allowlist, "skip" (no state change), continue.
        vm.goTo(.allowlist)
        await vm.refreshFullDiskAccessStatus()
        XCTAssertEqual(vm.fullDiskAccessStatus, .notRequested,
            "Skipping Messages/Mail must NOT auto-fire the FDA prompt")

        // Advance through browserExtension, livePreview, retention → prepareBrain.
        vm.advance() // browserExtension
        vm.advance() // livePreview
        vm.advance() // retention
        vm.advance() // prepareBrain
        XCTAssertEqual(vm.currentStep, .prepareBrain,
            "PrepareBrain must be reachable even with an empty allowlist")

        // Advance to done.
        vm.advance() // connectClaudeCode
        vm.advance() // mcpServers
        vm.advance() // done
        XCTAssertEqual(vm.currentStep, .done)
        XCTAssertFalse(vm.canAdvance, "canAdvance must be false at .done (exit-only)")

        // Final "Get Started" tap clears the resume hint.
        vm.clearResumeState()
        XCTAssertNil(store.load(),
            "clearResumeState() must scrub the persisted step on finish")
    }

    // MARK: - Invariant guard

    /// If a future PR inserts a step without updating this suite's walk
    /// fixture, the happy-path test would still pass (it iterates
    /// `Self.allSteps`) — this guard fails loudly instead.
    func testAllStepsFixtureMatchesEnum() {
        XCTAssertEqual(Self.allSteps.count, OnboardingStep.allCases.count,
            "OnboardingE2ETests.allSteps drifted from OnboardingStep.allCases — update the fixture.")
        XCTAssertEqual(Self.allSteps, OnboardingStep.allCases,
            "OnboardingE2ETests.allSteps order drifted from OnboardingStep.allCases — update the fixture.")
    }
}
