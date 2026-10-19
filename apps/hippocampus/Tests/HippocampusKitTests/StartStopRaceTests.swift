// SPDX-License-Identifier: Apache-2.0
//
// Starts and stops that overlap. A stop that ran inside a cancelled task
// threw before it signalled anything, and a stop that throws is a capture
// helper that may still be reading ("Couldn’t stop"), so a permission report
// during a start, a Pause during a start or a second open of the app could
// leave Hippocampus stuck on "Couldn’t stop" with only Quit, though nothing
// was reading.

import UserNotifications
import XCTest
@testable import HippocampusKit

/// Keeps the rules of `FoundationSupervisorTopology` that these races turn
/// on, where `FakeSupervisorTopology` does not:
/// - `stop()` closes the lease and waits for a graceful exit in a loop of
///   `try await Task.sleep`, so a stop run inside a cancelled task throws
///   CancellationError before any signal and before it lets go of anything;
/// - `waitForReadiness` polls with `try await Task.sleep`;
/// - a helper drains and exits by itself `drainDelay` after its lease
///   closes, and the agent with it;
/// - exited processes stay held until a stop returns, and `launch` refuses
///   while anything is held.
@MainActor
final class LeaseTopology: SupervisorTopologyControlling {
    enum Readiness { case ready, helperExits(Int32) }

    var drainDelay: TimeInterval = 0.3
    /// Readiness waits while this is true.
    var holdReadiness = false
    var readinessOutcomes: [Readiness] = []
    var permissionOffInReceipt: ((ProcessSupervisorLaunchPlan) -> TCCRevokedReason?)?
    var onReadinessWait: ((ProcessSupervisorLaunchPlan) -> Void)?
    private(set) var permissionOffAtReadiness: TCCRevokedReason?
    private(set) var holdsProcesses = false
    private(set) var launchPlans: [ProcessSupervisorLaunchPlan] = []
    private(set) var stopCalls = 0
    private(set) var stopsThatThrewCancellation = 0
    private(set) var readinessWaits = 0
    private var callbacks: [@MainActor @Sendable (String, Int32) -> Void] = []
    private var helperProcess = false
    private var agentProcess = false
    private var leaseClosedAt: Date?
    private var currentGenerationID: String?
    private var isStopping = false

    var helperAlive: Bool {
        guard helperProcess else { return false }
        if let closed = leaseClosedAt, Date().timeIntervalSince(closed) >= drainDelay { return false }
        return true
    }

    var agentAlive: Bool { agentProcess && helperAlive }
    var isRunning: Bool { helperAlive && agentAlive }
    var captureHelperAlive: Bool {
        helperAlive && launchPlans.last?.helperArguments.contains("--capture") == true
    }

    func launch(
        plan: ProcessSupervisorLaunchPlan,
        generation: SupervisorProcessGeneration,
        onUnexpectedExit: @escaping @MainActor @Sendable (String, Int32) -> Void
    ) async throws {
        guard !holdsProcesses else { throw SupervisorProcessRuntimeError.partialStop }
        permissionOffAtReadiness = nil
        launchPlans.append(plan)
        callbacks.append(onUnexpectedExit)
        helperProcess = true
        agentProcess = true
        leaseClosedAt = nil
        holdsProcesses = true
        isStopping = false
        currentGenerationID = generation.id
    }

    func waitForReadiness(generation: SupervisorProcessGeneration, timeout: TimeInterval) async throws {
        readinessWaits += 1
        onReadinessWait?(launchPlans.last!)
        let outcome = readinessOutcomes.isEmpty ? .ready : readinessOutcomes.removeFirst()
        repeat {
            guard currentGenerationID == generation.id else { throw SupervisorProcessRuntimeError.invalidReadiness }
            guard helperAlive else { throw SupervisorProcessRuntimeError.helperExited(-1) }
            guard agentAlive else { throw SupervisorProcessRuntimeError.agentExited(-1) }
            try await Task.sleep(for: .milliseconds(5))
        } while holdReadiness
        if case .helperExits(let status) = outcome {
            helperProcess = false
            throw SupervisorProcessRuntimeError.helperExited(status)
        }
        permissionOffAtReadiness = permissionOffInReceipt?(launchPlans.last!)
    }

