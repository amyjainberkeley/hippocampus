import Combine
import Foundation

/// Today: one day, its sessions, and where you are or where you left off
/// (SPEC 3.1; spec-recall S2 and S6, as amended by RULINGS W5 to W7, I2 and
/// I5, and the overview contract). The agent computes the day; this model
/// keeps a session selected across reads, decides the card at the top, and
/// reads whether Hippocampus is remembering.
///
/// Around the day it reads, when the window gives it the readers:
/// - the last day with anything saved, for a morning's "Where you left off";
/// - the card's newest moment, drawn as History draws it;
/// - Working On (`WorkReader`): the item the card's session is part of, and
///   "Also from yesterday";
/// - the calendar (`CalendarReader`, SPEC-DELTA 5): today's events over the
///   strip, and the names of calls and meetings. Only when it may be read.
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
            events = []
        }
    }
    /// The saved status: whether Hippocampus is remembering right now.
    @Published public private(set) var captureHealth: CaptureHealthReceipt?
    /// A kind picked in the legend: sessions of other kinds are dimmed.
    @Published public private(set) var highlightedKind: StripKind?
    /// The day's searches, opened from the fact that counts them.
    @Published public private(set) var showsSearches = false
    @Published private var selection: Selection = .latest
    /// The sessions a fact picked, by their time.
    @Published private var factRanges: [ClosedRange<Int64>] = []

    /// Whether the calendar may be read, and the selected day's events when it may.
    @Published public private(set) var calendarAccess: CalendarAccess = .notAsked
    @Published public private(set) var events: [CalendarEvent] = []
    /// The last day with anything saved before today, when today has nothing yet.
    @Published public private(set) var earlierDay: DayOverview?
    /// The card's newest moment, as History draws it.
    @Published public private(set) var cardMoment: Hit?
    /// What the window knows of Working On.
    @Published public private(set) var work: WorkSnapshot?
    /// The Working On item the card's session is part of, by id.
    @Published public private(set) var cardItemId: String?
    /// The first day: how many moments are saved, and the newest of them.
    @Published public private(set) var savedSoFar: UInt64?
    @Published public private(set) var newestMoment: Hit?
    /// The calendar was offered on Today and taken or put aside: it isn't again.
    @Published public private(set) var calendarOfferDone: Bool

    /// The day's reads: the last good one stays on screen during a refresh,
    /// and a delete clears it at once.
    public let feed: UnderstandingFeed<UnderstandingDay, DayOverview>
    public let calendar: Calendar
    private let understanding: UnderstandingReader
    private let healthLoader: @Sendable () async -> CaptureHealthReceipt?
    private let now: @Sendable () -> Date
    private let savedBefore: @Sendable (Date) async throws -> Bool
    private let deletions: MemoryDeletionSignal
    private let reader: BrainReader?
    private let workReader: (any WorkReader)?
    private let calendarReader: (any CalendarReader)?
    private let offers: KeyValueStore
    private var feedChanges: AnyCancellable?
    private var deletionChanges: AnyCancellable?

    /// The key that remembers the calendar was offered on Today.
    public static let calendarOfferKey = "ai.hippocampus.window.today.calendarOffered"

    /// What is saved from before today, as far as the window knows.
    private enum EarlierMemory: Equatable {
        /// Not read, or it could not be read.
        case unknown
        /// Nothing is saved from before the day that starts at this time.
        case nothingBefore(Date)
        /// Something is. That holds for every later day too, so it is kept
        /// until a delete moves `deletions` on.
        case something
    }

    @Published private var earlierMemory = EarlierMemory.unknown
    private var earlierMemoryGeneration: UInt64 = 0

    private enum Selection: Equatable {
        /// The day's last session: what the day ended with, or what is
        /// happening now. On today, with the card showing that session, the
        /// one before it, so the card's session isn't shown twice.
        case latest
        /// A session the person picked, kept by its time.
        case session(ClosedRange<Int64>)
    }

    /// `healthLoader` reads the saved status (`CaptureHealthReceipt.load` in
    /// the app, nothing in the preview); `now` is the clock. `savedBefore`
    /// says whether any moment is saved from before a time, or throws when
    /// it cannot say. Left out, it cannot say, and Today never treats a
    /// day as the first.
    ///
    /// `reader` reads the memory for the card's moment, the first day's count
    /// and a morning's earlier day; `work` reads Working On; `calendarReader`
    /// the calendar, and `offers` keeps whether it was offered. Each is
    /// optional: without it, Today shows the day without that part.
    public init(
        understanding: UnderstandingReader,
        selectedDate: Date? = nil,
        calendar: Calendar = .current,
        healthLoader: @escaping @Sendable () async -> CaptureHealthReceipt?,
        now: @escaping @Sendable () -> Date,
        deletions: MemoryDeletionSignal = .shared,
        savedBefore: @escaping @Sendable (Date) async throws -> Bool = { _ in throw UnderstandingError.unavailable },
        reader: BrainReader? = nil,
        work: (any WorkReader)? = nil,
        calendarReader: (any CalendarReader)? = nil,
        offers: KeyValueStore = UserDefaultsKeyValueStore()
    ) {
        _selectedDate = Published(initialValue: selectedDate ?? now())
        self.calendar = calendar
        self.understanding = understanding
        self.healthLoader = healthLoader
        self.now = now
        self.savedBefore = savedBefore
        self.deletions = deletions
        self.reader = reader
        self.workReader = work
        self.calendarReader = calendarReader
        self.offers = offers
        _calendarOfferDone = Published(initialValue: offers.data(forKey: Self.calendarOfferKey) != nil)
        feed = UnderstandingFeed(deletions: deletions) { day in
            try await understanding.overview(day)
        }
        feedChanges = feed.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        deletionChanges = deletions.center
            .publisher(for: MemoryDeletionSignal.notification, object: deletions)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.memoryWasDeleted() }
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

    /// The day shown is the day before today: its title says "Yesterday".
    public var isYesterday: Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now()) else { return false }
        return calendar.isDate(selectedDate, inSameDayAs: yesterday)
    }

    /// "Next day" stops at today.
    public var canMoveForward: Bool {
        guard let next = calendar.date(byAdding: .day, value: 1, to: selectedDate) else { return false }
        return calendar.startOfDay(for: next) <= calendar.startOfDay(for: now())
    }

    /// Read the saved status and, for today, whether anything is saved from
    /// before it; then the day, then what goes around it. The first two are
    /// quick local reads, done first so the day is never drawn with an old
    /// answer to either (the first day's welcome).
    public func reload() async {
        let requested = day
        async let receipt = healthLoader()
        if isToday { await readEarlierMemory() }
        captureHealth = await receipt
        await feed.load(requested)
        await readCalendar(for: requested)
        guard requested == day else { return }
        if isToday {
            await readAroundToday()
        }
    }

    /// Asks whether anything is saved from before today, unless something
    /// already was and nothing has been deleted since. One moment at most is
    /// read, newest first, through the time index; only whether there is one
    /// is kept.
    private func readEarlierMemory() async {
        let generation = deletions.generation
        if earlierMemory == .something, earlierMemoryGeneration == generation { return }
        let today = calendar.startOfDay(for: now())
        do {
            earlierMemory = try await savedBefore(today) ? .something : .nothingBefore(today)
            earlierMemoryGeneration = generation
        } catch {
            earlierMemory = .unknown
        }
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

    // MARK: Around today

    /// The calendar for `day`, when it may be read: its events, else none.
    private func readCalendar(for day: UnderstandingDay) async {
        guard let calendarReader else {
            calendarAccess = .notAsked
            events = []
            return
        }
        let access = await calendarReader.access()
        guard day == self.day else { return }
        calendarAccess = access
        guard access == .allowed, let interval = dayInterval(day) else {
            events = []
            return
        }
        let found = (try? await calendarReader.events(in: interval)) ?? []
        guard day == self.day else { return }
        events = found
    }

    private func dayInterval(_ day: UnderstandingDay) -> DateInterval? {
        if let overview, overview.date == day.dateLocal, overview.dayEndUs > overview.dayStartUs {
            return DateInterval(start: Date(timeIntervalSince1970: Double(overview.dayStartUs) / 1_000_000),
                                end: Date(timeIntervalSince1970: Double(overview.dayEndUs) / 1_000_000))
        }
        return calendar.dateInterval(of: .day, for: selectedDate)
    }

    /// Today's card, the first day's count, Working On: each from its own
    /// read, so one that fails leaves the rest.
    private func readAroundToday() async {
        if showsFirstDay {
            earlierDay = nil
            if let reader {
                savedSoFar = (try? await reader.summaryStats())?.totalEvents
                newestMoment = try? await reader.recentEvents(limit: 1).first
            }
            return
        }
        savedSoFar = nil
        newestMoment = nil
        // A morning, or a day back after time away: today has no session
        // yet, so the card is the last session of the last day with any.
        if let overview, overview.blocks.isEmpty || overview.now.state == .none {
            await readEarlierDay()
        } else {
            earlierDay = nil
        }
        if let id = rightNow?.openEventId.flatMap({ UInt64(exactly: $0) }), let reader {
            let found = try? await reader.fetchEventsByIds([id]).first { $0.id == id }
            cardMoment = found
        } else {
            cardMoment = nil
        }
        await readWork()
    }

    /// The last day before today with anything saved, found by its newest
    /// moment through the time index, then read as any other day.
    private func readEarlierDay() async {
        guard let reader else { return }
        let start = calendar.startOfDay(for: now())
        guard let newest = try? await reader.newestMoment(before: start) else {
            earlierDay = nil
            return
        }
        let date = Date(timeIntervalSince1970: Double(newest.tsUs) / 1_000_000)
        earlierDay = try? await understanding.overview(UnderstandingDay(date: date, calendar: calendar))
    }

    private func readWork() async {
        guard let workReader else { return }
        work = try? await workReader.work(days: 14)
        guard let card = rightNow, let id = card.openEventId.flatMap({ UInt64(exactly: $0) }) else {
            cardItemId = nil
            return
        }
        let found = try? await workReader.items(forMoments: [id])
        if let item = found?[id] ?? work?.momentItems[id] {
            cardItemId = item
        } else {
            cardItemId = await sessionItem(of: card, workReader: workReader)
        }
    }

    /// How many of the card's session's moments are asked about when its
    /// newest moment belongs to no item.
    static let sessionMomentsAsked = 120

    /// The Working On item most of the card's session belongs to, when its
    /// newest moment belongs to none: a session that ends on a chat with
    /// people (never part of an item) is still the project's, so the card
    /// keeps its Resume and "Part of" (SPEC 3.1, SPEC-DELTA 3). The item
    /// with the most of the session's moments; a tie goes to the newer.
    private func sessionItem(of card: RightNowCard, workReader: any WorkReader) async -> String? {
        guard let reader, card.copyRange.lowerBound >= 0 else { return nil }
        let options = SearchOptions(text: "", limit: Self.sessionMomentsAsked,
                                    timeFromUs: UInt64(card.copyRange.lowerBound),
                                    timeToUs: UInt64(card.copyRange.upperBound), browse: true)
        guard let moments = try? await reader.search(options), !moments.isEmpty else { return nil }
        let ids = moments.sorted { $0.tsUs == $1.tsUs ? $0.id > $1.id : $0.tsUs > $1.tsUs }.map(\.id)
        guard let found = try? await workReader.items(forMoments: ids), !found.isEmpty else { return nil }
        var counts: [String: (moments: Int, newest: Int)] = [:]
        for (index, id) in ids.enumerated() {
            guard let item = found[id] else { continue }
            let seen = counts[item] ?? (0, index)
            counts[item] = (seen.moments + 1, seen.newest)
        }
        return counts.max { a, b in
            a.value.moments == b.value.moments ? a.value.newest > b.value.newest : a.value.moments < b.value.moments
        }?.key
    }

    private func memoryWasDeleted() {
        cardMoment = nil
        newestMoment = nil
        earlierDay = nil
        cardItemId = nil
    }

    // MARK: Sessions

    /// The day's sessions, oldest first.
    public var blocks: [DayBlock] {
        overview?.blocks ?? []
    }

    /// The session whose detail shows: the one picked, found again by its
    /// time after every read (its id can change, RULINGS I2), else the day's
    /// last session; on today, with the card on that session, the one before.
    public var selectedBlock: DayBlock? {
        switch selection {
        case .latest:
            return latestBlock
        case let .session(range):
            return SessionMatch.best(for: range, in: blocks) ?? latestBlock
        }
    }

    private var latestBlock: DayBlock? {
        guard let last = blocks.last else { return nil }
        if blocks.count >= 2, let card = rightNow, card.blockId == last.id || card.block?.id == last.id {
            return blocks[blocks.count - 2]
        }
        return last
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
    /// session row on About You).
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

    /// A session's title: a call's or meeting's is its calendar event's.
    public func title(of block: DayBlock) -> String {
        TodayCalendar.title(of: block, events: events)
    }

    // MARK: Legend and facts

    /// Pick a kind in the legend, or put it back.
    public func toggleHighlight(_ kind: StripKind) {
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
        guard let kind = highlightedKind,
              blocks.contains(where: { SessionDetail.stripKind(of: $0) == kind })
        else { return false }
        return SessionDetail.stripKind(of: block) != kind
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

    /// Today's searches for "Looked up today": at most four, today only,
    /// leaving out the selected session's own (its chips show those).
    public var lookedUpToday: [DaySearch] {
        guard isToday, let overview else { return [] }
        let onCard = Set((selectedBlock?.searches ?? []).map { $0.query.lowercased() })
        var seen = Set<String>()
        return overview.searches.filter { search in
            let key = search.query.lowercased()
            return !onCard.contains(key) && seen.insert(key).inserted
        }.prefix(4).map { $0 }
    }

    /// The day's span on "Your day": its first session's start to its last
    /// session's end, or to now while one is going.
    public var daySpan: ClosedRange<Int64>? {
        guard let first = blocks.first, let last = blocks.last else { return nil }
        let end = max(last.endUs, rightNow.map { $0.copyRange.upperBound } ?? last.endUs)
        return first.startUs...max(first.startUs, end)
    }

    /// The strip's span with today's calendar on it.
    public var stripSpan: DayStrip? {
        guard let overview, let strip = overview.strip else { return nil }
        guard !events.isEmpty else { return strip }
        return TodayCalendar.span(strip: strip, events: events, dayStartUs: overview.dayStartUs,
                                  dayEndUs: overview.dayEndUs, calendar: calendar)
    }

    // MARK: The card

    /// The card at the top of Today (SPEC 3.1): Now, or where you left off
    /// today, or on the last day with anything when today has nothing yet.
    public var rightNow: RightNowCard? {
        guard isToday, let overview else { return nil }
        if let card = RightNowCard(overview: overview, receipt: captureHealth, now: now()) { return card }
        guard let earlierDay, overview.blocks.isEmpty else { return nil }
        return RightNowCard(leftOffFrom: earlierDay, now: now())
    }

    /// The card's title: a call's or meeting's is its calendar event's.
    public var cardTitle: String? {
        guard let card = rightNow else { return nil }
        if let block = card.block, !card.isFromEarlierDay(timeZone: calendar.timeZone) {
            return TodayCalendar.title(of: block, events: events)
        }
        return card.title
    }

    /// The selected session is the one the card shows, so its detail leaves
    /// out the card's buttons rather than repeat them.
    public var selectedIsRightNow: Bool {
        guard let id = rightNow?.blockId, let selected = selectedBlock else { return false }
        return selected.id == id
    }

    /// The Working On item the card's session is part of, when Working On
    /// lists it.
    public var cardItem: WorkItem? {
        guard let cardItemId else { return nil }
        return work?.items.first { $0.id == cardItemId }
    }

    /// "Part of trailhead-shop ›" shows only when the item goes by another
    /// name than the card already says.
    public var showsPartOf: Bool {
        guard let item = cardItem else { return false }
        let said = [cardTitle ?? "", cardMoment?.caption ?? ""].joined(separator: "\n")
        return !said.localizedCaseInsensitiveContains(item.name)
    }

    /// Today with nothing saved and no AI tool connected: the empty day
    /// offers "Connect", since there is no card to carry it.
    public var offersConnectOnEmptyDay: Bool {
        guard isToday, let overview, overview.blocks.isEmpty, rightNow == nil else { return false }
        return !overview.aiKnows.hookInstalled
    }

    // MARK: Also from yesterday

    /// Working On items from the last day of use that haven't been opened
    /// today, while today holds under 30 minutes of work (SPEC 3.1): at most
    /// three, newest first, never the card's own item.
    public func alsoFrom(locale: Locale = .autoupdatingCurrent) -> (day: String, items: [WorkItem])? {
        guard isToday, let work, !work.items.isEmpty else { return nil }
        let todayMinutes = blocks.reduce(Int64(0)) { $0 + max(0, $1.endUs - $1.startUs) } / 60_000_000
        guard todayMinutes < 30 else { return nil }
        let start = UInt64(max(0, calendar.startOfDay(for: now()).timeIntervalSince1970 * 1_000_000))
        let before = work.items.filter { $0.lastUs < start && $0.inSidebar && $0.id != cardItemId }
        guard let newest = before.map(\.lastUs).max() else { return nil }
        let lastDay = MemoryDay(date: Date(timeIntervalSince1970: Double(newest) / 1_000_000), calendar: calendar)
        let items = before.filter { lastDay.contains($0.lastUs) }.sorted { $0.lastUs > $1.lastUs }.prefix(3)
        guard !items.isEmpty else { return nil }
        let nowUs = Int64((now().timeIntervalSince1970 * 1_000_000).rounded())
        var word = RightNowCard.day(Int64(newest), from: nowUs, locale: locale, timeZone: calendar.timeZone)
        if word == UserFacingCopy.Overview.yesterday { word = word.lowercased() }
        return (word, Array(items))
    }

    // MARK: The first day

    /// Today is the first day of the person's memory: nothing is saved from
    /// before it. False while that is unknown.
    public var isFirstDay: Bool {
        guard isToday, case let .nothingBefore(day) = earlierMemory else { return false }
        return day == calendar.startOfDay(for: now())
    }

    /// The first day, before its first session: where the person lands after
    /// setup. Today welcomes them, says what comes next, and keeps the
    /// day's place, empty, with now marked (first landing, Oct 18). Any
    /// other empty day stays as it was.
    public var showsFirstDay: Bool {
        guard isFirstDay, let overview, overview.blocks.isEmpty,
              RightNowCard(overview: overview, receipt: captureHealth, now: now()) == nil
        else { return false }
        return true
    }

    /// Whether Hippocampus is remembering, by the rule of the sidebar's
    /// footer, so the welcome and the footer never disagree.
    public var isRemembering: Bool {
        SidebarStatus(receipt: captureHealth, now: now()).remembering
    }

    /// The first day's strip: the hours around now, with now marked.
    public var firstDayStrip: FirstDayStripLayout? {
        FirstDayStripLayout(now: now(), calendar: calendar)
    }

    /// The first-day card offers the calendar once (SPEC-DELTA 5): while it
    /// has never been offered and taken or put aside, and macOS hasn't been
    /// asked.
    public var showsCalendarOffer: Bool {
        showsFirstDay && calendarReader != nil && calendarAccess == .notAsked && !calendarOfferDone
    }

    /// The offer was taken or put aside: it isn't made again.
    public func calendarOffered() {
        offers.set(Data([1]), forKey: Self.calendarOfferKey)
        calendarOfferDone = true
    }
}

public extension BrainReader {
    /// Whether any moment is saved from before `date`, for Today's first
    /// day: the newest such moment, one at most, found through the time
    /// index. Only whether there is one is kept. Privacy markers are not
    /// moments, and browsing never returns them.
    func isAnythingSaved(before date: Date) async throws -> Bool {
        try await newestMoment(before: date) != nil
    }

    /// The newest moment saved before `date`, one at most, through the time
    /// index: Today's morning card starts from its day.
    func newestMoment(before date: Date) async throws -> Hit? {
        let start = (date.timeIntervalSince1970 * 1_000_000).rounded()
        guard start > 0 else { return nil }
        let hits = try await search(SearchOptions(text: "", limit: 1, timeToUs: UInt64(start) - 1, browse: true))
        return hits.first
    }
}

/// A store that keeps nothing past the window: the synthetic preview, the
/// renders and tests, which never write the person's own preferences.
public final class EphemeralKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func data(forKey key: String) -> Data? {
        lock.withLock { values[key] }
    }

    public func set(_ data: Data?, forKey key: String) {
        lock.withLock { values[key] = data }
    }

    public func removeObject(forKey key: String) {
        lock.withLock { values[key] = nil }
    }
}
