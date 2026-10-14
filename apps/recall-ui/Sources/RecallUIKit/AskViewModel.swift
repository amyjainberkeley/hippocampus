import Combine
import Foundation

/// Whether what is typed in Ask reads as a question: Return asks it rather
/// than moving to the matches (spec-recall S3). Only a whole first word
/// counts, so "whatsapp", "howard" and "whole foods" stay searches
/// (critique-recall-product finding 9). One word alone is a search unless it
/// ends with a question mark.
public enum AskIntent {
    static let questionWords: Set<String> = [
        "what", "whats", "what's", "when", "whens", "when's", "where", "wheres", "where's",
        "who", "whos", "who's", "whom", "whose", "why", "how", "hows", "how's", "which",
        "is", "are", "was", "were", "am", "do", "does", "did", "can", "could", "should", "would",
        "have", "has", "had", "tell", "explain", "summarize", "summarise", "remind", "describe",
    ]

    public static func looksLikeQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("?") || trimmed.hasSuffix("\u{FF1F}") { return true }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, let first = words.first else { return false }
        let word = first.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'")))
        return questionWords.contains(word)
    }
}

/// Ask: one field that searches as you type and answers a question, with
/// History under it while the field is empty (spec-recall S3 and S6, as
/// amended by critique-recall-engineering findings 2, 4, 5 and 16 and
/// critique-recall-product findings 3 and 9).
///
/// - It owns the question in flight: a new question, Esc, clearing the field
///   or leaving Ask stops it.
/// - An answer is kept with its question for the life of the window, and
///   comes back when that question is in the field again.
/// - It never says "No matches" for a question that has not been asked.
/// - Esc closes the detail, then the selection, then empties the field.
@MainActor
public final class AskViewModel: ObservableObject {
    /// What became of the question in the field.
    public enum AnswerState: Equatable, Sendable {
        case none
        /// "Thinking on your Mac…"
        case thinking(question: String)
        /// An answer, or why there is none (`answer.unavailable`), with its sources.
        case answered(question: String, answer: AskAnswer)
        /// Hippocampus could not be asked.
        case failed(question: String)
    }

    /// What Return did.
    public enum SubmitOutcome: Equatable, Sendable {
        case asked
        /// Not a question: the view moves to the first match.
        case focusFirstMatch
        case nothing
    }

    /// What Esc did, in the order it does it.
    public enum EscapeOutcome: Equatable, Sendable {
        case closedDetail
        case clearedSelection
        case stoppedQuestion
        case clearedField
        /// Nothing left to close: the window may have it.
        case ignored
    }

    public let search: SearchViewModel
    /// History, under the empty field.
    public let history: TimelineViewModel
    /// Filters show above the matches.
    @Published public var showsFilters = false
    /// Whether answers can come at all: learned from a reply, or from the
    /// model's status. Nil until known. While false, Return searches.
    @Published public private(set) var answersAvailable: Bool?
    /// Moves on each time the cursor should go to the field.
    @Published public private(set) var fieldFocusRequest = 0

    @Published private var asking: Asking?
    @Published private var kept: [String: AskAnswer] = [:]
    @Published private var failedQuestion: String?

    private struct Asking: Equatable {
        let question: String
        let id: UUID
    }

    /// Answers kept for the life of the window, newest last.
    static let keptLimit = 20
    private var keptOrder: [String] = []
    private let understanding: UnderstandingReader
    private let calendar: Calendar
    private var askTask: Task<Void, Never>?
    private var changes: Set<AnyCancellable> = []

