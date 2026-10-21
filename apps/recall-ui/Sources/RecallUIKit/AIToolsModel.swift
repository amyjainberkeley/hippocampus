// SPDX-License-Identifier: Apache-2.0
//
// AIToolsModel.swift — what the window's AI Tools page shows (SPEC 3.8):
// "what leaves my Mac, and to whom?" Each connectable tool with its plain
// status and switches, the exact words a session starts with and their size,
// the tool ⌘↩ opens, and the tools on this Mac that aren't connected, each
// with the truth. The page reads and links; switches and Disconnect work in
// Preferences › AI Tools, where the app asks its own questions.
//
// Its reads are content-free (`mci-agent clients`), the person's own day
// (`ai_knows`, as Today reads it) and the exact session-start words
// (`send-card` with `to: session-start`, which records nothing). Not shown
// until it is real: "Last sent" and look-up counts.

import Foundation

@MainActor
public final class AIToolsModel: ObservableObject {
    public enum State: Equatable, Sendable {
        case loading
        case ready
        /// The tools' state couldn't be read: the page says so and offers
        /// Try Again (SPEC 9, 19).
        case unavailable
    }

    /// One tool that can look things up and start sessions with recent work.
    public struct Card: Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let connected: Bool
        public let lookUps: Bool
        public let sessionStart: Bool
        /// Its plain status words, one line each.
        public let lines: [String]
        /// "Needs a step in Codex" and the step, while Codex hasn't run the hook.
        public let step: String?
        /// The switch rows it shows.
        public let showsSessionSwitch: Bool
        /// It starts each session with the words What It Starts With shows.
        public let showsStartsWith: Bool
        /// Its app, for the icon.
        public let appURL: URL?
    }

    /// A tool on this Mac that isn't connected: its name and the truth.
    public struct Other: Equatable, Identifiable, Sendable {
        public let tool: InstalledTool
        public let line: String
        public var id: String { tool.id }

        public init(tool: InstalledTool, line: String) {
            self.tool = tool
            self.line = line
        }
    }

    /// One thing said about the person, and where it was learned.
    public struct AboutLine: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let text: String
        public let source: String?

        public init(id: Int64, text: String, source: String?) {
            self.id = id
            self.text = text
            self.source = source
        }
    }

    /// The exact words a session starts with now (SPEC 3.8).
    public struct StartsWith: Equatable, Sendable {
        public let recentWork: [String]
        public let aboutYou: [AboutLine]
        public let exactText: String
        /// "About 120 words": rounded to tens.
        public let words: Int

        public init(recentWork: [String], aboutYou: [AboutLine], exactText: String, words: Int) {
            self.recentWork = recentWork
            self.aboutYou = aboutYou
            self.exactText = exactText
            self.words = words
        }
    }

    @Published public private(set) var state: State = .loading
    @Published public private(set) var cards: [Card] = []
    @Published public private(set) var others: [Other] = []
    @Published public private(set) var installed: [InstalledTool] = []
    @Published public private(set) var askTool: AskTool?
    @Published public private(set) var startsWith: StartsWith?

    private let client: SendCardClient
    private let detector: DestinationDetector
    private let understanding: UnderstandingReader
    private let choices: HandoffChoices
    private let locale: Locale
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date

    public init(
        client: SendCardClient = .live,
        detector: DestinationDetector = .live(),
        understanding: UnderstandingReader,
        choices: HandoffChoices = HandoffChoices(),
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.detector = detector
        self.understanding = understanding
        self.choices = choices
        self.locale = locale
        self.timeZone = timeZone
        self.now = now
    }

    /// No AI tool on this Mac at all.
    public var isEmpty: Bool { state == .ready && cards.isEmpty && others.isEmpty }

    /// Read everything again.
    public func reload() async {
        let installed = detector.installed()
        let statuses: [ClientStatus]
        do {
            statuses = try await client.clients()
        } catch {
            state = .unavailable
            return
        }
        let chatGPT = installed.contains { $0.tool == .chatgpt }
        let appOf = { (tool: AskTool) in installed.first { $0.tool == tool }?.appURL }
        cards = statuses
            .filter { $0.installed || $0.isConnected }
            .map { Self.card($0, chatGPTInstalled: chatGPT, appURL: appOf($0.id == "codex" ? .codex : .claudeCode)) }
        others = installed.compactMap { tool -> Other? in
            switch tool.tool {
            case .chatgpt: Other(tool: tool, line: HandoffCopy.chatGPTUse)
            case .claude, .cursor, .vscode: Other(tool: tool, line: HandoffCopy.use(tool.tool.name))
            case .claudeCode, .codex: nil
            }
        }
        self.installed = installed
        // Only a tool the person chose and that is still here: before that,
        // ⌘↩ opens nothing, and the page says Choose… (AskAIButtonRules).
        askTool = choices.lastTool.flatMap { last in installed.contains { $0.tool == last } ? last : nil }
        state = .ready
        startsWith = cards.contains(where: \.showsStartsWith) ? await readStartsWith() : nil
    }

    /// What With One Key's menu says until a tool is chosen: ⌘↩ opens no
    /// tool before then.
    public static let chooseTool = "Choose\u{2026}"

    /// The tool ⌘↩ opens, chosen here.
    public func choose(_ tool: AskTool) {
        choices.lastTool = tool
        askTool = tool
    }

    /// A card's words, from what `clients` says (SPEC 3.8; SPEC 9, 92 to 94).
    public static func card(_ status: ClientStatus, chatGPTInstalled: Bool, appURL: URL?) -> Card {
        let codex = status.id == "codex"
        let connected = status.isConnected
        let lookUps = status.lookUps == "on"
        let starts = status.sessionStart == "on"
        var lines: [String] = []
        var step: String?
        var sessionSwitch = true
        if !connected {
            lines.append(codex ? HandoffCopy.codexNotConnectedNote : HandoffCopy.notConnectedNote(status.name))
        } else if status.sessionStart == "turned_off_in_tool" {
            lines.append(HandoffCopy.turnedOffIn(status.name))
        } else if status.sessionStart == "overridden" {
            lines.append(HandoffCopy.overridden)
        } else if starts, status.startKind == "instruction" {
            lines.append(HandoffCopy.codexAsked)
            sessionSwitch = false
        } else if starts, status.needsStep == "allow_hooks" {
            step = HandoffCopy.codexStep
        } else if starts {
            lines.append(HandoffCopy.getsRecentWork)
        } else if lookUps {
            lines.append(HandoffCopy.looksThingsUp)
        }
        if codex, chatGPTInstalled, connected { lines.append(HandoffCopy.chatGPTShares) }
        return Card(
            id: status.id, name: status.name, connected: connected, lookUps: lookUps, sessionStart: starts,
            lines: lines, step: step, showsSessionSwitch: connected && sessionSwitch,
            showsStartsWith: connected && starts && status.startKind == "hook", appURL: appURL
        )
    }

    /// The exact words, from the same functions the session hook uses, and
    /// the same lines in a form a person reads, each with where it came from.
    private func readStartsWith() async -> StartsWith? {
        guard let exact = try? await client.card(SendCardRequest(to: "session-start", client: "claude-code")) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let overview = try? await understanding.overview(UnderstandingDay(date: now(), calendar: calendar))
        let page = try? await understanding.modelPage()
        let knows = overview?.aiKnows ?? .nothing
        let items = Dictionary((page?.shared ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let about = knows.aboutYou.map { line in
            AboutLine(id: line.id, text: line.text, source: items[line.id].map(Self.source))
        }
        return StartsWith(
            recentWork: knows.recentWork.map { $0.text(locale: locale, timeZone: timeZone) },
            aboutYou: about,
            exactText: exact.message,
            words: Self.aboutWords(exact.words)
        )
    }

    static func source(_ item: ModelItem) -> String {
        switch item.basis {
        case .confirmed: HandoffCopy.youConfirmed
        case .seenOnDays: HandoffCopy.seenOnDays(max(item.daysSeen, 2))
        case .seenOnce: HandoffCopy.seenOnDays(1)
        }
    }

    /// "About 120 words": to the nearest ten, never zero for some words.
    static func aboutWords(_ words: Int) -> Int {
        guard words > 0 else { return 0 }
        return max(10, Int((Double(words) / 10).rounded()) * 10)
    }

    #if DEBUG
    /// Fixture state for rendering the page without the agent.
    public func preview(
        cards: [Card], others: [Other], installed: [InstalledTool], askTool: AskTool?, startsWith: StartsWith?,
        state: State = .ready
    ) {
        self.cards = cards
        self.others = others
        self.installed = installed
        self.askTool = askTool
        self.startsWith = startsWith
        self.state = state
    }
    #endif
}
