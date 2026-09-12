import Darwin
import Foundation

public enum AIToolConnectorError: Error, LocalizedError {
    case agentUnavailable
    case launchFailed
    case timedOut
    case commandFailed(code: Int32, diagnostic: String)

    public var errorDescription: String? {
        switch self {
        case .agentUnavailable:
            "Hippocampus can\u{2019}t find its agent connector. Try reinstalling Hippocampus."
        case .launchFailed, .timedOut, .commandFailed:
            "Try again in a moment — if it keeps happening, use \u{201C}Send Feedback\u{201D} from the menu bar."
        }
    }
}

/// A bounded invocation of the bundled client's idempotent registration command.
public struct AIToolConnector: Sendable {
    public static let defaultTimeoutSeconds: TimeInterval = 15
    private static let outputLimit = 8_192

    public let agentURL: URL
    public let baseEnvironment: [String: String]
    public let timeoutSeconds: TimeInterval

    public init(
        agentURL: URL,
        baseEnvironment: [String: String],
        timeoutSeconds: TimeInterval = Self.defaultTimeoutSeconds
    ) {
        self.agentURL = agentURL
        self.baseEnvironment = baseEnvironment
        self.timeoutSeconds = timeoutSeconds
    }

    public func connectAll() async throws -> String {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw AIToolConnectorError.timedOut
        }
        guard FileManager.default.isExecutableFile(atPath: agentURL.path) else {
            throw AIToolConnectorError.agentUnavailable
        }

        let process = ChildProcessEnvironment.makeProcess(baseEnvironment: baseEnvironment)
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = agentURL
        process.arguments = ["connect", "--all"]
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw AIToolConnectorError.launchFailed
        }

        let outReader = Task.detached {
            Self.readCapped(stdout.fileHandleForReading)
        }
        let errReader = Task.detached {
            Self.readCapped(stderr.fileHandleForReading)
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning, Date() < deadline {
            try? await Task<Never, Never>.sleep(nanoseconds: 25_000_000)
        }
        let didTimeOut = process.isRunning
        if didTimeOut {
            process.terminate()
            let gracefulDeadline = Date().addingTimeInterval(0.25)
            while process.isRunning, Date() < gracefulDeadline {
                try? await Task<Never, Never>.sleep(nanoseconds: 25_000_000)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        let outData = await outReader.value
        let errData = await errReader.value
        if didTimeOut {
            throw AIToolConnectorError.timedOut
        }

        let output = String(decoding: outData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnostic = String(decoding: errData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw AIToolConnectorError.commandFailed(
                code: process.terminationStatus,
                diagnostic: diagnostic.isEmpty ? output : diagnostic
            )
        }
        return output.isEmpty
            ? "The registration command returned no report. Client connection has not been verified."
            : output
    }

    private static func readCapped(_ handle: FileHandle) -> Data {
        var result = Data()
        while let chunk = try? handle.read(upToCount: 8_192), !chunk.isEmpty {
            if result.count < outputLimit {
                result.append(chunk.prefix(outputLimit - result.count))
            }
        }
        return result
    }
}