    public init(
        search: SearchViewModel,
        history: TimelineViewModel,
        understanding: UnderstandingReader,
        calendar: Calendar = .current,
        deletions: MemoryDeletionSignal = .shared
    ) {
        self.search = search
        self.history = history
        self.understanding = understanding
        self.calendar = calendar
        // Ask redraws when the search or History changes
        // (critique-recall-engineering finding 16).
        for publisher in [search.objectWillChange, history.objectWillChange] {
            publisher.sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
            .store(in: &changes)
        }
        deletions.center
            .publisher(for: MemoryDeletionSignal.notification, object: deletions)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.memoryWasDeleted() }
            }
            .store(in: &changes)
    }

    /// The field. Typing searches as you type (`SearchViewModel`).
    public var query: String {
        get { search.query }
        set { search.query = newValue }
    }

    private var question: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The field holds a question, by its first word.
    public var looksLikeQuestion: Bool {
        AskIntent.looksLikeQuestion(query)
    }

    public var answerState: AnswerState {
        let question = self.question
        guard !question.isEmpty else { return .none }
        if asking?.question == question { return .thinking(question: question) }
        if let answer = kept[question] { return .answered(question: question, answer: answer) }
        if failedQuestion == question { return .failed(question: question) }
        return .none
    }

    /// Matches show when something is typed, or a memory was opened from
    /// outside the list; otherwise History shows.
    public var showsMatches: Bool {
        !question.isEmpty || search.isShowingFocusedEvent
    }

    public var showsHistory: Bool {
        !showsMatches
    }

    /// "No matches", only when a finished search found nothing for text that
    /// is not a question waiting to be asked (critique-recall-engineering
    /// finding 16), and no answer is about it.
    public var showsNoMatches: Bool {
        let question = self.question
        guard !question.isEmpty, !search.isShowingFocusedEvent, !search.isSearching,
              search.errorMessage == nil, search.hits.isEmpty, answerState == .none
        else { return false }
        return !(AskIntent.looksLikeQuestion(question) && answersAvailable != false)
    }

    /// Return: a question is asked; anything else moves to the first match.
    /// ⌘Return (`forceAsk`) asks whatever is typed. While answers are known
    /// to be unavailable, Return only searches.
    @discardableResult
    public func submit(forceAsk: Bool = false) -> SubmitOutcome {
        let question = self.question
        guard !question.isEmpty else { return .nothing }
        if forceAsk || (AskIntent.looksLikeQuestion(question) && answersAvailable != false) {
            ask(question)
            return .asked
        }
        return search.hits.isEmpty ? .nothing : .focusFirstMatch
    }

    /// Ask `text`. A question already being asked goes on; any other stops.
    /// The question travels to the warm answer child, never on a command line.
    public func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, asking?.question != question else { return }
        askTask?.cancel()
        let asking = Asking(question: question, id: UUID())
        self.asking = asking
        if failedQuestion == question { failedQuestion = nil }
        let understanding = self.understanding
        askTask = Task { [weak self] in
            do {
                let answer = try await understanding.ask(question, app: nil, title: nil, now: nil)
                self?.finish(asking, with: .success(answer))
            } catch {
                self?.finish(asking, with: .failure(error))
            }
        }
    }

    /// Stop the question in flight. Nothing is kept for it.
    public func stopAsking() {
        askTask?.cancel()
        askTask = nil
        asking = nil
    }

    /// Empty the field, so History shows. A question in flight stops; answers
    /// already given are kept for when their question comes back.
    public func clear() {
        stopAsking()
        failedQuestion = nil
        search.clear()
    }

    /// Esc: the detail, then the selection, then the question in flight, then
    /// the field (critique-recall-engineering finding 16).
    @discardableResult
    public func escape() -> EscapeOutcome {
        if showsMatches {
            if search.isDetailFocused, search.selectedHit != nil {
                search.dismissDetail()
                return .closedDetail
            }
            if search.selectedHitId != nil {
                search.selectedHitId = nil
                search.dismissDetail()
                return .clearedSelection
            }
        } else {
            if history.isDetailFocused, history.selectedHit != nil {
                history.dismissDetail()
                return .closedDetail
            }
            if history.selectedHitId != nil {
                history.selectedHitId = nil
                history.dismissDetail()
                return .clearedSelection
            }
        }
        if case .thinking = answerState {
            stopAsking()
            return .stoppedQuestion
        }
        if !query.isEmpty || search.isShowingFocusedEvent || search.filters.anyActive {
            clear()
            return .clearedField
        }
        return .ignored
    }

    /// Ask left the screen: the question in flight stops
    /// (critique-recall-engineering finding 2).
    public func disappear() {
        stopAsking()
    }

    /// What the model's status says about answers, when no reply has said yet.
    public func note(_ status: ModelStatus) {
        guard answersAvailable == nil else { return }
        switch status.state {
        case .available:
            answersAvailable = true
        case .unavailable:
            if Self.meansNoAnswers(status.reason) { answersAvailable = false }
        case .unknown:
            break
        }
    }

    /// Ask's part of a route: the field, a memory to show, or History on a
    /// day or a session's own time.
    public func open(_ route: RecallRoute) async {
        if route.clearsField { clear() }
        if route.focusesField { fieldFocusRequest += 1 }
        if let range = route.timeRange {
            let date = route.day ?? Date(timeIntervalSince1970: Double(range.lowerBound) / 1_000_000)
            await history.show(day: MemoryDay(date: date, calendar: calendar),
                               around: UInt64(clamping: range.lowerBound)...UInt64(clamping: range.upperBound),
                               selecting: route.focusEventId)
        } else if let date = route.day {
            await history.show(day: MemoryDay(date: date, calendar: calendar))
        } else if let eventId = route.focusEventId {
            await search.focusEvent(id: eventId)
        }
    }

    private func finish(_ asked: Asking, with result: Result<AskAnswer, any Error>) {
        guard asking == asked else { return }
        asking = nil
        askTask = nil
        switch result {
        case let .success(answer):
            keep(answer, for: asked.question)
            if answer.answer != nil {
                answersAvailable = true
            } else if Self.meansNoAnswers(answer.unavailable) {
                answersAvailable = false
            }
        case let .failure(error):
            if error is CancellationError { return }
            failedQuestion = asked.question
        }
    }

    private func keep(_ answer: AskAnswer, for question: String) {
        kept[question] = answer
        keptOrder.removeAll { $0 == question }
        keptOrder.append(question)
        while keptOrder.count > Self.keptLimit {
            kept[keptOrder.removeFirst()] = nil
        }
    }

    /// Answers cannot come on this Mac as it is: Apple Intelligence is off or
    /// cannot run here, there is no model server either, or the part that
    /// answers is missing. A model still getting ready, a model server that
    /// is not answering yet, or an error, may pass.
    private static func meansNoAnswers(_ reason: String?) -> Bool {
        switch reason {
        case "apple_intelligence_off", "device_not_eligible", "not_installed", "cannot_launch",
             "needs_apple_intelligence_or_local_model", "needs_macos_26": true
        default: false
        }
    }

    /// Moments were deleted: an answer may quote them, so every answer goes,
    /// and a question in flight stops (critique-recall-engineering finding 4).
    private func memoryWasDeleted() {
        stopAsking()
        kept = [:]
        keptOrder = []
        failedQuestion = nil
    }
}
