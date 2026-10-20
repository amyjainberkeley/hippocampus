import Foundation

/// What an Ask {Tool} button hands to a person's AI (SPEC 5.3.1, 5.3.3):
/// the moments they picked, a session, a Working On item or a question.
/// It names what to send by ids and times only; the one builder
/// (`mci-agent send-card`) reads the rest from memory just before anything
/// opens, so a moment forgotten since the click is left out.
public enum AskAISource: Equatable, Hashable, Sendable {
    /// Moments, newest first: History's detail or selection, a web page, a search.
    case moments([UInt64])
    /// A session on Today: its title and its own time, in microseconds.
    case session(title: String, range: ClosedRange<Int64>)
    /// A Working On item, by its id.
    case item(String)
    /// A question, with the moments its answer cited or its top matches.
    case question(String, moments: [UInt64])

    /// The moments it names directly, newest first: none for a session or an
    /// item, which the builder reads by time or by id.
    public var momentIds: [UInt64] {
        switch self {
        case let .moments(ids), let .question(_, ids): ids
        case .session, .item: []
        }
    }

    /// The request for `to`. `selected` is the moment picked among several,
    /// which is never dropped to fit; `itemMoments` are an item's moments,
    /// for when the work read doesn't know it yet.
    public func request(
        to: String, selected: UInt64? = nil, itemMoments: [UInt64] = [], appInstalled: Bool? = nil,
        includeAboutMe: Bool = false, includeScreenshot: Bool = false, full: Bool = false
    ) -> SendCardRequest {
        var request = SendCardRequest(
            to: to, selected: selected, includeAboutMe: includeAboutMe, includeScreenshot: includeScreenshot,
            appInstalled: appInstalled, full: full
        )
        switch self {
        case .moments(let ids):
            request.moments = ids
        case .question(let question, let ids):
            request.question = question
            request.moments = ids
        case .session(let title, let range):
            request.session = SendCardRequest.Session(
                startUs: UInt64(max(range.lowerBound, 0)), endUs: UInt64(max(range.upperBound, 0)), title: title
            )
        case .item(let id):
            request.item = id
            request.moments = itemMoments
        }
        return request
    }

    /// How many moments it holds, for "About 151 words · 1 moment", when
    /// the builder hasn't said yet.
    public var momentCount: Int {
        switch self {
        case .moments(let ids), .question(_, let ids): max(ids.count, 1)
        case .session, .item: 1
        }
    }
}

/// An AI tool Ask {Tool} hands to, by the id `mci-agent send-card` takes.
/// The menu-bar app has its own copy (the two apps share no Swift package).
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

    /// The site it opens at when its app isn't on this Mac: never with the
    /// message in the address (SPEC 5.3.4).
    public var site: (url: URL, name: String)? {
        switch self {
        case .claude: (URL(string: "https://claude.ai/new")!, "claude.ai")
        case .chatgpt: (URL(string: "https://chatgpt.com/")!, "chatgpt.com")
        default: nil
        }
    }

    /// The person pastes into it: its chats can't be filled in from
    /// another app.
    public var isPasted: Bool { self == .chatgpt }

    /// A screenshot can go with it (SPEC 5.3.7): Claude Code is never
    /// offered one.
    public var takesImages: Bool { self != .claudeCode }
}

/// What a person chose, remembered on this Mac: the tool ⌘↩ opens, and the
/// tools they have been told about once (SPEC 5.3.2, 5.3.8). The window and
/// the menu-bar app keep them under the same keys in the app's defaults, so
/// both open the same tool. Never anything that was sent.
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

/// What Ask {Tool} shows and does, apart from drawing it (SPEC 5.3.2, 5.3.4).
public enum AskAIButtonRules {
    /// The tool the button's main half opens: Claude Code for a code project
    /// (Codex when only it is here), else the last tool chosen while it is
    /// still on this Mac. Nil: the button reads Ask Your AI and opens its menu.
    public static func primaryTool(
        in tools: [InstalledTool], codeProject: String?, lastTool: AskTool?
    ) -> InstalledTool? {
        if codeProject != nil,
           let tool = tools.first(where: { $0.tool == .claudeCode && $0.hasApp })
            ?? tools.first(where: { $0.tool == .codex }) {
            return tool
        }
        guard let lastTool else { return nil }
        return tools.first { $0.tool == lastTool }
    }

    /// The button's words: Ask Claude, Open in Claude Code on a code project,
    /// Copy for Claude Code when only its command line is here, Ask Your AI
    /// before a tool is chosen.
    public static func label(primary: InstalledTool?, codeProject: String?) -> String {
        guard let tool = primary else { return HandoffCopy.ask(nil) }
        if codeProject != nil, tool.tool == .claudeCode || tool.tool == .codex {
            return HandoffCopy.openIn(tool.tool.name)
        }
        if tool.tool == .claudeCode, !tool.hasApp { return HandoffCopy.copyFor(tool.tool.name) }
        return HandoffCopy.ask(tool.tool.name)
    }

    /// The moment whose screenshot Include Screenshot offers: the one picked,
    /// or the only one. A session, an item or several moments offer none.
    public static func screenshotMoment(of source: AskAISource, selected: UInt64?) -> UInt64? {
        selected ?? (source.momentIds.count == 1 ? source.momentIds.first : nil)
    }

    /// Include Screenshot is offered only when the moment has one and the
    /// tool takes pictures (SPEC 5.3.7).
    public static func offersScreenshot(_ tool: AskTool, hasScreenshot: Bool) -> Bool {
        hasScreenshot && tool.takesImages
    }

    /// The note after Copy for Your AI: what was copied and what was left out.
    public static func copiedNote(_ card: SendCard) -> String {
        guard !card.message.isEmpty else { return HandoffCopy.forgotten(max(card.leftOut.forgotten, 1)) }
        var lines = [HandoffCopy.copied]
        if card.leftOut.secretLines > 0 { lines.append(HandoffCopy.heldBack(card.leftOut.secretLines)) }
        if card.leftOut.forgotten > 0 { lines.append(HandoffCopy.forgotten(card.leftOut.forgotten)) }
        if card.peopleMessages { lines.append(HandoffCopy.people) }
        return lines.joined(separator: "\n")
    }

    /// The note when the builder couldn't make the message.
    public static func failureNote(_ error: Error) -> String {
        (error as? SendCardError) == .locked ? HandoffCopy.locked : HandoffCopy.couldNotCopy
    }
}

/// A second press within 2 seconds is ignored (SPEC 5.3.4).
public struct SendGuard: Sendable {
    public static let interval: TimeInterval = 2
    private var last: Date?

    public init() {}

    /// Whether a press at `now` sends; a press that sends starts the wait.
    public mutating func allows(at now: Date) -> Bool {
        if let last, now >= last, now.timeIntervalSince(last) < Self.interval { return false }
        last = now
        return true
    }
}
