import Combine
import Foundation

// MARK: Data

/// What the user was looking at when the bar opened.
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
    public var body: String {
        let lines = textSnippet.split(separator: "\n", omittingEmptySubsequences: true)
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
}

public struct BarAnswer: Decodable, Sendable, Equatable {
    public let answer: String?
    public let sources: [BarSource]
    public let unavailable: String?
}

public struct BarDay: Decodable, Sendable, Equatable {
    public struct Kind: Decodable, Sendable, Equatable {
        public let kind: String
        public let label: String
        public let activeUs: UInt64
        enum CodingKeys: String, CodingKey { case kind, label, activeUs = "active_us" }
    }
    public struct App: Decodable, Sendable, Equatable {
        public let bundleId: String
        public let name: String
        public let activeUs: UInt64
        enum CodingKeys: String, CodingKey { case bundleId = "bundle_id", name, activeUs = "active_us" }
    }
    public struct Focus: Decodable, Sendable, Equatable {
        public let startUs: UInt64
        public let endUs: UInt64
        public let kind: String
        public let app: String
        enum CodingKeys: String, CodingKey { case startUs = "start_us", endUs = "end_us", kind, app }
    }
    public struct Search: Decodable, Sendable, Equatable {
        public let query: String
        public let tsUs: UInt64
        enum CodingKeys: String, CodingKey { case query, tsUs = "ts_us" }
    }
    public struct Session: Decodable, Sendable, Equatable {
        public let startUs: UInt64
        public let endUs: UInt64
        public let title: String
        public let beneath: String
        enum CodingKeys: String, CodingKey { case startUs = "start_us", endUs = "end_us", title, beneath }
    }
    public struct Breakdown: Decodable, Sendable, Equatable {
        public let dateLocal: String
        public let basis: String
        public let activeUs: UInt64
        public let apps: [App]
        public let kinds: [Kind]
        public let focusBlocks: [Focus]
        public let switches: UInt32
        public let switchesPerHour: Double
        public let searches: [Search]
        public let sessions: [Session]
        enum CodingKeys: String, CodingKey {
            case dateLocal = "date_local", basis, activeUs = "active_us", apps, kinds
            case focusBlocks = "focus_blocks", switches, switchesPerHour = "switches_per_hour", searches, sessions
        }
    }
    public struct Narrative: Decodable, Sendable, Equatable {
        public let headline: String
        public let narrative: String
        public let insights: [String]
        public let suggestion: String
    }
    public struct Payload: Decodable, Sendable, Equatable {
        public let breakdown: Breakdown
        public let narrative: Narrative?
        public let writtenBy: String?
        enum CodingKeys: String, CodingKey { case breakdown, narrative, writtenBy = "written_by" }
    }
    public let day: Payload
    public let facts: String
}

/// One selectable row in the bar.
public enum BarRow: Sendable, Equatable, Identifiable {
    case suggestion(BarSuggestion)
    case ask(String)
    case hit(BarHit)
    case source(BarSource)

    public var id: String {
        switch self {
        case .suggestion(let s): "s-\(s.id)"
        case .ask(let q): "a-\(q)"
        case .hit(let h): "h-\(h.eventId)"
        case .source(let s): "c-\(s.n)"
        }
    }
}

/// What activating a row does outside the bar.
public enum BarAction: Sendable, Equatable {
    case openURL(URL)
    case openEvent(UInt64)
    case copy(String)
}

// MARK: Model

/// The command bar: knows what you were looking at, suggests before you
/// type, searches as you type, answers questions from your memory and shows
/// your day.
@MainActor
public final class CommandBarModel: ObservableObject {
    public enum Mode: Equatable, Sendable { case home, results, answer, day }

    @Published public var query: String = ""
    @Published public private(set) var mode: Mode = .home
    @Published public private(set) var context: FrontmostContext?
    @Published public private(set) var suggestions: [BarSuggestion] = []
    @Published public private(set) var hits: [BarHit] = []
    @Published public private(set) var answer: BarAnswer?
    @Published public private(set) var askedQuestion: String?
    @Published public private(set) var isWorking = false
    @Published public private(set) var day: BarDay?
    @Published public private(set) var selection = 0
    @Published public private(set) var notice: String?

