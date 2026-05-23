import XCTest
@testable import OnboardingKit

@MainActor
final class OnboardingFlowViewModelTests: XCTestCase {

    private func makeVM() -> OnboardingFlowViewModel {
        OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted)
        )
    }

    func testInitialStepIsWelcome() {
        let vm = makeVM()
        XCTAssertEqual(vm.currentStep, .welcome)
    }

    func testAdvanceThroughAllSteps() {
        let vm = makeVM()
        let expected: [OnboardingStep] = [
            .welcome, .howItWorks, .trust, .permissions,
            .browserExtension, .livePreview, .retention,
            .prepareBrain, .done,
        ]
        for (i, step) in expected.enumerated() {
            XCTAssertEqual(vm.currentStep, step, "Step \(i)")
            if i < expected.count - 1 { vm.advance() }
        }
    }

    func testAdvancePastDoneIsNoop() {
        let vm = makeVM()
        for _ in 0..<8 { vm.advance() }
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
        for _ in 0..<8 { vm.advance() }
        XCTAssertFalse(vm.canAdvance)
    }

    func testCanGoBackIsFalseAtWelcome() {
        let vm = makeVM()
        XCTAssertFalse(vm.canGoBack)
    }

    func testNineStepsExist() {
        XCTAssertEqual(OnboardingStep.allCases.count, 9)
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
        for _ in 0..<8 { vm.advance() }
        XCTAssertEqual(vm.progress, 1.0, accuracy: 0.001)
    }

    func testProgressAtMidpoint() {
        let vm = makeVM()
        vm.goTo(.browserExtension) // step 4 of 0-8
        XCTAssertEqual(vm.progress, 4.0 / 8.0, accuracy: 0.001)
    }
}
