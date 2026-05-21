// SPDX-License-Identifier: TBD-private
import XCTest
import Combine
@testable import HippocampusKit

// MARK: - Mock

final class MockUpdaterService: UpdaterService, @unchecked Sendable {
    private let stateSubject = CurrentValueSubject<UpdaterState, Never>(.idle)
    private(set) var checkForUpdatesCallCount = 0
    var _canCheckForUpdates = true
    var _automaticallyChecks = false

    var statePublisher: AnyPublisher<UpdaterState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    var canCheckForUpdates: Bool { _canCheckForUpdates }

    var automaticallyChecksForUpdates: Bool {
        get { _automaticallyChecks }
        set { _automaticallyChecks = newValue }
    }

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
        stateSubject.send(.checking)
    }

    func simulateAvailable(version: String) {
        stateSubject.send(.available(version: version))
    }

    func simulateIdle() {
        stateSubject.send(.idle)
    }

    func simulateError(_ msg: String) {
        stateSubject.send(.error(msg))
    }
}

// MARK: - Tests

@MainActor
final class UpdaterStateTests: XCTestCase {

    func test_initial_state_is_idle() {
        let mock = MockUpdaterService()
        var states: [UpdaterState] = []
        let cancellable = mock.statePublisher.sink { states.append($0) }

        XCTAssertEqual(states, [.idle])
        cancellable.cancel()
    }

    func test_check_transitions_to_checking() {
        let mock = MockUpdaterService()
        var states: [UpdaterState] = []
        let cancellable = mock.statePublisher.sink { states.append($0) }

        mock.checkForUpdates()

        XCTAssertEqual(states, [.idle, .checking])
        XCTAssertEqual(mock.checkForUpdatesCallCount, 1)
        cancellable.cancel()
    }

    func test_available_state_carries_version() {
        let mock = MockUpdaterService()
        var states: [UpdaterState] = []
        let cancellable = mock.statePublisher.sink { states.append($0) }

        mock.checkForUpdates()
        mock.simulateAvailable(version: "1.2.0")

        XCTAssertEqual(states.last, .available(version: "1.2.0"))
        cancellable.cancel()
    }

    func test_error_state() {
        let mock = MockUpdaterService()
        var states: [UpdaterState] = []
        let cancellable = mock.statePublisher.sink { states.append($0) }

        mock.simulateError("network unreachable")

        XCTAssertEqual(states.last, .error("network unreachable"))
        cancellable.cancel()
    }

    func test_auto_check_default_off() {
        let mock = MockUpdaterService()
        XCTAssertFalse(mock.automaticallyChecksForUpdates)
    }

    func test_auto_check_toggle() {
        let mock = MockUpdaterService()
        mock.automaticallyChecksForUpdates = true
        XCTAssertTrue(mock.automaticallyChecksForUpdates)
        mock.automaticallyChecksForUpdates = false
        XCTAssertFalse(mock.automaticallyChecksForUpdates)
    }

    func test_full_lifecycle_idle_checking_available_idle() {
        let mock = MockUpdaterService()
        var states: [UpdaterState] = []
        let cancellable = mock.statePublisher.sink { states.append($0) }

        mock.checkForUpdates()
        mock.simulateAvailable(version: "2.0.0")
        mock.simulateIdle()

        XCTAssertEqual(states, [
            .idle,
            .checking,
            .available(version: "2.0.0"),
            .idle,
        ])
        cancellable.cancel()
    }
}
