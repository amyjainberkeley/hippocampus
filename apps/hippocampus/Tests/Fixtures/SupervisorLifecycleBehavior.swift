import Darwin
import Foundation
import HippocampusKit

@main
struct SupervisorLifecycleBehavior {
    @MainActor
    static func main() async throws {
        try await proveNormalQuitComposition()
        try await proveResistantRestartComposition()
        try await proveShutdownCancelsKeyPreparation()
        try await proveShutdownCancelsReadiness()
        try await proveShutdownCancelsCaptureReconfiguration()
        try await proveShutdownWinsBlockedInitialReconfigurationStop()
    }

    @MainActor
    private static func proveNormalQuitComposition() async throws {
        let topology = RealProcessTopology(resistsTermination: false)
        let supervisor = makeSupervisor(topology: topology)
        try await supervisor.startAndWaitForReadiness()
        let launcher = RecordingRestartLauncher(supervisor: supervisor, topology: topology)
        let coordinator = ApplicationTerminationCoordinator(
            supervisor: supervisor,
            restartLauncher: launcher,
            shutdownTimeout: 1,
            cleanup: {}
        )
        var replies: [Bool] = []

        await coordinator.terminate(intent: .quit) { replies.append($0) }

        precondition(supervisor.state == .stopped)
        precondition(replies == [true])
        precondition(launcher.scheduleCount == 0)
        precondition(topology.trackedPIDs.allSatisfy { !SupervisorProcessShutdown.pidIsAlive($0) })
    }

    @MainActor
    private static func proveResistantRestartComposition() async throws {
        let topology = RealProcessTopology(resistsTermination: true)
        let supervisor = makeSupervisor(topology: topology)
        try await supervisor.startAndWaitForReadiness()
        let launcher = RecordingRestartLauncher(supervisor: supervisor, topology: topology)
        let coordinator = ApplicationTerminationCoordinator(
            supervisor: supervisor,
            restartLauncher: launcher,
            shutdownTimeout: 0.1,
            cleanup: {}
        )
        var replies: [Bool] = []

        await coordinator.terminate(intent: .restart) { replies.append($0) }

        precondition(supervisor.state == .stopped)
        precondition(replies == [true])
        precondition(launcher.scheduleCount == 1)
        precondition(launcher.observedStoppedBeforeScheduling)
        precondition(launcher.observedDeadChildrenBeforeScheduling)
        precondition(topology.trackedPIDs.allSatisfy { !SupervisorProcessShutdown.pidIsAlive($0) })
    }

    @MainActor
    private static func makeSupervisor(topology: RealProcessTopology) -> ProcessSupervisor {
        ProcessSupervisor(
            locator: FixtureBinaryLocator(),
            keyStore: FixtureKeyStore(),
            runtimeConfig: FixtureRuntimeConfig(),
            topology: topology,
            keyCustodyPreparer: FixtureKeyCustodyPreparer(),
            readinessTimeout: 1
        )
    }

    @MainActor
    private static func proveShutdownCancelsKeyPreparation() async throws {
        let preparationGate = FixtureSuspension()
        let topology = SuspendingLifecycleTopology()
        let supervisor = makeSupervisor(
            topology: topology,
            keyCustodyPreparer: SuspendingKeyCustodyPreparer(gate: preparationGate)
        )
        let startup = Task { @MainActor in try await supervisor.startAndWaitForReadiness() }
        await preparationGate.waitUntilEntered()
        let shutdown = Task { @MainActor in try await supervisor.shutdownAndWait() }
        await topology.waitUntilStopped()
        preparationGate.resume()
        try await shutdown.value
        _ = try? await startup.value

        precondition(supervisor.state == .stopped)
        precondition(topology.launchCount == 0)
        precondition(!topology.isRunning)
    }

    @MainActor
    private static func proveShutdownCancelsReadiness() async throws {
        let readinessGate = FixtureSuspension()
        let topology = SuspendingLifecycleTopology(readinessGate: readinessGate)
        let supervisor = makeSupervisor(
            topology: topology,
            keyCustodyPreparer: FixtureKeyCustodyPreparer()
        )
        let startup = Task { @MainActor in try await supervisor.startAndWaitForReadiness() }
        await readinessGate.waitUntilEntered()
        let shutdown = Task { @MainActor in try await supervisor.shutdownAndWait() }
        await topology.waitUntilStopped()
        readinessGate.resume()
        try await shutdown.value
        _ = try? await startup.value

        precondition(supervisor.state == .stopped)
        precondition(topology.launchCount == 1)
        precondition(!topology.isRunning)
    }

