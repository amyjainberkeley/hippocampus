import Combine
import Foundation

/// One of History's lenses in Library: Documents, Code or Conversations
/// (SPEC-DELTA 1). History's own moments, newest first across days, kept
/// only when `LibraryLens.includes` says they are of its kind, a page at a
/// time with "Show Earlier" below the last row.
///
/// A lens reads the memory the way History does (a browse, newest first),
/// in two parts so the memory does most of the filtering: the lens's own
/// apps, which the store filters itself, and the browsers, whose moments
/// are kept by their page (`docs.google.com` is a document, `mail.google.com`
/// a conversation). The two are merged by time and cut where the fuller one
/// stopped, so no moment between pages is ever skipped. A browser full of
/// other pages is read on, a few pages at most per click, until rows turn up.
@MainActor
public final class LibraryLensModel: ObservableObject {
    public let lens: LibraryLens
    /// The moments of the lens read so far, newest first.
    @Published public private(set) var hits: [Hit] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    /// More moments may lie below the last row: "Show Earlier".
    @Published public private(set) var canLoadEarlier = false
    @Published public private(set) var isLoadingEarlier = false
    /// The rows picked: one opens its detail, several their summary.
    @Published public var selection: Set<UInt64> = []
    @Published public var isDetailFocused = false
    /// Conversations' chips: All, Chat, Email or AI.
    @Published public var filter: ConversationFilter = .all {
        didSet {
            guard filter != oldValue else { return }
            selection = selection.filter { id in shownHits.contains { $0.id == id } }
        }
    }

    public let pageSize: Int
    private let reader: BrainReader
    /// Reads of the browsers that find nothing of the lens are read on, at
    /// most this many times per page.
    static let maxReadsPerPage = 6
    private var generation = 0
    /// The newest time the next page may hold, and how far down every part
    /// is known.
    private var earlierUpperBound: UInt64?
    private var deletionObserver: AnyCancellable?

