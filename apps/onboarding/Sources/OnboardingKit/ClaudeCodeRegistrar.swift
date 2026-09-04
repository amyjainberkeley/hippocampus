// SPDX-License-Identifier: TBD-private
import Darwin
import Foundation

/// Protocol for the `mci-agent connect --all` invocation used by the
/// AI-tools onboarding slide. Behind a protocol so unit
/// tests can swap a stub instead of spawning a real process.
///
/// Production impl: `DefaultClaudeCodeRegistrar` finds `mci-agent` at
/// the sibling path next to the onboarding executable and runs
/// `mci-agent connect --all`, mirroring the wiring in
/// `StatusMenuView.connectAITools()` in HippocampusKit. We duplicate
/// (not import) that logic because OnboardingKit deliberately has no
/// dependency on HippocampusKit (each package builds in isolation per
/// Package.swift).
public protocol ClaudeCodeRegistrar: Sendable {
    /// Run the registration. On success returns the stdout/result
    /// message the user should see. On failure throws a
    /// `ClaudeCodeRegistrarError` whose `message` is the user-facing
    /// diagnostic.
    func register() async throws -> String

    /// The exact shell command a power user can run themselves if the
    /// in-app Connect button isn't enough. Surfaced as the "Copy
    /// command" affordance in the failure state.
    var manualCommand: String { get }
}

public enum ClaudeCodeRegistrarError: Error, Equatable {
    case agentNotFound(searchedPath: String)
    case launchFailed(message: String)
    case timedOut
    case nonZeroExit(code: Int32, stderr: String)

    public var message: String {
        // Cycle 8.54 copy audit — user-facing messages no longer expose
        // the internal `mci-agent` binary name, the search path, or a
        // raw exit code. Detailed engineer strings (path, exit code)
        // remain available via the associated values for logging.
        switch self {
        case .agentNotFound:
            return "Hippocampus can\u{2019}t find its agent connector. Reinstall Hippocampus, then try connecting again."
        case .launchFailed, .timedOut:
            return "Couldn\u{2019}t connect AI tools. Try again — if it keeps happening, use \u{201C}Send Feedback\u{201D} from the menu bar."
        case .nonZeroExit:
            return "Couldn\u{2019}t connect AI tools. Try again — if it keeps happening, use \u{201C}Send Feedback\u{201D} from the menu bar."
        }
    }
}

/// Default registrar — spawns `mci-agent connect --all` as a child
/// process and captures stdout / stderr. The agent binary is expected
/// to sit alongside the onboarding executable inside
/// `Hippocampus.app/Contents/MacOS/`.
public struct DefaultClaudeCodeRegistrar: ClaudeCodeRegistrar {
    public static let defaultTimeoutSeconds: TimeInterval = 15
    private static let outputLimit = 8_192

    public let agentURL: URL
    public let timeoutSeconds: TimeInterval

    public init(
        agentURL: URL? = nil,
        timeoutSeconds: TimeInterval = Self.defaultTimeoutSeconds
    ) {
        if let url = agentURL {
            self.agentURL = url
        } else {
            // The path the OS used to launch us; deleting the last
            // component lands us in Contents/MacOS/ when running inside
            // a .app bundle, or in apps/onboarding/.build/<profile>/
            // when running under `swift run`.
            let argv0 = ProcessInfo.processInfo.arguments.first
                ?? "/usr/bin/false"
            let dir = URL(fileURLWithPath: argv0).deletingLastPathComponent()
            self.agentURL = dir.appendingPathComponent("mci-agent")
        }
        self.timeoutSeconds = timeoutSeconds
    }

    public var manualCommand: String {
        // Quote-stable across shells. The path embeds the user's home,
        // so we don't dare interpolate it into a `pbcopy`-friendly
        // string; users can always type `mci-agent connect --all` once
        // it's on PATH.
        "mci-agent connect --all"
    }

    public func register() async throws -> String {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw ClaudeCodeRegistrarError.timedOut
        }
        guard FileManager.default.isExecutableFile(atPath: agentURL.path) else {
            throw ClaudeCodeRegistrarError.agentNotFound(searchedPath: agentURL.path)
        }

        let proc = ChildProcessEnvironment.makeProcess()
        proc.executableURL = agentURL
        proc.arguments = ["connect", "--all"]
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        do {
            try proc.run()
        } catch {
            throw ClaudeCodeRegistrarError.launchFailed(
                message: error.localizedDescription
            )
        }

        let outReader = Task.detached {
            Self.readCapped(stdout.fileHandleForReading)
        }
        let errReader = Task.detached {
            Self.readCapped(stderr.fileHandleForReading)
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while proc.isRunning, Date() < deadline {
            try? await Task<Never, Never>.sleep(nanoseconds: 25_000_000)
        }
        let didTimeOut = proc.isRunning
        if didTimeOut {
            proc.terminate()
            let gracefulDeadline = Date().addingTimeInterval(0.25)
            while proc.isRunning, Date() < gracefulDeadline {
                try? await Task<Never, Never>.sleep(nanoseconds: 25_000_000)
            }
            if proc.isRunning {
                _ = Darwin.kill(proc.processIdentifier, SIGKILL)
            }
        }

        let outData = await outReader.value
        let errData = await errReader.value
        if didTimeOut {
            throw ClaudeCodeRegistrarError.timedOut
        }
        let out = String(decoding: outData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let err = String(decoding: errData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if proc.terminationStatus == 0 {
            if !out.isEmpty { return out }
            return "Hippocampus connected the AI tools installed on this Mac."
        } else {
            throw ClaudeCodeRegistrarError.nonZeroExit(
                code: proc.terminationStatus,
                stderr: err.isEmpty ? out : err
            )
        }
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
