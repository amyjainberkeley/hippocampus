// SPDX-License-Identifier: TBD-private
import XCTest
@testable import HippocampusKit

/// The termination coordinator owns the promise behind Quit: once the user
/// asks, the app ends. These tests pin that promise against the failure mode
/// observed on the owner's Mac on 2026-09-26, where capture was in a
/// failed/recovering state and Quit left every process running.
@MainActor
final class ApplicationTerminationCoordinatorTests: XCTestCase {
    private enum TestError: LocalizedError {
        case partialStop
        case launchFailed

        var errorDescription: String? { String(describing: self) }
    }

    @MainActor
    private final class TerminationProbe {
        var outcome: Bool?
        var replies: [Bool] = []
    }

    // MARK: - Reproduction

    func test_quit_completes_even_when_the_verified_stop_hangs_during_recovery() async throws {
        let (supervisor, topology, backoff) = try await makeRecoveringSupervisor()
        let hungStop = TestSuspension()
        topology.stopSuspensionOnCall = topology.stopCalls + 1
        topology.stopSuspension = hungStop
        var cleanedUp = false
        let coordinator = ApplicationTerminationCoordinator(
            supervisor: supervisor,
            restartLauncher: FakeApplicationRestartLauncher(),
            shutdownTimeout: 0.05,
            cleanup: { cleanedUp = true }
        )

        let probe = await runQuit(coordinator, intent: .quit)

        XCTAssertEqual(
            probe.outcome, true,
            "a deliberate quit must complete even when the supervisor cannot stop cleanly"
        )
        XCTAssertEqual(probe.replies, [true])
        XCTAssertTrue(coordinator.hasVerifiedShutdown)
        XCTAssertTrue(cleanedUp)
        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertEqual(topology.launchPlans.count, 1, "quitting must never relaunch capture")
        hungStop.resume()
        backoff.resume()
    }

    func test_quit_completes_when_the_verified_stop_fails() async throws {
        let (supervisor, topology, backoff) = try await makeRecoveringSupervisor()
        topology.stopResults = [.failure(TestError.partialStop)]
        var cleanedUp = false
        let coordinator = ApplicationTerminationCoordinator(
            supervisor: supervisor,
            restartLauncher: FakeApplicationRestartLauncher(),
            shutdownTimeout: 0.05,
            cleanup: { cleanedUp = true }
        )

        let probe = await runQuit(coordinator, intent: .quit)

        XCTAssertEqual(probe.outcome, true, "a failed verified stop must escalate, not refuse the quit")
        XCTAssertEqual(probe.replies, [true])
        XCTAssertTrue(coordinator.hasVerifiedShutdown)
        XCTAssertTrue(cleanedUp)
        XCTAssertEqual(topology.launchPlans.count, 1)
        backoff.resume()
    }

    // MARK: - What the supervisor does not own (spec-shell S6.7)

    func test_quit_stops_ask_and_the_windows_alongside_and_sweeps_once_stopped() async throws {
        let (supervisor, topology, backoff) = try await makeSupervisor()
        let heldStop = TestSuspension()
        topology.stopSuspensionOnCall = topology.stopCalls + 1
        topology.stopSuspension = heldStop
        let record = QuitRecord()
        let coordinator = ApplicationTerminationCoordinator(
            supervisor: supervisor,
            restartLauncher: FakeApplicationRestartLauncher(),
            shutdownTimeout: 5,
            stopExtras: { record.events.append("extras") },
            afterStop: { record.events.append(supervisor.state == .stopped ? "sweep after stop" : "sweep early") },
            cleanup: { record.events.append("cleanup") }
        )
        let probe = TerminationProbe()
        let quit = Task { @MainActor in
            probe.outcome = await coordinator.terminate(intent: .quit) { probe.replies.append($0) }
        }

        await heldStop.waitUntilEntered()
        for _ in 0..<200 where record.events.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(record.events, ["extras"], "Ask and the windows stop while the supervisor is still stopping")
        XCTAssertEqual(probe.replies, [])

        heldStop.resume()
        await quit.value
        XCTAssertEqual(record.events, ["extras", "sweep after stop", "cleanup"])
        XCTAssertEqual(probe.replies, [true])
        backoff.resume()
    }

    func test_a_forced_quit_still_stops_the_extras_and_sweeps_before_replying() async throws {
        let (supervisor, topology, backoff) = try await makeRecoveringSupervisor()
        topology.stopResults = [.failure(TestError.partialStop)]
        let record = QuitRecord()
        let coordinator = ApplicationTerminationCoordinator(
            supervisor: supervisor,
            restartLauncher: FakeApplicationRestartLauncher(),
            shutdownTimeout: 0.05,
            stopExtras: { record.events.append("extras") },
            afterStop: { record.events.append(supervisor.state == .stopped ? "sweep after stop" : "sweep early") },
            cleanup: { record.events.append("cleanup") }
        )

        let probe = await runQuit(coordinator, intent: .quit)

        XCTAssertEqual(probe.replies, [true])
        XCTAssertEqual(Set(record.events.dropLast()), ["extras", "sweep after stop"])
        XCTAssertEqual(record.events.last, "cleanup", "both finish before cleanup and the reply")
        backoff.resume()
    }

