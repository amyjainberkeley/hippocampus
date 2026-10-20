// SPDX-License-Identifier: Apache-2.0
//
// SendCardClient.swift — the window's way to the one builder
// (`mci-agent send-card`, SPEC 5.3.10) and to what each AI tool has of
// Hippocampus (`mci-agent clients`). The request goes on standard input,
// never in arguments, so a question never shows in the process list.
// Nothing here sends anything: a card is a link to open or text to copy,
// and the person presses send in the tool. Then the plan: open the link,
// or copy and open the tool, and the note that says which.

import Foundation

/// What to hand to which tool, as `send-card` reads it.
public struct SendCardRequest: Encodable, Equatable, Sendable {
    public struct Session: Encodable, Equatable, Sendable {
        public var startUs: UInt64
        public var endUs: UInt64
        public var title: String?

        public init(startUs: UInt64, endUs: UInt64, title: String?) {
            self.startUs = startUs
            self.endUs = endUs
            self.title = title
        }

        enum CodingKeys: String, CodingKey {
            case startUs = "start_us", endUs = "end_us", title
        }
    }

    public var to: String
    public var question: String?
    public var moments: [UInt64]
    public var selected: UInt64?
    public var session: Session?
    public var item: String?
    public var includeAboutMe: Bool
    public var includeScreenshot: Bool
    public var appInstalled: Bool?
    public var full: Bool
    public var client: String?

    public init(
        to: String, question: String? = nil, moments: [UInt64] = [], selected: UInt64? = nil,
        session: Session? = nil, item: String? = nil, includeAboutMe: Bool = false,
        includeScreenshot: Bool = false, appInstalled: Bool? = nil, full: Bool = false, client: String? = nil
    ) {
        self.to = to
        self.question = question
        self.moments = moments
        self.selected = selected
        self.session = session
        self.item = item
        self.includeAboutMe = includeAboutMe
        self.includeScreenshot = includeScreenshot
        self.appInstalled = appInstalled
        self.full = full
        self.client = client
    }

    enum CodingKeys: String, CodingKey {
        case to, question, moments, selected, session, item, full, client
        case includeAboutMe = "include_about_me"
        case includeScreenshot = "include_screenshot"
        case appInstalled = "app_installed"
    }
}

/// What goes in the tool's message box, and how it gets there.
public struct SendCard: Decodable, Equatable, Sendable {
    public struct LeftOut: Decodable, Equatable, Sendable {
        public var forgotten = 0
        public var keptOut = 0
        public var secretLines = 0
        public var trimmedMoments = 0

        public init(forgotten: Int = 0, keptOut: Int = 0, secretLines: Int = 0, trimmedMoments: Int = 0) {
            self.forgotten = forgotten
            self.keptOut = keptOut
            self.secretLines = secretLines
            self.trimmedMoments = trimmedMoments
        }

        enum CodingKeys: String, CodingKey {
            case forgotten, keptOut = "kept_out", secretLines = "secret_lines", trimmedMoments = "trimmed_moments"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            forgotten = try c.decodeIfPresent(Int.self, forKey: .forgotten) ?? 0
            keptOut = try c.decodeIfPresent(Int.self, forKey: .keptOut) ?? 0
            secretLines = try c.decodeIfPresent(Int.self, forKey: .secretLines) ?? 0
            trimmedMoments = try c.decodeIfPresent(Int.self, forKey: .trimmedMoments) ?? 0
        }
    }

    public var message: String
    public var words: Int
    public var open: String?
    public var copy: Bool
    public var folder: String?
    public var included: [UInt64]
    public var leftOut: LeftOut
    public var shortened: Bool
    public var peopleMessages: Bool
    public var screenshotMoment: UInt64?

