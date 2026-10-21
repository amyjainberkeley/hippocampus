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
        let result = try await run(["register-clients"])
        guard result.status == 0 else {
            throw AIToolConnectorError.commandFailed(code: result.status, diagnostic: result.diagnostic)
        }
        return result.output.isEmpty ? AIToolsCopy.unconfirmed : result.output
    }

    /// Connects every tool it finds and says what happened to each. A tool
    /// that failed is in the report; the command failing as a whole throws.
    public func connect() async throws -> AIToolReport {
        let result = try await run(["register-clients"])
        let report = AIToolReport.parse(result.output + "\n" + result.diagnostic)
        guard result.status == 0 || !report.outcomes.isEmpty else {
            throw AIToolConnectorError.commandFailed(code: result.status, diagnostic: result.diagnostic)
        }
        return report
    }

    /// What each tool has of Hippocampus now (`mci-agent clients`): content-
    /// free, and without the memory's key.
    public func clients() async throws -> [AITool: AIToolState] {
        let result = try await run(["clients", "--json"])
        guard result.status == 0 else {
            throw AIToolConnectorError.commandFailed(code: result.status, diagnostic: result.diagnostic)
        }
        return AIToolState.parse(result.output)
    }

    /// Disconnect (SPEC 5.5): Hippocampus's look-up entry taken out of each
    /// tool's settings. The hooks and Codex's instruction are taken out by
    /// `SessionContextInstaller`. Each tool's answer: true when its entry is
    /// gone (or there was none).
    public func disconnect(_ tools: [AITool]) async throws -> [AITool: Bool] {
        let which = Set(tools) == Set(AITool.allCases) ? "all" : (tools.first?.rawValue ?? "all")
        let result = try await run(["clients", "--disconnect", which, "--json"])
        guard result.status == 0,
              let object = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
              let done = object["disconnected"] as? [[String: Any]] else {
            throw AIToolConnectorError.commandFailed(code: result.status, diagnostic: result.diagnostic)
        }
        var out: [AITool: Bool] = [:]
        for entry in done {
            guard let id = entry["id"] as? String, let tool = AITool(rawValue: id) else { continue }
            out[tool] = (entry["look_ups"] as? String) != "failed"
        }
        return out
    }

    private func run(_ arguments: [String]) async throws -> (status: Int32, output: String, diagnostic: String) {
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
        process.arguments = arguments
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

/// What a tool has of Hippocampus, as `mci-agent clients --json` says.
public struct AIToolState: Equatable, Sendable {
    /// Its command or its settings are on this Mac.
    public var installed: Bool
    /// "Look things up in my memory" is on.
    public var lookUps: Bool
    /// `on`, `off`, `turned_off_in_tool`, `overridden` or `unavailable`.
    public var sessionStart: String
    /// `hook` or `instruction`, when its sessions start with recent work.
    public var startKind: String?
    /// Codex hasn't run Hippocampus's new hook yet: it needs the person to
    /// allow it once.
    public var needsStep: Bool

    public init(installed: Bool, lookUps: Bool, sessionStart: String, startKind: String? = nil, needsStep: Bool = false) {
        self.installed = installed
        self.lookUps = lookUps
        self.sessionStart = sessionStart
        self.startKind = startKind
        self.needsStep = needsStep
    }

    /// Connected: it looks things up, or its sessions start with recent work.
    public var isConnected: Bool { lookUps || sessionStart == "on" }

    static func parse(_ json: String) -> [AITool: AIToolState] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let tools = object["tools"] as? [[String: Any]] else { return [:] }
        var out: [AITool: AIToolState] = [:]
        for entry in tools {
            guard let id = entry["id"] as? String, let tool = AITool(rawValue: id) else { continue }
            out[tool] = AIToolState(
                installed: entry["installed"] as? Bool ?? false,
                lookUps: entry["look_ups"] as? String == "on",
                sessionStart: entry["session_start"] as? String ?? "off",
                startKind: entry["start_kind"] as? String,
                needsStep: entry["needs_step"] as? String == "allow_hooks"
            )
        }
        return out
    }
}

