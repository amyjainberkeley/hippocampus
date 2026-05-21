// SPDX-License-Identifier: TBD-private
import XCTest
@testable import HippocampusKit

// MARK: - Stub

final class StubLoginItemService: LoginItemService, @unchecked Sendable {
    var currentStatus: LoginItemStatus = .notRegistered
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    var registerShouldThrow = false
    var unregisterShouldThrow = false

    func status() -> LoginItemStatus { currentStatus }

    func register() throws {
        registerCallCount += 1
        if registerShouldThrow { throw TestError.forced }
        currentStatus = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if unregisterShouldThrow { throw TestError.forced }
        currentStatus = .notRegistered
    }

    enum TestError: Error { case forced }
}

// MARK: - Tests

@MainActor
final class LoginItemViewModelTests: XCTestCase {

    func test_initial_state_not_registered() {
        let stub = StubLoginItemService()
        let vm = LoginItemViewModel(service: stub)
        XCTAssertFalse(vm.isEnabled)
    }

    func test_initial_state_enabled() {
        let stub = StubLoginItemService()
        stub.currentStatus = .enabled
        let vm = LoginItemViewModel(service: stub)
        XCTAssertTrue(vm.isEnabled)
    }

    func test_toggle_enables_when_disabled() {
        let stub = StubLoginItemService()
        let vm = LoginItemViewModel(service: stub)

        vm.toggle()

        XCTAssertTrue(vm.isEnabled)
        XCTAssertEqual(stub.registerCallCount, 1)
        XCTAssertEqual(stub.unregisterCallCount, 0)
    }

    func test_toggle_disables_when_enabled() {
        let stub = StubLoginItemService()
        stub.currentStatus = .enabled
        let vm = LoginItemViewModel(service: stub)

        vm.toggle()

        XCTAssertFalse(vm.isEnabled)
        XCTAssertEqual(stub.unregisterCallCount, 1)
    }

    func test_toggle_roundtrip() {
        let stub = StubLoginItemService()
        let vm = LoginItemViewModel(service: stub)

        vm.toggle()  // OFF → ON
        XCTAssertTrue(vm.isEnabled)

        vm.toggle()  // ON → OFF
        XCTAssertFalse(vm.isEnabled)
    }

    func test_register_failure_keeps_disabled() {
        let stub = StubLoginItemService()
        stub.registerShouldThrow = true
        let vm = LoginItemViewModel(service: stub)

        vm.toggle()

        XCTAssertFalse(vm.isEnabled)
        XCTAssertEqual(stub.registerCallCount, 1)
    }

    func test_unregister_failure_keeps_enabled() {
        let stub = StubLoginItemService()
        stub.currentStatus = .enabled
        stub.unregisterShouldThrow = true
        let vm = LoginItemViewModel(service: stub)

        vm.toggle()

        XCTAssertTrue(vm.isEnabled)
        XCTAssertEqual(stub.unregisterCallCount, 1)
    }

    func test_refresh_status_syncs() {
        let stub = StubLoginItemService()
        let vm = LoginItemViewModel(service: stub)
        XCTAssertFalse(vm.isEnabled)

        stub.currentStatus = .enabled
        vm.refreshStatus()
        XCTAssertTrue(vm.isEnabled)
    }

    func test_should_prompt_initially_true() {
        // Clear persisted state from prior test runs
        UserDefaults.standard.removeObject(forKey: "ai.hippocampus.loginItem.prompted")
        let stub = StubLoginItemService()
        let vm = LoginItemViewModel(service: stub)
        XCTAssertTrue(vm.shouldPrompt)
    }

    func test_mark_prompted_clears_prompt() {
        let stub = StubLoginItemService()
        let vm = LoginItemViewModel(service: stub)
        vm.markPrompted()
        XCTAssertFalse(vm.shouldPrompt)
    }

    func test_should_prompt_false_when_already_enabled() {
        let stub = StubLoginItemService()
        stub.currentStatus = .enabled
        let vm = LoginItemViewModel(service: stub)
        XCTAssertFalse(vm.shouldPrompt)
    }
}