    public init(
        message: String, words: Int, open: String?, copy: Bool, folder: String? = nil, included: [UInt64],
        leftOut: LeftOut = LeftOut(), shortened: Bool = false, peopleMessages: Bool = false,
        screenshotMoment: UInt64? = nil
    ) {
        self.message = message
        self.words = words
        self.open = open
        self.copy = copy
        self.folder = folder
        self.included = included
        self.leftOut = leftOut
        self.shortened = shortened
        self.peopleMessages = peopleMessages
        self.screenshotMoment = screenshotMoment
    }

    enum CodingKeys: String, CodingKey {
        case message, words, open, copy, folder, included, shortened
        case leftOut = "left_out", peopleMessages = "people_messages", screenshotMoment = "screenshot_moment"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try c.decode(String.self, forKey: .message)
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        open = try c.decodeIfPresent(String.self, forKey: .open)
        copy = try c.decodeIfPresent(Bool.self, forKey: .copy) ?? true
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        included = try c.decodeIfPresent([UInt64].self, forKey: .included) ?? []
        leftOut = try c.decodeIfPresent(LeftOut.self, forKey: .leftOut) ?? LeftOut()
        shortened = try c.decodeIfPresent(Bool.self, forKey: .shortened) ?? false
        peopleMessages = try c.decodeIfPresent(Bool.self, forKey: .peopleMessages) ?? false
        screenshotMoment = try c.decodeIfPresent(UInt64.self, forKey: .screenshotMoment)
    }
}

/// What a connectable tool has of Hippocampus, as `mci-agent clients`
/// says: content-free.
public struct ClientStatus: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var installed: Bool
    /// `on`, `off` or `unavailable`.
    public var lookUps: String
    /// `on`, `off`, `turned_off_in_tool`, `overridden` or `unavailable`.
    public var sessionStart: String
    /// `hook` or `instruction`.
    public var startKind: String?
    /// `allow_hooks` while Codex hasn't run Hippocampus's new hook yet.
    public var needsStep: String?

    public init(id: String, name: String, installed: Bool, lookUps: String, sessionStart: String,
                startKind: String? = nil, needsStep: String? = nil) {
        self.id = id
        self.name = name
        self.installed = installed
        self.lookUps = lookUps
        self.sessionStart = sessionStart
        self.startKind = startKind
        self.needsStep = needsStep
    }

    enum CodingKeys: String, CodingKey {
        case id, name, installed
        case lookUps = "look_ups", sessionStart = "session_start", startKind = "start_kind", needsStep = "needs_step"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        lookUps = try c.decodeIfPresent(String.self, forKey: .lookUps) ?? "off"
        sessionStart = try c.decodeIfPresent(String.self, forKey: .sessionStart) ?? "off"
        startKind = try c.decodeIfPresent(String.self, forKey: .startKind)
        needsStep = try c.decodeIfPresent(String.self, forKey: .needsStep)
    }

    /// Connected: it looks things up, or its sessions start with recent work.
    public var isConnected: Bool { lookUps == "on" || sessionStart == "on" }
}

public enum SendCardError: Error, Equatable, Sendable {
    case unavailable
    /// The memory couldn't be opened (its key, after a password change).
    case locked
    case failed
}

/// The builder and the `clients` read, as the window reaches them.
public struct SendCardClient: Sendable {
    public var card: @Sendable (SendCardRequest) async throws -> SendCard
    public var clients: @Sendable () async throws -> [ClientStatus]

    public init(
        card: @escaping @Sendable (SendCardRequest) async throws -> SendCard,
        clients: @escaping @Sendable () async throws -> [ClientStatus]
    ) {
        self.card = card
        self.clients = clients
    }

    /// The bundled agent, run as the window runs every command: its child
    /// environment, bounded in time, stopped with the window.
    public static let live = SendCardClient.agent { try ContextHandoffCommand.agentURL() }

