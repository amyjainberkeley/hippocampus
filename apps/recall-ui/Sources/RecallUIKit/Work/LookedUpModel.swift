import Foundation

/// One row of Looked Up: a search, and how many times that day.
public struct LookedUpRow: Identifiable, Equatable, Sendable {
    /// Its day, engine and query.
    public let id: String
    /// The newest time it was searched that day.
    public let record: SearchRecord
    /// How many times it was searched that day.
    public let times: Int
    /// The moments of every time it was searched that day, newest first:
    /// what Forget This Search forgets and what Ask is given.
    public let eventIds: [UInt64]
    /// The results page's moment, read through the FFI.
    public var page: Hit?

    public init(id: String, record: SearchRecord, times: Int, eventIds: [UInt64]? = nil, page: Hit? = nil) {
        self.id = id
        self.record = record
        self.times = times
        self.eventIds = eventIds ?? [record.eventId]
        self.page = page
    }

    /// "Google", "YouTube".
    public var engine: String { WorkFormat.engineName(id: record.engine) }
    /// "Google · Chrome".
    public var origin: String {
        [engine, record.app].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}

/// Looked Up (SPEC 3.6): searches made on the sites the agent reads, newest
/// first, by day; the same query on one day is one row, "searched 3 times".
/// A lens over History: each row is its results page's moment, and its
/// detail lists the pages opened next in the same browser.
@MainActor
public final class LookedUpModel: ObservableObject {
    public enum State: Equatable, Sendable {
        case loading
        case loaded
        case failed
    }

    @Published public private(set) var state: State = .loading
    @Published public private(set) var rows: [LookedUpRow] = []
    @Published public var selectedId: String?
    /// The selected search's pages opened next, at most five.
    @Published public private(set) var openedNext: [Hit] = []

    private let searches: any SearchesReading
    private let reader: any BrainReader
    public let calendar: Calendar
    private let now: @Sendable () -> Date

    /// 31 days, at most 500: what the agent keeps answering for.
    public static let hours = 744
    public static let limit = 500
    /// What counts as opened next: five minutes after, five pages at most.
    static let nextWindowUs: UInt64 = 5 * 60 * 1_000_000
    static let nextLimit = 5

    public init(searches: any SearchesReading, reader: any BrainReader, calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.searches = searches
        self.reader = reader
        self.calendar = calendar
        self.now = now
    }

    public func reload() async {
        do {
            let records = try await searches.searches(hours: Self.hours, limit: Self.limit)
            var rows = Self.rows(from: records, calendar: calendar)
            let pages = try await WorkingOnItemModel.fetch(rows.prefix(300).map(\.record.eventId), reader: reader)
            let byId = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for index in rows.indices {
                rows[index].page = byId[rows[index].record.eventId]
            }
            self.rows = rows
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            if rows.isEmpty { state = .failed }
        }
        if let selectedId, !rows.contains(where: { $0.id == selectedId }) {
            self.selectedId = nil
        }
    }

    /// Searches as rows: one per query, engine and day, newest first.
    public static func rows(from records: [SearchRecord], calendar: Calendar) -> [LookedUpRow] {
        var rows: [String: (record: SearchRecord, times: Int, ids: [UInt64])] = [:]
        var order: [String] = []
        for record in records.sorted(by: { $0.tsUs > $1.tsUs }) {
            let day = MemoryDay(date: Date(timeIntervalSince1970: Double(record.tsUs) / 1_000_000),
                                calendar: calendar).dateLocal
            let key = "\(day)|\(record.engine)|\(record.query.lowercased())"
            if let existing = rows[key] {
                let ids = existing.ids.contains(record.eventId) ? existing.ids : existing.ids + [record.eventId]
                rows[key] = (existing.record, existing.times + 1, ids)
            } else {
                order.append(key)
                rows[key] = (record, 1, [record.eventId])
            }
        }
        return order.compactMap { key in
            rows[key].map { LookedUpRow(id: key, record: $0.record, times: $0.times, eventIds: $0.ids) }
        }
    }

    public var sections: [(title: String, rows: [LookedUpRow])] {
        DateSections.group(rows, time: \.record.tsUs, now: now(), calendar: calendar)
    }

    public var selected: LookedUpRow? { rows.first { $0.id == selectedId } }

    /// Select a search and read what was opened next.
    public func select(_ id: String?) async {
        selectedId = id
        openedNext = []
        guard let row = selected else { return }
        let next = await Self.openedNext(after: row, reader: reader)
        guard selectedId == id else { return }
        openedNext = next
    }

    /// Up to five pages opened in the same browser in the five minutes after
    /// the search: never another results page, each page once.
    static func openedNext(after row: LookedUpRow, reader: any BrainReader) async -> [Hit] {
        let start = row.record.tsUs + 1
        let options = SearchOptions(text: "", limit: 60, appFilter: row.page?.appBundleId,
                                    timeFromUs: start, timeToUs: start + nextWindowUs, browse: true)
        guard let hits = try? await reader.search(options) else { return [] }
        var seen = Set<String>()
        var out: [Hit] = []
        for hit in hits.sorted(by: { $0.tsUs < $1.tsUs }) {
            guard hit.id != row.record.eventId, hit.url != nil,
                  !(hit.url.map(WebPagesModel.isSearch) ?? false) else { continue }
            if let app = row.page?.appBundleId, hit.appBundleId != app { continue }
            let title = Formatters.titleWithoutMarks(hit.windowTitle ?? "")
            guard !title.isEmpty, seen.insert(title).inserted else { continue }
            out.append(hit)
            if out.count == nextLimit { break }
        }
        return out
    }

    /// "Search Again": the results page's address with only its query, so
    /// nothing else the address carried goes with it.
    public static func searchAgainURL(_ row: LookedUpRow) -> URL? {
        guard let address = row.record.url, var components = URLComponents(string: address),
              ["http", "https"].contains(components.scheme ?? "") else { return nil }
        let names = ["q", "p", "k", "search_query", "search", "query", "keywords"]
        let kept = components.queryItems?.first { names.contains($0.name) }
        components.queryItems = kept.map { [$0] }
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }
}