    func stop(timeout: TimeInterval) async throws {
        stopCalls += 1
        isStopping = true
        if holdsProcesses, leaseClosedAt == nil { leaseClosedAt = Date() }
        let graceful = min(1, max(0.05, timeout / 2))
        let deadline = Date().addingTimeInterval(graceful)
        do {
            while Date() < deadline, helperAlive || agentAlive {
                try await Task.sleep(for: .milliseconds(25))
            }
        } catch {
            stopsThatThrewCancellation += 1
            throw error
        }
        holdsProcesses = false
        currentGenerationID = nil
        permissionOffAtReadiness = nil
        helperProcess = false
        agentProcess = false
        leaseClosedAt = nil
        isStopping = false
    }

    /// The memory agent exits on its own (another writer holds the memory);
    /// the capture helper lives on, held.
    func agentExitsUnexpectedly(status: Int32 = 1) {
        agentProcess = false
        guard !isStopping, let callback = callbacks.last else { return }
        callback("agent", status)
    }
}

/// A notification center that records nothing and asks nobody.
final class SilentNotificationCenter: UserNotificationCenter, @unchecked Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    func add(_ request: UNNotificationRequest) async throws {}
    func removePendingNotificationRequests(withIdentifiers ids: [String]) {}
    func removeDeliveredNotifications(withIdentifiers ids: [String]) {}
}

@MainActor
final class StartStopRaceTests: XCTestCase {
    private let clock = TestClock()
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("start-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func make(
        _ topology: LeaseTopology, captureEnabled: Bool = true,
        retrySleep: (@MainActor @Sendable (TimeInterval) async throws -> Void)? = nil
    ) -> ProcessSupervisor {
        let locator = FakeBinaryLocator()
        locator.helperURL = URL(fileURLWithPath: "/bundle/MCICaptureHelper")
        locator.agentURL = URL(fileURLWithPath: "/bundle/mci-agent")
        let keyStore = FakeKeyStore()
        keyStore.storedKey = String(repeating: "ab", count: 32)
        let clock = self.clock
        return ProcessSupervisor(
            locator: locator, keyStore: keyStore,
            runtimeConfig: FakeRuntimeConfig(captureEnabled: captureEnabled), topology: topology,
            keyCustodyPreparer: FakeKeyCustodyPreparer(), readinessTimeout: 30,
            retrySleep: retrySleep ?? { try await Task.sleep(for: .seconds($0)) },
            captureStatusReader: { (nil, nil) }, clock: { clock.now }
        )
    }

    private func row(_ supervisor: ProcessSupervisor) -> StatusRow {
        supervisor.statusRow(setupFinished: true, now: clock.now)
    }

    private func describe(_ supervisor: ProcessSupervisor) -> String {
        let row = row(supervisor)
        return "state=\(supervisor.state) stopFailed=\(supervisor.stopFailed) "
            + "row=[\(row.title) | \(row.detail ?? "-") | \(row.action.map(\.title) ?? "-")]"
    }

