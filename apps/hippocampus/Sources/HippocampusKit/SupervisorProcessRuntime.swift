// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin

package struct SupervisorProcessGeneration: Sendable, Equatable {
    let id: String
    let readinessURL: URL
    let captureEnabled: Bool

    package static func make(captureEnabled: Bool) throws -> SupervisorProcessGeneration {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai.hippocampus.helper-readiness", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let id = UUID().uuidString.lowercased()
        return SupervisorProcessGeneration(
            id: id,
            readinessURL: directory.appendingPathComponent("\(id).json"),
            captureEnabled: captureEnabled
        )
    }
}

enum SupervisorProcessRuntimeError: LocalizedError, Equatable {
    case keyPreparationFailed(Int32, String)
    case helperExited(Int32)
    case agentExited(Int32)
    case readinessTimedOut
    case invalidReadiness
    case partialStop

    var errorDescription: String? {
        switch self {
        case .keyPreparationFailed(let status, let detail):
            return "Database-key preparation failed (\(status)): \(detail)"
        case .helperExited(let status): return "Capture helper exited during startup (\(status))."
        case .agentExited(let status): return "Memory agent exited during startup (\(status))."
        case .readinessTimedOut: return "Capture helper readiness timed out."
        case .invalidReadiness: return "Capture helper returned a stale or invalid readiness receipt."
        case .partialStop: return "The prior helper topology did not stop completely."
        }
    }
}

@MainActor
package protocol KeyCustodyPreparing: AnyObject {
    func prepare(
        agentURL: URL,
        databaseURL: URL,
        keyReference: KeychainKeyReference
    ) async throws
}

@MainActor
final class AgentKeyCustodyPreparer: KeyCustodyPreparing {
    func prepare(
        agentURL: URL,
        databaseURL: URL,
        keyReference: KeychainKeyReference
    ) async throws {
        let result = try await KeyCustodyCommandRunner.run(
            executableURL: agentURL,
            arguments: ["ensure-key", "--db-path", databaseURL.path],
            environment: ProcessSupervisorLaunchPlan.sanitizedEnvironment(
                baseEnvironment: ProcessInfo.processInfo.environment,
                dbPath: databaseURL,
                keyReference: keyReference
            )
        )
        guard result.terminationStatus == 0 else {
            throw SupervisorProcessRuntimeError.keyPreparationFailed(
                result.terminationStatus,
                result.diagnostic.isEmpty ? "no diagnostic" : result.diagnostic
            )
        }
    }
}

@MainActor
package protocol SupervisorTopologyControlling: AnyObject {
    /// The helper and the agent are both running.
    var isRunning: Bool { get }
    /// It still holds a helper or an agent, running or exited, that only
    /// `stop()` releases: `launch` refuses until then. A helper whose agent
    /// exited is not `isRunning`, but it is held, and may still be reading.
    var holdsProcesses: Bool { get }
    func launch(
        plan: ProcessSupervisorLaunchPlan,
        generation: SupervisorProcessGeneration,
        onUnexpectedExit: @escaping @MainActor @Sendable (String, Int32) -> Void
    ) async throws
    func waitForReadiness(
        generation: SupervisorProcessGeneration,
        timeout: TimeInterval
    ) async throws
    func stop(timeout: TimeInterval) async throws
    /// The permission the last ready helper found off as it started, from
    /// its readiness receipt, Screen Recording first. A capture helper
    /// started with one off is paused on it, and starts reading by itself
    /// once it is allowed.
    var permissionOffAtReadiness: TCCRevokedReason? { get }
    /// The running helper and agent, which the orphan sweep leaves alone
    /// outside Quit (spec-shell S6.4).
    var childProcessIDs: Set<pid_t> { get }
    /// Asks the running capture helper for one fresh read of the window in
    /// front (Ask opened). False when there is no helper to ask.
    func requestFocusedRead() -> Bool
}

extension SupervisorTopologyControlling {
    package var holdsProcesses: Bool { isRunning }
    package var permissionOffAtReadiness: TCCRevokedReason? { nil }
    package var childProcessIDs: Set<pid_t> { [] }
    package func requestFocusedRead() -> Bool { false }
}

@MainActor
final class FoundationSupervisorTopology: SupervisorTopologyControlling {
    private struct ReadinessPayload: Decodable {
        let generation: String
        let captureEnabled: Bool
        /// Absent from an older helper's receipt.
        let permissionsOff: [String]?

        private enum CodingKeys: String, CodingKey {
            case generation
            case captureEnabled = "capture_enabled"
            case permissionsOff = "permissions_off"
        }
    }

    /// Reads a readiness receipt, which must be `generation`'s, with its
    /// capture setting, and returns the permission it says the helper found
    /// off as it started, Screen Recording first. A name this app does not
    /// know is not one it can offer to fix, so it is left to the helper.
    static func permissionOff(
        inReadiness data: Data,
        for generation: SupervisorProcessGeneration
    ) throws -> TCCRevokedReason? {
        let payload = try JSONDecoder().decode(ReadinessPayload.self, from: data)
        guard payload.generation == generation.id,
              payload.captureEnabled == generation.captureEnabled
        else {
            throw SupervisorProcessRuntimeError.invalidReadiness
        }
        let off = Set(payload.permissionsOff ?? [])
        return TCCRevokedReason.allCases.first { off.contains($0.rawValue) }
    }

    private var helper: Process?
    private var agent: Process?
    private var bridgePipe: Pipe?
    private var parentLeaseWriteHandle: FileHandle?
    private var helperStderrHandle: FileHandle?
    private var agentStderrHandle: FileHandle?
    private var currentGeneration: SupervisorProcessGeneration?
    private var isStopping = false
    private(set) var permissionOffAtReadiness: TCCRevokedReason?

