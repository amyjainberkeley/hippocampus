import XCTest
@testable import HippocampusKit

@MainActor
final class ProcessSupervisorRecoveryTests: XCTestCase {
    func test_rapid_crashes_exhaust_ten_attempts_and_publish_visible_reason() async throws {
        let fixture = RecoveryFixture()
        try await fixture.supervisor.startAndWaitForReadiness()
        for _ in 0..<10 { try await fixture.crashAndRestart() }
        XCTAssertEqual(fixture.clock.delays, [1, 2, 4, 8, 16, 32, 60, 60, 60, 60])

        fixture.crash()
        try await eventually { fixture.exhausted }
        XCTAssertEqual(fixture.topology.launchPlans.count, 11)
        XCTAssertEqual(fixture.clock.delays.count, 10)
        guard case .error(let reason) = fixture.supervisor.menuBarStatus else {
            return XCTFail("Exhaustion must remain visible in the existing error surface")
        }
        XCTAssertTrue(reason.contains("10 restart attempts"))
        try await fixture.supervisor.shutdownAndWait()
    }

    func test_stable_95_minute_and_two_hour_generations_replenish_exhausted_budget() async throws {
        let fixture = RecoveryFixture()
        try await fixture.supervisor.startAndWaitForReadiness()
        for _ in 0..<10 { try await fixture.crashAndRestart() }

        for duration in [Duration.seconds(95 * 60), .seconds(2 * 60 * 60)] {
            fixture.clock.advance(duration)
            try await fixture.crashAndRestart()
            XCTAssertEqual(fixture.clock.delays.last, 1, "A stable committed run replenishes the backoff budget")
        }
        XCTAssertEqual(fixture.topology.launchPlans.count, 13)
        XCTAssertEqual(fixture.supervisor.state, .running)
        XCTAssertEqual(fixture.config.captureWrites, [], "Recovery must not change capture permission")
        XCTAssertTrue(fixture.topology.launchPlans.allSatisfy { $0.helperArguments.contains("--parent-lease-stdin") })
        try await fixture.supervisor.shutdownAndWait()
    }

    func test_replenishment_requires_five_minutes_since_readiness_commit() async throws {
        let fixture = RecoveryFixture()
        try await fixture.supervisor.startAndWaitForReadiness()
        try await fixture.crashAndRestart()
        fixture.clock.advance(.seconds(299))
        try await fixture.crashAndRestart()
        XCTAssertEqual(fixture.clock.delays.last, 2)
        fixture.clock.advance(.seconds(300))
        try await fixture.crashAndRestart()
        XCTAssertEqual(fixture.clock.delays.last, 1)
        try await fixture.supervisor.shutdownAndWait()
    }

    func test_backoff_and_slow_readiness_do_not_count_as_stable_running_time() async throws {
        let fixture = RecoveryFixture()
        try await fixture.supervisor.startAndWaitForReadiness()
        fixture.crash()
        try await eventually { fixture.clock.isSleeping }
        fixture.clock.advance(.seconds(7200))
        fixture.topology.onReadinessWait = { _ in fixture.clock.advance(.seconds(7200)) }
        fixture.clock.resume()
        try await eventually { fixture.supervisor.state == .running }
        fixture.topology.onReadinessWait = nil
        try await fixture.crashAndRestart()
        XCTAssertEqual(fixture.clock.delays, [1, 2], "Only time after readiness and commit counts")
        try await fixture.supervisor.shutdownAndWait()
    }

    func test_long_failed_startups_still_exhaust_the_bounded_budget() async throws {
        let fixture = RecoveryFixture()
        try await fixture.supervisor.startAndWaitForReadiness()
        fixture.topology.readinessResults = Array(repeating: .failure(SupervisorProcessRuntimeError.readinessTimedOut), count: 10)
        fixture.topology.onReadinessWait = { _ in fixture.clock.advance(.seconds(7200)) }
        fixture.crash()
        for attempt in 1...10 {
            try await eventually { fixture.clock.delays.count == attempt && fixture.clock.isSleeping }
            fixture.clock.resume()
        }
        try await eventually { fixture.exhausted }
        XCTAssertEqual(fixture.topology.launchPlans.count, 11)
        XCTAssertFalse(fixture.topology.isRunning)
        XCTAssertEqual(fixture.clock.delays, [1, 2, 4, 8, 16, 32, 60, 60, 60, 60])
        fixture.topology.onReadinessWait = nil
        try await fixture.supervisor.shutdownAndWait()
    }

    func test_retired_generation_exit_cannot_replenish_new_generation_budget() async throws {
        let fixture = RecoveryFixture()
        try await fixture.supervisor.startAndWaitForReadiness()
        fixture.clock.advance(.seconds(7200))
        try await fixture.crashAndRestart()
        fixture.topology.fireUnexpectedExit(forLaunchAt: 0)
        XCTAssertEqual(fixture.supervisor.state, .running)
        try await fixture.crashAndRestart()
        XCTAssertEqual(fixture.clock.delays, [1, 2])
        try await fixture.supervisor.shutdownAndWait()
    }

    func test_paused_time_cannot_replenish_a_new_child_run() async throws {
        let fixture = RecoveryFixture()
        try await fixture.supervisor.startAndWaitForReadiness()
        try await fixture.crashAndRestart()
        try await fixture.supervisor.setPausedAndWait(true)
        fixture.clock.advance(.seconds(7200))
        fixture.topology.fireUnexpectedExit(forLaunchAt: 1)
        XCTAssertEqual(fixture.supervisor.state, .paused)
        try await fixture.supervisor.setPausedAndWait(false)
        try await fixture.crashAndRestart()
        XCTAssertEqual(fixture.clock.delays, [1, 2])
        try await fixture.supervisor.shutdownAndWait()
    }

