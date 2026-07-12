import XCTest
@testable import OnboardingKit

@MainActor
final class OnboardingFlowViewModelTests: XCTestCase {

    private func makeVM() -> OnboardingFlowViewModel {
        // Hermetic: use the in-memory store so tests don't read/write
        // the real `~/Library/Application Support/MCI/.onboarding-state`
        // file (which would leak state between parallel test runs and
        // between this suite and a developer's actual machine).
        OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
            stateStore: InMemoryOnboardingStateStore()
        )
    }

    func testInitialStepIsWelcome() {
        let vm = makeVM()
        XCTAssertEqual(vm.currentStep, .welcome)
    }

    func testAdvanceThroughAllSteps() {
        let vm = makeVM()
        // V2-MCP-2 inserted `.mcpServers` between `.connectClaudeCode`
        // and `.done`; the step count is now 12.
        let expected: [OnboardingStep] = [
            .welcome, .howItWorks, .trust, .permissions, .allowlist,
            .browserExtension, .livePreview, .retention,
            .prepareBrain, .connectClaudeCode, .mcpServers, .done,
        ]
        for (i, step) in expected.enumerated() {
            XCTAssertEqual(vm.currentStep, step, "Step \(i)")
            if i < expected.count - 1 { vm.advance() }
        }
    }

    func testAdvancePastDoneIsNoop() {
        let vm = makeVM()
        // 12 steps total ⇒ advance 11 times reaches `.done`.
        for _ in 0..<11 { vm.advance() }
        XCTAssertEqual(vm.currentStep, .done)
        vm.advance()
        XCTAssertEqual(vm.currentStep, .done)
    }

    func testBackMovesToPriorStep() {
        let vm = makeVM()
        vm.advance() // howItWorks
        vm.advance() // trust
        vm.back()
        XCTAssertEqual(vm.currentStep, .howItWorks)
    }

    func testBackFromWelcomeIsNoop() {
        let vm = makeVM()
        vm.back()
        XCTAssertEqual(vm.currentStep, .welcome)
    }

    func testGoToJumpsDirectly() {
        let vm = makeVM()
        vm.goTo(.done)
        XCTAssertEqual(vm.currentStep, .done)
    }

    func testCanAdvanceIsFalseAtDone() {
        let vm = makeVM()
        for _ in 0..<11 { vm.advance() }
        XCTAssertFalse(vm.canAdvance)
    }

    func testCanGoBackIsFalseAtWelcome() {
        let vm = makeVM()
        XCTAssertFalse(vm.canGoBack)
    }

    func testStepCountMatchesOnboardingStepEnum() {
        // V2-MCP-2 added `.mcpServers` ⇒ 12 cases.
        XCTAssertEqual(OnboardingStep.allCases.count, 12)
    }

    func testStepLabelsAreNonEmpty() {
        for step in OnboardingStep.allCases {
            XCTAssertFalse(step.title.isEmpty)
            XCTAssertFalse(step.stepLabel.isEmpty)
        }
    }

    func testProgressAtWelcomeIsZero() {
        let vm = makeVM()
        XCTAssertEqual(vm.progress, 0, accuracy: 0.001)
    }

    func testProgressAtDoneIsOne() {
        let vm = makeVM()
        for _ in 0..<11 { vm.advance() }
        XCTAssertEqual(vm.progress, 1.0, accuracy: 0.001)
    }

    func testProgressAtMidpoint() {
        let vm = makeVM()
        vm.goTo(.browserExtension) // raw 5 out of allCases.count - 1 = 11
        XCTAssertEqual(vm.progress, 5.0 / 11.0, accuracy: 0.001)
    }

    // MARK: - Migration source (cycle 8.38 audit F4 / PR-2)

    func testMigrationSourceDefaultsToNil() {
        let vm = makeVM()
        XCTAssertNil(vm.migrationSource,
            "Cold-start install must not surface migration-specific copy.")
    }

    func testApplyLaunchURLWithRewindMigration() {
        let vm = makeVM()
        let ok = vm.applyLaunchURL(URL(string: "onboarding://start?migration=rewind")!)
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.migrationSource, .rewind)
    }

    func testApplyLaunchURLWithUnknownMigrationIsIgnored() {
        let vm = makeVM()
        let ok = vm.applyLaunchURL(URL(string: "onboarding://start?migration=notion")!)
        XCTAssertFalse(ok)
        XCTAssertNil(vm.migrationSource,
            "Stale/unknown migration deep-links must not surprise a non-migrator user.")
    }

    func testApplyLaunchURLWithoutMigrationQueryIsIgnored() {
        let vm = makeVM()
        let ok = vm.applyLaunchURL(URL(string: "onboarding://start")!)
        XCTAssertFalse(ok)
        XCTAssertNil(vm.migrationSource)
    }

    func testMigrationSourceInjectableViaInit() {
        // Test-side injection path — bypasses the URL parse so a slide
        // test can hold a "user came from Rewind" fixture directly.
        let vm = OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
            stateStore: InMemoryOnboardingStateStore(),
            migrationSource: .rewind
        )
        XCTAssertEqual(vm.migrationSource, .rewind)
    }
}
