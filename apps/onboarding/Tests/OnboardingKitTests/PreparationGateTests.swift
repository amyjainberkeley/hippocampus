import XCTest
@testable import OnboardingKit

@MainActor
final class PreparationGateTests: XCTestCase {
    func testFailedKeyPreparationCannotContinueButRetryCanRecover() async {
        let keys = RecoverableKeyGenerator()
        let model = PrepareBrainViewModel(keyGenerator: keys, modelDownloader: StubModelDownloader())
        XCTAssertFalse(model.canContinue)
        XCTAssertFalse(model.keyFailed)
        await model.generateKey()
        guard case .failed = model.keyState else { return XCTFail("Expected key failure") }
        XCTAssertFalse(model.canContinue)
        XCTAssertTrue(model.keyFailed, "Promise shows the failure and Try Again")
        await keys.allowGeneration()
        await model.generateKey()
        XCTAssertTrue(model.canContinue)
        XCTAssertFalse(model.keyFailed)
    }

    func testStartRememberingSaysWhileTheKeyIsBeingSetUp() {
        XCTAssertEqual(OnboardingCopy.promisePrimary(isReview: false, keyState: .checking), "Setting up encryption…")
        XCTAssertEqual(OnboardingCopy.promisePrimary(isReview: false, keyState: .generating), "Setting up encryption…")
        XCTAssertEqual(OnboardingCopy.promisePrimary(isReview: false, keyState: .ready), "Start Remembering")
        XCTAssertEqual(OnboardingCopy.promisePrimary(isReview: false, keyState: .failed("x")), "Start Remembering")
        XCTAssertEqual(OnboardingCopy.promisePrimary(isReview: true, keyState: .checking), "Continue",
                       "in review the button only continues")
    }

    func testStartRememberingWaitsForTheKeyAndBothPermissions() throws {
        let sources = onboardingPackageRoot.appendingPathComponent("Sources/Onboarding")
        let flow = try String(contentsOf: sources.appendingPathComponent("OnboardingFlowView.swift"), encoding: .utf8)
        XCTAssertTrue(flow.contains("await flowVM.startRemembering(keyReady: prepareBrainVM.canContinue)"))
        XCTAssertTrue(flow.contains(
            "prepareBrainVM.canContinue && flowVM.bothGranted && !flowVM.isStartingRemembering"
        ))
        XCTAssertTrue(flow.contains("case .promise: flowVM.isReview ? flowVM.canAdvance : canStart"))
        let bar = try String(
            contentsOf: sources.appendingPathComponent("SharedComponents/OnboardingWindow.swift"), encoding: .utf8
        )
        XCTAssertTrue(bar.contains(".disabled(!primaryEnabled)"))
        // Setup can resume at Promise without passing Permissions.
        let promise = try String(contentsOf: sources.appendingPathComponent("Slides/PromiseSlide.swift"), encoding: .utf8)
        XCTAssertTrue(promise.contains(".task {\n            await prepareBrainVM.generateKey()\n        }"))
    }
}

private actor RecoverableKeyGenerator: KeyGenerator {
    private var allowed = false
    private var exists = false
    func allowGeneration() { allowed = true }
    func keyExists() -> Bool { exists }
    func generateKey() throws {
        guard allowed else { throw CocoaError(.fileWriteNoPermission) }
        exists = true
    }
}
