// SPDX-License-Identifier: Apache-2.0
//
// ToolHistoryPrivacy.swift — a connected AI tool keeps its own history
// (storage review S6). Claude Code saves every session in ~/.claude (or
// CLAUDE_CONFIG_DIR) and Codex in ~/.codex (or CODEX_HOME), unencrypted, and
// what they read from your memory is in it, where Hippocampus's encryption,
// retention and forgetting don't reach. On a Mac with more than one account,
// those folders can be open to the others. Connect AI Tools… checks, by
// file modes alone (it never opens a file), and offers to make them private
// to you. Nothing changes unless you choose Make Private.

import Foundation

public struct ToolHistoryPrivacy: Sendable {
    public let home: URL
    public let codexHome: URL?
    public let claudeConfigDir: URL?

    public init(home: URL, codexHome: URL? = nil, claudeConfigDir: URL? = nil) {
        self.home = home
        self.codexHome = codexHome
        self.claudeConfigDir = claudeConfigDir
    }

    /// The folders `register-clients` uses: `HOME`, and `CODEX_HOME` and
    /// `CLAUDE_CONFIG_DIR` when they are set to a full path.
    public init(environment: [String: String]) {
        func directory(_ key: String) -> URL? {
            environment[key].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        }
        self.init(
            home: directory("HOME") ?? FileManager.default.homeDirectoryForCurrentUser,
            codexHome: directory("CODEX_HOME"),
            claudeConfigDir: directory("CLAUDE_CONFIG_DIR")
        )
    }

    /// The folder where `tool` keeps its sessions.
    public func folder(for tool: AITool) -> URL {
        switch tool {
        case .claudeCode: claudeConfigDir ?? home.appendingPathComponent(".claude")
        case .codex: codexHome ?? home.appendingPathComponent(".codex")
        }
    }

    /// The folder as the person knows it: `~/.codex` inside the home folder.
    public func shownPath(for tool: AITool) -> String {
        let path = folder(for: tool).standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~" + path.dropFirst(homePath.count)
    }

    /// The tools among `tools` whose history another account on this Mac can
    /// open: a file in it that group or others may read, inside folders they
    /// may enter, and, for a folder in the home folder, a home folder they
    /// may enter. Read from file modes only.
    public func openToOthers(_ tools: [AITool]) -> [AITool] {
        let homeFolder = home.resolvingSymlinksInPath()
        let homeIsOpen = Self.mode(of: homeFolder.path).map { Self.isFolder($0) && $0 & 0o011 != 0 } ?? false
        return tools.filter { tool in
            let folder = folder(for: tool).resolvingSymlinksInPath()
            if folder.path.hasPrefix(homeFolder.path + "/"), !homeIsOpen { return false }
            return Self.holdsOpenFile(folder)
        }
    }

    /// Makes `tool`'s history private to you, as `chmod -R go-rwx` would: no
    /// read, write or entry for group or others on the folder or anything in
    /// it. A link is never followed out of it. False when something couldn't
    /// be changed.
    @discardableResult
    public func makePrivate(_ tool: AITool) -> Bool {
        let root = folder(for: tool).resolvingSymlinksInPath()
        guard let rootMode = Self.mode(of: root.path), Self.isFolder(rootMode) else { return false }
        return Self.closeTree(root, mode: rootMode)
    }

    // MARK: Modes

    private static func mode(of path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode
    }

    private static func isFolder(_ mode: mode_t) -> Bool { mode & S_IFMT == S_IFDIR }
    private static func isFile(_ mode: mode_t) -> Bool { mode & S_IFMT == S_IFREG }

    private static func children(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    /// A file group or others may read, reached only through folders they
    /// may enter. Links are skipped.
    private static func holdsOpenFile(_ folder: URL) -> Bool {
        guard let folderMode = Self.mode(of: folder.path), isFolder(folderMode), folderMode & 0o011 != 0 else {
            return false
        }
        for child in children(of: folder) {
            guard let childMode = Self.mode(of: child.path) else { continue }
            if isFile(childMode), childMode & 0o044 != 0 { return true }
            if isFolder(childMode), holdsOpenFile(child) { return true }
        }
        return false
    }

    private static func closeTree(_ folder: URL, mode folderMode: mode_t) -> Bool {
        var closed = close(folder.path, mode: folderMode)
        for child in children(of: folder) {
            guard let childMode = Self.mode(of: child.path) else { continue }
            if isFolder(childMode) {
                closed = closeTree(child, mode: childMode) && closed
            } else if isFile(childMode) {
                closed = close(child.path, mode: childMode) && closed
            }
        }
        return closed
    }

    private static func close(_ path: String, mode: mode_t) -> Bool {
        guard mode & 0o077 != 0 else { return true }
        return chmod(path, mode & 0o7700) == 0
    }
}