    var isRunning: Bool {
        helper?.isRunning == true && agent?.isRunning == true
    }

    /// Until `stop()` cleans up, an exited helper or agent is still held,
    /// and `launch` refuses with `.partialStop`.
    var holdsProcesses: Bool {
        helper != nil || agent != nil
    }

    var childProcessIDs: Set<pid_t> {
        Set([helper, agent].compactMap { process in
            guard let process, process.isRunning else { return nil }
            return process.processIdentifier
        })
    }

    /// One byte on the helper's lease, which only this app holds.
    func requestFocusedRead() -> Bool {
        guard !isStopping, helper?.isRunning == true, let lease = parentLeaseWriteHandle else { return false }
        return HelperLeaseCommand.send(HelperLeaseCommand.freshRead, to: lease)
    }

    func launch(
        plan: ProcessSupervisorLaunchPlan,
        generation: SupervisorProcessGeneration,
        onUnexpectedExit: @escaping @MainActor @Sendable (String, Int32) -> Void
    ) async throws {
        guard helper == nil, agent == nil else {
            throw SupervisorProcessRuntimeError.partialStop
        }
        permissionOffAtReadiness = nil
        try? FileManager.default.removeItem(at: generation.readinessURL)
        let bridgePipe = Pipe()
        let parentLeasePipe = Pipe()
        let logDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MCI")
        let helperLog = LogRotator(path: logDirectory.appendingPathComponent("helper.stderr.log"))
        let agentLog = LogRotator(path: logDirectory.appendingPathComponent("agent.stderr.log"))
        let helperStderr = try helperLog.fileHandle()
        let agentStderr = try agentLog.fileHandle()

        let helper = try ChildProcessEnvironment.makeProcess(
            preparedEnvironment: plan.helperEnvironment
        )
        helper.executableURL = plan.helperExecutableURL
        helper.arguments = plan.helperArguments
        helper.standardInput = parentLeasePipe
        helper.standardOutput = bridgePipe
        helper.standardError = helperStderr

        let agent = try ChildProcessEnvironment.makeProcess(
            preparedEnvironment: plan.agentEnvironment
        )
        agent.executableURL = plan.agentExecutableURL
        agent.arguments = plan.agentArguments
        agent.standardInput = bridgePipe
        agent.standardError = agentStderr

        isStopping = false
        currentGeneration = generation
        helper.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in
                guard let self, !self.isStopping, self.currentGeneration?.id == generation.id else {
                    return
                }
                onUnexpectedExit("helper", status)
            }
        }
        agent.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in
                guard let self, !self.isStopping, self.currentGeneration?.id == generation.id else {
                    return
                }
                onUnexpectedExit("agent", status)
            }
        }

        self.bridgePipe = bridgePipe
        self.parentLeaseWriteHandle = parentLeasePipe.fileHandleForWriting
        self.helperStderrHandle = helperStderr
        self.agentStderrHandle = agentStderr
        do {
            try helper.run()
            self.helper = helper
            try agent.run()
            self.agent = agent
            try? parentLeasePipe.fileHandleForReading.close()
            try? bridgePipe.fileHandleForReading.close()
            try? bridgePipe.fileHandleForWriting.close()
        } catch let launchError {
            isStopping = true
            do {
                try await SupervisorProcessShutdown.stop(
                    processes: [helper],
                    termTimeout: 0.25
                )
                cleanup()
            } catch {
                throw SupervisorProcessRuntimeError.partialStop
            }
            throw launchError
        }
    }

    func waitForReadiness(
        generation: SupervisorProcessGeneration,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard currentGeneration?.id == generation.id else {
                throw SupervisorProcessRuntimeError.invalidReadiness
            }
            guard let helper, helper.isRunning else {
                throw SupervisorProcessRuntimeError.helperExited(helper?.terminationStatus ?? -1)
            }
            guard let agent, agent.isRunning else {
                throw SupervisorProcessRuntimeError.agentExited(agent?.terminationStatus ?? -1)
            }
            if FileManager.default.fileExists(atPath: generation.readinessURL.path) {
                permissionOffAtReadiness = try Self.permissionOff(
                    inReadiness: Data(contentsOf: generation.readinessURL),
                    for: generation
                )
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SupervisorProcessRuntimeError.readinessTimedOut
    }

    func stop(timeout: TimeInterval) async throws {
        isStopping = true
        try? parentLeaseWriteHandle?.close()
        parentLeaseWriteHandle = nil
        let gracefulTimeout = min(1, max(0.05, timeout / 2))
        let gracefulDeadline = Date().addingTimeInterval(gracefulTimeout)
        while Date() < gracefulDeadline,
              helper?.isRunning == true || agent?.isRunning == true
        {
            try await Task.sleep(for: .milliseconds(25))
        }
        do {
            let survivors = [helper, agent].compactMap { process in
                process?.isRunning == true ? process : nil
            }
            if !survivors.isEmpty {
                try await SupervisorProcessShutdown.stop(
                    processes: survivors,
                    termTimeout: max(0.05, timeout - gracefulTimeout)
                )
            }
        } catch {
            throw SupervisorProcessRuntimeError.partialStop
        }
        cleanup()
    }

    private func cleanup() {
        if let readinessURL = currentGeneration?.readinessURL {
            try? FileManager.default.removeItem(at: readinessURL)
        }
        try? helperStderrHandle?.close()
        try? agentStderrHandle?.close()
        helper = nil
        agent = nil
        bridgePipe = nil
        try? parentLeaseWriteHandle?.close()
        parentLeaseWriteHandle = nil
        helperStderrHandle = nil
        agentStderrHandle = nil
        currentGeneration = nil
        permissionOffAtReadiness = nil
        isStopping = false
    }
}
