import Combine
import CoreGraphics
import Foundation

// MARK: Data

/// What the user was looking at when Ask opened.
public struct FrontmostContext: Sendable, Equatable {
    public let bundleId: String?
    public let appName: String?
    public let windowTitle: String?

    public init(bundleId: String?, appName: String?, windowTitle: String?) {
        self.bundleId = bundleId
        self.appName = appName
        self.windowTitle = windowTitle
    }
}

public struct BarSuggestion: Decodable, Sendable, Equatable, Identifiable {
    public let kind: String
    public let title: String
    public let why: String
    public let action: BarSuggestionAction
    public let score: Int
    public var id: String { kind + title }
}

public struct BarSuggestionAction: Decodable, Sendable, Equatable {
    public let query: String?
    public let ask: String?
    public let view: String?
    public let openSession: UInt64?

    enum CodingKeys: String, CodingKey { case query, ask, view, openSession = "open_session" }
}

public struct BarHit: Decodable, Sendable, Equatable, Identifiable {
    public let eventId: UInt64
    public let tsUs: UInt64
    public let appBundleId: String?
    public let windowTitle: String?
    public let url: String?
    public let textSnippet: String
    public var id: UInt64 { eventId }

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id", tsUs = "ts_us", appBundleId = "app_bundle_id"
        case windowTitle = "window_title", url, textSnippet = "text_snippet"
    }

    /// The snippet without the provenance header line the store prepends.
    public var body: String { MomentText.body(textSnippet) }
}

