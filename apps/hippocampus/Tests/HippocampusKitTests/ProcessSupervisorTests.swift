// SPDX-License-Identifier: TBD-private
import XCTest
@testable import HippocampusKit

final class FakeBinaryLocator: BinaryLocator, @unchecked Sendable {
    var helperURL: URL?
    var agentURL: URL?
    var recallURL: URL?
    var onboardingURL: URL?
    var brainCLIURL: URL?
    var knownSafeURL: URL?

    func helperPath() -> URL? { helperURL }
    func agentPath() -> URL? { agentURL }
    func recallUIPath() -> URL? { recallURL }
    func onboardingPath() -> URL? { onboardingURL }
    func brainCLIPath() -> URL? { brainCLIURL }
    func knownSafeAppsPath() -> URL? { knownSafeURL }
}

final class FakeKeyStore: KeyStore, @unchecked Sendable {
    var storedKey: String?
    var lastWrittenKey: String?

    func readKey() throws -> String {
        guard let storedKey else { throw KeyStoreError.noKeyFound }
        return storedKey
    }

    func writeKey(_ hex: String) throws {
        storedKey = hex
        lastWrittenKey = hex
    }
}

final class FakeRuntimeConfig: RuntimeConfiguring, @unchecked Sendable {
    var captureEnabled: Bool
    var crashReportOptedIn = false
    var captureWriteError: Error?
    private(set) var captureWrites: [Bool] = []

    init(captureEnabled: Bool) {
        self.captureEnabled = captureEnabled
    }

    func setCaptureEnabled(_ value: Bool) throws {
        captureWrites.append(value)
        if let captureWriteError { throw captureWriteError }
        captureEnabled = value
    }

    func setCrashReportOptedIn(_ value: Bool) throws {
        crashReportOptedIn = value
    }
}

@MainActor
final class FakeKeyCustodyPreparer: KeyCustodyPreparing {
    var error: Error?
    private(set) var calls: [(URL, URL, KeychainKeyReference)] = []

    func prepare(
        agentURL: URL,
        databaseURL: URL,
        keyReference: KeychainKeyReference
    ) async throws {
        calls.append((agentURL, databaseURL, keyReference))
        if let error { throw error }
    }
}

@MainActor
final class FakeSupervisorTopology: SupervisorTopologyControlling {
    var readinessResults: [Result<Void, Error>] = []
    var stopResults: [Result<Void, Error>] = []
    var isRunning = false
    var onReadinessWait: ((ProcessSupervisorLaunchPlan) -> Void)?
    var onStop: (() -> Void)?
    var stopDelay: Duration?
    private(set) var launchPlans: [ProcessSupervisorLaunchPlan] = []
    private(set) var generations: [SupervisorProcessGeneration] = []
    private(set) var unexpectedExitCallbacks: [@MainActor @Sendable (String, Int32) -> Void] = []
    private(set) var stopCalls = 0

    func launch(
        plan: ProcessSupervisorLaunchPlan,
        generation: SupervisorProcessGeneration,
        onUnexpectedExit: @escaping @MainActor @Sendable (String, Int32) -> Void
    ) async throws {
        launchPlans.append(plan)
        generations.append(generation)
        unexpectedExitCallbacks.append(onUnexpectedExit)
        isRunning = true
    }

    func waitForReadiness(
        generation: SupervisorProcessGeneration,
        timeout: TimeInterval
    ) async throws {
        _ = (generation, timeout)
        onReadinessWait?(launchPlans.last!)
        if !readinessResults.isEmpty {
            try readinessResults.removeFirst().get()
        }
    }

    func stop(timeout: TimeInterval) async throws {
        _ = timeout
        stopCalls += 1
        onStop?()
        if let stopDelay { try? await Task.sleep(for: stopDelay) }
        if !stopResults.isEmpty {
            try stopResults.removeFirst().get()
        }
        isRunning = false
    }

