import Darwin
import Foundation
import TOMLKit

public enum AIToolConnectorError: Error, LocalizedError {
    case agentUnavailable
    case launchFailed
    case timedOut
    case commandFailed(code: Int32, diagnostic: String)

    public var errorDescription: String? {
        switch self {
        case .agentUnavailable:
            "Part of Hippocampus is missing. Reinstall it, then try again."
        case .launchFailed, .timedOut, .commandFailed:
            "Try again. If it keeps happening, use Send feedback in Preferences, About."
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

    /// The raw report, for checks of the command's bounds.
    public func connectAll() async throws -> String {
        let result = try await run()
        guard result.status == 0 else {
            throw AIToolConnectorError.commandFailed(code: result.status, diagnostic: result.diagnostic)
        }
        return result.output.isEmpty ? AIToolsCopy.unconfirmed : result.output
    }

    /// Connects every tool it finds and says what happened to each. A tool
    /// that failed is in the report; the command failing as a whole throws.
    public func connect() async throws -> AIToolReport {
        let result = try await run()
        let report = AIToolReport.parse(result.output + "\n" + result.diagnostic)
        guard result.status == 0 || !report.outcomes.isEmpty else {
            throw AIToolConnectorError.commandFailed(code: result.status, diagnostic: result.diagnostic)
        }
        return report
    }

    private func run() async throws -> (status: Int32, output: String, diagnostic: String) {
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
        // A distinct subcommand fails closed with older agents. A new flag on
        // `connect` could be ignored, silently installing hooks and an importer.
        process.arguments = ["register-clients"]
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
        return (process.terminationStatus, output, diagnostic.isEmpty && process.terminationStatus != 0 ? output : diagnostic)
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

/// An AI tool Hippocampus can connect, by the name `register-clients` uses.
public enum AITool: String, CaseIterable, Sendable, Identifiable {
    case claudeCode = "claude-code"
    case codex

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// What `register-clients` did for each tool, read from its one line per
/// tool ("  claude-code: MCP registered, skipped").
public struct AIToolReport: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case connected, notInstalled, failed
    }

    public var outcomes: [AITool: Outcome]

    public init(outcomes: [AITool: Outcome] = [:]) {
        self.outcomes = outcomes
    }

    public static func parse(_ text: String) -> AIToolReport {
        var outcomes: [AITool: Outcome] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for tool in AITool.allCases where trimmed.hasPrefix("\(tool.rawValue): ") {
                let rest = trimmed.dropFirst(tool.rawValue.count + 2)
                if rest.hasPrefix("MCP registered") || rest.hasPrefix("MCP already registered") {
                    outcomes[tool] = .connected
                } else if rest.hasPrefix("not installed") {
                    outcomes[tool] = .notInstalled
                } else if rest.hasPrefix("MCP failed") {
                    outcomes[tool] = .failed
                }
            }
        }
        return AIToolReport(outcomes: outcomes)
    }

    public func tools(_ outcome: Outcome) -> [AITool] {
        AITool.allCases.filter { outcomes[$0] == outcome }
    }
}

/// Which tools have Hippocampus in their settings, read where
/// `register-clients` writes it: `mcpServers.hippocampus` in
/// `~/.claude.json`, `mcp_servers.hippocampus` in Codex's `config.toml`.
/// A file that is missing, too large or unreadable counts as not connected.
public enum AIToolRegistrations {
    public static let serverName = "hippocampus"

    public static func connected(home: URL, codexHome: URL? = nil) -> Set<AITool> {
        var tools: Set<AITool> = []
        if let data = read(home.appendingPathComponent(".claude.json"), limit: 32 << 20),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = object["mcpServers"] as? [String: Any], servers[serverName] != nil {
            tools.insert(.claudeCode)
        }
        let codex = (codexHome ?? home.appendingPathComponent(".codex")).appendingPathComponent("config.toml")
        if let data = read(codex, limit: 4 << 20), let text = String(data: data, encoding: .utf8),
           let table = try? TOMLTable(string: text), table["mcp_servers"]?.table?[serverName] != nil {
            tools.insert(.codex)
        }
        return tools
    }

    /// The homes `register-clients` uses: `HOME`, and `CODEX_HOME` when set.
    public static func connected(environment: [String: String]) -> Set<AITool> {
        let home = environment["HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
        let codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return connected(home: home, codexHome: codexHome)
    }

    private static func read(_ url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }
}

/// Every word of Connect AI Tools… and the AI Tools pane (RULINGS S4,
/// product critique 5, spec-copy S4.5).
public enum AIToolsCopy {
    public static let paneTitle = "AI Tools"
    public static let boundary = "What a connected tool reads goes to the company that runs it. Hippocampus sends nothing on its own."
    /// Said once, in the pane (and the README).
    public static let whileQuit = "Connected tools can still read your memory while Hippocampus is quit. Disconnect a tool to stop that."
    public static let connectButton = "Connect AI Tools…"
    public static let connected = "Connected"
    public static let notConnected = "Not connected"
    public static let sessionToggle = "Start each session with what I’m working on"
    public static let unconfirmed = "Done, but Hippocampus couldn’t confirm it. Restart your AI tool and check."

    /// "Claude Code", or "Claude Code and Codex".
    public static func names(_ tools: [AITool]) -> String {
        let names = tools.map(\.name)
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    // The one question Connect AI Tools… asks.
    public static let questionTitle = "Start each session with what you’re working on?"
    public static let share = "Share"
    public static let dontShare = "Don’t Share"

    public static func questionMessage(_ tools: [AITool]) -> String {
        let who = names(tools)
        let receiver = tools.count == 1 ? "The company that runs \(who) receives it." : "The company that runs each tool receives it."
        return "At the start of each session, \(who) \(tools.count == 1 ? "gets" : "get") a short summary of your recent work, "
            + "with sources. It can include other projects. \(receiver)"
    }

    // The pane's per-tool question (spec-copy S3 #5 and S4.5).
    public static func shareTitle(_ tool: AITool) -> String { "Share your recent work with \(tool.name)?" }

    public static func shareMessage(_ tool: AITool) -> String {
        switch tool {
        case .claudeCode:
            "At the start of each session, Claude Code gets a short summary of your recent work, with sources. "
                + "It can include other projects. The company that runs Claude Code receives it. "
                + "Restart Claude Code after changing this."
        case .codex:
            "Codex is told to ask Hippocampus for a short summary of your recent work, with sources. "
                + "It can include other projects. The company that runs Codex receives it. "
                + "Restart Codex after changing this."
        }
    }

    public static func turnedOn(_ tool: AITool) -> String { "On. Restart \(tool.name) to start." }

    public static func turnedOff(_ tool: AITool) -> String {
        "Off. Restart \(tool.name). What it already read stays in its history."
    }

    public static func status(_ status: SessionContextConfigurationStatus, for tool: AITool) -> String? {
        switch status {
        case .disabledByClient: "Turned off in \(tool.name)’s own settings"
        case .overridden: "Overridden by your AGENTS.override.md file"
        case .configured, .notConfigured: nil
        }
    }

    public struct Result: Equatable, Sendable {
        public let title: String
        public let message: String
    }

    /// How Connect AI Tools… ends: "Connected. Restart {tool}." (RULINGS S4).
    public static func result(_ report: AIToolReport, sessionErrors: [String] = []) -> Result {
        let connected = report.tools(.connected)
        let failed = report.tools(.failed).map { "Couldn’t connect \($0.name). Try again." }
        if !connected.isEmpty {
            let lines = ["Restart \(names(connected))."] + failed + sessionErrors
            return Result(title: Self.connected, message: lines.joined(separator: "\n"))
        }
        if !failed.isEmpty {
            return Result(title: "Couldn’t connect AI tools", message: (failed + [
                "If it keeps happening, use Send feedback in Preferences, About.",
            ]).joined(separator: "\n"))
        }
        if report.outcomes.isEmpty {
            return Result(title: "Done", message: "Hippocampus couldn’t confirm it. Restart your AI tool and check.")
        }
        return Result(title: "No AI tools found", message: "Install Claude Code or Codex, then try again.")
    }
}