    private func eventually(
        _ condition: @MainActor () -> Bool, within seconds: TimeInterval = 3,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    // MARK: A permission report during a start

    /// The helper's boot-time `tcc_revoked` line can reach the app while the
    /// start that launched it still waits for readiness. That ends the start,
    /// and what it launched is stopped, all of it: Needs permission, not
    /// Couldn’t stop, and the next look starts it again.
    func test_a_permission_report_during_a_start_is_not_a_failed_stop() async throws {
        let topology = LeaseTopology()
        let supervisor = make(topology)
        topology.holdReadiness = true
        supervisor.start()
        await eventually { topology.readinessWaits == 1 }
        XCTAssertEqual(supervisor.state, .starting)

        // What the stderr tail's sink does with the line.
        supervisor.tccRevokedSurface = .screenRecording
        await eventually { !topology.holdsProcesses }

        XCTAssertEqual(topology.stopsThatThrewCancellation, 0, "the stop ran in the cancelled start")
        XCTAssertFalse(supervisor.stopFailed, describe(supervisor))
        XCTAssertEqual(row(supervisor).title, "Needs permission", describe(supervisor))
        XCTAssertEqual(row(supervisor).action, .openSystemSettings(.screenRecording))

        // Not a dead end: remembering is on, so a look starts it again.
        topology.holdReadiness = false
        supervisor.retryIfPermissionMayBeBack()
        await eventually { supervisor.state == .running }
        XCTAssertEqual(topology.launchPlans.count, 2)
        try await supervisor.shutdownAndWait()
    }

    /// The same through the real stderr tail and sink: the helper writes its
    /// line and the tail reads it while readiness is still on its way.
    func test_a_permission_report_through_the_tail_during_a_start_reads_needs_permission() async throws {
        let topology = LeaseTopology()
        let supervisor = make(topology)
        let log = scratch.appendingPathComponent("helper.stderr.log")
        FileManager.default.createFile(atPath: log.path, contents: Data())
        let tail = TCCHelperStderrTail(
            sink: TCCNotifierAndSupervisorSink(
                notifier: TCCRevokedNotifier(center: SilentNotificationCenter()), supervisor: supervisor
            ),
            logPath: log
        )
        tail.start()
        defer { tail.stop() }
        topology.holdReadiness = true
        topology.onReadinessWait = { plan in
            guard plan.helperArguments.contains("--capture"), let handle = try? FileHandle(forWritingTo: log) else {
                return
            }
            handle.seekToEndOfFile()
            handle.write(Data("mci-capture-helper: helper_health tcc_revoked=screenRecording\n".utf8))
            try? handle.close()
        }

        supervisor.start()
        await eventually({ supervisor.tccRevokedSurface != nil }, within: 4)
        await eventually { !topology.holdsProcesses }

        XCTAssertFalse(supervisor.stopFailed, describe(supervisor))
        XCTAssertEqual(row(supervisor).title, "Needs permission")
        XCTAssertEqual(topology.stopsThatThrewCancellation, 0)
        try await supervisor.shutdownAndWait()
    }

    /// Try Again's restart, ended the same way.
    func test_a_permission_report_during_a_try_again_restart_reads_needs_permission() async throws {
        let topology = LeaseTopology()
        let supervisor = make(topology)
        supervisor.start()
        await eventually { supervisor.state == .running }
        topology.holdReadiness = true
        supervisor.retryNow()
        await eventually { topology.readinessWaits == 2 }

        supervisor.tccRevokedSurface = .screenRecording
        await eventually { !topology.holdsProcesses }

        XCTAssertFalse(supervisor.stopFailed, describe(supervisor))
        XCTAssertEqual(row(supervisor).title, "Needs permission")
        XCTAssertEqual(topology.stopsThatThrewCancellation, 0)
        try await supervisor.shutdownAndWait()
    }

    // MARK: Pause during a start

    /// "Starting…" offers Pause. The pause ends the start, whose own cleanup
    /// stop ran in the cancelled task and read "Couldn’t stop / Quit" until
    /// the pause's stop came back.
    func test_pause_during_a_start_never_reads_couldnt_stop() async throws {
        let topology = LeaseTopology()
        let supervisor = make(topology)
        topology.holdReadiness = true
        supervisor.start()
        await eventually { topology.readinessWaits == 1 }
        XCTAssertEqual(row(supervisor).action, .pause)

        supervisor.performAskStatusAction(.pause, setupFinished: true) { _ in }
        var sawCouldntStop = false
        let deadline = Date().addingTimeInterval(3)
        while supervisor.state != .paused && Date() < deadline {
            if supervisor.stopFailed { sawCouldntStop = true }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(supervisor.state, .paused)
        XCTAssertFalse(sawCouldntStop, "the row read Couldn’t stop while the pause stopped a start")
        XCTAssertFalse(supervisor.stopFailed)
        XCTAssertFalse(topology.holdsProcesses)
        XCTAssertEqual(topology.stopsThatThrewCancellation, 0)
        try await supervisor.shutdownAndWait()
    }
}