    func setPaused(_ paused: Bool) throws {
        _ = paused
    }

    func fireUnexpectedExit(forLaunchAt index: Int, label: String = "helper", status: Int32 = 9) {
        unexpectedExitCallbacks[index](label, status)
    }
}

@MainActor
final class ProcessSupervisorTests: XCTestCase {
    private enum TestError: LocalizedError {
        case denied
        case earlyExit
        case timeout
        case partialStop
        case writeFailed

        var errorDescription: String? { String(describing: self) }
    }

    private func makeSupervisor(captureEnabled: Bool = false) -> (
        ProcessSupervisor,
        FakeBinaryLocator,
        FakeKeyStore,
        FakeRuntimeConfig,
        FakeSupervisorTopology,
        FakeKeyCustodyPreparer
    ) {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = "ab".repeat(32)
        let config = FakeRuntimeConfig(captureEnabled: captureEnabled)
        let topology = FakeSupervisorTopology()
        let custody = FakeKeyCustodyPreparer()
        let supervisor = ProcessSupervisor(
            locator: locator,
            keyStore: keyStore,
            runtimeConfig: config,
            topology: topology,
            keyCustodyPreparer: custody,
            readinessTimeout: 0.1
        )
        return (supervisor, locator, keyStore, config, topology, custody)
    }

    private func generation(captureEnabled: Bool = false) -> SupervisorProcessGeneration {
        SupervisorProcessGeneration(
            id: "generation-1",
            readinessURL: URL(fileURLWithPath: "/tmp/generation-1.json"),
            captureEnabled: captureEnabled
        )
    }

    func test_launch_plan_uses_generation_receipt_and_single_capture_authority() {
        let generation = generation(captureEnabled: false)
        let plan = ProcessSupervisorLaunchPlan.make(
            helperURL: URL(fileURLWithPath: "/bundle/MCICaptureHelper"),
            agentURL: URL(fileURLWithPath: "/bundle/mci-agent"),
            dbPath: URL(fileURLWithPath: "/tmp/mci.sqlite"),
            keyReference: .defaultDatabaseKey,
            knownSafeAppsURL: nil,
            captureEnabled: false,
            crashReportOptedIn: false,
            generation: generation,
            baseEnvironment: [
                "MCI_DB_KEY_HEX": "ef".repeat(32),
                "MCI_DEVELOPMENT_FILE_KEY": "1",
                "HIPPOCAMPUS_ENABLE_V2P1": "1",
            ]
        )

        XCTAssertFalse(plan.helperArguments.contains("--capture"))
        XCTAssertTrue(plan.helperArguments.contains(generation.readinessURL.path))
        XCTAssertTrue(plan.helperArguments.contains(generation.id))
        for environment in [plan.helperEnvironment, plan.agentEnvironment] {
            XCTAssertNil(environment["MCI_DB_KEY_HEX"])
            XCTAssertNil(environment["MCI_DEVELOPMENT_FILE_KEY"])
            XCTAssertNil(environment["HIPPOCAMPUS_ENABLE_V2P1"])
        }
    }

    func test_launch_plan_includes_capture_only_for_explicit_setting() {
        let generation = generation(captureEnabled: true)
        let plan = ProcessSupervisorLaunchPlan.make(
            helperURL: URL(fileURLWithPath: "/bundle/MCICaptureHelper"),
            agentURL: URL(fileURLWithPath: "/bundle/mci-agent"),
            dbPath: URL(fileURLWithPath: "/tmp/mci.sqlite"),
            keyReference: .defaultDatabaseKey,
            knownSafeAppsURL: nil,
            captureEnabled: true,
            crashReportOptedIn: false,
            generation: generation,
            baseEnvironment: [:]
        )

        XCTAssertTrue(plan.helperArguments.contains("--capture"))
    }

