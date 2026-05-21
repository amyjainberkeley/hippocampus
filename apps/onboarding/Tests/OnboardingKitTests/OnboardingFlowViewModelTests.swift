import XCTest
@testable import OnboardingKit

@MainActor
final class OnboardingFlowViewModelTests: XCTestCase {

    private func makeVM() -> OnboardingFlowViewModel {
        OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording),
            accessibility: StubTCCPermission(kind: .accessibility),
            automation: StubTCCPermission(kind: .automation)
        )
    }

    func testInitialStepIsWelcome() {
        let vm = makeVM()
        XCTAssertEqual(vm.currentStep, .welcome)
    }

    func testAdvanceMovesToNextStep() {
        let vm = makeVM()
        vm.advance()
        XCTAssertEqual(vm.currentStep, .screenRecording)
        vm.advance()
        XCTAssertEqual(vm.currentStep, .accessibility)
        vm.advance()
        XCTAssertEqual(vm.currentStep, .automation)
        vm.advance()
        XCTAssertEqual(vm.currentStep, .browserExtension)
        vm.advance()
        XCTAssertEqual(vm.currentStep, .done)
    }

    func testAdvancePastDoneIsNoop() {
        let vm = makeVM()
        // Walk to done
        for _ in 0..<5 { vm.advance() }
        XCTAssertEqual(vm.currentStep, .done)
        vm.advance()
        XCTAssertEqual(vm.currentStep, .done)
    }

    func testBackMovesToPriorStep() {
        let vm = makeVM()
        vm.advance() // -> screenRecording
        vm.advance() // -> accessibility
        vm.back()
        XCTAssertEqual(vm.currentStep, .screenRecording)
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
        for _ in 0..<5 { vm.advance() }
        XCTAssertFalse(vm.canAdvance)
    }

    func testCanGoBackIsFalseAtWelcome() {
        let vm = makeVM()
        XCTAssertFalse(vm.canGoBack)
    }

    func testPermissionForCurrentStep() {
        let vm = makeVM()
        XCTAssertNil(vm.permissionForCurrentStep()) // welcome
        vm.advance()
        XCTAssertNotNil(vm.permissionForCurrentStep()) // screenRecording
    }

    func testTrustPanelInitiallyDismissed() {
        let vm = makeVM()
        XCTAssertFalse(vm.isTrustPanelPresented)
    }

    func testSixStepsExist() {
        XCTAssertEqual(OnboardingStep.allCases.count, 6)
    }

    func testStepLabelsAreNonEmpty() {
        for step in OnboardingStep.allCases {
            XCTAssertFalse(step.title.isEmpty)
            XCTAssertFalse(step.stepLabel.isEmpty)
        }
    }
}
