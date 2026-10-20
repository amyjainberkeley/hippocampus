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
    /// The bundle id of the app at a URL, to tell a tool's own app from
    /// another that claims its link (`linkOwners`). Nil where the lookups
    /// above are fixtures that name each tool's own app.
    public var bundleIdentifier: (@Sendable (URL) -> String?)?

    /// Lookups that name each tool's own app: tests and pictures.
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
        bundleIdentifier = nil
    }

    /// Lookups that may name any app: each link's app is checked by its
    /// bundle id before its tool is offered with it.
    public init(
        appForScheme: @escaping @Sendable (String) -> URL?,
        appForBundle: @escaping @Sendable (String) -> URL?,
        isExecutable: @escaping @Sendable (String) -> Bool,
        environment: [String: String],
        bundleIdentifier: @escaping @Sendable (URL) -> String?
    ) {
        self.init(appForScheme: appForScheme, appForBundle: appForBundle, isExecutable: isExecutable,
                  environment: environment)
        self.bundleIdentifier = bundleIdentifier
    }

    /// This Mac: Launch Services for the apps, each link's app checked by
    /// its bundle id, the file system for the command line.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> DestinationDetector {
        DestinationDetector(
            appForScheme: { scheme in
                URL(string: "\(scheme)://").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            },
            appForBundle: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            environment: environment,
            bundleIdentifier: { Bundle(url: $0)?.bundleIdentifier }
        )
    }

    /// No tools at all.
    public static let none = DestinationDetector(
        appForScheme: { _ in nil }, appForBundle: { _ in nil }, isExecutable: { _ in false }, environment: [:]
    )

    /// ChatGPT's desktop apps.
    public static let chatGPTBundles = ["com.openai.chat"]

    /// The apps each tool's link may open, by bundle id, as each app's own
    /// Info.plist names itself and the scheme it handles (October 2026).
    /// macOS gives a link to whichever app claims its scheme, so another
    /// app that registers claude:// would be handed the question and what
    /// was on screen in the link. Such an app is never opened: the tool is
    /// offered without an app, and its message is copied (SPEC 5.3.5). The
    /// menu-bar app holds the same list.
    public static let linkOwners: [String: Set<String>] = [
        "claude": ["com.anthropic.claudefordesktop"],
        "codex": ["com.openai.codex"],
        "cursor": ["com.todesktop.230313mzl4w4u92"],
        "vscode": ["com.microsoft.VSCode"],
    ]

    /// The app that opens `scheme`'s links when it is the tool's own; nil
    /// when no app does, or another app claims them.
    func ownApp(for scheme: String) -> (app: URL?, claimed: Bool) {
        guard let app = appForScheme(scheme) else { return (nil, false) }
        guard let bundleIdentifier else { return (app, true) }
        let owned = bundleIdentifier(app).map { Self.linkOwners[scheme]?.contains($0) == true } ?? false
        return (owned ? app : nil, true)
    }

    /// The tools on this Mac, in the menu's order. A tool whose link another
    /// app claims is offered without an app: its message is copied, never
    /// sent in a link that app would open.
    public func installed() -> [InstalledTool] {
        AskTool.menuOrder.compactMap { tool in
            switch tool {
            case .chatgpt:
                return Self.chatGPTBundles.lazy.compactMap(appForBundle).first
                    .map { InstalledTool(tool: tool, appURL: $0) }
            case .claudeCode:
                let app = ownApp(for: "claude").app
                let line = app == nil ? claudeCommandLine() : nil
                guard app != nil || line != nil else { return nil }
                return InstalledTool(tool: tool, appURL: app, commandLine: line)
            default:
                guard let scheme = tool.scheme else { return nil }
                let found = ownApp(for: scheme)
                guard found.claimed else { return nil }
                return InstalledTool(tool: tool, appURL: found.app)
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
