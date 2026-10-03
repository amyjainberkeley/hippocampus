import Darwin
import Foundation

public enum ContextHandoffError: Error, Equatable, LocalizedError {
    case agentUnavailable
    case launchFailed
    case timedOut
    case commandFailed
    case emptyOutput
    case invalidProject

    public var errorDescription: String? {
        switch self {
        case .agentUnavailable:
            "The local context service is unavailable."
        case .launchFailed:
            "The local context service could not start."
        case .timedOut:
            "The local context service did not respond in time."
        case .commandFailed:
            "Hippocampus could not prepare context for this task."
        case .emptyOutput:
            "No context packet was returned."
        case .invalidProject:
            "Choose a project folder on this Mac."
        }
    }
}

/// An invocation of the bundled agent's canonical context compiler.
/// Project handoffs can record a content-free local delivery receipt.
public struct ContextHandoffCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    /// Explicit project scope. No import/refresh and no global-context fallback.
    /// The local compiler may record a content-free delivery receipt.
    public static func makeProject(
        directory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        recallExecutableURL: URL? = Bundle.main.executableURL,
        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) throws -> Self {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              !directory.path.contains("\0") else { throw ContextHandoffError.invalidProject }
        let agent = try make(focus: "", environment: environment,
            recallExecutableURL: recallExecutableURL, isExecutable: isExecutable).executableURL
        var arguments = ["handoff", "--cwd", directory.standardizedFileURL.path,
            "--no-refresh", "--max-tokens", "600", "--format", "markdown"]
        if let path = environment["MCI_DB_PATH"], !path.isEmpty {
            arguments += ["--db-path", path]
        }
        return Self(executableURL: agent, arguments: arguments)
    }

    /// Resolve only an app-bundled sibling in production. An explicit path is
    /// accepted solely in the already-gated development-key mode.
    public static func make(
        focus: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        recallExecutableURL: URL? = Bundle.main.executableURL,
        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) throws -> Self {
        let explicitDevelopmentURL: URL? = if environment["MCI_DEVELOPMENT_FILE_KEY"] == "1",
                                              let path = environment["MCI_AGENT_PATH"],
                                              !path.isEmpty {
            URL(fileURLWithPath: path)
        } else {
            nil
        }
        let siblingURL = recallExecutableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("mci-agent", isDirectory: false)
        guard let executableURL = [explicitDevelopmentURL, siblingURL]
            .compactMap({ $0 })
            .first(where: isExecutable)
        else {
            throw ContextHandoffError.agentUnavailable
        }

        var arguments = ["context"]
        if let dbPath = environment["MCI_DB_PATH"], !dbPath.isEmpty {
            arguments.append(contentsOf: ["--db-path", dbPath])
        }
        let normalizedFocus = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedFocus.isEmpty {
            arguments.append(contentsOf: ["--focus", normalizedFocus])
        }
        arguments.append(contentsOf: [
            "--max-tokens", "1200",
            "--max-evidence", "24",
            "--format", "markdown",
        ])
        return Self(executableURL: executableURL, arguments: arguments)
    }
}

/// Runs the local context command away from the main actor without importing sessions.
public enum ContextHandoffExporter {
    public static let defaultTimeoutSeconds: TimeInterval = 15

    public static func export(
        focus: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        recallExecutableURL: URL? = Bundle.main.executableURL
    ) async throws -> String {
        let command = try ContextHandoffCommand.make(
            focus: focus,
            environment: environment,
            recallExecutableURL: recallExecutableURL
        )
        return try await run(command: command)
    }

    /// Execute a local context command with a hard wall-clock bound.
    /// Timeout first requests a normal exit, then uses `SIGKILL` if the
    /// bundled child does not honor the grace period.
    public static func run(
        command: ContextHandoffCommand,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds
    ) async throws -> String {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw ContextHandoffError.timedOut
        }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = command.executableURL
            process.arguments = command.arguments
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let parent = ProcessInfo.processInfo.environment
            let names = ["HOME", "TMPDIR", "LANG", "LC_ALL", "MCI_DB_PATH",
                "MCI_DB_KEYCHAIN_SERVICE", "MCI_DB_KEYCHAIN_ACCOUNT", "MCI_DEVELOPMENT_FILE_KEY",
                "MCI_DB_KEY_FILE", "MCI_EMBEDDER_DISABLED"]
            process.environment = parent.filter { names.contains($0.key) }
            process.environment?["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            if parent["MCI_DEVELOPMENT_FILE_KEY"] == "1" {
                process.environment?["MCI_DB_KEY_HEX"] = parent["MCI_DB_KEY_HEX"]
            }
            do {
                try process.run()
            } catch {
                throw ContextHandoffError.launchFailed
            }

            let outputReader = Task.detached(priority: .userInitiated) {
                outputPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning, !Task.isCancelled, Date() < deadline {
                try? await Task<Never, Never>.sleep(nanoseconds: 25_000_000)
            }
            if process.isRunning {
                process.terminate()
                let gracefulDeadline = Date().addingTimeInterval(0.25)
                while process.isRunning, Date() < gracefulDeadline {
                    try? await Task<Never, Never>.sleep(nanoseconds: 25_000_000)
                }
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
                let killedDeadline = Date().addingTimeInterval(1)
                while process.isRunning, Date() < killedDeadline {
                    try? await Task<Never, Never>.sleep(nanoseconds: 25_000_000)
                }
                if process.isRunning {
                    outputPipe.fileHandleForReading.closeFile()
                }
                _ = await outputReader.value
                try Task.checkCancellation()
                throw ContextHandoffError.timedOut
            }

            try Task.checkCancellation()
            let output = await outputReader.value
            guard process.terminationStatus == 0 else {
                throw ContextHandoffError.commandFailed
            }
            guard let value = String(data: output, encoding: .utf8),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ContextHandoffError.emptyOutput
            }
            return value
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
