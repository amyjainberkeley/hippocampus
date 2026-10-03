// SPDX-License-Identifier: TBD-private
import XCTest
@testable import HippocampusKit

/// The Swift app and `mci-agent connect --all` (`apps/agent/src/client_hooks.rs`)
/// edit the same `~/.claude/settings.json` group. These tests pin the shape the
/// app's non-importing variant and the two markers both sides recognise.
/// Everything runs in a sandbox; the real home is never read.
final class SessionContextInstallerTests: XCTestCase {

    private var sandbox: URL!
    private var installer: SessionContextInstaller!
    private var settings: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("SessionContextInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        installer = SessionContextInstaller(
            homeURL: sandbox,
            executableURL: sandbox.appendingPathComponent("Hippocampus.app/Contents/MacOS/Hippocampus"),
            dbURL: sandbox.appendingPathComponent("Application Support/MCI/mci.sqlite")
        )
        settings = installer.claudeSettingsURL
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - Helpers

    private func write(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: settings)
    }

    private func read() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
    }

    private func sessionStarts() throws -> [[String: Any]] {
        let hooks = try XCTUnwrap(read()["hooks"] as? [String: Any])
        return hooks["SessionStart"] as? [[String: Any]] ?? []
    }

    private func group(command: String, timeout: Int = 10) -> [String: Any] {
        ["matcher": "startup|resume|clear|compact", "hooks": [
            ["type": "command", "command": command, "timeout": timeout]
        ]]
    }

    private var userHook: [String: Any] {
        ["matcher": "startup", "hooks": [["type": "command", "command": "echo user-hook"]]]
    }

    /// What `client_hooks.rs` writes, rendered here independently of the
    /// installer so a drift on either side fails this test.
    private var rustCommand: String {
        func quote(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }
        let agent = installer.executableURL.deletingLastPathComponent().appendingPathComponent("mci-agent").path
        return "\(quote(agent)) handoff --format claude-hook --db-path \(quote(installer.dbURL.path))"
    }

    // MARK: - Status

    func testStatusRecognisesTheNewMarker() throws {
        try write(["hooks": ["SessionStart": [userHook, group(command: installer.claudeCommand)]]])
        XCTAssertEqual(try installer.claudeStatus(), .configured)
    }

    func testStatusRecognisesTheLegacyMarker() throws {
        try write(["hooks": ["SessionStart": [group(command: installer.legacyClaudeCommand)]]])
        XCTAssertEqual(try installer.claudeStatus(), .configured)
    }

    func testStatusIsNotConfiguredWithoutEitherMarker() throws {
        try write(["hooks": ["SessionStart": [userHook]], "theme": "dark"])
        XCTAssertEqual(try installer.claudeStatus(), .notConfigured)
        XCTAssertEqual(try SessionContextInstaller(
            homeURL: sandbox.appendingPathComponent("empty"),
            executableURL: installer.executableURL, dbURL: installer.dbURL
        ).claudeStatus(), .notConfigured)
    }

    // MARK: - Enable

    func testPreviousImportingHookCanBeReviewedOrRemoved() throws {
        let previous = ["hooks": ["SessionStart": [userHook, group(command: rustCommand)]]]
        try write(previous)
        XCTAssertEqual(try installer.claudeStatus(), .configured)
        try installer.setClaudeEnabled(true)
        let enabled = try sessionStarts()
        XCTAssertEqual(enabled.count, 2)
        XCTAssertEqual(enabled[0]["matcher"] as? String, "startup")
        let handlers = try XCTUnwrap(enabled[1]["hooks"] as? [[String: Any]])
        XCTAssertEqual(handlers[0]["command"] as? String, rustCommand + " --no-refresh")

        try write(previous)
        try installer.setClaudeEnabled(false)
        let remaining = try sessionStarts()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0]["matcher"] as? String, "startup")
    }

    func testEnableSharesExistingMemoryWithoutImportingTranscripts() throws {
        try installer.setClaudeEnabled(true)

        let starts = try sessionStarts()
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts[0]["matcher"] as? String, "startup|resume|clear|compact")
        let handlers = try XCTUnwrap(starts[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(handlers.count, 1)
        XCTAssertEqual(handlers[0]["type"] as? String, "command")
        XCTAssertEqual(handlers[0]["timeout"] as? Int, 10)
        XCTAssertEqual(handlers[0]["command"] as? String, rustCommand + " --no-refresh")
        XCTAssertEqual(installer.claudeCommand, rustCommand + " --no-refresh")
        XCTAssertEqual(handlers[0].count, 3, "no extra keys the Rust side would not write")
        XCTAssertTrue(rustCommand.contains(SessionContextInstaller.handoffMarker))
        XCTAssertFalse(rustCommand.contains(SessionContextHook.flag))
        XCTAssertEqual(installer.agentURL.lastPathComponent, "mci-agent")
        XCTAssertEqual(installer.agentURL.deletingLastPathComponent(), installer.executableURL.deletingLastPathComponent())
    }

    func testEnableQuotesPathsWithSingleQuotesLikeTheRustSide() throws {
        let odd = SessionContextInstaller(
            homeURL: sandbox,
            executableURL: sandbox.appendingPathComponent("It's Here.app/Contents/MacOS/Hippocampus"),
            dbURL: sandbox.appendingPathComponent("db's.sqlite")
        )
        let agent = sandbox.appendingPathComponent("It's Here.app/Contents/MacOS/mci-agent").path
            .replacingOccurrences(of: "'", with: "'\"'\"'")
        let db = sandbox.appendingPathComponent("db's.sqlite").path
            .replacingOccurrences(of: "'", with: "'\"'\"'")
        XCTAssertEqual(odd.claudeCommand, "'\(agent)' handoff --format claude-hook --db-path '\(db)' --no-refresh")
    }

    func testEnableOverTheLegacyGroupReplacesItInPlace() throws {
        let after: [String: Any] = ["matcher": "compact", "hooks": [["type": "command", "command": "echo after"]]]
        try write([
            "hooks": ["SessionStart": [userHook, group(command: installer.legacyClaudeCommand), after]],
            "theme": "dark",
        ])

        try installer.setClaudeEnabled(true)

        let starts = try sessionStarts()
        XCTAssertEqual(starts.count, 3, "replaced, not appended")
        XCTAssertEqual(starts[0]["matcher"] as? String, "startup")
        XCTAssertEqual(starts[2]["matcher"] as? String, "compact")
        let handlers = try XCTUnwrap(starts[1]["hooks"] as? [[String: Any]])
        XCTAssertEqual(handlers[0]["command"] as? String, installer.claudeCommand)
        XCTAssertEqual(try read()["theme"] as? String, "dark")
        let text = try String(contentsOf: settings, encoding: .utf8)
        XCTAssertFalse(text.contains(SessionContextHook.flag))
        XCTAssertEqual(try installer.claudeStatus(), .configured)
    }

    func testEnableIsIdempotentOverTheNewShape() throws {
        try installer.setClaudeEnabled(true)
        let first = try Data(contentsOf: settings)
        try installer.setClaudeEnabled(true)
        XCTAssertEqual(try Data(contentsOf: settings), first)
        XCTAssertEqual(try sessionStarts().count, 1)
    }

    // MARK: - Disable

    func testDisableRemovesTheNewShapeAndKeepsEverythingElse() throws {
        try write(["hooks": ["SessionStart": [userHook], "Stop": [["hooks": []]]], "theme": "dark"])
        let original = try read() as NSDictionary
        try installer.setClaudeEnabled(true)
        XCTAssertEqual(try sessionStarts().count, 2)

        try installer.setClaudeEnabled(false)

        XCTAssertEqual(try read() as NSDictionary, original)
        XCTAssertEqual(try installer.claudeStatus(), .notConfigured)
    }

    func testDisableRemovesTheLegacyShapeToo() throws {
        try write(["hooks": ["SessionStart": [group(command: installer.legacyClaudeCommand)]], "theme": "dark"])

        try installer.setClaudeEnabled(false)

        let object = try read()
        XCTAssertNil(object["hooks"], "empty containers are pruned")
        XCTAssertEqual(object["theme"] as? String, "dark")
    }

    func testDisableWithoutOurGroupIsANoOp() throws {
        try write(["hooks": ["SessionStart": [userHook]]])
        let before = try Data(contentsOf: settings)
        try installer.setClaudeEnabled(false)
        XCTAssertEqual(try Data(contentsOf: settings), before)
    }

    // MARK: - Conflicts

    func testEditedGroupWithOurMarkerIsAConflictInEitherShape() throws {
        for command in [installer.claudeCommand, installer.legacyClaudeCommand] {
            try write(["hooks": ["SessionStart": [group(command: command, timeout: 20)]]])
            let before = try Data(contentsOf: settings)
            XCTAssertThrowsError(try installer.claudeStatus()) { error in
                XCTAssertEqual(error as? SessionContextInstallError, .conflict)
            }
            XCTAssertThrowsError(try installer.setClaudeEnabled(true))
            XCTAssertThrowsError(try installer.setClaudeEnabled(false))
            XCTAssertEqual(try Data(contentsOf: settings), before, "conflicts never write")
        }
    }

    func testTwoCanonicalGroupsAreAConflict() throws {
        try write(["hooks": ["SessionStart": [
            group(command: installer.legacyClaudeCommand), group(command: installer.claudeCommand),
        ]]])
        XCTAssertThrowsError(try installer.claudeStatus()) { error in
            XCTAssertEqual(error as? SessionContextInstallError, .conflict)
        }
    }

    func testDisabledHooksSwitchStillWins() throws {
        try write(["disableAllHooks": true, "hooks": ["SessionStart": [group(command: installer.claudeCommand)]]])
        XCTAssertEqual(try installer.claudeStatus(), .disabledByClient)
        XCTAssertThrowsError(try installer.setClaudeEnabled(true))
    }
}