    /// The agent `executable` names. The request goes on its standard input;
    /// `dbPath` is the memory the app gave the window, when it gave one.
    public static func agent(
        _ executable: @escaping @Sendable () throws -> URL,
        dbPath: String? = ProcessInfo.processInfo.environment["MCI_DB_PATH"],
        timeoutSeconds: TimeInterval = ContextHandoffExporter.defaultTimeoutSeconds
    ) -> SendCardClient {
        var cardArguments = ["send-card", "--json"]
        if let dbPath, !dbPath.isEmpty { cardArguments += ["--db-path", dbPath] }
        return SendCardClient(
            card: { [cardArguments] request in
                let body = try JSONEncoder().encode(request)
                let output: String
                do {
                    output = try await ContextHandoffExporter.run(
                        command: ContextHandoffCommand(executableURL: try executable(), arguments: cardArguments),
                        timeoutSeconds: timeoutSeconds,
                        input: body
                    )
                } catch let error as ContextHandoffError {
                    switch error {
                    case .memoryLocked: throw SendCardError.locked
                    case .commandFailed, .emptyOutput: throw SendCardError.failed
                    default: throw SendCardError.unavailable
                    }
                }
                guard let card = try? JSONDecoder().decode(SendCard.self, from: Data(output.utf8)) else {
                    throw SendCardError.failed
                }
                return card
            },
            clients: {
                let output = try await ContextHandoffExporter.run(
                    command: ContextHandoffCommand(executableURL: try executable(), arguments: ["clients", "--json"]),
                    timeoutSeconds: timeoutSeconds
                )
                struct Reply: Decodable { let tools: [ClientStatus] }
                guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(output.utf8)) else {
                    throw SendCardError.failed
                }
                return reply.tools
            }
        )
    }

    /// Nothing to reach: the synthetic preview, and a window with no agent.
    public static let unavailable = SendCardClient(
        card: { _ in throw SendCardError.unavailable }, clients: { [] }
    )
}

// MARK: After the builder answers (SPEC 5.3.4, 5.3.8)

/// The note after Ask {Tool}: its first line, any lines after it, and its
/// one button.
public struct HandoffNote: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Copy the message that went in the link.
        case copyInstead(String)
        /// Copy the whole message, not the shortened one.
        case copyFullVersion
        /// Open Terminal in the project's folder.
        case openTerminal(URL)
        /// Copy the ticked screenshot, after the text was pasted.
        case copyScreenshot

        public var title: String {
            switch self {
            case .copyInstead: HandoffCopy.copyInstead
            case .copyFullVersion: HandoffCopy.copyFullVersion
            case .openTerminal: HandoffCopy.openTerminalHere
            case .copyScreenshot: HandoffCopy.copyScreenshot
            }
        }
    }

    public var text: String
    public var lines: [String]
    public var action: Action?

    public init(text: String, lines: [String] = [], action: Action? = nil) {
        self.text = text
        self.lines = lines
        self.action = action
    }

    /// The note as one piece of text: its lines under it.
    public var fullText: String { ([text] + lines).joined(separator: "\n") }
}

