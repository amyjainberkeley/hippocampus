import Combine
import Foundation

/// Overview: one day, its sessions, and what is happening right now (spec-recall
/// S2 and S6, as amended by RULINGS W5 to W7, I2 and I5, and the overview
/// contract). The agent computes the day; this model keeps a session selected
/// across reads, decides the Right now card, and reads whether Hippocampus is
/// remembering.
@MainActor
public final class OverviewViewModel: ObservableObject {
    public typealias Phase = UnderstandingFeed<UnderstandingDay, DayOverview>.Phase

    /// The day on screen. Another day selects its last session again and
    /// clears what was picked in the legend or the facts.
    @Published public var selectedDate: Date {
        didSet {
            guard UnderstandingDay(date: oldValue, calendar: calendar) != day else { return }
            selection = .latest
            highlightedKind = nil
            factRanges = []
            showsSearches = false
        }
    }
    /// The saved status: whether Hippocampus is remembering right now.
    @Published public private(set) var captureHealth: CaptureHealthReceipt?
    /// A kind picked in the legend: sessions of other kinds are dimmed.
    @Published public private(set) var highlightedKind: WorkKind?
    /// The day's searches, opened from the fact that counts them.
    @Published public private(set) var showsSearches = false
    @Published private var selection: Selection = .latest
    /// The sessions a fact picked, by their time.
    @Published private var factRanges: [ClosedRange<Int64>] = []

    /// The day's reads: the last good one stays on screen during a refresh,
    /// and a delete clears it at once.
    public let feed: UnderstandingFeed<UnderstandingDay, DayOverview>
    public let calendar: Calendar
    private let healthLoader: @Sendable () async -> CaptureHealthReceipt?
    private let now: @Sendable () -> Date
    private var feedChanges: AnyCancellable?

    private enum Selection: Equatable {
        /// The day's last session: what the day ended with, or what is
        /// happening now.
        case latest
        /// A session the person picked, kept by its time.
        case session(ClosedRange<Int64>)
    }

    /// `healthLoader` reads the saved status (`CaptureHealthReceipt.load` in
    /// the app, nothing in the preview); `now` is the clock.
    public init(
        understanding: UnderstandingReader,
        selectedDate: Date? = nil,
        calendar: Calendar = .current,
        healthLoader: @escaping @Sendable () async -> CaptureHealthReceipt?,
        now: @escaping @Sendable () -> Date,
        deletions: MemoryDeletionSignal = .shared
    ) {
        _selectedDate = Published(initialValue: selectedDate ?? now())
        self.calendar = calendar
        self.healthLoader = healthLoader
        self.now = now
        feed = UnderstandingFeed(deletions: deletions) { day in
            try await understanding.overview(day)
        }
        feedChanges = feed.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    // MARK: The day

    /// The day as the agent is asked about it.
    public var day: UnderstandingDay {
        UnderstandingDay(date: selectedDate, calendar: calendar)
    }

    /// The selected day's overview; nil until it is read.
    public var overview: DayOverview? {
        feed.key == day ? feed.value : nil
    }

    public var phase: Phase {
        if feed.key == day { return feed.phase }
        return feed.phase == .idle ? .idle : .loading
    }

    public var isToday: Bool {
        calendar.isDate(selectedDate, inSameDayAs: now())
    }

    /// "Next day" stops at today.
    public var canMoveForward: Bool {
        guard let next = calendar.date(byAdding: .day, value: 1, to: selectedDate) else { return false }
        return calendar.startOfDay(for: next) <= calendar.startOfDay(for: now())
    }

    /// Read the day, and the saved status.
    public func reload() async {
        let requested = day
        async let receipt = healthLoader()
        await feed.load(requested)
        captureHealth = await receipt
    }

    /// The day before or after; never past today.
    public func moveDay(_ amount: Int) {
        guard let date = calendar.date(byAdding: .day, value: amount, to: selectedDate),
              calendar.startOfDay(for: date) <= calendar.startOfDay(for: now())
        else { return }
        selectedDate = date
    }

    public func goToToday() {
        selectedDate = now()
    }

    // MARK: Sessions

    /// The day's sessions, oldest first.
    public var blocks: [DayBlock] {
        overview?.blocks ?? []
    }

    /// The session whose detail shows: the one picked, found again by its
    /// time after every read (its id can change, RULINGS I2), else the day's
    /// last session.
    public var selectedBlock: DayBlock? {
        switch selection {
        case .latest:
            return blocks.last
        case let .session(range):
            return SessionMatch.best(for: range, in: blocks) ?? blocks.last
        }
    }

    public func select(_ block: DayBlock) {
        selection = .session(block.startUs...block.endUs)
        factRanges = []
    }

    /// Left and right arrows: the session before or after the selected one.
    public func moveSelection(by delta: Int) {
        let blocks = self.blocks
        guard !blocks.isEmpty else { return }
        let current = selectedBlock.flatMap { selected in
            blocks.firstIndex { $0.id == selected.id }
        } ?? (blocks.count - 1)
        let target = min(max(current + delta, 0), blocks.count - 1)
        select(blocks[target])
    }

    /// Show `route`'s day, with the session overlapping its time selected (a
    /// session row on You).
    public func open(_ route: RecallRoute) {
        if let date = route.day ?? route.timeRange.map({ Date(timeIntervalSince1970: Double($0.lowerBound) / 1_000_000) }) {
            selectedDate = date
        }
        if let range = route.timeRange {
            selection = .session(range)
            factRanges = []
        }
    }

    /// "Show in History" for a session: its own time, its newest moment
    /// selected (RULINGS W8).
    public func historyRoute(for block: DayBlock) -> RecallRoute {
        .history(of: block.startUs...block.endUs, selecting: block.openEventId)
    }

    // MARK: Legend and facts

    /// Pick a kind in the legend, or put it back.
    public func toggleHighlight(_ kind: WorkKind) {
        highlightedKind = highlightedKind == kind ? nil : kind
        factRanges = []
    }

    /// The sessions a fact picked, found again by their time.
    public var highlightedBlocks: [DayBlock] {
        factRanges.compactMap { SessionMatch.best(for: $0, in: blocks) }
    }

    /// A session drawn dimmed: another kind is picked in the legend, or a
    /// fact picked other sessions. A kind no session has any more dims nothing.
    public func isDimmed(_ block: DayBlock) -> Bool {
        if !factRanges.isEmpty {
            return !highlightedBlocks.contains { $0.id == block.id }
        }
        guard let kind = highlightedKind, blocks.contains(where: { $0.kind == kind }) else { return false }
        return block.kind != kind
    }

    /// Clicking a fact: its sessions are picked and the first is selected, or
    /// the day's searches open.
    public func perform(_ fact: DayFact) {
        guard let action = fact.action else { return }
        switch action.kind {
        case .selectBlocks:
            let ranges = action.blockIds.compactMap { id in
                blocks.first { $0.id == id }.map { $0.startUs...$0.endUs }
            }
            guard let first = ranges.first else { return }
            highlightedKind = nil
            selection = .session(first)
            factRanges = ranges
        case .showSearches:
            showsSearches = true
        case .none:
            break
        }
    }

    public func hideSearches() {
        showsSearches = false
    }

    // MARK: Right now

    /// The Right now card, today only (RULINGS W5).
    public var rightNow: RightNowCard? {
        guard isToday, let overview else { return nil }
        return RightNowCard(overview: overview, receipt: captureHealth, now: now())
    }
}
