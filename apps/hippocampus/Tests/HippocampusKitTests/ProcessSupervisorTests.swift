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
    var suspension: TestSuspension?
    private(set) var calls: [(URL, URL, KeychainKeyReference)] = []

    func prepare(
        agentURL: URL,
        databaseURL: URL,
        keyReference: KeychainKeyReference
    ) async throws {
        calls.append((agentURL, databaseURL, keyReference))
        if let suspension { await suspension.suspend() }
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
    var stopSuspensionOnCall: Int?
    var stopSuspension: TestSuspension?
    var readinessSuspension: TestSuspension?
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
        if let readinessSuspension { await readinessSuspension.suspend() }
        if !readinessResults.isEmpty {
            try readinessResults.removeFirst().get()
        }
    }

    func stop(timeout: TimeInterval) async throws {
        _ = timeout
        stopCalls += 1
        onStop?()
        if stopCalls == stopSuspensionOnCall, let stopSuspension {
            await stopSuspension.suspend()
        }
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
final class TestSuspension {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class FakeApplicationRestartLauncher: ApplicationRestartLaunching {
    var onSchedule: (() -> Void)?
    private(set) var scheduleCount = 0

    func scheduleRestart() throws {
        scheduleCount += 1
        onSchedule?()
    }
}

final class FakeCaptureConsentAuthority: CaptureConsentControlling, @unchecked Sendable {
    var disableError: Error?
    private(set) var enabledGenerationID: String?
    private(set) var enabledGenerations: [String] = []

    func enable(generationID: String) throws {
        enabledGenerationID = generationID
        enabledGenerations.append(generationID)
    }

    func disable() throws {
        if let disableError { throw disableError }
        enabledGenerationID = nil
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

    private func makeSupervisor(
        captureEnabled: Bool = false,
        captureConsentAuthority: any CaptureConsentControlling = NoopCaptureConsentAuthority()
    ) -> (
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
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let config = FakeRuntimeConfig(captureEnabled: captureEnabled)
        let topology = FakeSupervisorTopology()
        let custody = FakeKeyCustodyPreparer()
        let supervisor = ProcessSupervisor(
            locator: locator,
            keyStore: keyStore,
            runtimeConfig: config,
            topology: topology,
            keyCustodyPreparer: custody,
            captureConsentAuthority: captureConsentAuthority,
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
                "MCI_DB_KEY_HEX": String(repeating: "ef", count: 32),
                "MCI_DEVELOPMENT_FILE_KEY": "1",
                "HIPPOCAMPUS_ENABLE_V2P1": "1",
            ]
        )

        XCTAssertFalse(plan.helperArguments.contains("--capture"))
        XCTAssertTrue(plan.helperArguments.contains("--parent-lease-stdin"))
        XCTAssertTrue(plan.helperArguments.contains(generation.readinessURL.path))
        XCTAssertTrue(plan.helperArguments.contains(generation.id))
        for environment in [plan.helperEnvironment, plan.agentEnvironment] {
            XCTAssertNil(environment["MCI_DB_KEY_HEX"])
            XCTAssertNil(environment["MCI_DEVELOPMENT_FILE_KEY"])
            XCTAssertNil(environment["HIPPOCAMPUS_ENABLE_V2P1"])
        }
        XCTAssertEqual(plan.agentEnvironment["MCI_CAPTURE_ENABLED"], "0")
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
        XCTAssertFalse(plan.helperArguments.contains("--live-overlap-qualification"))
        XCTAssertEqual(plan.agentEnvironment["MCI_CAPTURE_ENABLED"], "1")
    }

    func test_development_launch_plan_passes_only_marker_and_fixed_file_reference() {
        let keyURL = URL(fileURLWithPath: "/tmp/MCI/dev.key")
        let plan = ProcessSupervisorLaunchPlan.make(
            helperURL: URL(fileURLWithPath: "/bundle/MCICaptureHelper"),
            agentURL: URL(fileURLWithPath: "/bundle/mci-agent"),
            dbPath: URL(fileURLWithPath: "/tmp/mci.sqlite"),
            keyReference: .defaultDatabaseKey,
            developmentKeyMode: DevelopmentFileKeyMode(keyURL: keyURL),
            knownSafeAppsURL: nil,
            captureEnabled: true,
            crashReportOptedIn: false,
            generation: generation(captureEnabled: true),
            baseEnvironment: ["MCI_DB_KEY_HEX": String(repeating: "ef", count: 32)]
        )

        for environment in [plan.helperEnvironment, plan.agentEnvironment] {
            XCTAssertEqual(environment["MCI_DEVELOPMENT_FILE_KEY"], "1")
            XCTAssertEqual(environment["MCI_DB_KEY_FILE"], keyURL.path)
            XCTAssertNil(environment["MCI_DB_KEY_HEX"])
            XCTAssertNil(environment["MCI_DB_KEYCHAIN_SERVICE"])
            XCTAssertNil(environment["MCI_DB_KEYCHAIN_ACCOUNT"])
        }
    }

    func test_start_with_capture_disabled_does_not_start_safari_ingestion() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor(captureEnabled: false)
        topology.readinessResults = [.success(())]

        try await supervisor.startAndWaitForReadiness()

        XCTAssertNil(supervisor.safariInboxStats)
    }

    func test_start_with_capture_enabled_starts_safari_ingestion() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor(captureEnabled: true)
        topology.readinessResults = [.success(())]

        try await supervisor.startAndWaitForReadiness()

        XCTAssertNotNil(supervisor.safariInboxStats)
    }

    func test_pause_requested_before_start_prevents_topology_launch() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor(captureEnabled: true)

        supervisor.setPaused(true)
        try await supervisor.startAndWaitForReadiness()

        XCTAssertEqual(supervisor.state, .paused)
        XCTAssertTrue(topology.launchPlans.isEmpty)
        XCTAssertFalse(topology.isRunning)
        XCTAssertNil(supervisor.safariInboxStats)
    }

    func test_pause_requested_during_startup_cancels_uncommitted_topology() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor(captureEnabled: true)
        let readiness = TestSuspension()
        topology.readinessSuspension = readiness
        topology.readinessResults = [.success(())]
        let startup = Task { @MainActor in
            try await supervisor.startAndWaitForReadiness()
        }
        await readiness.waitUntilEntered()

        supervisor.setPaused(true)
        while topology.stopCalls == 0 { await Task.yield() }
        readiness.resume()
        _ = try? await startup.value
        while supervisor.state != .paused { await Task.yield() }

        XCTAssertEqual(topology.launchPlans.count, 1)
        XCTAssertFalse(topology.isRunning)
        XCTAssertNil(supervisor.safariInboxStats)
    }

    func test_user_pause_stops_the_owned_topology_and_resume_launches_a_fresh_generation() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor(captureEnabled: true)
        topology.readinessResults = [.success(()), .success(())]
        try await supervisor.startAndWaitForReadiness()

        try await supervisor.setPausedAndWait(true)

        XCTAssertEqual(supervisor.state, .paused)
        XCTAssertEqual(topology.stopCalls, 1)
        XCTAssertFalse(topology.isRunning)
        XCTAssertNil(supervisor.safariInboxStats)

        try await supervisor.setPausedAndWait(false)

        XCTAssertEqual(supervisor.state, .running)
        XCTAssertEqual(topology.launchPlans.count, 2)
        XCTAssertNotEqual(topology.generations[0].id, topology.generations[1].id)
        XCTAssertTrue(topology.isRunning)
        XCTAssertNotNil(supervisor.safariInboxStats)
    }

    func test_latest_resume_intent_wins_while_pause_stop_is_in_flight() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor(captureEnabled: true)
        topology.readinessResults = [.success(()), .success(())]
        try await supervisor.startAndWaitForReadiness()
        let suspension = TestSuspension()
        topology.stopSuspensionOnCall = 1
        topology.stopSuspension = suspension

        supervisor.setPaused(true)
        await suspension.waitUntilEntered()
        supervisor.setPaused(false)
        suspension.resume()

        while topology.launchPlans.count < 2 { await Task.yield() }
        while supervisor.state != .running { await Task.yield() }
        XCTAssertEqual(topology.stopCalls, 1)
        XCTAssertTrue(topology.isRunning)
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

    func test_shutdown_during_key_preparation_prevents_late_launch() async throws {
        let (supervisor, _, _, _, topology, custody) = makeSupervisor()
        let suspension = TestSuspension()
        custody.suspension = suspension
        let startup = Task { @MainActor in try await supervisor.startAndWaitForReadiness() }
        await suspension.waitUntilEntered()

        let shutdown = Task { @MainActor in try await supervisor.shutdownAndWait() }
        while topology.stopCalls == 0 { await Task.yield() }
        suspension.resume()
        try await shutdown.value
        await XCTAssertThrowsErrorAsync(try await startup.value)

        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertEqual(topology.launchPlans.count, 0)
        XCTAssertFalse(topology.isRunning)
    }

    func test_shutdown_during_readiness_keeps_stopped_and_discards_launch() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor()
        let suspension = TestSuspension()
        topology.readinessSuspension = suspension
        let startup = Task { @MainActor in try await supervisor.startAndWaitForReadiness() }
        await suspension.waitUntilEntered()

        let shutdown = Task { @MainActor in try await supervisor.shutdownAndWait() }
        while topology.stopCalls == 0 { await Task.yield() }
        suspension.resume()
        try await shutdown.value
        await XCTAssertThrowsErrorAsync(try await startup.value)

        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertEqual(topology.launchPlans.count, 1)
        XCTAssertFalse(topology.isRunning)
    }

    func test_shutdown_during_capture_reconfiguration_readiness_discards_requested_topology() async throws {
        let (supervisor, _, _, config, topology, _) = makeSupervisor()
        topology.readinessResults = [.success(())]
        try await supervisor.startAndWaitForReadiness()
        let suspension = TestSuspension()
        topology.readinessSuspension = suspension

        let reconfiguration = Task { @MainActor in
            try await supervisor.applyCaptureEnabled(true)
        }
        await suspension.waitUntilEntered()
        let shutdown = Task { @MainActor in try await supervisor.shutdownAndWait() }
        while topology.stopCalls < 2 { await Task.yield() }
        suspension.resume()
        try await shutdown.value
        await XCTAssertThrowsErrorAsync(try await reconfiguration.value)

        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertEqual(config.captureWrites, [])
        XCTAssertEqual(topology.launchPlans.count, 2)
        XCTAssertFalse(topology.isRunning)
    }

    func test_shutdown_wins_when_initial_reconfiguration_stop_resumes_late() async throws {
        let (supervisor, _, _, config, topology, _) = makeSupervisor()
        topology.readinessResults = [.success(())]
        try await supervisor.startAndWaitForReadiness()
        let suspension = TestSuspension()
        topology.stopSuspensionOnCall = 1
        topology.stopSuspension = suspension

        let reconfiguration = Task { @MainActor in
            try await supervisor.applyCaptureEnabled(true)
        }
        await suspension.waitUntilEntered()
        let shutdown = Task { @MainActor in try await supervisor.shutdownAndWait() }
        while topology.stopCalls < 2 { await Task.yield() }
        try await shutdown.value
        XCTAssertEqual(supervisor.state, .stopped)

        suspension.resume()
        await XCTAssertThrowsErrorAsync(try await reconfiguration.value)
        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertEqual(config.captureWrites, [])
        XCTAssertFalse(topology.isRunning)
    }

    func test_termination_coordinator_replies_after_stopped_and_restart_scheduling() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor()
        topology.readinessResults = [.success(())]
        try await supervisor.startAndWaitForReadiness()
        let restartLauncher = FakeApplicationRestartLauncher()
        restartLauncher.onSchedule = {
            XCTAssertEqual(supervisor.state, .stopped)
            XCTAssertFalse(topology.isRunning)
        }
        var cleanedUp = false
        var replies: [Bool] = []
        let coordinator = ApplicationTerminationCoordinator(
            supervisor: supervisor,
            restartLauncher: restartLauncher,
            cleanup: { cleanedUp = true }
        )

        let allowed = await coordinator.terminate(intent: .restart) {
            XCTAssertEqual(supervisor.state, .stopped)
            XCTAssertTrue(cleanedUp)
            replies.append($0)
        }

        XCTAssertTrue(allowed)
        XCTAssertTrue(coordinator.hasVerifiedShutdown)
        XCTAssertEqual(restartLauncher.scheduleCount, 1)
        XCTAssertEqual(replies, [true])
    }

    func test_termination_coordinator_replies_false_without_restart_or_cleanup_on_failed_stop() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor()
        topology.readinessResults = [.success(())]
        topology.stopResults = [.failure(TestError.partialStop)]
        try await supervisor.startAndWaitForReadiness()
        let restartLauncher = FakeApplicationRestartLauncher()
        var cleanedUp = false
        var replies: [Bool] = []
        let coordinator = ApplicationTerminationCoordinator(
            supervisor: supervisor,
            restartLauncher: restartLauncher,
            cleanup: { cleanedUp = true }
        )

        let allowed = await coordinator.terminate(intent: .restart) {
            replies.append($0)
        }

        XCTAssertFalse(allowed)
        XCTAssertFalse(coordinator.hasVerifiedShutdown)
        XCTAssertEqual(restartLauncher.scheduleCount, 0)
        XCTAssertFalse(cleanedUp)
        XCTAssertEqual(replies, [false])
        guard case .crashed = supervisor.state else {
            return XCTFail("failed stop must remain visible, got \(supervisor.state)")
        }
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

    func test_shutdown_attempts_topology_stop_when_consent_revocation_fails() async throws {
        let consent = FakeCaptureConsentAuthority()
        let (supervisor, _, _, _, topology, _) = makeSupervisor(
            captureConsentAuthority: consent
        )
        topology.readinessResults = [.success(())]
        try await supervisor.startAndWaitForReadiness()
        consent.disableError = TestError.writeFailed

        await XCTAssertThrowsErrorAsync(try await supervisor.shutdownAndWait())

        XCTAssertEqual(topology.stopCalls, 1)
        XCTAssertFalse(topology.isRunning)
        guard case .crashed = supervisor.state else {
            return XCTFail("revocation failure must be visible after shutdown")
        }
    }

    func test_pause_attempts_topology_stop_when_consent_revocation_fails() async throws {
        let consent = FakeCaptureConsentAuthority()
        let (supervisor, _, _, _, topology, _) = makeSupervisor(
            captureEnabled: true,
            captureConsentAuthority: consent
        )
        topology.readinessResults = [.success(())]
        try await supervisor.startAndWaitForReadiness()
        consent.disableError = TestError.writeFailed

        await XCTAssertThrowsErrorAsync(try await supervisor.setPausedAndWait(true))

        XCTAssertEqual(topology.stopCalls, 1)
        XCTAssertFalse(topology.isRunning)
        guard case .crashed = supervisor.state else {
            return XCTFail("revocation failure must be visible after pause")
        }
    }

    func test_capture_change_attempts_topology_stop_when_consent_revocation_fails() async throws {
        let consent = FakeCaptureConsentAuthority()
        let (supervisor, _, _, config, topology, _) = makeSupervisor(
            captureConsentAuthority: consent
        )
        topology.readinessResults = [.success(())]
        try await supervisor.startAndWaitForReadiness()
        consent.disableError = TestError.writeFailed

        await XCTAssertThrowsErrorAsync(try await supervisor.applyCaptureEnabled(true))

        XCTAssertEqual(topology.stopCalls, 1)
        XCTAssertFalse(topology.isRunning)
        XCTAssertEqual(config.captureWrites, [])
        guard case .crashed = supervisor.state else {
            return XCTFail("revocation failure must be visible after capture change")
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

    func test_first_run_can_enable_capture_directly_from_idle() async throws {
        let (supervisor, _, _, config, topology, _) = makeSupervisor()
        topology.readinessResults = [.success(())]

        try await supervisor.applyCaptureEnabled(true)

        XCTAssertEqual(supervisor.state, .running)
        XCTAssertTrue(supervisor.captureEnabled)
        XCTAssertTrue(config.captureEnabled)
        XCTAssertEqual(config.captureWrites, [true])
        XCTAssertEqual(topology.launchPlans.count, 1)
        XCTAssertTrue(topology.launchPlans[0].helperArguments.contains("--capture"))
        XCTAssertEqual(topology.launchPlans[0].agentEnvironment["MCI_CAPTURE_ENABLED"], "1")
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

    func test_explicit_stop_helper_exit_persists_off_revokes_consent_and_never_retries() async throws {
        let consent = FakeCaptureConsentAuthority()
        let (supervisor, _, _, config, topology, _) = makeSupervisor(
            captureEnabled: true, captureConsentAuthority: consent
        )
        try await supervisor.startAndWaitForReadiness()
        XCTAssertNotNil(consent.enabledGenerationID)

        topology.fireUnexpectedExit(forLaunchAt: 0, label: "helper", status: 82)
        await waitForExplicitStop(supervisor)
        try await Task.sleep(for: .milliseconds(1150))

        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertFalse(config.captureEnabled)
        XCTAssertEqual(config.captureWrites, [false])
        XCTAssertNil(consent.enabledGenerationID)
        XCTAssertNil(supervisor.safariInboxStats)
        XCTAssertFalse(topology.isRunning)
        XCTAssertEqual(topology.launchPlans.count, 1)
        XCTAssertEqual(topology.stopCalls, 1)
        XCTAssertEqual(supervisor.state, .stopped)

        try await supervisor.applyCaptureEnabled(true)
        XCTAssertTrue(supervisor.captureEnabled)
        XCTAssertEqual(config.captureWrites, [false, true])
        XCTAssertEqual(consent.enabledGenerationID, topology.generations.last?.id)
        try await supervisor.shutdownAndWait()
    }

    func test_explicit_stop_cancels_retry_already_scheduled_by_agent_exit() async throws {
        let (supervisor, _, _, config, topology, _) = makeSupervisor(captureEnabled: true)
        try await supervisor.startAndWaitForReadiness()

        topology.fireUnexpectedExit(forLaunchAt: 0, label: "agent", status: 1)
        topology.fireUnexpectedExit(forLaunchAt: 0, label: "helper", status: 82)
        await waitForExplicitStop(supervisor)
        try await Task.sleep(for: .milliseconds(1150))

        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertEqual(config.captureWrites, [false])
        XCTAssertEqual(topology.launchPlans.count, 1)
        XCTAssertFalse(topology.isRunning)
        try await supervisor.shutdownAndWait()
    }

    func test_agent_exit82_and_helper_exit81_keep_generic_retry_behavior() async throws {
        for (label, status): (String, Int32) in [("agent", 82), ("helper", 81)] {
            let (supervisor, _, _, config, topology, _) = makeSupervisor(captureEnabled: true)
            try await supervisor.startAndWaitForReadiness()

            topology.fireUnexpectedExit(forLaunchAt: 0, label: label, status: status)
            let deadline = Date().addingTimeInterval(3)
            while topology.launchPlans.count < 2 && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }

            XCTAssertEqual(topology.launchPlans.count, 2)
            XCTAssertTrue(supervisor.captureEnabled)
            XCTAssertTrue(config.captureEnabled)
            XCTAssertEqual(config.captureWrites, [])
            XCTAssertTrue(topology.launchPlans.last?.helperArguments.contains("--capture") == true)
            try await supervisor.shutdownAndWait()
        }
    }

    func test_retry_continues_when_replacement_helper_cannot_start() async throws {
        let (supervisor, _, _, config, topology, _) = makeSupervisor(captureEnabled: true)
        try await supervisor.startAndWaitForReadiness()
        topology.readinessResults = [.failure(SupervisorProcessRuntimeError.helperExited(79)), .success(())]
        topology.fireUnexpectedExit(forLaunchAt: 0, label: "helper", status: 81)
        let deadline = Date().addingTimeInterval(5)
        while topology.launchPlans.count < 3 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(topology.launchPlans.count, 3)
        XCTAssertEqual(supervisor.state, .running)
        XCTAssertTrue(supervisor.captureEnabled)
        XCTAssertEqual(config.captureWrites, [])
        try await supervisor.shutdownAndWait()
    }

    func test_workspace_wake_recovers_failed_enabled_capture_without_changing_consent() async throws {
        let consent = FakeCaptureConsentAuthority()
        let (supervisor, _, _, config, topology, _) = makeSupervisor(
            captureEnabled: true, captureConsentAuthority: consent
        )
        topology.readinessResults = [.failure(SupervisorProcessRuntimeError.helperExited(79))]
        do { try await supervisor.startAndWaitForReadiness(); XCTFail("fixture must fail startup") }
        catch {}
        await supervisor.recoverAfterWorkspaceWake()
        XCTAssertEqual(supervisor.state, .running)
        XCTAssertEqual(topology.launchPlans.count, 2)
        XCTAssertEqual(config.captureWrites, [])
        XCTAssertEqual(consent.enabledGenerationID, topology.generations.last?.id)
        try await supervisor.shutdownAndWait()
    }

    func test_workspace_wake_never_enables_disabled_capture() async throws {
        let (supervisor, _, _, config, topology, _) = makeSupervisor()
        topology.readinessResults = [.failure(SupervisorProcessRuntimeError.helperExited(79))]
        do { try await supervisor.startAndWaitForReadiness(); XCTFail("fixture must fail startup") }
        catch {}
        await supervisor.recoverAfterWorkspaceWake()
        XCTAssertEqual(topology.launchPlans.count, 1)
        XCTAssertFalse(config.captureEnabled)
        XCTAssertFalse(supervisor.captureEnabled)
        try await supervisor.shutdownAndWait()
    }

    func test_workspace_wake_never_overrides_explicit_stop_even_when_disk_write_failed() async throws {
        let (supervisor, _, _, config, topology, _) = makeSupervisor(captureEnabled: true)
        try await supervisor.startAndWaitForReadiness()
        config.captureWriteError = TestError.writeFailed
        topology.fireUnexpectedExit(forLaunchAt: 0, status: 82)
        await waitForExplicitStop(supervisor)
        await supervisor.recoverAfterWorkspaceWake()
        XCTAssertTrue(config.captureEnabled, "the failed write leaves the old disk value")
        XCTAssertFalse(supervisor.captureEnabled, "session intent must still win")
        XCTAssertEqual(topology.launchPlans.count, 1)
        XCTAssertFalse(topology.isRunning)
        try await supervisor.shutdownAndWait()
    }

    func test_workspace_wake_does_not_override_pause_or_duplicate_a_running_session() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor(captureEnabled: true)
        try await supervisor.startAndWaitForReadiness()
        await supervisor.recoverAfterWorkspaceWake()
        XCTAssertEqual(topology.launchPlans.count, 1)
        try await supervisor.setPausedAndWait(true)
        await supervisor.recoverAfterWorkspaceWake()
        XCTAssertEqual(supervisor.state, .paused)
        XCTAssertEqual(topology.launchPlans.count, 1)
        XCTAssertFalse(topology.isRunning)
        try await supervisor.shutdownAndWait()
    }

    func test_workspace_wake_coalesces_while_readiness_is_pending() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor(captureEnabled: true)
        topology.readinessResults = [.failure(SupervisorProcessRuntimeError.helperExited(79))]
        do { try await supervisor.startAndWaitForReadiness(); XCTFail("fixture must fail startup") }
        catch {}
        let suspension = TestSuspension()
        topology.readinessSuspension = suspension
        let first = Task { await supervisor.recoverAfterWorkspaceWake() }
        await suspension.waitUntilEntered()
        await supervisor.recoverAfterWorkspaceWake()
        XCTAssertEqual(topology.launchPlans.count, 2)
        suspension.resume()
        await first.value
        XCTAssertEqual(supervisor.state, .running)
        try await supervisor.shutdownAndWait()
    }

    func test_workspace_wake_keeps_revoked_permission_visible_without_relaunch() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor(captureEnabled: true)
        topology.readinessResults = [.failure(SupervisorProcessRuntimeError.helperExited(79))]
        do { try await supervisor.startAndWaitForReadiness(); XCTFail("fixture must fail startup") }
        catch {}
        supervisor.tccRevokedSurface = .screenRecording
        await supervisor.recoverAfterWorkspaceWake()
        XCTAssertEqual(topology.launchPlans.count, 1)
        XCTAssertEqual(supervisor.tccRevokedSurface, .screenRecording)
        try await supervisor.shutdownAndWait()
    }

    func test_pause_during_wake_cleanup_prevents_a_new_capture_launch() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor(captureEnabled: true)
        topology.readinessResults = [.failure(SupervisorProcessRuntimeError.helperExited(79))]
        do { try await supervisor.startAndWaitForReadiness(); XCTFail("fixture must fail startup") }
        catch {}
        let suspension = TestSuspension()
        topology.stopSuspensionOnCall = topology.stopCalls + 1
        topology.stopSuspension = suspension
        let recovery = Task { await supervisor.recoverAfterWorkspaceWake() }
        await suspension.waitUntilEntered()
        try await supervisor.setPausedAndWait(true)
        suspension.resume()
        await recovery.value
        XCTAssertEqual(supervisor.state, .paused)
        XCTAssertEqual(topology.launchPlans.count, 1)
        XCTAssertFalse(topology.isRunning)
        try await supervisor.shutdownAndWait()
    }

    func test_revocation_during_wake_cleanup_prevents_launch_and_consent() async throws {
        let consent = FakeCaptureConsentAuthority()
        let (supervisor, _, _, config, topology, _) = makeSupervisor(
            captureEnabled: true, captureConsentAuthority: consent
        )
        topology.readinessResults = [.failure(SupervisorProcessRuntimeError.helperExited(79))]
        await XCTAssertThrowsErrorAsync(try await supervisor.startAndWaitForReadiness())
        let suspension = TestSuspension()
        topology.stopSuspensionOnCall = topology.stopCalls + 1
        topology.stopSuspension = suspension
        let recovery = Task { await supervisor.recoverAfterWorkspaceWake() }
        await suspension.waitUntilEntered()
        supervisor.tccRevokedSurface = .screenRecording
        suspension.resume()
        await recovery.value
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertEqual(topology.launchPlans.count, 1)
        XCTAssertTrue(consent.enabledGenerations.isEmpty)
        XCTAssertFalse(topology.isRunning)
        XCTAssertEqual(config.captureWrites, [])
        try await supervisor.shutdownAndWait()
    }

    func test_revocation_during_replacement_readiness_prevents_consent_and_retries() async throws {
        let consent = FakeCaptureConsentAuthority()
        let (supervisor, _, _, _, topology, _) = makeSupervisor(
            captureEnabled: true, captureConsentAuthority: consent
        )
        try await supervisor.startAndWaitForReadiness()
        let suspension = TestSuspension()
        topology.readinessSuspension = suspension
        topology.fireUnexpectedExit(forLaunchAt: 0, status: 81)
        await suspension.waitUntilEntered()
        supervisor.tccRevokedSurface = .accessibility
        suspension.resume()
        try await Task.sleep(for: .milliseconds(2150))
        XCTAssertEqual(topology.launchPlans.count, 2)
        XCTAssertEqual(consent.enabledGenerations.count, 1)
        XCTAssertNil(consent.enabledGenerationID)
        XCTAssertFalse(topology.isRunning)
        try await supervisor.shutdownAndWait()
    }

    func test_revocation_during_retry_backoff_prevents_relaunch() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor(captureEnabled: true)
        try await supervisor.startAndWaitForReadiness()
        topology.fireUnexpectedExit(forLaunchAt: 0, status: 81)
        supervisor.tccRevokedSurface = .screenRecording
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertEqual(topology.launchPlans.count, 1)
        try await supervisor.shutdownAndWait()
    }

    func test_failed_quit_is_not_eligible_for_wake_recovery() async throws {
        let consent = FakeCaptureConsentAuthority()
        let (supervisor, _, _, config, topology, _) = makeSupervisor(
            captureEnabled: true, captureConsentAuthority: consent
        )
        try await supervisor.startAndWaitForReadiness()
        topology.stopResults = [.failure(TestError.partialStop)]
        await XCTAssertThrowsErrorAsync(try await supervisor.shutdownAndWait())
        await supervisor.recoverAfterWorkspaceWake()
        supervisor.start()
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertEqual(topology.launchPlans.count, 1)
        XCTAssertNil(consent.enabledGenerationID)
        XCTAssertEqual(config.captureWrites, [])
        guard case .crashed = supervisor.state else {
            return XCTFail("failed Quit must stay visible until termination is retried")
        }
        try await supervisor.shutdownAndWait()
        XCTAssertEqual(supervisor.state, .stopped)
    }

    func test_revoked_child_exit_stays_failed_until_restoration_and_wake() async throws {
        let (supervisor, _, _, config, topology, _) = makeSupervisor(captureEnabled: true)
        try await supervisor.startAndWaitForReadiness()
        supervisor.tccRevokedSurface = .screenRecording
        topology.fireUnexpectedExit(forLaunchAt: 0, label: "agent", status: 9)
        guard case .crashed = supervisor.state else {
            return XCTFail("permission loss must not hide a dead child")
        }
        await supervisor.recoverAfterWorkspaceWake()
        XCTAssertEqual(topology.launchPlans.count, 1)
        supervisor.tccRevokedSurface = nil
        await supervisor.recoverAfterWorkspaceWake()
        XCTAssertEqual(topology.launchPlans.count, 2)
        XCTAssertEqual(supervisor.state, .running)
        XCTAssertEqual(config.captureWrites, [])
        try await supervisor.shutdownAndWait()
    }

    func test_pause_succeeds_while_permission_is_revoked() async throws {
        let consent = FakeCaptureConsentAuthority()
        let (supervisor, _, _, _, topology, _) = makeSupervisor(
            captureEnabled: true, captureConsentAuthority: consent
        )
        try await supervisor.startAndWaitForReadiness()
        supervisor.tccRevokedSurface = .accessibility
        try await supervisor.setPausedAndWait(true)
        XCTAssertEqual(supervisor.state, .paused)
        XCTAssertFalse(topology.isRunning)
        XCTAssertNil(consent.enabledGenerationID)
        await supervisor.recoverAfterWorkspaceWake()
        XCTAssertEqual(topology.launchPlans.count, 1)
        supervisor.tccRevokedSurface = nil
        try await supervisor.setPausedAndWait(false)
        XCTAssertEqual(supervisor.state, .running)
        try await supervisor.shutdownAndWait()
    }

    func test_initial_start_cannot_launch_capture_with_known_revocation() async throws {
        let (supervisor, _, _, _, topology, _) = makeSupervisor(captureEnabled: true)
        supervisor.tccRevokedSurface = .screenRecording
        await XCTAssertThrowsErrorAsync(try await supervisor.startAndWaitForReadiness())
        XCTAssertTrue(topology.launchPlans.isEmpty)
        try await supervisor.shutdownAndWait()
    }

    func test_explicit_stop_during_replacement_start_cancels_all_further_retries() async throws {
        let (supervisor, _, _, config, topology, _) = makeSupervisor(captureEnabled: true)
        try await supervisor.startAndWaitForReadiness()
        topology.readinessResults = [.failure(SupervisorProcessRuntimeError.helperExited(82))]
        topology.fireUnexpectedExit(forLaunchAt: 0, status: 81)
        let deadline = Date().addingTimeInterval(3)
        while supervisor.captureEnabled && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await waitForExplicitStop(supervisor)
        try await Task.sleep(for: .milliseconds(2150))
        XCTAssertEqual(topology.launchPlans.count, 2)
        XCTAssertEqual(config.captureWrites, [false])
        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertFalse(topology.isRunning)
        try await supervisor.shutdownAndWait()
    }

    func test_explicit_stop_from_retired_generation_cannot_stop_current_capture() async throws {
        let consent = FakeCaptureConsentAuthority()
        let (supervisor, _, _, config, topology, _) = makeSupervisor(
            captureEnabled: true, captureConsentAuthority: consent
        )
        try await supervisor.startAndWaitForReadiness()
        try await supervisor.setPausedAndWait(true)
        try await supervisor.setPausedAndWait(false)

        topology.fireUnexpectedExit(forLaunchAt: 0, status: 82)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(supervisor.state, .running)
        XCTAssertTrue(supervisor.captureEnabled)
        XCTAssertTrue(topology.isRunning)
        XCTAssertEqual(topology.stopCalls, 1)
        XCTAssertEqual(config.captureWrites, [])
        XCTAssertEqual(consent.enabledGenerationID, topology.generations[1].id)
        try await supervisor.shutdownAndWait()
    }

    func test_explicit_stop_during_start_readiness_prevents_commit() async throws {
        let consent = FakeCaptureConsentAuthority()
        let (supervisor, _, _, config, topology, _) = makeSupervisor(
            captureEnabled: true, captureConsentAuthority: consent
        )
        let readiness = TestSuspension()
        topology.readinessSuspension = readiness
        let startup = Task { try await supervisor.startAndWaitForReadiness() }
        await readiness.waitUntilEntered()

        topology.fireUnexpectedExit(forLaunchAt: 0, status: 82)
        await waitForExplicitStop(supervisor)
        readiness.resume()
        await XCTAssertThrowsErrorAsync(try await startup.value)

        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertEqual(config.captureWrites, [false])
        XCTAssertFalse(topology.isRunning)
        XCTAssertEqual(consent.enabledGenerations, [])
        try await supervisor.shutdownAndWait()
    }

    func test_explicit_stop_during_enable_readiness_prevents_commit_or_rollback() async throws {
        let consent = FakeCaptureConsentAuthority()
        let (supervisor, _, _, config, topology, _) = makeSupervisor(
            captureConsentAuthority: consent
        )
        try await supervisor.startAndWaitForReadiness()
        let readiness = TestSuspension()
        topology.readinessSuspension = readiness
        let enabling = Task { try await supervisor.applyCaptureEnabled(true) }
        await readiness.waitUntilEntered()

        topology.fireUnexpectedExit(forLaunchAt: 0, status: 82)
        XCTAssertEqual(config.captureWrites, [])
        topology.fireUnexpectedExit(forLaunchAt: 1, status: 82)
        await waitForExplicitStop(supervisor)
        topology.readinessSuspension = nil
        readiness.resume()
        await XCTAssertThrowsErrorAsync(try await enabling.value)

        XCTAssertEqual(supervisor.state, .stopped)
        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertEqual(config.captureWrites, [false])
        XCTAssertEqual(topology.launchPlans.count, 2)
        XCTAssertFalse(topology.isRunning)
        XCTAssertEqual(consent.enabledGenerations, [])
        try await supervisor.shutdownAndWait()
    }

    func test_explicit_stop_reported_by_readiness_also_persists_off() async throws {
        let (supervisor, _, _, config, topology, _) = makeSupervisor(captureEnabled: true)
        topology.readinessResults = [.failure(SupervisorProcessRuntimeError.helperExited(82))]

        await XCTAssertThrowsErrorAsync(try await supervisor.startAndWaitForReadiness())
        await waitForExplicitStop(supervisor)

        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertEqual(config.captureWrites, [false])
        XCTAssertFalse(topology.isRunning)
        XCTAssertEqual(topology.launchPlans.count, 1)
        try await supervisor.shutdownAndWait()
    }

    func test_disable_persistence_failure_stays_off_stops_capture_and_blocks_implicit_start() async throws {
        let consent = FakeCaptureConsentAuthority()
        let (supervisor, _, _, config, topology, _) = makeSupervisor(
            captureEnabled: true, captureConsentAuthority: consent
        )
        try await supervisor.startAndWaitForReadiness()
        config.captureWriteError = TestError.writeFailed

        await XCTAssertThrowsErrorAsync(try await supervisor.applyCaptureEnabled(false))

        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertTrue(config.captureEnabled, "the injected write failure leaves disk unchanged")
        XCTAssertEqual(config.captureWrites, [false])
        XCTAssertFalse(topology.isRunning)
        XCTAssertNil(consent.enabledGenerationID)
        XCTAssertNil(supervisor.safariInboxStats)
        XCTAssertEqual(topology.launchPlans.count, 1)
        assertVisibleError(supervisor, containing: "writeFailed")

        config.captureWriteError = nil
        await XCTAssertThrowsErrorAsync(try await supervisor.startAndWaitForReadiness())
        supervisor.start()
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertEqual(topology.launchPlans.count, 1)
        XCTAssertEqual(config.captureWrites, [false], "no silent persistence retry")
        assertVisibleError(supervisor, containing: "writeFailed")

        try await supervisor.applyCaptureEnabled(true)
        XCTAssertTrue(supervisor.captureEnabled)
        XCTAssertEqual(config.captureWrites, [false, true])
        try await supervisor.shutdownAndWait()
    }

    func test_disable_teardown_failure_persists_off_without_rollback_or_retry() async throws {
        let consent = FakeCaptureConsentAuthority()
        let (supervisor, _, _, config, topology, _) = makeSupervisor(
            captureEnabled: true, captureConsentAuthority: consent
        )
        try await supervisor.startAndWaitForReadiness()
        topology.stopResults = [.failure(TestError.partialStop)]

        await XCTAssertThrowsErrorAsync(try await supervisor.applyCaptureEnabled(false))
        try await Task.sleep(for: .milliseconds(1150))

        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertFalse(config.captureEnabled)
        XCTAssertEqual(config.captureWrites, [false])
        XCTAssertNil(consent.enabledGenerationID)
        XCTAssertNil(supervisor.safariInboxStats)
        XCTAssertEqual(topology.stopCalls, 1)
        XCTAssertEqual(topology.launchPlans.count, 1)
        assertVisibleError(supervisor, containing: "partialStop")
        try await supervisor.shutdownAndWait()
    }

    func test_explicit_stop_preserves_both_write_and_teardown_errors_without_retry() async throws {
        let consent = FakeCaptureConsentAuthority()
        let (supervisor, _, _, config, topology, _) = makeSupervisor(
            captureEnabled: true, captureConsentAuthority: consent
        )
        try await supervisor.startAndWaitForReadiness()
        config.captureWriteError = TestError.writeFailed
        topology.stopResults = [.failure(TestError.partialStop)]

        topology.fireUnexpectedExit(forLaunchAt: 0, status: 82)
        await waitForExplicitStop(supervisor)
        try await Task.sleep(for: .milliseconds(1150))

        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertEqual(config.captureWrites, [false])
        XCTAssertNil(consent.enabledGenerationID)
        XCTAssertEqual(topology.stopCalls, 1)
        XCTAssertEqual(topology.launchPlans.count, 1)
        assertVisibleError(supervisor, containing: "writeFailed")
        assertVisibleError(supervisor, containing: "partialStop")
        try await supervisor.shutdownAndWait()
    }

    func test_disable_consent_failure_still_persists_off_and_stops_topology() async throws {
        let consent = FakeCaptureConsentAuthority()
        let (supervisor, _, _, config, topology, _) = makeSupervisor(
            captureEnabled: true, captureConsentAuthority: consent
        )
        try await supervisor.startAndWaitForReadiness()
        consent.disableError = TestError.denied

        await XCTAssertThrowsErrorAsync(try await supervisor.applyCaptureEnabled(false))

        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertEqual(config.captureWrites, [false])
        XCTAssertFalse(topology.isRunning)
        XCTAssertEqual(topology.stopCalls, 1)
        assertVisibleError(supervisor, containing: "denied")
        consent.disableError = nil
        try await supervisor.shutdownAndWait()
    }

    func test_disable_interrupts_enable_even_before_capture_enabled_is_published() async throws {
        let (supervisor, _, _, config, topology, _) = makeSupervisor()
        try await supervisor.startAndWaitForReadiness()
        let readiness = TestSuspension()
        topology.readinessSuspension = readiness
        let enabling = Task { try await supervisor.applyCaptureEnabled(true) }
        await readiness.waitUntilEntered()
        XCTAssertFalse(supervisor.captureEnabled)

        try await supervisor.applyCaptureEnabled(false)
        topology.readinessSuspension = nil
        readiness.resume()
        await XCTAssertThrowsErrorAsync(try await enabling.value)

        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertEqual(config.captureWrites, [false])
        XCTAssertFalse(topology.isRunning)
        XCTAssertEqual(topology.launchPlans.count, 2)
        try await supervisor.shutdownAndWait()
    }

    func test_disable_during_key_preparation_prevents_late_capture_launch() async throws {
        let (supervisor, _, _, config, topology, custody) = makeSupervisor(captureEnabled: true)
        let preparation = TestSuspension()
        custody.suspension = preparation
        let startup = Task { try await supervisor.startAndWaitForReadiness() }
        await preparation.waitUntilEntered()

        await disableAllowingFailure(supervisor)
        preparation.resume()
        await XCTAssertThrowsErrorAsync(try await startup.value)

        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertEqual(config.captureWrites, [false])
        XCTAssertEqual(topology.launchPlans.count, 0)
        XCTAssertEqual(supervisor.state, .stopped)
        try await supervisor.shutdownAndWait()
    }

    func test_disable_cancels_pending_generic_retry() async throws {
        let (supervisor, _, _, config, topology, _) = makeSupervisor(captureEnabled: true)
        try await supervisor.startAndWaitForReadiness()
        topology.fireUnexpectedExit(forLaunchAt: 0, status: 81)

        try await supervisor.applyCaptureEnabled(false)
        try await Task.sleep(for: .milliseconds(1150))

        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertEqual(config.captureWrites, [false])
        XCTAssertEqual(topology.launchPlans.count, 1)
        XCTAssertFalse(topology.isRunning)
        try await supervisor.shutdownAndWait()
    }

    func test_disable_while_enable_stop_is_blocked_requires_old_transition_to_unwind() async throws {
        let (supervisor, _, _, config, topology, _) = makeSupervisor()
        try await supervisor.startAndWaitForReadiness()
        let stopping = TestSuspension()
        topology.stopSuspensionOnCall = 1
        topology.stopSuspension = stopping
        let enabling = Task { try await supervisor.applyCaptureEnabled(true) }
        await stopping.waitUntilEntered()

        try await supervisor.applyCaptureEnabled(false)
        await XCTAssertThrowsErrorAsync(try await supervisor.applyCaptureEnabled(true))
        stopping.resume()
        await XCTAssertThrowsErrorAsync(try await enabling.value)
        XCTAssertFalse(supervisor.captureEnabled)
        XCTAssertEqual(config.captureWrites, [false])
        XCTAssertEqual(topology.launchPlans.count, 1)

        try await supervisor.applyCaptureEnabled(true)
        XCTAssertTrue(supervisor.captureEnabled)
        XCTAssertTrue(topology.isRunning)
        XCTAssertEqual(topology.launchPlans.count, 2)
        try await supervisor.shutdownAndWait()
    }

    private func waitForExplicitStop(_ supervisor: ProcessSupervisor) async {
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            if !supervisor.captureEnabled {
                if supervisor.state == .stopped { return }
                if case .crashed = supervisor.state { return }
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func disableAllowingFailure(_ supervisor: ProcessSupervisor) async {
        do {
            try await supervisor.applyCaptureEnabled(false)
        } catch {
            XCTFail("disable must supersede an in-flight start: \(error)")
        }
    }

    private func assertVisibleError(
        _ supervisor: ProcessSupervisor, containing text: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .crashed(let reason) = supervisor.state else {
            return XCTFail("expected visible error, got \(supervisor.state)", file: file, line: line)
        }
        XCTAssertTrue(reason.contains(text), "\(reason) must contain \(text)", file: file, line: line)
        guard case .error = supervisor.menuBarStatus else {
            return XCTFail("stop failures must remain visible in the menu", file: file, line: line)
        }
    }

    func test_health_snapshot_display_does_not_claim_saved_memory() {
        let snapshot = HealthSnapshot(
            framesDelivered: 77,
            framesSuppressed: 5,
            lastCaptureTs: Date().addingTimeInterval(-60),
            lastUpdated: Date()
        )
        XCTAssertTrue(snapshot.displayText.contains("77 delivered"))
        XCTAssertTrue(snapshot.displayText.contains("5 suppressed"))
        XCTAssertTrue(snapshot.displayText.contains("not saved counts"))
        XCTAssertFalse(snapshot.displayText.contains("events captured"))
    }

    func test_has_onboarding_reflects_locator() {
        let (supervisor, locator, _, _, _, _) = makeSupervisor()
        XCTAssertFalse(supervisor.hasOnboarding)
        locator.onboardingURL = URL(fileURLWithPath: "/bundle/onboarding")
        XCTAssertTrue(supervisor.hasOnboarding)
    }

    func test_onboarding_environment_routes_to_real_allowlist_editor() {
        let environment = ProcessSupervisorLaunchPlan.onboardingEnvironment(
            baseEnvironment: [
                "MCI_DB_KEY_HEX": String(repeating: "ef", count: 32),
                "UNRELATED": "kept",
            ],
            dbPath: URL(fileURLWithPath: "/tmp/mci.sqlite"),
            keyReference: .defaultDatabaseKey,
            initialStep: "allowlist"
        )

        XCTAssertEqual(environment["MCI_ONBOARDING_STEP"], "allowlist")
        XCTAssertEqual(environment["UNRELATED"], "kept")
        XCTAssertNil(environment["MCI_DB_KEY_HEX"])
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T: Sendable>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