    private let reads = MemorySession()
    private let assistant = MemorySession()
    private let launch: @MainActor (_ assist: Bool) -> MemorySessionLaunch?
    private var searchTask: Task<Void, Never>?
    private var queryObserver: AnyCancellable?
    private var openGeneration = 0
    private var previewing = false

    public init(launch: @escaping @MainActor (_ assist: Bool) -> MemorySessionLaunch?) {
        self.launch = launch
        queryObserver = $query
            .removeDuplicates()
            .sink { [weak self] text in
                Task { @MainActor in self?.queryChanged(text) }
            }
    }

    // MARK: Rows

    public var rows: [BarRow] {
        switch mode {
        case .home:
            return suggestions.map(BarRow.suggestion)
        case .results:
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return [.ask(trimmed)] + hits.map(BarRow.hit)
        case .answer:
            return (answer?.sources ?? []).map(BarRow.source)
        case .day:
            return []
        }
    }

    /// A query that reads like a question is answered; anything else is searched.
    nonisolated public static func looksLikeQuestion(_ text: String) -> Bool {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespaces)
        if lowered.hasSuffix("?") { return true }
        let starters = ["what", "when", "where", "who", "why", "how", "which", "did ", "do ", "does ",
                        "is ", "are ", "was ", "were ", "can ", "could ", "should ", "summarize", "remind"]
        return starters.contains { lowered.hasPrefix($0) }
    }

    // MARK: Lifecycle

    /// The bar opened over `context`.
    public func opened(context: FrontmostContext?) {
        openGeneration += 1
        let generation = openGeneration
        self.context = context
        query = ""
        mode = .home
        hits = []
        answer = nil
        askedQuestion = nil
        day = nil
        selection = 0
        notice = nil
        Task { await loadSuggestions(generation: generation, model: false) }
        Task { await loadSuggestions(generation: generation, model: true) }
    }

    private func loadSuggestions(generation: Int, model: Bool) async {
        guard let launch = launch(true) else {
            notice = "Hippocampus isn’t running yet."
            return
        }
        var arguments: [String: Any] = ["model": model]
        if let bundle = context?.bundleId { arguments["app"] = bundle }
        if let title = context?.windowTitle { arguments["title"] = title }
        guard let body = try? JSONSerialization.data(withJSONObject: arguments) else { return }
        do {
            let data = try await assistant.call("mci_suggest", arguments: body, launch: launch,
                                                timeout: model ? .seconds(40) : .seconds(8))
            struct Reply: Decodable { let suggestions: [BarSuggestion] }
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            guard generation == openGeneration else { return }
            // Model predictions add to, never replace, the measured ones.
            var merged = model ? suggestions : []
            for item in reply.suggestions where !merged.contains(where: { $0.title == item.title }) {
                merged.append(item)
            }
            suggestions = Array(merged.sorted { $0.score > $1.score }.prefix(7))
        } catch {
            if !model, generation == openGeneration, suggestions.isEmpty {
                notice = "Your memory is starting up…"
            }
        }
    }

    // MARK: Typing and search

    private func queryChanged(_ text: String) {
        if previewing { return }
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if mode == .results { mode = .home }
            hits = []
            selection = 0
            return
        }
        if mode != .results {
            mode = .results
            answer = nil
        }
        selection = Self.looksLikeQuestion(trimmed) ? 0 : (hits.isEmpty ? 0 : 1)
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.search(trimmed)
        }
    }

    private func search(_ text: String) async {
        guard let launch = launch(false),
              let body = try? JSONSerialization.data(withJSONObject: ["query": text, "limit": 8])
        else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try await reads.call("mci_recall", arguments: body, launch: launch, timeout: .seconds(10))
            let reply = try JSONDecoder().decode(RecallReply.self, from: data)
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            hits = (reply.hits?.isEmpty == false ? reply.hits : reply.relatedContext) ?? []
            if !Self.looksLikeQuestion(text), !hits.isEmpty, selection == 0 { selection = 1 }
            selection = min(selection, max(rows.count - 1, 0))
        } catch {
            notice = "Search isn’t available right now."
        }
    }

    // MARK: Asking

    public func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let launch = launch(true) else { return }
        searchTask?.cancel()
        askedQuestion = trimmed
        answer = nil
        mode = .answer
        selection = 0
        isWorking = true
        var arguments: [String: Any] = ["question": trimmed]
        // Only the app's name: what is in its window reaches the answer only
        // through memories Hippocampus was allowed to capture.
        if let app = context?.appName {
            arguments["now"] = "Using \(app)"
        }
        guard let body = try? JSONSerialization.data(withJSONObject: arguments) else { return }
        Task {
            defer { if self.askedQuestion == trimmed { self.isWorking = false } }
            do {
                let data = try await assistant.call("mci_ask", arguments: body, launch: launch, timeout: .seconds(75))
                let reply = try JSONDecoder().decode(BarAnswer.self, from: data)
                guard askedQuestion == trimmed else { return }
                answer = reply
            } catch {
                guard askedQuestion == trimmed else { return }
                notice = "Couldn’t answer that just now."
            }
        }
    }

    // MARK: Day

    public func showDay() {
        guard let launch = launch(false) else { return }
        mode = .day
        selection = 0
        isWorking = day == nil
        Task {
            defer { isWorking = false }
            do {
                let data = try await reads.call("mci_day", arguments: Data("{}".utf8), launch: launch, timeout: .seconds(15))
                day = try JSONDecoder().decode(BarDay.self, from: data)
            } catch {
                notice = "Your day isn’t available yet."
            }
        }
    }

    /// Context for any AI: a cited packet for the current query or screen.
    public func copyContext() async -> String? {
        guard let launch = launch(false) else { return nil }
        let focus = query.isEmpty ? (context?.windowTitle ?? "") : query
        guard let body = try? JSONSerialization.data(withJSONObject: ["focus": focus, "max_tokens": 1200]),
              let data = try? await reads.call("mci_context", arguments: body, launch: launch, timeout: .seconds(15)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String
        else { return nil }
        return text
    }

    // MARK: Keyboard

    public func moveSelection(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    public func select(_ index: Int) {
        if rows.indices.contains(index) { selection = index }
    }

    /// Activate the selected row. Returns an action for the controller to
    /// perform outside the bar, or nil when the bar handled it.
    public func activate(preferAsk: Bool = false) -> BarAction? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if preferAsk, !trimmed.isEmpty {
            ask(trimmed)
            return nil
        }
        guard rows.indices.contains(selection) else {
            if !trimmed.isEmpty { ask(trimmed) }
            return nil
        }
        switch rows[selection] {
        case .ask(let question):
            ask(question)
            return nil
        case .hit(let hit):
            if let url = hit.url.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true {
                return .openURL(url)
            }
            return .openEvent(hit.eventId)
        case .source(let source):
            if let url = source.url.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true {
                return .openURL(url)
            }
            return .openEvent(UInt64(max(source.eventId, 0)))
        case .suggestion(let suggestion):
            if suggestion.action.view == "day" || suggestion.action.openSession != nil {
                showDay()
            } else if let question = suggestion.action.ask {
                query = question
                ask(question)
            } else if let text = suggestion.action.query {
                query = text
            }
            return nil
        }
    }

    /// Esc: step back (answer or day → results or home), or close.
    public func back() -> Bool {
        switch mode {
        case .answer, .day:
            mode = query.isEmpty ? .home : .results
            selection = 0
            return true
        case .results:
            query = ""
            return true
        case .home:
            return false
        }
    }

    /// Stop the sessions (on quit).
    public func shutdown() async {
        await reads.stop()
        await assistant.stop()
    }
}

#if DEBUG
extension CommandBarModel {
    /// Fixture state for rendering the bar without a brain.
    public func preview(
        mode: Mode,
        query: String = "",
        context: FrontmostContext? = nil,
        suggestions: [BarSuggestion] = [],
        hits: [BarHit] = [],
        answer: BarAnswer? = nil,
        question: String? = nil,
        day: BarDay? = nil,
        working: Bool = false
    ) {
        previewing = true
        queryObserver = nil
        self.query = query
        self.mode = mode
        self.context = context
        self.suggestions = suggestions
        self.hits = hits
        self.answer = answer
        self.askedQuestion = question
        self.day = day
        self.isWorking = working
        self.selection = mode == .results ? 1 : 0
    }
}
#endif
