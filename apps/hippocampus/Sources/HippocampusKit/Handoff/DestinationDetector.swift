// SPDX-License-Identifier: Apache-2.0
//
// DestinationDetector.swift — which AI tools Ask {Tool} can open on this Mac
// (SPEC 5.3.2): the app that handles each tool's link, ChatGPT's app by its
// bundle id, and Claude Code's command line where its installers put it.
// When two versions of a tool are installed, the one that handles the link
// wins. The window has its own copy of this code (the two apps share no
// Swift package); both are tested.

import AppKit
import Foundation

/// An AI tool Ask {Tool} hands to, by the id `mci-agent send-card` takes.
public enum AskTool: String, CaseIterable, Codable, Sendable {
    case claude
    case claudeCode = "claude-code"
    case chatgpt
    case codex
    case cursor
    case vscode

    /// The tool's name, as its makers write it.
    public var name: String {
        switch self {
        case .claude: "Claude"
        case .claudeCode: "Claude Code"
        case .chatgpt: "ChatGPT"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .vscode: "VS Code"
        }
    }

    /// The menu's order (SPEC 5.3.2). VS Code joins once its link is
    /// verified on the stable build.
    public static let menuOrder: [AskTool] = [.claude, .claudeCode, .chatgpt, .codex, .cursor]

    /// The link scheme whose handler is this tool's app.
    var scheme: String? {
        switch self {
        case .claude, .claudeCode: "claude"
        case .codex: "codex"
        case .cursor: "cursor"
        case .vscode: "vscode"
        case .chatgpt: nil
        }
    }

    /// The site a tool opens at when its app isn't on this Mac: never with
    /// the message in the address (SPEC 5.3.4).
    public var site: (url: URL, name: String)? {
        switch self {
        case .claude: (URL(string: "https://claude.ai/new")!, "claude.ai")
        case .chatgpt: (URL(string: "https://chatgpt.com/")!, "chatgpt.com")
        default: nil
        }
    }

    /// Whether the person pastes into it: its chats can't be filled in
    /// from another app.
    public var isPasted: Bool { self == .chatgpt }
}

/// How a tool is on this Mac.
public struct InstalledTool: Equatable, Sendable {
    public let tool: AskTool
    /// The app that opens it, when there is one.
    public let appURL: URL?
    /// Claude Code's command line, when only that is here.
    public let commandLine: String?

    public init(tool: AskTool, appURL: URL?, commandLine: String? = nil) {
        self.tool = tool
        self.appURL = appURL
        self.commandLine = commandLine
    }

    /// Whether Ask opens it through its link (or, for ChatGPT, its app).
    public var hasApp: Bool { appURL != nil }
}

/// Finds the AI tools on this Mac. Every lookup is injected, so tests never
/// ask the real system.
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

    /// ChatGPT's desktop apps, newest first.
    public static let chatGPTBundles = ["com.openai.chat"]

    /// The apps each tool's link may open, by bundle id, as each app's own
    /// Info.plist names itself and the scheme it handles (October 2026).
    /// macOS gives a link to whichever app claims its scheme, so another
    /// app that registers claude:// would be handed the question and what
    /// was on screen in the link. Such an app is never opened: the tool is
    /// offered without an app, and its message is copied (SPEC 5.3.5).
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

/// What a person chose, remembered on this Mac: the tool ⌘↩ opens, and the
/// tools they have been told about once (SPEC 5.3.2, 5.3.8). Kept in the
/// app's own defaults, which the window shares, so the panel and the window
/// open the same tool. Never anything that was sent.
public struct HandoffChoices: @unchecked Sendable {
    public static let lastToolKey = "ai.hippocampus.handoff.lastTool"
    public static let toldKeyPrefix = "ai.hippocampus.handoff.told."

    private let read: (String) -> Any?
    private let write: (Any?, String) -> Void

    public init(defaults: UserDefaults = .standard) {
        self.init(read: { defaults.object(forKey: $0) }, write: { defaults.set($0, forKey: $1) })
    }

    /// Choices read and written by `read` and `write`, under the same keys.
    public init(read: @escaping (String) -> Any?, write: @escaping (Any?, String) -> Void) {
        self.read = read
        self.write = write
    }

    /// The tool ⌘↩ opens: the last one chosen.
    public var lastTool: AskTool? {
        get { (read(Self.lastToolKey) as? String).flatMap(AskTool.init(rawValue:)) }
        nonmutating set { write(newValue?.rawValue, Self.lastToolKey) }
    }

    /// Whether the person has seen the first-use sheet for `tool`.
    public func wasTold(_ tool: AskTool) -> Bool {
        (read(Self.toldKeyPrefix + tool.rawValue) as? Bool) ?? false
    }

    public func markTold(_ tool: AskTool) {
        write(true, Self.toldKeyPrefix + tool.rawValue)
    }

    /// Choices kept in memory only, for previews, renders and tests: nothing
    /// is written on this Mac.
    public static func ephemeral() -> HandoffChoices {
        let store = ChoicesInMemory()
        return HandoffChoices(read: store.value, write: store.set)
    }
}

/// A few values in memory, for `HandoffChoices.ephemeral()`.
private final class ChoicesInMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func value(_ key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: Any?, _ key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}