    func test_a_failed_restart_leaves_ask_and_the_windows_alone() async throws {
        let (supervisor, topology, backoff) = try await makeSupervisor()
        topology.stopResults = [.failure(TestError.partialStop)]
        let record = QuitRecord()
        let launcher = FakeApplicationRestartLauncher()
        let coordinator = ApplicationTerminationCoordinator(
            supervisor: supervisor,
            restartLauncher: launcher,
            shutdownTimeout: 0.05,
            stopExtras: { record.events.append("extras") },
            afterStop: { record.events.append("sweep") },
            cleanup: { record.events.append("cleanup") },
            onFailure: { _ in record.events.append("failure") }
        )

        let probe = await runQuit(coordinator, intent: .restart)

        XCTAssertEqual(probe.outcome, false)
        XCTAssertEqual(probe.replies, [false])
        XCTAssertEqual(record.events, ["failure"], "Hippocampus stays open, so Ask and the windows keep working")
        XCTAssertEqual(launcher.scheduleCount, 0)
        backoff.resume()
    }

    func test_a_restart_stops_the_extras_after_a_verified_stop_and_before_relaunching() async throws {
        let (supervisor, _, backoff) = try await makeSupervisor()
        let record = QuitRecord()
        let launcher = FakeApplicationRestartLauncher()
        launcher.onSchedule = { record.events.append("relaunch") }
        let coordinator = ApplicationTerminationCoordinator(
            supervisor: supervisor,
            restartLauncher: launcher,
            shutdownTimeout: 0.05,
            stopExtras: { record.events.append(supervisor.state == .stopped ? "extras after stop" : "extras early") },
            afterStop: { record.events.append("sweep") },
            cleanup: { record.events.append("cleanup") }
        )

        let probe = await runQuit(coordinator, intent: .restart)

        XCTAssertEqual(probe.replies, [true])
        XCTAssertEqual(Set(record.events.prefix(2)), ["extras after stop", "sweep"])
        XCTAssertEqual(Array(record.events.suffix(2)), ["relaunch", "cleanup"])
        backoff.resume()
    }

    func test_quit_does_not_wait_past_its_deadline_for_a_step_that_hangs() async throws {
        let (supervisor, _, backoff) = try await makeSupervisor()
        let hung = TestSuspension()
        let coordinator = ApplicationTerminationCoordinator(
            supervisor: supervisor,
            restartLauncher: FakeApplicationRestartLauncher(),
            shutdownTimeout: 0.05,
            extrasTimeout: 0.1,
            stopExtras: { await hung.suspend() },
            cleanup: {}
        )

        let probe = await runQuit(coordinator, intent: .quit, within: 2)

        XCTAssertEqual(probe.replies, [true])
        XCTAssertTrue(coordinator.hasVerifiedShutdown)
        hung.resume()
        backoff.resume()
    }

    // MARK: - Helpers

    @MainActor
    private final class QuitRecord {
        var events: [String] = []
    }

    /// A supervisor whose capture is running, with its recovery backoff held.
    private func makeSupervisor() async throws -> (
        ProcessSupervisor, FakeSupervisorTopology, TestSuspension
    ) {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let topology = FakeSupervisorTopology()
        let backoff = TestSuspension()
        let supervisor = ProcessSupervisor(
            locator: locator,
            keyStore: keyStore,
            runtimeConfig: FakeRuntimeConfig(captureEnabled: true),
            topology: topology,
            keyCustodyPreparer: FakeKeyCustodyPreparer(),
            readinessTimeout: 0.1,
            retrySleep: { _ in
                await backoff.suspend()
                try Task.checkCancellation()
            },
            captureStatusReader: { (nil, nil) }
        )
        try await supervisor.startAndWaitForReadiness()
        return (supervisor, topology, backoff)
    }

    /// A supervisor whose capture crashed and whose recovery loop is parked in
    /// backoff: the state the owner's Mac was in when Quit stopped working.
    private func makeRecoveringSupervisor() async throws -> (
        ProcessSupervisor, FakeSupervisorTopology, TestSuspension
    ) {
        let (supervisor, topology, backoff) = try await makeSupervisor()
        topology.isRunning = false
        topology.fireUnexpectedExit(forLaunchAt: 0, label: "helper", status: 81)
        await backoff.waitUntilEntered()
        guard case .crashed = supervisor.state else {
            throw XCTSkip("fixture must be recovering, got \(supervisor.state)")
        }
        return (supervisor, topology, backoff)
    }

    /// Runs the quit on its own task and waits a bounded time so a coordinator
    /// that never answers fails the test instead of hanging the suite.
    private func runQuit(
        _ coordinator: ApplicationTerminationCoordinator,
        intent: ApplicationTerminationIntent,
        within seconds: TimeInterval = 3
    ) async -> TerminationProbe {
        let probe = TerminationProbe()
        let quit = Task { @MainActor in
            probe.outcome = await coordinator.terminate(intent: intent) { probe.replies.append($0) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while probe.outcome == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if probe.outcome == nil {
            quit.cancel()
            XCTFail("quit never completed within \(seconds)s")
        }
        return probe
    }
}