    @MainActor
    private static func proveShutdownCancelsCaptureReconfiguration() async throws {
        let readinessGate = FixtureSuspension()
        let topology = SuspendingLifecycleTopology()
        let supervisor = makeSupervisor(
            topology: topology,
            keyCustodyPreparer: FixtureKeyCustodyPreparer()
        )
        try await supervisor.startAndWaitForReadiness()
        topology.suspendNextReadiness(on: readinessGate)

        let reconfiguration = Task { @MainActor in
            try await supervisor.applyCaptureEnabled(true)
        }
        await readinessGate.waitUntilEntered()
        let shutdown = Task { @MainActor in try await supervisor.shutdownAndWait() }
        await topology.waitUntilStopped(minimumCount: 2)
        readinessGate.resume()
        try await shutdown.value
        _ = try? await reconfiguration.value

        precondition(supervisor.state == .stopped)
        precondition(!supervisor.captureEnabled)
        precondition(topology.launchCount == 2)
        precondition(!topology.isRunning)
    }

    @MainActor
    private static func proveShutdownWinsBlockedInitialReconfigurationStop() async throws {
        let stopGate = FixtureSuspension()
        let topology = SuspendingLifecycleTopology()
        let supervisor = makeSupervisor(
            topology: topology,
            keyCustodyPreparer: FixtureKeyCustodyPreparer()
        )
        try await supervisor.startAndWaitForReadiness()
        topology.suspendStop(onCall: 1, at: stopGate)

        let reconfiguration = Task { @MainActor in
            try await supervisor.applyCaptureEnabled(true)
        }
        await stopGate.waitUntilEntered()
        let shutdown = Task { @MainActor in try await supervisor.shutdownAndWait() }
        await topology.waitUntilStopped(minimumCount: 2)
        try await shutdown.value
        precondition(supervisor.state == .stopped)

        stopGate.resume()
        _ = try? await reconfiguration.value
        precondition(supervisor.state == .stopped)
        precondition(!topology.isRunning)
    }

    @MainActor
    private static func makeSupervisor(
        topology: any SupervisorTopologyControlling,
        keyCustodyPreparer: any KeyCustodyPreparing
    ) -> ProcessSupervisor {
        ProcessSupervisor(
            locator: FixtureBinaryLocator(),
            keyStore: FixtureKeyStore(),
            runtimeConfig: FixtureRuntimeConfig(),
            topology: topology,
            keyCustodyPreparer: keyCustodyPreparer,
            readinessTimeout: 1
        )
    }
}

private struct FixtureBinaryLocator: BinaryLocator {
    func helperPath() -> URL? { URL(fileURLWithPath: "/bin/sh") }
    func agentPath() -> URL? { URL(fileURLWithPath: "/bin/sh") }
    func recallUIPath() -> URL? { nil }
    func onboardingPath() -> URL? { nil }
    func brainCLIPath() -> URL? { nil }
    func knownSafeAppsPath() -> URL? { nil }
}

private final class FixtureKeyStore: KeyStore, @unchecked Sendable {
    func readKey() throws -> String { String(repeating: "ab", count: 32) }
    func writeKey(_ hex: String) throws { _ = hex }
}

private struct FixtureRuntimeConfig: RuntimeConfiguring {
    var crashReportOptedIn: Bool { false }
    var captureEnabled: Bool { false }
    func setCrashReportOptedIn(_ value: Bool) throws { _ = value }
    func setCaptureEnabled(_ value: Bool) throws { _ = value }
}

@MainActor
private final class FixtureKeyCustodyPreparer: KeyCustodyPreparing {
    func prepare(
        agentURL: URL,
        databaseURL: URL,
        keyReference: KeychainKeyReference
    ) async throws {
        _ = (agentURL, databaseURL, keyReference)
    }
}

@MainActor
private final class FixtureSuspension {
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
private final class SuspendingKeyCustodyPreparer: KeyCustodyPreparing {
    private let gate: FixtureSuspension

    init(gate: FixtureSuspension) { self.gate = gate }