/// What to do with a card for one tool.
public struct HandoffPlan: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case open(URL)
        case copy(String)
    }

    public var steps: [Step]
    public var note: HandoffNote
    /// When a link doesn't open: copy this instead, and say so.
    public var fallbackCopy: String?

    public init(steps: [Step], note: HandoffNote, fallbackCopy: String? = nil) {
        self.steps = steps
        self.note = note
        self.fallbackCopy = fallbackCopy
    }

    public var isEmpty: Bool { steps.isEmpty }

    /// The plan for `card` and `tool`, as `installed` is on this Mac.
    /// `home` makes a `~` folder absolute for Terminal; `screenshot` says a
    /// screenshot goes with it, by the clipboard after the link opens, or
    /// by its own button when the text is pasted.
    public static func make(
        card: SendCard, tool: AskTool, installed: InstalledTool?, home: String, screenshot: Bool = false
    ) -> HandoffPlan {
        var lines: [String] = []
        if card.leftOut.secretLines > 0 { lines.append(HandoffCopy.heldBack(card.leftOut.secretLines)) }
        if card.leftOut.forgotten > 0 { lines.append(HandoffCopy.forgotten(card.leftOut.forgotten)) }
        if card.peopleMessages { lines.append(HandoffCopy.people) }
        guard !card.message.isEmpty else {
            let text = lines.first ?? HandoffCopy.forgotten(max(card.leftOut.forgotten, 1))
            return HandoffPlan(steps: [], note: HandoffNote(text: text, lines: Array(lines.dropFirst())))
        }
        if card.shortened { lines.insert(HandoffCopy.shortened(tool.name), at: 0) }
        let fullAction: HandoffNote.Action? = card.shortened ? .copyFullVersion : nil

        if !card.copy, let link = card.open.flatMap(URL.init(string:)) {
            if screenshot { lines.insert(HandoffCopy.screenshotPaste, at: 0) }
            return HandoffPlan(
                steps: [.open(link)],
                note: HandoffNote(text: HandoffCopy.opened(tool.name), lines: lines,
                                  action: fullAction ?? .copyInstead(card.message)),
                fallbackCopy: card.message
            )
        }
        let clears = [HandoffCopy.clears] + lines
        let pastedAction: HandoffNote.Action? = fullAction ?? (screenshot ? .copyScreenshot : nil)
        if tool == .claudeCode, installed?.hasApp != true {
            let folder = card.folder.flatMap { absolute($0, home: home) }
            let name = folder?.lastPathComponent ?? HandoffCopy.yourProject
            return HandoffPlan(
                steps: [.copy(card.message)],
                note: HandoffNote(text: HandoffCopy.copiedRunClaude(name), lines: clears,
                                  action: fullAction ?? folder.map(HandoffNote.Action.openTerminal))
            )
        }
        if let app = installed?.appURL {
            return HandoffPlan(
                steps: [.copy(card.message), .open(app)],
                note: HandoffNote(text: HandoffCopy.copiedPaste(tool.name), lines: clears, action: pastedAction)
            )
        }
        if let site = tool.site {
            return HandoffPlan(
                steps: [.copy(card.message), .open(site.url)],
                note: HandoffNote(text: HandoffCopy.notInstalled(tool.name, site: site.name), lines: clears,
                                  action: pastedAction)
            )
        }
        return HandoffPlan(
            steps: [.copy(card.message)],
            note: HandoffNote(text: HandoffCopy.copied, lines: lines, action: fullAction)
        )
    }

    static func absolute(_ folder: String, home: String) -> URL? {
        if folder == "~" { return URL(fileURLWithPath: home, isDirectory: true) }
        if folder.hasPrefix("~/") {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(String(folder.dropFirst(2)), isDirectory: true)
        }
        return folder.hasPrefix("/") ? URL(fileURLWithPath: folder, isDirectory: true) : nil
    }
}

extension HandoffPlan {
    /// Carries the plan out: copies by the clipboard rules, opens the link or
    /// the app, copies the message instead when a link won't open, and puts a
    /// ticked screenshot on the clipboard once a link opened (a link leaves
    /// the clipboard alone otherwise). The note to show, or nil when the
    /// message couldn't be copied.
    @MainActor
    public func perform(
        tool: AskTool,
        screenshot: Data?,
        copy: (String) -> Bool,
        copyJPEG: (Data) -> Bool,
        open: (URL) -> Bool
    ) -> HandoffNote? {
        var note = self.note
        var opened = false
        for step in steps {
            switch step {
            case .copy(let text):
                guard copy(text) else { return nil }
            case .open(let url):
                if open(url) {
                    opened = true
                } else if let fallbackCopy {
                    guard copy(fallbackCopy) else { return nil }
                    note = HandoffNote(text: HandoffCopy.couldNotOpen(tool.name), lines: [HandoffCopy.clears])
                }
            }
        }
        let copiedText = steps.contains { if case .copy = $0 { true } else { false } }
        if let screenshot, opened, !copiedText {
            _ = copyJPEG(screenshot)
        }
        return note
    }
}