    func test_startup_denial_never_reaches_running() async {
        let (supervisor, _, _, _, topology, _) = makeSupervisor()
        topology.readinessResults = [.failure(TestError.denied)]

        await XCTAssertThrowsErrorAsync(try await supervisor.startAndWaitForReadiness())

        guard case .crashed(let reason) = supervisor.state else {
            return XCTFail("expected visible error, got \(supervisor.state)")
        }
        XCTAssertTrue(reason.contains("denied"))
        XCTAssertFalse(supervisor.captureEnabled)
    }

    func test_helper_early_exit_never_reaches_running() async {
        let (supervisor, _, _, _, topology, _) = makeSupervisor()
        topology.readinessResults = [.failure(TestError.earlyExit)]

        await XCTAssertThrowsErrorAsync(try await supervisor.startAndWaitForReadiness())

        XCTAssertNotEqual(supervisor.state, .running)
        XCTAssertEqual(topology.stopCalls, 1)
    }

    func test_readiness_timeout_never_reaches_running() async {
        let (supervisor, _, _, _, topology, _) = makeSupervisor()
        topology.readinessResults = [.failure(TestError.timeout)]

        await XCTAssertThrowsErrorAsync(try await supervisor.startAndWaitForReadiness())

        XCTAssertNotEqual(supervisor.state, .running)
        XCTAssertFalse(supervisor.captureEnabled)
    }

    func test_partial_stop_leaves_visible_error_and_does_not_persist_requested_setting() async throws {
        let (supervisor, _, _, config, topology, _) = makeSupervisor()
        topology.readinessResults = [.success(())]
        try await supervisor.startAndWaitForReadiness()
        topology.stopResults = [.failure(TestError.partialStop)]

        await XCTAssertThrowsErrorAsync(try await supervisor.applyCaptureEnabled(true))

        XCTAssertEqual(config.captureWrites, [])
        XCTAssertFalse(config.captureEnabled)
        guard case .crashed = supervisor.state else {
            return XCTFail("partial stop must be visible, got \(supervisor.state)")
        }
    }

    func test_verified_shutdown_publishes_stopped_only_after_topology_stop_returns() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor()
        topology.readinessResults = [.success(())]
        try await supervisor.startAndWaitForReadiness()
        topology.onStop = {
            XCTAssertEqual(supervisor.state, .running)
            XCTAssertTrue(topology.isRunning)
        }