    func prepare(
        agentURL: URL,
        databaseURL: URL,
        keyReference: KeychainKeyReference
    ) async throws {
        _ = (agentURL, databaseURL, keyReference)
        await gate.suspend()
    }
}

@MainActor
private final class SuspendingLifecycleTopology: SupervisorTopologyControlling {
    private var readinessGate: FixtureSuspension?
    private var blockedStopCall: Int?
    private var stopGate: FixtureSuspension?
    private(set) var isRunning = false
    private(set) var launchCount = 0
    private(set) var stopCount = 0

    init(readinessGate: FixtureSuspension? = nil) {
        self.readinessGate = readinessGate
    }

    func suspendNextReadiness(on gate: FixtureSuspension) {
        readinessGate = gate
    }

    func suspendStop(onCall call: Int, at gate: FixtureSuspension) {
        blockedStopCall = call
        stopGate = gate
    }

    func launch(
        plan: ProcessSupervisorLaunchPlan,
        generation: SupervisorProcessGeneration,
        onUnexpectedExit: @escaping @MainActor @Sendable (String, Int32) -> Void
    ) async throws {
        _ = (plan, generation, onUnexpectedExit)
        launchCount += 1
        isRunning = true
    }

    func waitForReadiness(
        generation: SupervisorProcessGeneration,
        timeout: TimeInterval
    ) async throws {
        _ = (generation, timeout)
        if let readinessGate {
            self.readinessGate = nil
            await readinessGate.suspend()
        }
    }

    func stop(timeout: TimeInterval) async throws {
        _ = timeout
        stopCount += 1
        if stopCount == blockedStopCall, let stopGate {
            self.stopGate = nil
            await stopGate.suspend()
        }
        isRunning = false
    }

    func setPaused(_ paused: Bool) throws { _ = paused }

    func waitUntilStopped(minimumCount: Int = 1) async {
        while stopCount < minimumCount { await Task.yield() }
    }
}

@MainActor
private final class RealProcessTopology: SupervisorTopologyControlling {
    let resistsTermination: Bool
    private(set) var trackedPIDs: [pid_t] = []
    private var processes: [Process] = []

    init(resistsTermination: Bool) {
        self.resistsTermination = resistsTermination
    }

    var isRunning: Bool {
        processes.count == 2 && processes.allSatisfy(\.isRunning)
    }

    func launch(
        plan: ProcessSupervisorLaunchPlan,
        generation: SupervisorProcessGeneration,
        onUnexpectedExit: @escaping @MainActor @Sendable (String, Int32) -> Void
    ) async throws {
        _ = (plan, generation, onUnexpectedExit)
        let trap = resistsTermination ? "trap '' TERM" : "trap 'exit 0' TERM"
        processes = try [launchShell("\(trap); while :; do sleep 1; done"),
                         launchShell("\(trap); while :; do sleep 1; done")]
        trackedPIDs = processes.map(\.processIdentifier)
        try await Task.sleep(for: .milliseconds(75))
    }

    func waitForReadiness(
        generation: SupervisorProcessGeneration,
        timeout: TimeInterval
    ) async throws {
        _ = (generation, timeout)
        precondition(isRunning)
    }

    func stop(timeout: TimeInterval) async throws {
        try await SupervisorProcessShutdown.stop(
            processes: processes,
            termTimeout: timeout
        )
        processes = []
    }

    func setPaused(_ paused: Bool) throws { _ = paused }

    private func launchShell(_ script: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        return process
    }
}

@MainActor
private final class RecordingRestartLauncher: ApplicationRestartLaunching {
    private unowned let supervisor: ProcessSupervisor
    private unowned let topology: RealProcessTopology
    private(set) var scheduleCount = 0
    private(set) var observedStoppedBeforeScheduling = false
    private(set) var observedDeadChildrenBeforeScheduling = false

    init(supervisor: ProcessSupervisor, topology: RealProcessTopology) {
        self.supervisor = supervisor
        self.topology = topology
    }

    func scheduleRestart() throws {
        scheduleCount += 1
        observedStoppedBeforeScheduling = supervisor.state == .stopped
        observedDeadChildrenBeforeScheduling = topology.trackedPIDs.allSatisfy {
            !SupervisorProcessShutdown.pidIsAlive($0)
        }
    }
}
