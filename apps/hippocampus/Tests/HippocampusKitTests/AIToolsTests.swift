// SPDX-License-Identifier: Apache-2.0
//
// Connect AI Tools… in one step (RULINGS S4, product critique 5): what the
// connector reports per tool, whether a tool is connected, and every word
// of the question and the ending. Fixtures only; nothing reads a real home.

import XCTest
@testable import HippocampusKit

final class AIToolsTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ai-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: The report

    /// The lines `mci-agent register-clients` prints (`print_connect_receipt`).
    func testTheReportIsReadToolByTool() {
        let report = AIToolReport.parse("""
          claude-code: MCP registered, skipped
          codex: not installed, skipped
        Session hooks and transcript refresh were not changed.
        """)
        XCTAssertEqual(report.outcomes, [.claudeCode: .connected, .codex: .notInstalled])
        XCTAssertEqual(AIToolReport.parse("  claude-code: MCP already registered, skipped").outcomes,
                       [.claudeCode: .connected])
        XCTAssertEqual(AIToolReport.parse("  codex: MCP failed: config.toml is malformed, skipped").outcomes,
                       [.codex: .failed])
        XCTAssertEqual(AIToolReport.parse("connected-line-00001").outcomes, [:])
    }

    private func agent(_ script: String) throws -> URL {
        let url = home.appendingPathComponent("agent")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// One tool failing still reports the other; it prints to stderr and
    /// exits 14.
    func testOneToolFailingStillReportsTheOther() async throws {
        let url = try agent("""
        #!/bin/sh
        echo '  claude-code: MCP registered, skipped'
        echo '  codex: MCP failed: denied, skipped' >&2
        exit 14
        """)
        let report = try await AIToolConnector(agentURL: url, baseEnvironment: [:]).connect()
        XCTAssertEqual(report.outcomes, [.claudeCode: .connected, .codex: .failed])
    }

    func testTheCommandFailingAsAWholeThrowsWithoutItsText() async throws {
        let url = try agent("#!/bin/sh\necho 'mci-agent register-clients: HOME not set' >&2\nexit 14\n")
        do {
            _ = try await AIToolConnector(agentURL: url, baseEnvironment: [:]).connect()
            XCTFail("expected a failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("HOME"))
            XCTAssertEqual(error.localizedDescription,
                           "Try again. If it keeps happening, use Send feedback in Preferences, About.")
        }
    }

    func testAMissingConnectorSaysPartOfHippocampusIsMissing() async {
        do {
            _ = try await AIToolConnector(agentURL: home.appendingPathComponent("missing"), baseEnvironment: [:]).connect()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Part of Hippocampus is missing. Reinstall it, then try again.")
        }
    }

    // MARK: Connected

    func testAToolIsConnectedWhenItsSettingsNameHippocampus() throws {
        XCTAssertEqual(AIToolRegistrations.connected(home: home), [])
        try #"{"projects":{},"mcpServers":{"other":{},"hippocampus":{"command":"/x"}}}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AIToolRegistrations.connected(home: home), [.claudeCode])

        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try "model = \"x\"\n\n[mcp_servers.hippocampus]\ncommand = \"/x\"\n"
            .write(to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AIToolRegistrations.connected(home: home), [.claudeCode, .codex])
    }

    func testOtherServersOrUnreadableSettingsAreNotConnected() throws {
        try #"{"mcpServers":{"hippocampus-old":{}}}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try "[mcp_servers.hippocampus\n".write(to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AIToolRegistrations.connected(home: home), [])
    }

    func testCodexHomeMovesCodexsSettings() throws {
        let elsewhere = home.appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try "[mcp_servers.hippocampus]\ncommand = \"/x\"\n"
            .write(to: elsewhere.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AIToolRegistrations.connected(environment: ["HOME": home.path, "CODEX_HOME": elsewhere.path]),
                       [.codex])
        XCTAssertEqual(AIToolRegistrations.connected(environment: ["HOME": home.path]), [])
    }

    // MARK: The words

    func testTheOneQuestion() {
        XCTAssertEqual(AIToolsCopy.questionTitle, "Start each session with what you’re working on?")
        XCTAssertEqual(AIToolsCopy.questionMessage([.claudeCode]),
                       "At the start of each session, Claude Code gets a short summary of your recent work, "
                       + "with sources. It can include other projects. The company that runs Claude Code receives it.")
        XCTAssertEqual(AIToolsCopy.questionMessage([.claudeCode, .codex]),
                       "At the start of each session, Claude Code and Codex get a short summary of your recent work, "
                       + "with sources. It can include other projects. The company that runs each tool receives it.")
        XCTAssertEqual([AIToolsCopy.share, AIToolsCopy.dontShare], ["Share", "Don’t Share"])
    }

    /// It ends on "Connected. Restart {tool}." (RULINGS S4).
    func testItEndsOnConnectedRestartTheTool() {
        let one = AIToolsCopy.result(AIToolReport(outcomes: [.claudeCode: .connected, .codex: .notInstalled]))
        XCTAssertEqual(one, AIToolsCopy.Result(title: "Connected", message: "Restart Claude Code."))
        let both = AIToolsCopy.result(AIToolReport(outcomes: [.claudeCode: .connected, .codex: .connected]))
        XCTAssertEqual(both.message, "Restart Claude Code and Codex.")
        let partly = AIToolsCopy.result(AIToolReport(outcomes: [.claudeCode: .connected, .codex: .failed]),
                                        sessionErrors: ["Hooks are turned off in Claude Code’s settings. Turn them on there first."])
        XCTAssertEqual(partly.title, "Connected")
        XCTAssertEqual(partly.message, "Restart Claude Code.\nCouldn’t connect Codex. Try again.\n"
                       + "Hooks are turned off in Claude Code’s settings. Turn them on there first.")
    }

    func testItSaysWhenNothingWasConnected() {
        XCTAssertEqual(AIToolsCopy.result(AIToolReport(outcomes: [.claudeCode: .notInstalled, .codex: .notInstalled])),
                       AIToolsCopy.Result(title: "No AI tools found", message: "Install Claude Code or Codex, then try again."))
        XCTAssertEqual(AIToolsCopy.result(AIToolReport(outcomes: [.codex: .failed])).title, "Couldn’t connect AI tools")
        XCTAssertEqual(AIToolsCopy.result(AIToolReport()).message,
                       "Hippocampus couldn’t confirm it. Restart your AI tool and check.")
    }

    /// Said once, in the pane (RULINGS S4), and the pane's own words
    /// (product critique 5, spec-copy S4.5).
    func testThePanesWords() {
        XCTAssertEqual(AIToolsCopy.whileQuit,
                       "Connected tools can still read your memory while Hippocampus is quit. Disconnect a tool to stop that.")
        XCTAssertEqual(AIToolsCopy.paneTitle, "AI Tools")
        XCTAssertEqual(AIToolsCopy.sessionToggle, "Start each session with what I’m working on")
        XCTAssertEqual(AIToolsCopy.turnedOn(.codex), "On. Restart Codex to start.")
        XCTAssertEqual(AIToolsCopy.turnedOff(.claudeCode), "Off. Restart Claude Code. What it already read stays in its history.")
        XCTAssertEqual(AIToolsCopy.status(.disabledByClient, for: .claudeCode), "Turned off in Claude Code’s own settings")
        XCTAssertEqual(AIToolsCopy.status(.overridden, for: .codex), "Overridden by your AGENTS.override.md file")
        XCTAssertNil(AIToolsCopy.status(.configured, for: .codex))
        for words in [AIToolsCopy.boundary, AIToolsCopy.whileQuit, AIToolsCopy.questionMessage([.codex]),
                      AIToolsCopy.shareMessage(.claudeCode), AIToolsCopy.shareMessage(.codex)] {
            for banned in ["MCP", "provider", "register", "client", "verified", "brain", "packet"] {
                XCTAssertFalse(words.lowercased().contains(banned.lowercased()), "\(banned) in \(words)")
            }
        }
    }
}

final class PermissionResetTests: XCTestCase {
    /// Only Hippocampus's own grants: without the bundle id, tccutil resets
    /// the service for every app on the Mac (RULINGS S10).
    func testResetNamesTheAppForEveryService() {
        var calls: [(URL, [String])] = []
        let failed = PermissionReset.reset { url, arguments in
            calls.append((url, arguments))
            return 0
        }
        XCTAssertEqual(failed, [])
        XCTAssertEqual(calls.map(\.0), Array(repeating: URL(fileURLWithPath: "/usr/bin/tccutil"), count: 3))
        XCTAssertEqual(calls.map(\.1), [
            ["reset", "ScreenCapture", "ai.hippocampus"],
            ["reset", "Accessibility", "ai.hippocampus"],
            ["reset", "SystemPolicyAllFiles", "ai.hippocampus"],
        ])
    }

    func testAFailedResetSaysWhichPermissionAndWhereToResetIt() {
        let failed = PermissionReset.reset { _, arguments in arguments[1] == "Accessibility" ? 1 : (arguments[1] == "ScreenCapture" ? nil : 0) }
        XCTAssertEqual(failed, ["Screen Recording", "Accessibility"])
        XCTAssertEqual(PermissionReset.failureMessage(names: ["Accessibility"]),
                       "Couldn’t reset Accessibility. Reset it in System Settings, under Privacy & Security.")
    }

    func testTheWords() {
        XCTAssertEqual(PermissionReset.confirmTitle, "Reset permissions?")
        XCTAssertEqual(PermissionReset.confirmMessage,
                       "macOS will forget that you allowed Screen Recording, Accessibility and Full Disk Access. "
                       + "Hippocampus asks again next time it opens.")
        XCTAssertEqual(PermissionReset.doneTitle, "Permissions reset")
        XCTAssertEqual(PermissionReset.doneMessage, "Restart Hippocampus to allow them again.")
    }
}

final class PreferencesSectionLabelTests: XCTestCase {
    /// People read the names; links and the toolbar keep the raw values.
    func testSectionsAreNamedAsPeopleReadThem() {
        XCTAssertEqual(PreferencesSection.allCases.map(\.label),
                       ["General", "Remembering", "AI Tools", "Privacy", "Advanced", "About"])
        XCTAssertEqual(PreferencesSection.allCases.map(\.rawValue),
                       ["General", "Capture", "Sources", "Privacy", "Advanced", "About"])
    }
}