    public init(
        lens: LibraryLens,
        reader: BrainReader,
        pageSize: Int = 200,
        deletions: MemoryDeletionSignal = .shared
    ) {
        self.lens = lens
        self.reader = reader
        self.pageSize = max(1, pageSize)
        deletionObserver = deletions.center
            .publisher(for: MemoryDeletionSignal.notification, object: deletions)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.memoryWasDeleted() }
            }
    }

    // MARK: Selection

    /// The moments the chips let through, newest first.
    public var shownHits: [Hit] {
        lens == .conversations && filter != .all ? hits.filter(filter.includes) : hits
    }

    /// The one row picked, when one is: its detail shows.
    public var selectedHitId: UInt64? {
        get { selection.count == 1 ? selection.first : nil }
        set { selection = newValue.map { [$0] } ?? [] }
    }

    public var selectedHit: Hit? {
        guard let id = selectedHitId else { return nil }
        return hits.first { $0.id == id }
    }

    public func focusDetail() {
        if !selection.isEmpty { isDetailFocused = true }
    }

    public func dismissDetail() {
        isDetailFocused = false
    }

    // MARK: Reading

    /// The parts a page is read in: the lens's own apps, then the browsers.
    private var parts: [[String]] {
        [lens.apps, MomentKinds.browsers]
    }

    /// Read from the newest moment again.
    public func reload() async {
        generation += 1
        let request = generation
        isLoading = true
        isLoadingEarlier = false
        errorMessage = nil
        defer { if request == generation { isLoading = false } }
        do {
            let page = try await readPage(below: nil, after: [])
            guard request == generation, !Task.isCancelled else { return }
            hits = page.rows
            canLoadEarlier = page.next != nil
            earlierUpperBound = page.next
            selection = selection.filter { id in page.rows.contains { $0.id == id } }
            if selection.isEmpty { isDetailFocused = false }
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            hits = []
            canLoadEarlier = false
            earlierUpperBound = nil
            errorMessage = "\(error)"
        }
    }

    /// "Show Earlier": the next page, under the last row.
    public func loadEarlier() async {
        guard canLoadEarlier, !isLoading, !isLoadingEarlier, let upper = earlierUpperBound else { return }
        let request = generation
        isLoadingEarlier = true
        defer { if request == generation { isLoadingEarlier = false } }
        do {
            let page = try await readPage(below: upper, after: hits)
            guard request == generation, !Task.isCancelled else { return }
            hits += page.rows
            canLoadEarlier = page.next != nil
            earlierUpperBound = page.next
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            errorMessage = "\(error)"
        }
    }

    /// The window's ten-second tick: newer moments of the lens go on top,
    /// and the pages below stay. More than a page newer reads from the top.
    public func refresh() async {
        guard !isLoading, !isLoadingEarlier else { return }
        guard let top = hits.first else {
            await reload()
            return
        }
        let request = generation
        do {
            guard let newest = try await reader.recentEvents(limit: 1).first,
                  newest.tsUs > top.tsUs || (newest.tsUs == top.tsUs && !hits.contains { $0.id == newest.id })
            else { return }
            var fresh: [Hit] = []
            var complete = true
            let edge = hits.prefix { $0.tsUs == top.tsUs }.count
            for apps in parts {
                let found = try await reader.search(SearchOptions(
                    text: "", limit: pageSize + 1 + edge, timeFromUs: top.tsUs, mode: .text, browse: true,
                    appFilters: apps))
                if found.count > pageSize + edge { complete = false }
                fresh += found
            }
            guard request == generation, !Task.isCancelled else { return }
            guard complete else {
                await reload()
                return
            }
            var seen = Set(hits.map(\.id))
            let rows = fresh
                .filter { $0.tsUs >= top.tsUs && lens.includes($0) && seen.insert($0.id).inserted }
                .sorted(by: Self.newestFirst)
            if !rows.isEmpty { hits = rows + hits }
        } catch {
            return
        }
    }

    /// One page: each part's newest moments at or below `upper`, merged,
    /// cut at the highest time a part stopped at, and kept by the lens.
    /// Everything at or above that time is then read, so the next read goes
    /// on from it, asking past the moments already read there. A page that
    /// keeps too little reads on, a few times at most.
    private func readPage(below upper: UInt64?, after shown: [Hit]) async throws -> (rows: [Hit], next: UInt64?) {
        var rows: [Hit] = []
        var seen = Set(shown.map(\.id))
        var countAt: [UInt64: Int] = [:]
        for hit in shown { countAt[hit.tsUs, default: 0] += 1 }
        var bound = upper
        for _ in 0..<Self.maxReadsPerPage {
            let edge = bound.map { countAt[$0] ?? 0 } ?? 0
            var found: [Hit] = []
            var floor: UInt64?
            for apps in parts {
                let part = try await reader.search(SearchOptions(
                    text: "", limit: pageSize + 1 + edge, timeToUs: bound, mode: .text, browse: true,
                    appFilters: apps))
                    .filter { hit in bound.map { hit.tsUs <= $0 } ?? true }
                if part.count > pageSize + edge, let last = part.last {
                    floor = max(floor ?? 0, last.tsUs)
                }
                found += part
            }
            var kept: [Hit] = []
            for hit in found where floor.map({ hit.tsUs >= $0 }) ?? true {
                guard seen.insert(hit.id).inserted else { continue }
                countAt[hit.tsUs, default: 0] += 1
                if lens.includes(hit) { kept.append(hit) }
            }
            rows += kept.sorted(by: Self.newestFirst)
            guard let floor else { return (rows, nil) }
            bound = floor
            if rows.count >= max(1, pageSize / 4) { return (rows, floor) }
        }
        return (rows, bound)
    }

    private static func newestFirst(_ a: Hit, _ b: Hit) -> Bool {
        a.tsUs == b.tsUs ? a.id > b.id : a.tsUs > b.tsUs
    }

    /// Moments were deleted: none shown may be one of them, so the rows go
    /// at once and are read again.
    private func memoryWasDeleted() {
        generation += 1
        hits = []
        canLoadEarlier = false
        earlierUpperBound = nil
        isLoadingEarlier = false
        Task { [weak self] in await self?.reload() }
    }

    // MARK: Sections

    /// The lens's rows under Apple Notes' day headings, newest first; runs
    /// of one window are one row, as in History.
    public func sections(now: Date, calendar: Calendar) -> [LibrarySection] {
        LibrarySections.group(shownHits, now: now, calendar: calendar)
    }

    // MARK: Whether a lens holds anything

    /// Whether the lens holds any moment, for its row in the sidebar (a
    /// kind's row appears only once it has something). Its own apps are one
    /// read of one moment; the browsers, a few pages at most.
    public static func holdsMoments(_ lens: LibraryLens, reader: BrainReader) async -> Bool {
        if let own = try? await reader.search(SearchOptions(
            text: "", limit: 1, mode: .text, browse: true, appFilters: lens.apps)),
           own.contains(where: lens.includes) {
            return true
        }
        var bound: UInt64?
        for _ in 0..<3 {
            guard let page = try? await reader.search(SearchOptions(
                text: "", limit: 200, timeToUs: bound, mode: .text, browse: true,
                appFilters: MomentKinds.browsers)) else { return false }
            if page.contains(where: lens.includes) { return true }
            guard page.count >= 200, let last = page.last, last.tsUs > 0 else { return false }
            bound = last.tsUs - 1
        }
        return false
    }
}

