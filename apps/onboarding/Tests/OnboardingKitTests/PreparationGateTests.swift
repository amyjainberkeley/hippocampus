import XCTest
@testable import OnboardingKit

@MainActor
final class PreparationGateTests: XCTestCase {
    func testFailedKeyPreparationCannotContinueButRetryCanRecover() async {
        let keys = RecoverableKeyGenerator()
        let model = PrepareBrainViewModel(keyGenerator: keys, modelDownloader: StubModelDownloader())
        XCTAssertFalse(model.canContinue)
        await model.generateKey()
        guard case .failed = model.keyState else { return XCTFail("Expected key failure") }
        XCTAssertFalse(model.canContinue)
        await keys.allowGeneration()
        await model.generateKey()
        XCTAssertTrue(model.canContinue)
    }

    func testDoneAndNavigationUseRealPreparationAndPermissionState() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let flow = try String(contentsOf: root.appendingPathComponent("Sources/Onboarding/OnboardingFlowView.swift"), encoding: .utf8)
        let done = try String(contentsOf: root.appendingPathComponent("Sources/Onboarding/Slides/DoneSlide.swift"), encoding: .utf8)
        XCTAssertTrue(flow.contains("prepareBrainVM.canContinue"))
        XCTAssertTrue(flow.contains("guard canFinish"))
        XCTAssertTrue(flow.contains(".disabled(!canFinish)"))
        XCTAssertTrue(done.contains("granted: prepareBrainVM.canContinue"))
        XCTAssertFalse(done.contains("checkRow(granted: true, label: \"Encrypted\")"))
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
