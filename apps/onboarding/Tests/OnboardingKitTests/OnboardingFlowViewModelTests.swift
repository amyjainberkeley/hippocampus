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
        let expected: [OnboardingStep] = [
            .welcome, .howItWorks, .trust, .permissions, .allowlist,
            .browserExtension, .livePreview, .retention,
            .prepareBrain, .connectClaudeCode, .done,
        ]
        for (i, step) in expected.enumerated() {
            XCTAssertEqual(vm.currentStep, step, "Step \(i)")
            if i < expected.count - 1 { vm.advance() }
        }
    }

    func testAdvancePastDoneIsNoop() {
        let vm = makeVM()
        for _ in 0..<10 { vm.advance() }
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
        for _ in 0..<10 { vm.advance() }
        XCTAssertFalse(vm.canAdvance)
    }

    func testCanGoBackIsFalseAtWelcome() {
        let vm = makeVM()
        XCTAssertFalse(vm.canGoBack)
    }

    func testStepCountMatchesOnboardingStepEnum() {
        XCTAssertEqual(OnboardingStep.allCases.count, 11)
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
        for _ in 0..<10 { vm.advance() }
        XCTAssertEqual(vm.progress, 1.0, accuracy: 0.001)
    }

    func testProgressAtMidpoint() {
        let vm = makeVM()
        vm.goTo(.browserExtension) // raw 5 out of allCases.count - 1 = 10
        XCTAssertEqual(vm.progress, 5.0 / 10.0, accuracy: 0.001)
    }
}