/// One heading of a lens's list, as Apple Notes heads its days.
public struct LibrarySection: Equatable, Sendable, Identifiable {
    public enum Period: Equatable, Hashable, Sendable {
        case today, yesterday, previous7Days, previous30Days
        /// A month: its first day.
        case month(Date)
    }

    public let period: Period
    /// Newest first; a run of one window is one row.
    public let rows: [HistoryRow]

    public var id: String {
        switch period {
        case .today: "today"
        case .yesterday: "yesterday"
        case .previous7Days: "previous7"
        case .previous30Days: "previous30"
        case let .month(start): "month-\(Int(start.timeIntervalSince1970))"
        }
    }

    /// "Today", "Previous 7 Days", "October", "September 2025".
    public func title(now: Date, calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String {
        switch period {
        case .today: return LibraryCopy.today
        case .yesterday: return LibraryCopy.yesterday
        case .previous7Days: return LibraryCopy.previous7Days
        case .previous30Days: return LibraryCopy.previous30Days
        case let .month(start):
            var calendar = calendar
            calendar.locale = locale
            let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
            var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.wide)
            if !sameYear { style = style.year() }
            return start.formatted(style)
        }
    }
}

/// Groups moments under Apple Notes' day headings: Today, Yesterday,
/// Previous 7 Days, Previous 30 Days, then each month (SPEC 3.5).
public enum LibrarySections {
    public static func group(_ hits: [Hit], now: Date, calendar: Calendar) -> [LibrarySection] {
        var sections: [(period: LibrarySection.Period, runs: [[Hit]])] = []
        for hit in hits {
            let period = Self.period(of: hit, now: now, calendar: calendar)
            if sections.last?.period != period {
                sections.append((period, []))
            }
            let index = sections.count - 1
            if let previous = sections[index].runs.last?.first, HistorySections.sameWindow(previous, hit) {
                sections[index].runs[sections[index].runs.count - 1].append(hit)
            } else {
                sections[index].runs.append([hit])
            }
        }
        return sections.map { LibrarySection(period: $0.period, rows: $0.runs.map(HistoryRow.init(hits:))) }
    }

    static func period(of hit: Hit, now: Date, calendar: Calendar) -> LibrarySection.Period {
        let date = Date(timeIntervalSince1970: Double(hit.tsUs) / 1_000_000)
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch days {
        case ...0: return .today
        case 1: return .yesterday
        case 2...7: return .previous7Days
        case 8...30: return .previous30Days
        default:
            let month = calendar.dateInterval(of: .month, for: date)?.start ?? day
            return .month(month)
        }
    }
}
