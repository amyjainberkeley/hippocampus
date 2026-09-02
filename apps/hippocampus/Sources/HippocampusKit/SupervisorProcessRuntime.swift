// SPDX-License-Identifier: TBD-private
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
    var isRunning: Bool { get }
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
}

@MainActor
final class FoundationSupervisorTopology: SupervisorTopologyControlling {
    private struct ReadinessPayload: Decodable {
        let generation: String
        let captureEnabled: Bool

        private enum CodingKeys: String, CodingKey {
            case generation
            case captureEnabled = "capture_enabled"
        }
    }

    private var helper: Process?
    private var agent: Process?
    private var bridgePipe: Pipe?
    private var parentLeaseWriteHandle: FileHandle?
    private var helperStderrHandle: FileHandle?
    private var agentStderrHandle: FileHandle?
    private var currentGeneration: SupervisorProcessGeneration?
    private var isStopping = false

    var isRunning: Bool {
        helper?.isRunning == true && agent?.isRunning == true
    }

    func launch(
        plan: ProcessSupervisorLaunchPlan,
        generation: SupervisorProcessGeneration,
        onUnexpectedExit: @escaping @MainActor @Sendable (String, Int32) -> Void
    ) async throws {
        guard helper == nil, agent == nil else {
            throw SupervisorProcessRuntimeError.partialStop
        }
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
                let payload = try JSONDecoder().decode(
                    ReadinessPayload.self,
                    from: Data(contentsOf: generation.readinessURL)
                )
                guard payload.generation == generation.id,
                      payload.captureEnabled == generation.captureEnabled
                else {
                    throw SupervisorProcessRuntimeError.invalidReadiness
                }
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
        isStopping = false
    }
}