/// A moment's stored text as one line, without the header line the store
/// puts first (`[app=… | title=…]`) when there is one (RULINGS X8).
enum MomentText {
    static func body(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.first?.hasPrefix("[app=") == true ? lines.dropFirst() : lines[...]
        return kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

struct RecallReply: Decodable {
    let hits: [BarHit]?
    let relatedContext: [BarHit]?
    enum CodingKeys: String, CodingKey { case hits, relatedContext = "related_context" }
}

public struct BarSource: Decodable, Sendable, Equatable, Identifiable {
    public let n: Int
    public let eventId: Int64
    public let tsUs: UInt64
    public let app: String
    public let title: String?
    public let url: String?
    public let text: String
    public var id: Int { n }

    enum CodingKeys: String, CodingKey {
        case n, eventId = "event_id", tsUs = "ts_us", app, title, url, text
    }

    /// The excerpt without its header line, as one line.
    public var body: String { MomentText.body(text) }
}

public struct BarAnswer: Decodable, Sendable, Equatable {
    public let answer: String?
    public let sources: [BarSource]
    public let unavailable: String?
}

/// One selectable row in Ask.
public enum BarRow: Sendable, Equatable, Identifiable {
    case suggestion(BarSuggestion)
    case ask(String)
    case hit(BarHit)
    case source(BarSource)
    /// The window in front as the answer read it, labelled "This window".
    case thisWindow(BarSource)

    public var id: String {
        switch self {
        case .suggestion(let s): "s-\(s.id)"
        case .ask(let q): "a-\(q)"
        case .hit(let h): "h-\(h.eventId)"
        case .source(let s), .thisWindow(let s): "c-\(s.n)"
        }
    }
}

/// What Ask asks the app to do outside the panel.
public enum BarAction: Sendable, Equatable {
    case openURL(URL)
    case openEvent(UInt64)
    /// The window on one of its places: "overview" or "you" (RULINGS X9).
    case openWindow(tab: String)
    case copy(String)
    /// Copy context for an AI tool; it is fetched first.
    case copyForAI
    /// The footer's button.
    case status(AskPanelStatus.Action)
}

/// What the answer card says: never nothing once a request has ended (spec-copy
/// M2 finding 7).
public enum AnswerLine: Equatable, Sendable {
    case answer(String)
    case thinking
    case note(String)

    /// The answer; "Thinking…" while it is written; why there is none; or
    /// the notice of a request that failed.
    public static func make(answer: BarAnswer?, asking: Bool, notice: String?) -> AnswerLine? {
        if let text = answer?.answer { return .answer(text) }
        if asking { return .thinking }
        if let reason = answer?.unavailable {
            return .note(explain(reason, matched: answer?.sources.isEmpty == false))
        }
        if let notice { return .note(notice) }
        return nil
    }

    /// Why there is no answer, then the matches when there are some.
    public static func explain(_ reason: String, matched: Bool) -> String {
        let why = switch reason {
        case "apple_intelligence_off": "Turn on Apple Intelligence in System Settings to get answers."
        case "device_not_eligible", "not_installed", "cannot_launch": "Answers need macOS 26 with Apple Intelligence."
        case "model_not_ready": "Apple Intelligence is still getting ready."
        default: "Couldn’t write an answer."
        }
        return matched ? "\(why) Here’s what matched:" : why
    }
}

/// A key pressed with ⌘ in Ask.
public enum AskKeyCommand: Equatable, Sendable {
    case copyAnswer
    case copyForAI
    case openOverview
    case openYou
    case close

    public init?(key: String, command: Bool, shift: Bool, option: Bool, control: Bool) {
        guard command, !option, !control else { return nil }
        switch (key.lowercased(), shift) {
        case ("c", false): self = .copyAnswer
        case ("c", true): self = .copyForAI
        case ("d", false): self = .openOverview
        case ("u", false): self = .openYou
        case ("q", false): self = .close
        default: return nil
        }
    }
}

// MARK: Model

/// Ask: knows the window you were in, offers at most three things before
/// you type, searches as you type, and answers questions from your memory.
///
/// An answer is never thrown away: closing Ask keeps the question, the answer
/// and the window it was asked over for 10 minutes, and a request keeps
/// running while Ask is closed (product critique 1). Return always asks; ↓
/// then Return opens a memory (product critique 6).
@MainActor
public final class CommandBarModel: ObservableObject {
    public enum Mode: Equatable, Sendable { case home, results, answer }

    public static let keepAnswerFor: TimeInterval = 10 * 60
    public static let homeRowLimit = 3
    /// The rows offered before anything is typed: the window in front, the
    /// last session, more about this window. Never a past search, the day or
    /// what Hippocampus understands about you.
    public static let homeKinds: Set<String> = ["screen", "resume", "related"]

    @Published public var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    @Published public private(set) var mode: Mode = .home
    /// The window a question is about: the one in front, or, for a kept
    /// answer, the one it was asked over.
    @Published public private(set) var context: FrontmostContext?
    /// Whether Hippocampus has a saved read of that window; nil until known.
    @Published public private(set) var savedRead: Bool?
    @Published public private(set) var homeRows: [BarSuggestion] = []
    @Published public private(set) var hits: [BarHit] = []
    @Published public private(set) var answer: BarAnswer?
    @Published public private(set) var askedQuestion: String?
    @Published public private(set) var isAsking = false
    @Published public private(set) var isSearching = false
    /// -1 is the field itself: Return asks what is typed.
    @Published public private(set) var selection = 0
    @Published public private(set) var notice: String?
    /// A word the footer shows for a moment, such as "Copied".
    @Published public private(set) var flash: String?
    @Published public private(set) var status: AskPanelStatus
    @Published public private(set) var answersAvailable: Bool
    /// Room for the content between the search row and the footer.
    @Published public var maxContentHeight: CGFloat = 520
    /// Bumped on every open so the view moves keyboard focus to the field
    /// once the panel is key.
    @Published public private(set) var focusRequest = 0
    /// Bumped when a kept question comes back, so the view selects it and
    /// typing replaces it.
    @Published public private(set) var selectQuestionRequest = 0
    /// When the shown question was sent.
    @Published public private(set) var askedAt: Date?

    private let memory: AskMemory
    private let now: () -> Date
    private var availability: AnswerAvailability
    private var openID = 0
    private var homeGeneration = 0
    private var homeLoaded = false
    private var homeWaitsForAsk = false
    private var liveContext: FrontmostContext?
    private var liveContextKnown = false
    private var showingKeptAnswer = false
    private var closedAt: Date?
    private var askToken = 0
    private var asksRunning = 0
    private var pendingQuestion: String?
    private var readEventId: UInt64?
    private var readGeneration = 0
    private var searchToken = 0
    private var searchTask: Task<Void, Never>?
    private var readCheck: Task<Void, Never>?
    private var quiet = false
    private var previewing = false

    public convenience init(launch: @escaping @MainActor (_ assist: Bool) -> MemorySessionLaunch?) {
        self.init(memory: WarmMemorySessions(launch: launch))
    }

    public init(
        memory: AskMemory,
        availability: AnswerAvailability = AnswerAvailability(),
        now: @escaping () -> Date = Date.init
    ) {
        self.memory = memory
        self.availability = availability
        self.now = now
        status = AskPanelStatus(.starting)
        answersAvailable = availability.isAvailable(at: now())
    }

    // MARK: What the panel shows

    public var isWorking: Bool { isAsking || isSearching }

    /// Hippocampus is reading and has read the window in front, so a
    /// question can be about "this".
    public var windowRead: Bool { status.readsThisWindow && savedRead == true }

    public var placeholder: String {
        if !answersAvailable { return "Search anything you’ve seen" }
        return windowRead ? "Ask about this or anything you’ve seen" : "Ask about anything you’ve seen"
    }

    public var footerText: String {
        if let flash { return flash }
        if status.isRemembering, !answersAvailable { return "Answers need Apple Intelligence" }
        return status.text
    }

    public var footerAction: AskPanelStatus.Action? { flash == nil ? status.action : nil }

    /// The written answer, for ⌘C.
    public var answerText: String? { mode == .answer ? answer?.answer : nil }

    public var answerLine: AnswerLine? {
        mode == .answer ? AnswerLine.make(answer: answer, asking: isAsking, notice: notice) : nil
    }

    /// The window chip is at full strength only when Hippocampus has read
    /// the window (product critique 2).
    public var chipStrength: Double { windowRead ? 1 : 0.5 }

    public var chipTooltip: String {
        windowRead ? "Ask about this window" : "Hippocampus hasn’t read this window"
    }

    public var rows: [BarRow] {
        switch mode {
        case .home:
            return homeRows.map(BarRow.suggestion)
        case .results:
            let ask = answersAvailable ? [BarRow.ask(query.trimmed)] : []
            return ask + hits.map(BarRow.hit)
        case .answer:
            return (answer?.sources ?? []).enumerated().map { index, source in
                index == 0 && isThisWindow(source) ? .thisWindow(source) : .source(source)
            }
        }
    }

    /// The agent puts the window in front first when the answer read it
    /// (`answer_sources` in `query.rs`). It is the moment Ask found for that
    /// window, or one with its title (or app) from the time asked.
    private func isThisWindow(_ source: BarSource) -> Bool {
        if let readEventId, source.eventId >= 0, UInt64(source.eventId) == readEventId { return true }
        guard let context, let askedAt else { return false }
        let age = askedAt.timeIntervalSince1970 - Double(source.tsUs) / 1_000_000
        if let title = context.windowTitle {
            return source.title == title && age <= ThisWindowRead.sameTitleWithin
        }
        return context.appName != nil && source.app == context.appName && age <= ThisWindowRead.sameAppWithin
    }

    /// The rows offered before anything is typed, in the agent's order, cut
    /// to three. The window in front is offered only while it is being read,
    /// and nothing offers to ask when no answer can be written.
    public static func homeRows(
        from suggestions: [BarSuggestion], readsThisWindow: Bool, answersAvailable: Bool = true
    ) -> [BarSuggestion] {
        Array(suggestions
            .filter { homeKinds.contains($0.kind) }
            .filter { $0.kind != "screen" || readsThisWindow }
            .filter { $0.action.ask == nil || answersAvailable }
            .prefix(homeRowLimit))
    }

    // MARK: Opening and closing

    /// Ask opened. Returns the id `contextArrived` must quote. An answer from
    /// the last 10 minutes comes back with its question selected and the
    /// window it was asked over; anything else starts fresh.
    @discardableResult
    public func opened() -> Int {
        openID += 1
        focusRequest += 1
        flash = nil
        liveContext = nil
        liveContextKnown = false
        answersAvailable = availability.isAvailable(at: now())
        if keepsAnswer {
            showingKeptAnswer = true
            selection = -1
            selectQuestionRequest += 1
            return openID
        }
        homeGeneration += 1
        homeLoaded = false
        homeWaitsForAsk = false
        askToken += 1
        searchTask?.cancel()
        readCheck?.cancel()
        setQuery("")
        mode = .home
        context = nil
        savedRead = nil
        readEventId = nil
        homeRows = []
        hits = []
        answer = nil
        askedQuestion = nil
        askedAt = nil
        pendingQuestion = nil
        isAsking = false
        isSearching = false
        notice = nil
        selection = 0
        showingKeptAnswer = false
        return openID
    }

    private var keepsAnswer: Bool {
        guard mode == .answer, askedQuestion != nil else { return false }
        guard let closedAt else { return true }
        return now().timeIntervalSince(closedAt) <= Self.keepAnswerFor
    }

    /// Ask closed. A question and its answer stay; a request keeps running.
    public func closed() {
        closedAt = now()
        flash = nil
        searchTask?.cancel()
        isSearching = false
    }

    /// The window in front, read once the panel is up (RULINGS S9).
    public func contextArrived(_ context: FrontmostContext?, openID: Int) {
        guard openID == self.openID else { return }
        liveContext = context
        liveContextKnown = true
        guard !showingKeptAnswer else { return }
        useLiveContext()
        if let question = pendingQuestion {
            send(question)
        } else if mode == .home {
            loadHome()
        }
    }

    public func setStatus(_ status: AskPanelStatus) {
        self.status = status
    }

    private func useLiveContext() {
        context = liveContext
        savedRead = nil
        readEventId = nil
        checkWindowRead()
    }

    /// Whether this window has a saved read, asked of the reads session,
    /// which never waits behind an answer (RULINGS S9).
    private func checkWindowRead() {
        readCheck?.cancel()
        readGeneration += 1
        guard let context, let app = context.bundleId, !app.isEmpty else {
            savedRead = false
            return
        }
        let generation = readGeneration
        let body = Self.json(["app_bundle_id": app, "limit": 200])
        readCheck = Task { [weak self] in
            guard let self else { return }
            var found: BarHit?
            do {
                let data = try await self.memory.call(.reads, "mci_events_by_app", arguments: body, timeout: .seconds(5))
                struct Reply: Decodable { let events: [BarHit] }
                let moments = try JSONDecoder().decode(Reply.self, from: data).events
                found = ThisWindowRead.latest(of: moments, for: context, now: self.now())
            } catch {
                found = nil
            }
            guard !Task.isCancelled, generation == self.readGeneration else { return }
            if let found {
                self.savedRead = true
                self.readEventId = found.eventId
            } else if self.savedRead == nil {
                self.savedRead = false
            }
        }
    }

    /// The rows offered before typing: asked once per open and never
    /// reordered, and never while an answer is being written, because the
    /// assistant session takes one request at a time (RULINGS S9).
    private func loadHome() {
        guard !homeLoaded, liveContextKnown, !previewing else { return }
        guard asksRunning == 0 else {
            homeWaitsForAsk = true
            return
        }
        homeLoaded = true
        homeWaitsForAsk = false
        let generation = homeGeneration
        var arguments: [String: Any] = ["model": false]
        if let app = context?.bundleId { arguments["app"] = app }
        if let title = context?.windowTitle { arguments["title"] = title }
        let body = Self.json(arguments)
        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.memory.call(.assistant, "mci_suggest", arguments: body, timeout: .seconds(8))
                struct Reply: Decodable { let suggestions: [BarSuggestion] }
                let suggestions = try JSONDecoder().decode(Reply.self, from: data).suggestions
                guard generation == self.homeGeneration else { return }
                // The agent offers the screen only when it has read it.
                if suggestions.contains(where: { $0.kind == "screen" }) { self.savedRead = true }
                self.homeRows = Self.homeRows(
                    from: suggestions,
                    readsThisWindow: self.status.readsThisWindow,
                    answersAvailable: self.answersAvailable
                )
            } catch {
                guard generation == self.homeGeneration else { return }
                self.notice = Self.notice(for: error, otherwise: "Opening your memory…")
            }
        }
    }

