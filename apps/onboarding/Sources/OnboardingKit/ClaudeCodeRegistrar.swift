// SPDX-License-Identifier: TBD-private
import Foundation

/// Protocol for the `mci-agent register-mcp` invocation used by the
/// Connect-to-Claude-Code onboarding slide. Behind a protocol so unit
/// tests can swap a stub instead of spawning a real process.
///
/// Production impl: `DefaultClaudeCodeRegistrar` finds `mci-agent` at
/// the sibling path next to the onboarding executable and runs
/// `mci-agent register-mcp`, mirroring the wiring in
/// `StatusMenuView.connectToClaude()` in HippocampusKit. We duplicate
/// (not import) that logic because OnboardingKit deliberately has no
/// dependency on HippocampusKit (each package builds in isolation per
/// Package.swift).
public protocol ClaudeCodeRegistrar: Sendable {
    /// Run the registration. On success returns the stdout/result
    /// message the user should see ("Hippocampus registered with Claude
    /// Code. Restart Claude Code to connect."). On failure throws a
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
    case nonZeroExit(code: Int32, stderr: String)

    public var message: String {
        switch self {
        case .agentNotFound(let path):
            return "Couldn't find the mci-agent helper at \(path). Reinstall Hippocampus and try again."
        case .launchFailed(let msg):
            return "Couldn't launch mci-agent: \(msg)"
        case .nonZeroExit(let code, let stderr):
            return stderr.isEmpty
                ? "mci-agent register-mcp exited with code \(code)"
                : stderr
        }
    }
}

/// Default registrar — spawns `mci-agent register-mcp` as a child
/// process and captures stdout / stderr. The agent binary is expected
/// to sit alongside the onboarding executable inside
/// `Hippocampus.app/Contents/MacOS/`.
public struct DefaultClaudeCodeRegistrar: ClaudeCodeRegistrar {
    public let agentURL: URL

    public init(agentURL: URL? = nil) {
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
    }

    public var manualCommand: String {
        // Quote-stable across shells. The path embeds the user's home,
        // so we don't dare interpolate it into a `pbcopy`-friendly
        // string; users can always type `mci-agent register-mcp` once
        // it's on PATH.
        "mci-agent register-mcp"
    }

    public func register() async throws -> String {
        guard FileManager.default.fileExists(atPath: agentURL.path) else {
            throw ClaudeCodeRegistrarError.agentNotFound(searchedPath: agentURL.path)
        }

        let proc = Process()
        proc.executableURL = agentURL
        proc.arguments = ["register-mcp"]
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

        // The agent is fast (~50 ms typical); waitUntilExit is fine on
        // a background task. Caller invokes us from `Task.detached`.
        proc.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let out = String(decoding: outData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let err = String(decoding: errData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if proc.terminationStatus == 0 {
            if !out.isEmpty { return out }
            return "Hippocampus registered with Claude Code. Restart Claude Code to connect."
        } else {
            throw ClaudeCodeRegistrarError.nonZeroExit(
                code: proc.terminationStatus,
                stderr: err.isEmpty ? out : err
            )
        }
    }
}