/// Per tool, here rather than in SessionContextInstaller.swift, which the
/// standalone session-context check compiles without this file.
extension SessionContextInstaller {
    /// Turns starting each session with recent work on or off for one tool.
    public func setEnabled(_ enabled: Bool, for tool: AITool) throws {
        switch tool {
        case .claudeCode: try setClaudeEnabled(enabled)
        case .codex: try setCodexEnabled(enabled)
        }
    }

    public func status(for tool: AITool) throws -> SessionContextConfigurationStatus {
        switch tool {
        case .claudeCode: try claudeStatus()
        case .codex: try codexStatus()
        }
    }
}

/// Which tools have Hippocampus in their settings, read where
/// `register-clients` writes it: `mcpServers.hippocampus` in
/// `~/.claude.json`, `mcp_servers.hippocampus` in Codex's `config.toml`.
/// A file that is missing, too large or unreadable counts as not connected.
public enum AIToolRegistrations {
    public static let serverName = "hippocampus"

    public static func connected(home: URL, codexHome: URL? = nil, claudeConfigDir: URL? = nil) -> Set<AITool> {
        var tools: Set<AITool> = []
        // CLAUDE_CONFIG_DIR moves Claude Code's .claude.json (SPEC 5.5).
        if let data = read((claudeConfigDir ?? home).appendingPathComponent(".claude.json"), limit: 32 << 20),
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

    /// The homes `register-clients` uses: `HOME`, and `CODEX_HOME` and
    /// `CLAUDE_CONFIG_DIR` when set.
    public static func connected(environment: [String: String]) -> Set<AITool> {
        let home = environment["HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
        func directory(_ key: String) -> URL? {
            environment[key].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        }
        return connected(home: home, codexHome: directory("CODEX_HOME"), claudeConfigDir: directory("CLAUDE_CONFIG_DIR"))
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
    /// The pane's lead (SPEC 5.5): what leaves this Mac, and only that.
    public static let boundary = HandoffCopy.lead
    /// Said once, in the pane (and the README).
    public static let whileQuit = HandoffCopy.whileQuit
    public static let connectButton = "Connect AI Tools…"
    public static let connected = "Connected"
    public static let notConnected = "Not connected"
    /// What it sends, named for what it is (SPEC 5.4): "Working On" now
    /// names the sidebar's list, which no tool receives.
    public static let sessionToggle = HandoffCopy.sessionSwitch
    public static let unconfirmed = "Done, but Hippocampus couldn’t confirm it. Restart your AI tool and check."

    /// "Claude Code", or "Claude Code and Codex".
    public static func names(_ tools: [AITool]) -> String {
        let names = tools.map(\.name)
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    // Connect AI Tools… asks first whether the tools may look things up
    // (SPEC 5.4), naming the tools it found.
    public static func connectTitle(_ tools: [AITool]) -> String { HandoffCopy.connectTitle(names(tools)) }

    public static func connectMessage(_ tools: [AITool], chatGPTInstalled: Bool) -> String {
        HandoffCopy.connectMessage(names(tools), count: tools.count, chatGPTInstalled: chatGPTInstalled && tools.contains(.codex))
    }

    // Then the session-start question, for the tools whose sessions can
    // start with recent work.
    public static let questionTitle = HandoffCopy.sessionTitle
    public static let share = "Share"
    public static let dontShare = "Don’t Share"

    public static func questionMessage(_ tools: [AITool]) -> String {
        HandoffCopy.sessionMessage(names(tools), count: tools.count, codex: tools.contains(.codex))
    }

    // Then, for the connected tools whose own history other accounts on this
    // Mac can open, an offer to make it private (storage review S6).
    public static func privateHistoryTitle(_ tools: [AITool]) -> String {
        HandoffCopy.privateHistoryTitle(tools.map(\.name))
    }

    public static func privateHistoryMessage(_ tools: [AITool], privacy: ToolHistoryPrivacy) -> String {
        HandoffCopy.privateHistoryMessage(tools.map(\.name), folders: tools.map(privacy.shownPath(for:)))
    }

    public static let makePrivate = HandoffCopy.makePrivate

    public static func couldNotMakePrivate(_ tool: AITool) -> String { HandoffCopy.couldNotMakePrivate(tool.name) }

    // The pane's per-tool question: the same question, for one tool.
    public static func shareTitle(_ tool: AITool) -> String { HandoffCopy.sessionTitle }

    public static func shareMessage(_ tool: AITool) -> String { questionMessage([tool]) }

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