    // MARK: Typing and search

    private func setQuery(_ text: String) {
        quiet = true
        query = text
        quiet = false
    }

    private func queryChanged() {
        guard !quiet, !previewing else { return }
        searchTask?.cancel()
        let trimmed = query.trimmed
        // Typing replaces a question; emptying the field drops its answer.
        if mode == .answer { leaveAnswer() }
        if trimmed.isEmpty {
            hits = []
            isSearching = false
            notice = nil
            if mode != .home {
                mode = .home
                selection = 0
                loadHome()
            }
            return
        }
        mode = .results
        selection = answersAvailable ? 0 : -1
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.search(trimmed)
        }
    }

    private func search(_ text: String) async {
        searchToken += 1
        let token = searchToken
        isSearching = true
        defer { if token == searchToken { isSearching = false } }
        do {
            let data = try await memory.call(
                .reads, "mci_recall", arguments: Self.json(["query": text, "limit": 8]), timeout: .seconds(10)
            )
            let reply = try JSONDecoder().decode(RecallReply.self, from: data)
            guard mode == .results, query.trimmed == text else { return }
            hits = (reply.hits?.isEmpty == false ? reply.hits : reply.relatedContext) ?? []
            notice = nil
            selection = min(selection, rows.count - 1)
        } catch {
            guard mode == .results, query.trimmed == text else { return }
            notice = Self.notice(for: error, otherwise: "Couldn’t search. Try again.")
        }
    }

    // MARK: Asking

    /// Ask a question. It is sent once the window in front is known, keeps
    /// running while Ask is closed, and its answer comes back with Ask for
    /// 10 minutes.
    public func ask(_ question: String) {
        let trimmed = question.trimmed
        guard !trimmed.isEmpty else { return }
        if askedQuestion == trimmed, isAsking { return }
        searchTask?.cancel()
        isSearching = false
        if showingKeptAnswer {
            // Asked again: it is about the window in front now.
            showingKeptAnswer = false
            homeGeneration += 1
            homeLoaded = false
            homeRows = []
            if liveContextKnown { useLiveContext() }
        }
        setQuery(trimmed)
        askToken += 1
        askedQuestion = trimmed
        askedAt = nil
        answer = nil
        notice = nil
        mode = .answer
        selection = -1
        isAsking = true
        if liveContextKnown {
            send(trimmed)
        } else {
            pendingQuestion = trimmed
        }
    }

    private func send(_ question: String) {
        pendingQuestion = nil
        askedAt = now()
        var arguments: [String: Any] = ["question": question]
        // Which window is in front, not what is in it: the agent answers from
        // its own latest read of that window, so an app Hippocampus never
        // reads contributes nothing but its name.
        if let app = context?.appName { arguments["now"] = "Using \(app)" }
        if let bundleId = context?.bundleId { arguments["app"] = bundleId }
        if let title = context?.windowTitle { arguments["title"] = title }
        let body = Self.json(arguments)
        let token = askToken
        asksRunning += 1
        Task { [weak self] in
            guard let self else { return }
            var reply: BarAnswer?
            var failure: String?
            do {
                let data = try await self.memory.call(.assistant, "mci_ask", arguments: body, timeout: .seconds(75))
                reply = try JSONDecoder().decode(BarAnswer.self, from: data)
            } catch {
                failure = Self.notice(for: error, otherwise: "Couldn’t answer that. Try again.")
            }
            self.asksRunning -= 1
            if let reply {
                self.availability.learn(from: reply, at: self.now())
                self.answersAvailable = self.availability.isAvailable(at: self.now())
            }
            if token == self.askToken {
                self.isAsking = false
                if let reply { self.answer = reply } else { self.notice = failure }
            }
            if self.asksRunning == 0, self.homeWaitsForAsk { self.loadHome() }
        }
    }

    /// Forget the question and its answer. A request still running finishes
    /// in the agent; its reply is not shown.
    private func leaveAnswer() {
        askToken += 1
        askedQuestion = nil
        askedAt = nil
        answer = nil
        notice = nil
        isAsking = false
        pendingQuestion = nil
        guard showingKeptAnswer else { return }
        showingKeptAnswer = false
        homeGeneration += 1
        homeLoaded = false
        homeRows = []
        if liveContextKnown {
            useLiveContext()
        } else {
            context = nil
            savedRead = nil
            readEventId = nil
        }
    }

    /// Context for an AI tool: a cited packet for the question or the window.
    public func copyForAI() async -> String? {
        let focus = query.isEmpty ? (context?.windowTitle ?? "") : query
        guard let data = try? await memory.call(
                .reads, "mci_context", arguments: Self.json(["focus": focus, "max_tokens": 1200]), timeout: .seconds(15)
              ),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String
        else { return nil }
        return text
    }

    public func showFlash(_ text: String?) {
        flash = text
    }

    // MARK: Keyboard

    /// ↑ and ↓. Above the first row is the field, where Return asks, in an
    /// answer and wherever there is no Ask row.
    public func moveSelection(_ delta: Int) {
        let lowest = mode == .answer || (mode == .results && !answersAvailable) ? -1 : 0
        let highest = max(rows.count - 1, lowest)
        selection = min(max(selection + delta, lowest), highest)
    }

    public func select(_ index: Int) {
        if rows.indices.contains(index) { selection = index }
    }

    /// Return: open the chosen row, or ask what is typed. Returns an action
    /// for the controller to perform outside the panel, or nil.
    public func activate() -> BarAction? {
        let text = query.trimmed
        if rows.indices.contains(selection) {
            switch rows[selection] {
            case .ask:
                ask(text)
                return nil
            case .hit(let hit):
                return Self.open(url: hit.url, event: hit.eventId)
            case .source(let source), .thisWindow(let source):
                return Self.open(url: source.url, event: UInt64(max(source.eventId, 0)))
            case .suggestion(let suggestion):
                return run(suggestion)
            }
        }
        if !text.isEmpty { ask(text) }
        return nil
    }

    /// What a ⌘ key does now; nil lets the field have it (⌘C with no answer
    /// copies what is selected in the field). The controller closes on ⌘Q.
    public func action(for command: AskKeyCommand) -> BarAction? {
        switch command {
        case .copyAnswer: answerText.map(BarAction.copy)
        case .copyForAI: .copyForAI
        case .openOverview: .openWindow(tab: "overview")
        case .openYou: .openWindow(tab: "you")
        case .close: nil
        }
    }

    private func run(_ suggestion: BarSuggestion) -> BarAction? {
        if let question = suggestion.action.ask {
            ask(question)
            return nil
        }
        if let text = suggestion.action.query {
            query = text
            return nil
        }
        if suggestion.action.openSession != nil || suggestion.action.view == "day" {
            return .openWindow(tab: "overview")
        }
        if suggestion.action.view == "model" {
            return .openWindow(tab: "you")
        }
        return nil
    }

    private static func open(url: String?, event: UInt64) -> BarAction {
        if let url = url.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true {
            return .openURL(url)
        }
        return .openEvent(event)
    }

    /// Esc: forget an answer or what is typed, then close.
    public func back() -> Bool {
        switch mode {
        case .answer:
            leaveAnswer()
            setQuery("")
            mode = .home
            selection = 0
            loadHome()
            return true
        case .results:
            searchTask?.cancel()
            setQuery("")
            hits = []
            isSearching = false
            notice = nil
            mode = .home
            selection = 0
            loadHome()
            return true
        case .home:
            return false
        }
    }

    /// Stop the sessions (on quit).
    public func shutdown() async {
        await memory.stop()
    }

    private static func notice(for error: Error, otherwise: String) -> String {
        (error as? MemorySessionError) == .unavailable ? "Hippocampus is still starting." : otherwise
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

#if DEBUG
extension CommandBarModel {
    /// Fixture state for rendering Ask without memory.
    public func preview(
        mode: Mode,
        query: String = "",
        context: FrontmostContext? = nil,
        status: AskPanelStatus = AskPanelStatus(.recording),
        savedRead: Bool? = true,
        answersAvailable: Bool = true,
        homeRows: [BarSuggestion] = [],
        hits: [BarHit] = [],
        answer: BarAnswer? = nil,
        notice: String? = nil,
        flash: String? = nil,
        working: Bool = false,
        askedAt: Date? = nil
    ) {
        previewing = true
        setQuery(query)
        self.mode = mode
        self.context = context
        self.status = status
        self.savedRead = savedRead
        self.answersAvailable = answersAvailable
        self.homeRows = homeRows
        self.hits = hits
        self.answer = answer
        self.askedQuestion = mode == .answer ? query : nil
        self.askedAt = askedAt
        self.notice = notice
        self.flash = flash
        self.isAsking = working && mode == .answer
        self.isSearching = working && mode == .results
        switch mode {
        case .home: selection = 0
        case .results: selection = answersAvailable ? 0 : -1
        case .answer: selection = -1
        }
    }
}
#endif