        try await supervisor.shutdownAndWait()

        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertFalse(topology.isRunning)
    }

    func test_concurrent_verified_shutdown_callers_share_one_stop() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor()
        topology.readinessResults = [.success(())]
        try await supervisor.startAndWaitForReadiness()
        topology.stopDelay = .milliseconds(75)

        async let first: Void = supervisor.shutdownAndWait()
        async let second: Void = supervisor.shutdownAndWait()
        _ = try await (first, second)

        XCTAssertEqual(topology.stopCalls, 1)
        XCTAssertEqual(supervisor.state, .stopped)
    }

    func test_failed_verified_shutdown_never_claims_stopped() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor()
        topology.readinessResults = [.success(())]
        try await supervisor.startAndWaitForReadiness()
        topology.stopResults = [.failure(TestError.partialStop)]

        await XCTAssertThrowsErrorAsync(try await supervisor.shutdownAndWait())

        guard case .crashed = supervisor.state else {
            return XCTFail("failed shutdown must stay visible, got \(supervisor.state)")
        }
    }

    func test_failed_enable_restarts_and_verifies_prior_topology_before_rollback() async throws {
        let (supervisor, _, _, config, topology, _) = makeSupervisor()
        topology.readinessResults = [
            .success(()),
            .failure(TestError.denied),
            .success(()),
        ]
        topology.stopResults = [.success(()), .success(())]
        try await supervisor.startAndWaitForReadiness()

        await XCTAssertThrowsErrorAsync(try await supervisor.applyCaptureEnabled(true))

        XCTAssertEqual(
            topology.launchPlans.map { $0.helperArguments.contains("--capture") },
            [false, true, false]
        )
        XCTAssertEqual(Set(topology.generations.map(\.id)).count, 3)
        XCTAssertEqual(supervisor.state, .running)
        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertFalse(config.captureEnabled)
        XCTAssertEqual(config.captureWrites, [])
    }

    func test_exit_callbacks_during_requested_start_and_rollback_are_suppressed() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor()
        topology.readinessResults = [
            .success(()),
            .failure(TestError.denied),
            .success(()),
        ]
        topology.stopResults = [.success(()), .success(())]
        try await supervisor.startAndWaitForReadiness()
        var callbackStates: [SupervisorState] = []
        topology.onReadinessWait = { _ in
            let launchIndex = topology.launchPlans.count - 1
            guard launchIndex > 0 else { return }
            topology.fireUnexpectedExit(forLaunchAt: launchIndex)
            callbackStates.append(supervisor.state)
        }

        await XCTAssertThrowsErrorAsync(try await supervisor.applyCaptureEnabled(true))

        XCTAssertEqual(callbackStates, [.starting, .starting])
        XCTAssertEqual(topology.launchPlans.count, 3)
        XCTAssertEqual(supervisor.state, .running)
        XCTAssertFalse(supervisor.captureEnabled)
    }

    func test_setting_is_persisted_only_after_expected_generation_is_ready() async throws {
        let (supervisor, _, _, config, topology, _) = makeSupervisor()
        topology.readinessResults = [.success(()), .success(())]
        topology.stopResults = [.success(())]
        try await supervisor.startAndWaitForReadiness()
        topology.onReadinessWait = { plan in
            if plan.helperArguments.contains("--capture") {
                XCTAssertFalse(config.captureEnabled)
                XCTAssertEqual(config.captureWrites, [])
            }
        }

        try await supervisor.applyCaptureEnabled(true)

        XCTAssertTrue(supervisor.captureEnabled)
        XCTAssertTrue(config.captureEnabled)
        XCTAssertEqual(config.captureWrites, [true])
    }

    func test_persistence_failure_rolls_back_to_verified_prior_topology() async throws {
        let (supervisor, _, _, config, topology, _) = makeSupervisor()
        topology.readinessResults = [.success(()), .success(()), .success(())]
        topology.stopResults = [.success(()), .success(())]
        try await supervisor.startAndWaitForReadiness()
        config.captureWriteError = TestError.writeFailed

        await XCTAssertThrowsErrorAsync(try await supervisor.applyCaptureEnabled(true))

        XCTAssertEqual(
            topology.launchPlans.map { $0.helperArguments.contains("--capture") },
            [false, true, false]
        )
        XCTAssertEqual(supervisor.state, .running)
        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertFalse(config.captureEnabled)
    }

    func test_start_runs_shared_key_custody_before_launch() async throws {
        let (supervisor, _, _, _, topology, custody) = makeSupervisor()
        topology.readinessResults = [.success(())]

        try await supervisor.startAndWaitForReadiness()

        XCTAssertEqual(custody.calls.count, 1)
        XCTAssertEqual(custody.calls[0].2, .defaultDatabaseKey)
        XCTAssertEqual(topology.launchPlans.count, 1)
    }

    func test_health_snapshot_display_reports_processed_frames() {
        let snapshot = HealthSnapshot(
            framesDelivered: 77,
            framesSuppressed: 5,
            lastCaptureTs: Date().addingTimeInterval(-60),
            lastUpdated: Date()
        )
        XCTAssertTrue(snapshot.displayText.contains("77 frames processed"))
        XCTAssertFalse(snapshot.displayText.contains("events captured"))
    }

    func test_has_onboarding_reflects_locator() {
        let (supervisor, locator, _, _, _, _) = makeSupervisor()
        XCTAssertFalse(supervisor.hasOnboarding)
        locator.onboardingURL = URL(fileURLWithPath: "/bundle/onboarding")
        XCTAssertTrue(supervisor.hasOnboarding)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
