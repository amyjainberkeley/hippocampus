// SPDX-License-Identifier: Apache-2.0
//
// A connected tool's own history (storage review S6): whether other accounts
// on this Mac can open it, read from file modes alone, and Make Private,
// which closes it as `chmod -R go-rwx` would and never follows a link out.
// Throwaway folders only: never the real ~/.claude or ~/.codex.

import Foundation
import XCTest
@testable import HippocampusKit

final class ToolHistoryPrivacyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-history-privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Give every folder back its owner's access, so cleanup can't fail.
        if let walk = FileManager.default.enumerator(atPath: root.path) {
            while let item = walk.nextObject() as? String {
                _ = chmod(root.appendingPathComponent(item).path, 0o700)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ path: String, mode: mode_t) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(url.path, mode), 0)
        return url
    }

    @discardableResult
    private func file(_ path: String, mode: mode_t) throws -> URL {
        let url = root.appendingPathComponent(path)
        try Data("{\"type\":\"session\"}\n".utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, mode), 0)
        return url
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0, url.path)
        return info.st_mode & 0o7777
    }

    /// What the review found on a Mac with two accounts: a home others can
    /// enter, and Codex's sessions in folders and files open to them.
    private func reviewedMac() throws -> (privacy: ToolHistoryPrivacy, files: [URL], folders: [URL]) {
        let home = try folder("home", mode: 0o755)
        let codex = try folder("home/.codex", mode: 0o755)
        let day = try folder("home/.codex/sessions/2026/10/19", mode: 0o755)
        let session = try file("home/.codex/sessions/2026/10/19/rollout-1.jsonl", mode: 0o644)
        let config = try file("home/.codex/config.toml", mode: 0o600)
        // Claude Code's folder is closed to others, though its files say 0644.
        let claude = try folder("home/.claude", mode: 0o700)
        _ = try folder("home/.claude/projects/p", mode: 0o755)
        let transcript = try file("home/.claude/projects/p/s.jsonl", mode: 0o644)
        let privacy = ToolHistoryPrivacy(home: home)
        return (privacy, [session, config, transcript], [codex, day, claude])
    }

    func testAHistoryOthersCanOpenIsFoundAndOnlyThatOne() throws {
        let (privacy, _, _) = try reviewedMac()
        XCTAssertEqual(privacy.openToOthers([.claudeCode, .codex]), [.codex])
    }

    func testMakePrivateClosesTheWholeFolderToOthersAndChangesNothingElse() throws {
        let (privacy, files, folders) = try reviewedMac()
        XCTAssertTrue(privacy.makePrivate(.codex))
        XCTAssertEqual(mode(folders[0]), 0o700, "~/.codex")
        XCTAssertEqual(mode(folders[1]), 0o700, "a day's folder")
        XCTAssertEqual(mode(files[0]), 0o600, "a session")
        XCTAssertEqual(mode(files[1]), 0o600, "already private")
        XCTAssertEqual(mode(files[2]), 0o644, "Claude Code's history is untouched")
        XCTAssertEqual(privacy.openToOthers([.claudeCode, .codex]), [])
    }

    /// Nothing is reachable when the home folder lets no one else in.
    func testAPrivateHomeHidesEverythingInIt() throws {
        let (privacy, _, _) = try reviewedMac()
        XCTAssertEqual(chmod(privacy.home.path, 0o700), 0)
        XCTAssertEqual(privacy.openToOthers([.claudeCode, .codex]), [])
    }

    /// A history kept outside the home folder (CODEX_HOME) is judged by its
    /// own folders, not by the home folder's.
    func testAHistoryOutsideAPrivateHomeIsStillChecked() throws {
        let home = try folder("home", mode: 0o700)
        let codex = try folder("tools/codex", mode: 0o755)
        try file("tools/codex/history.jsonl", mode: 0o644)
        let privacy = ToolHistoryPrivacy(environment: ["HOME": home.path, "CODEX_HOME": codex.path])
        XCTAssertEqual(privacy.openToOthers([.codex, .claudeCode]), [.codex])
        XCTAssertTrue(privacy.makePrivate(.codex))
        XCTAssertEqual(privacy.openToOthers([.codex]), [])
    }

    /// A folder others can enter but whose files are the owner's alone is
    /// not open.
    func testFoldersOthersCanEnterWithPrivateFilesAreNotOpen() throws {
        let home = try folder("home", mode: 0o755)
        _ = try folder("home/.codex/sessions", mode: 0o755)
        try file("home/.codex/sessions/rollout-1.jsonl", mode: 0o600)
        XCTAssertEqual(ToolHistoryPrivacy(home: home).openToOthers([.codex]), [])
    }

    /// A link inside the history is neither counted nor followed: whatever
    /// it points at keeps its mode.
    func testALinkOutOfTheFolderIsNeverFollowed() throws {
        let home = try folder("home", mode: 0o755)
        let codex = try folder("home/.codex", mode: 0o755)
        let elsewhere = try folder("elsewhere", mode: 0o755)
        let outside = try file("elsewhere/notes.txt", mode: 0o644)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("home/.codex/link"), withDestinationURL: elsewhere
        )
        let privacy = ToolHistoryPrivacy(home: home)
        XCTAssertEqual(privacy.openToOthers([.codex]), [])
        XCTAssertTrue(privacy.makePrivate(.codex))
        XCTAssertEqual(mode(codex), 0o700)
        XCTAssertEqual(mode(elsewhere), 0o755)
        XCTAssertEqual(mode(outside), 0o644)
    }

    /// The folders `register-clients` uses: CODEX_HOME and CLAUDE_CONFIG_DIR
    /// when set to a full path, else ~/.codex and ~/.claude; shown with `~`.
    func testTheFoldersFollowTheToolsOwnSettings() throws {
        let home = try folder("home", mode: 0o755)
        let plain = ToolHistoryPrivacy(environment: ["HOME": home.path])
        XCTAssertEqual(plain.folder(for: .codex).path, home.appendingPathComponent(".codex").path)
        XCTAssertEqual(plain.folder(for: .claudeCode).path, home.appendingPathComponent(".claude").path)
        XCTAssertEqual(plain.shownPath(for: .codex), "~/.codex")
        XCTAssertEqual(plain.shownPath(for: .claudeCode), "~/.claude")

        let moved = ToolHistoryPrivacy(environment: [
            "HOME": home.path,
            "CODEX_HOME": home.appendingPathComponent("tools/codex").path,
            "CLAUDE_CONFIG_DIR": "/Volumes/Work/claude",
        ])
        XCTAssertEqual(moved.shownPath(for: .codex), "~/tools/codex")
        XCTAssertEqual(moved.shownPath(for: .claudeCode), "/Volumes/Work/claude")
        XCTAssertEqual(ToolHistoryPrivacy(environment: ["HOME": home.path, "CODEX_HOME": "relative"])
            .shownPath(for: .codex), "~/.codex", "only a full path counts")
    }

    /// Connect AI Tools asks; it never closes a folder on its own.
    func testConnectAIToolsOffersAndNeverActsWithoutTheButton() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Hippocampus/ConnectAITools.swift"), encoding: .utf8)
        let offer = try XCTUnwrap(source.range(of: "private func offerPrivateHistory"))
        let body = source[offer.lowerBound...]
        let button = try XCTUnwrap(body.range(of: "guard alert.runModal() == .alertFirstButtonReturn else { return [] }"))
        let change = try XCTUnwrap(body.range(of: "privacy.makePrivate("))
        XCTAssertLessThan(button.lowerBound, change.lowerBound, "Make Private changes the folder; nothing else does")
        XCTAssertEqual(source.components(separatedBy: "makePrivate(").count - 1, 1, "one place changes it")
    }
}