    func test_explicit_helper_stop_after_stable_run_never_restarts() async throws {
        let fixture = RecoveryFixture()
        try await fixture.supervisor.startAndWaitForReadiness()
        try await fixture.crashAndRestart()
        fixture.clock.advance(.seconds(7200))
        fixture.crash(status: 82)
        try await eventually { fixture.supervisor.state == .stopped }
        fixture.supervisor.start()
        await fixture.supervisor.recoverAfterWorkspaceWake()
        XCTAssertEqual(fixture.topology.launchPlans.count, 2)
        XCTAssertEqual(fixture.clock.delays, [1])
        XCTAssertEqual(fixture.config.captureWrites, [false])
        XCTAssertFalse(fixture.topology.isRunning)
        try await fixture.supervisor.shutdownAndWait()
    }

    func test_explicit_stop_and_shutdown_cancel_replenished_pending_retry() async throws {
        for shutdown in [false, true] {
            let fixture = RecoveryFixture()
            try await fixture.supervisor.startAndWaitForReadiness()
            fixture.clock.advance(.seconds(7200))
            fixture.crash()
            try await eventually { fixture.clock.isSleeping }
            if shutdown {
                try await fixture.supervisor.shutdownAndWait()
            } else {
                try await fixture.supervisor.applyCaptureEnabled(false)
            }
            fixture.clock.resume()
            try await eventually { fixture.clock.completedSleeps == 1 }
            XCTAssertEqual(fixture.supervisor.state, .stopped)
            XCTAssertEqual(fixture.topology.launchPlans.count, 1)
            XCTAssertFalse(fixture.topology.isRunning)
            try await fixture.supervisor.shutdownAndWait()
        }
    }

    func test_permission_revocation_blocks_stable_run_recovery_and_pending_retry() async throws {
        for revokeDuringBackoff in [false, true] {
            let fixture = RecoveryFixture()
            try await fixture.supervisor.startAndWaitForReadiness()
            fixture.clock.advance(.seconds(7200))
            if !revokeDuringBackoff { fixture.supervisor.tccRevokedSurface = .screenRecording }
            fixture.crash()
            if revokeDuringBackoff {
                try await eventually { fixture.clock.isSleeping }
                fixture.supervisor.tccRevokedSurface = .screenRecording
                fixture.clock.resume()
                try await eventually { fixture.clock.completedSleeps == 1 }
            }
            XCTAssertEqual(fixture.topology.launchPlans.count, 1)
            XCTAssertEqual(fixture.clock.delays.count, revokeDuringBackoff ? 1 : 0)
            XCTAssertEqual(fixture.supervisor.tccRevokedSurface, .screenRecording)
            XCTAssertEqual(fixture.config.captureWrites, [])
            XCTAssertFalse(fixture.exhausted, "Revoked permission must not be mislabeled as budget exhaustion")
            try await fixture.supervisor.shutdownAndWait()
        }
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        try await waitForRecovery(predicate)
    }
}

@MainActor
private final class RecoveryClock {
    var now = ContinuousClock().now
    private(set) var delays: [TimeInterval] = []
    private(set) var completedSleeps = 0
    private var continuation: CheckedContinuation<Void, Never>?
    var isSleeping: Bool { continuation != nil }

    func advance(_ duration: Duration) { now = now.advanced(by: duration) }

    func sleep(_ seconds: TimeInterval) async throws {
        delays.append(seconds)
        await withCheckedContinuation { continuation = $0 }
        completedSleeps += 1
        try Task.checkCancellation()
    }

    func resume() {
        if let delay = delays.last { advance(.seconds(delay)) }
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

@MainActor
private final class RecoveryFixture {
    let clock = RecoveryClock()
    let topology = FakeSupervisorTopology()
    let config = FakeRuntimeConfig(captureEnabled: false)
    let supervisor: ProcessSupervisor

    init() {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/fixture/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/fixture/mci-agent")
        let key = FakeKeyStore()
        key.storedKey = String(repeating: "ab", count: 32)
        let clock = self.clock
        supervisor = ProcessSupervisor(
            locator: locator, keyStore: key, runtimeConfig: config, topology: topology,
            keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 0.1,
            recoveryNow: { clock.now }, retrySleep: { try await clock.sleep($0) },
            captureStatusReader: { (nil, nil) }
        )
    }

    var exhausted: Bool {
        guard case .crashed(let reason) = supervisor.state else { return false }
        return reason.contains("Automatic recovery stopped")
    }

    func crash(status: Int32 = 81) {
        topology.isRunning = false
        topology.fireUnexpectedExit(forLaunchAt: topology.launchPlans.count - 1, status: status)
    }

    func crashAndRestart() async throws {
        let launchCount = topology.launchPlans.count
        let delayCount = clock.delays.count
        crash()
        try await waitForRecovery { self.clock.delays.count == delayCount + 1 && self.clock.isSleeping }
        clock.resume()
        try await waitForRecovery { self.topology.launchPlans.count == launchCount + 1 && self.supervisor.state == .running }
    }
}

@MainActor
private func waitForRecovery(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock().now.advanced(by: .seconds(2))
    while !predicate() {
        guard ContinuousClock().now < deadline else {
            XCTFail("Timed out waiting for the expected supervisor transition")
            throw RecoveryTestError.timedOut
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private enum RecoveryTestError: Error { case timedOut }
