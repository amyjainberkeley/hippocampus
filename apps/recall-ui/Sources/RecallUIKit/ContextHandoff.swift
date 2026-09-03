import Foundation

public enum ContextHandoffError: Error, Equatable, LocalizedError {
    case agentUnavailable
    case launchFailed
    case commandFailed
    case emptyOutput

    public var errorDescription: String? {
        switch self {
        case .agentUnavailable:
            "The local context service is unavailable."
        case .launchFailed:
            "The local context service could not start."
        case .commandFailed:
            "Hippocampus could not prepare context for this task."
        case .emptyOutput:
            "No context packet was returned."
        }
    }
}

/// A read-only invocation of the bundled agent's canonical context compiler.
public struct ContextHandoffCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
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

/// Runs the local read-only handoff command away from the main actor.
public enum ContextHandoffExporter {
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
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = command.executableURL
            process.arguments = command.arguments
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw ContextHandoffError.launchFailed
            }
            process.waitUntilExit()
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                throw ContextHandoffError.commandFailed
            }
            guard let value = String(data: output, encoding: .utf8),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ContextHandoffError.emptyOutput
            }
            return value
        }.value
    }
}
