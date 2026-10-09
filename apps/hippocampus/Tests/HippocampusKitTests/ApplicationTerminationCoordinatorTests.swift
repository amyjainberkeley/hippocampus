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

    // MARK: - Helpers

    /// A supervisor whose capture crashed and whose recovery loop is parked in
    /// backoff: the state the owner's Mac was in when Quit stopped working.
    private func makeRecoveringSupervisor() async throws -> (
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
