// SPDX-License-Identifier: Apache-2.0
//
// DestinationDetector.swift — which AI tools Ask {Tool} can open on this Mac
// (SPEC 5.3.2): the app that handles each tool's link, ChatGPT's app by its
// bundle id, and Claude Code's command line where its installers put it.
// When two versions of a tool are installed, the one that handles the link
// wins. The menu-bar app has its own copy of this code (the two apps share
// no Swift package); both are tested.

import AppKit
import Foundation

/// How a tool is on this Mac.
public struct InstalledTool: Equatable, Hashable, Sendable, Identifiable {
    public let tool: AskTool
    /// The app that opens it, when there is one.
    public let appURL: URL?
    /// Claude Code's command line, when only that is here.
    public let commandLine: String?

    public var id: String { tool.rawValue }

    public init(tool: AskTool, appURL: URL?, commandLine: String? = nil) {
        self.tool = tool
        self.appURL = appURL
        self.commandLine = commandLine
    }

    /// Whether Ask opens it through its link (or, for ChatGPT, its app).
    public var hasApp: Bool { appURL != nil }
}

/// Finds the AI tools on this Mac. Every lookup is injected, so tests and
/// the renderer never ask the real system.
public struct DestinationDetector: Sendable {
    public var appForScheme: @Sendable (String) -> URL?
    public var appForBundle: @Sendable (String) -> URL?
    public var isExecutable: @Sendable (String) -> Bool
    public var environment: [String: String]

    public init(
        appForScheme: @escaping @Sendable (String) -> URL?,
        appForBundle: @escaping @Sendable (String) -> URL?,
        isExecutable: @escaping @Sendable (String) -> Bool,
        environment: [String: String]
    ) {
        self.appForScheme = appForScheme
        self.appForBundle = appForBundle
        self.isExecutable = isExecutable
        self.environment = environment
    }

    /// This Mac: Launch Services for the apps, the file system for the
    /// command line.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> DestinationDetector {
        DestinationDetector(
            appForScheme: { scheme in
                URL(string: "\(scheme)://").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            },
            appForBundle: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            environment: environment
        )
    }

    /// No tools at all.
    public static let none = DestinationDetector(
        appForScheme: { _ in nil }, appForBundle: { _ in nil }, isExecutable: { _ in false }, environment: [:]
    )

    /// ChatGPT's desktop apps.
    public static let chatGPTBundles = ["com.openai.chat"]

    /// The tools on this Mac, in the menu's order.
    public func installed() -> [InstalledTool] {
        AskTool.menuOrder.compactMap { tool in
            switch tool {
            case .chatgpt:
                return Self.chatGPTBundles.lazy.compactMap(appForBundle).first
                    .map { InstalledTool(tool: tool, appURL: $0) }
            case .claudeCode:
                let app = appForScheme("claude")
                let line = app == nil ? claudeCommandLine() : nil
                guard app != nil || line != nil else { return nil }
                return InstalledTool(tool: tool, appURL: app, commandLine: line)
            default:
                return tool.scheme.flatMap(appForScheme).map { InstalledTool(tool: tool, appURL: $0) }
            }
        }
    }

    /// Claude Code's command line: where its installers put it, or on PATH.
    public func claudeCommandLine() -> String? {
        let home = environment["HOME"] ?? NSHomeDirectory()
        var places = ["/usr/local/bin/claude", "/opt/homebrew/bin/claude", home + "/.local/bin/claude"]
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            places.append(String(directory) + "/claude")
        }
        return places.first(where: isExecutable)
    }
}

/// Open Terminal Here (SPEC 5.3.4), after Claude Code's message was copied
/// for its command line: Terminal, and only Terminal, in the project's
/// folder, and only a folder on this Mac.
@MainActor
public enum TerminalHere {
    public static let bundleIdentifier = "com.apple.Terminal"

    /// The folder Terminal opens in: a directory on this Mac, or nil.
    public static func folder(
        _ url: URL,
        isDirectory: (String) -> Bool = { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }
    ) -> URL? {
        guard url.isFileURL, isDirectory(url.path) else { return nil }
        return url
    }

    /// Opens Terminal in `folder`. False when the folder or Terminal isn't here.
    @discardableResult
    public static func open(_ folder: URL) -> Bool {
        guard let folder = Self.folder(folder),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return false }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
