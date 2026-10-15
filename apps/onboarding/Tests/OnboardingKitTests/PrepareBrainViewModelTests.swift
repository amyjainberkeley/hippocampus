import Combine
import XCTest
@testable import OnboardingKit

@MainActor
final class PrepareBrainViewModelTests: XCTestCase {

    private func makeVM(keyExists: Bool = false) -> PrepareBrainViewModel {
        PrepareBrainViewModel(keyGenerator: StubKeyGenerator(exists: keyExists))
    }

    func testInitialState() {
        let vm = makeVM()
        XCTAssertEqual(vm.keyState, .checking)
        XCTAssertFalse(vm.canContinue)
    }

    func testGenerateKeyWhenNoneExists() async {
        let vm = makeVM(keyExists: false)
        await vm.generateKey()
        XCTAssertEqual(vm.keyState, .ready)
        XCTAssertTrue(vm.canContinue)
    }

    func testGenerateKeyWhenAlreadyExists() async {
        let vm = makeVM(keyExists: true)
        await vm.generateKey()
        XCTAssertEqual(vm.keyState, .ready)
    }

    func testAReadyKeyReturnsAtOnceAndNeverGoesBackToSettingUp() async {
        let keys = CountingKeyGenerator()
        let vm = PrepareBrainViewModel(keyGenerator: keys)
        await vm.generateKey()
        XCTAssertEqual(vm.keyState, .ready)
        var states: [PrepareBrainViewModel.KeyState] = []
        let watch = vm.$keyState.sink { states.append($0) }
        await vm.generateKey()
        await vm.generateKey()
        watch.cancel()
        XCTAssertEqual(states, [.ready], "Back then Continue never turns Start Remembering off")
        let checks = await keys.existenceChecks
        XCTAssertEqual(checks, 1)
    }

    func testKeySetupDoesNotWaitBeforeItStarts() async {
        let vm = makeVM(keyExists: true)
        let started = Date()
        await vm.generateKey()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.4)
        XCTAssertTrue(vm.canContinue)
    }
}

/// Counts how often key setup looks for an existing key.
actor CountingKeyGenerator: KeyGenerator {
    private(set) var existenceChecks = 0
    private var exists = false

    func keyExists() -> Bool {
        existenceChecks += 1
        return exists
    }

    func generateKey() {
        exists = true
    }
}
