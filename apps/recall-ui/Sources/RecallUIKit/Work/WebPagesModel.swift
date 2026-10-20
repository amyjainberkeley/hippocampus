import Foundation

/// Apple Notes' date sections, which Web Pages and Looked Up share (SPEC
/// 3.5): Today, Yesterday, Previous 7 Days, Previous 30 Days, then each
/// month by name, and the year for one from another year.
public enum DateSections {
    public static func title(for us: UInt64, now: Date, calendar: Calendar) -> String {
        let date = Date(timeIntervalSince1970: Double(us) / 1_000_000)
        if calendar.isDate(date, inSameDayAs: now) { return WorkCopy.today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return WorkCopy.yesterday
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return WorkCopy.previous7Days }
        if days < 30 { return WorkCopy.previous30Days }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMM" : "MMMM yyyy")
        return formatter.string(from: date)
    }

    /// Rows under their sections, in order: newest first throughout.
    public static func group<Row>(_ rows: [Row], time: (Row) -> UInt64, now: Date,
                                  calendar: Calendar) -> [(title: String, rows: [Row])] {
        var sections: [(title: String, rows: [Row])] = []
        for row in rows {
            let title = Self.title(for: time(row), now: now, calendar: calendar)
            if sections.last?.title == title {
                sections[sections.count - 1].rows.append(row)
            } else {
                sections.append((title, [row]))
            }
        }
        return sections
    }
}

/// One row of Web Pages: one page across days.
public struct WebPageRow: Identifiable, Equatable, Sendable {
    /// Its address, or its browser and title when there is none.
    public let id: String
    public let page: WorkPage
    /// Its newest moment, read through the FFI: the row's text and picture.
    public var newest: Hit?

    /// When it was last read: its newest moment's own time.
    public var lastUs: UInt64 { newest?.tsUs ?? page.lastUs }
}

/// Web Pages (SPEC 3.5): pages read in a browser, one row per page across
/// days, newest first, under date sections, with a browser filter. A lens
/// over History: each row is its newest moment, and its detail History's.
/// From the work read's pages; when the agent can't answer, from the last
/// seven days of moments with an address, grouped here by address.
@MainActor
public final class WebPagesModel: ObservableObject {
    /// How many of a page's newest moments Ask is given.
    public static let askMoments = 5

    public enum State: Equatable, Sendable {
        case loading
        case loaded
        case failed
    }

    @Published public private(set) var state: State = .loading
    @Published public private(set) var rows: [WebPageRow] = []
    /// The browser shown, by bundle id; nil shows all.
    @Published public var browser: String?
    @Published public var selectedId: String?
    /// The selected page's moments, newest first, for "Read on 3 days".
    @Published public private(set) var selectedMoments: [Hit] = []
    /// The rows came from moments, not the work read.
    @Published public private(set) var usesFallback = false

    private let work: any WorkReader
    private let reader: any BrainReader
    public let calendar: Calendar
    private let now: @Sendable () -> Date

    /// How many rows read their newest moment at once.
    static let firstRows = 300

    public init(work: any WorkReader, reader: any BrainReader, calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.work = work
        self.reader = reader
        self.calendar = calendar
        self.now = now
    }

    public func reload() async {
        do {
            let pages = try await work.work(days: 90).pages
            usesFallback = false
            rows = try await Self.withNewest(pages.map { WebPageRow(id: Self.key(of: $0), page: $0) },
                                             reader: reader)
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            await loadFallback()
        }
        if let selectedId, !rows.contains(where: { $0.id == selectedId }) {
            self.selectedId = nil
        }
    }

    /// Without the work read: the last seven days of moments with an
    /// address, grouped by address.
    private func loadFallback() async {
        let from = now().addingTimeInterval(-7 * 86_400)
        let options = SearchOptions(text: "", limit: 1_000,
                                    timeFromUs: UInt64(max(0, from.timeIntervalSince1970 * 1_000_000)),
                                    browse: true, hasUrl: true)
        do {
            let hits = try await reader.search(options)
            usesFallback = true
            rows = Self.pages(from: hits, calendar: calendar)
            state = .loaded
        } catch {
            if rows.isEmpty { state = .failed }
        }
    }

    /// Pages from moments with an address, newest first: one per address,
    /// never its query or fragment. Search result pages are left out.
    public static func pages(from hits: [Hit], calendar: Calendar) -> [WebPageRow] {
        var rows: [String: WebPageRow] = [:]
        var order: [String] = []
        var days: [String: Set<String>] = [:]
        var moments: [String: [UInt64]] = [:]
        for hit in hits.sorted(by: { $0.tsUs > $1.tsUs }) {
            guard let url = hit.url, let address = Self.address(url), !Self.isSearch(url),
                  let app = hit.appBundleId else { continue }
            let key = address.host + address.path
            let day = MemoryDay(date: Date(timeIntervalSince1970: Double(hit.tsUs) / 1_000_000), calendar: calendar)
            days[key, default: []].insert(day.dateLocal)
            moments[key, default: []].append(hit.id)
            if rows[key] == nil {
                order.append(key)
                let title = hit.windowTitle.map(Formatters.titleWithoutMarks) ?? address.host
                rows[key] = WebPageRow(id: key, page: WorkPage(title: title, host: address.host, path: address.path,
                                                               app: app, lastUs: hit.tsUs, moments: []),
                                       newest: hit)
            }
        }
        return order.compactMap { key in
            guard let row = rows[key] else { return nil }
            let page = row.page
            return WebPageRow(id: key, page: WorkPage(title: page.title, host: page.host, path: page.path,
                                                      app: page.app, days: days[key]?.count ?? 1, lastUs: page.lastUs,
                                                      moments: moments[key] ?? []),
                              newest: row.newest)
        }
    }

    /// An address's host (lower case, without "www.") and path ("/" when
    /// none, no closing slash).
    static func address(_ url: String) -> (host: String, path: String)? {
        guard let components = URLComponents(string: url), ["http", "https"].contains(components.scheme ?? ""),
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = components.path.isEmpty ? "/" : components.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return (host, path)
    }

    static func isSearch(_ url: String) -> Bool {
        guard let components = URLComponents(string: url), let host = components.host?.lowercased() else { return false }
        let path = components.path
        return (host.contains("google.") && path.hasPrefix("/search")) || (host.hasSuffix("bing.com") && path.hasPrefix("/search"))
            || host.hasSuffix("duckduckgo.com") || host.hasSuffix("search.brave.com")
            || (host.hasSuffix("kagi.com") && path.hasPrefix("/search"))
            || (host.hasSuffix("youtube.com") && path.hasPrefix("/results"))
    }

    static func key(of page: WorkPage) -> String {
        page.address ?? "\(page.app)|\(page.title.lowercased())"
    }

    /// Each row with its newest moment, for the first rows.
    static func withNewest(_ rows: [WebPageRow], reader: any BrainReader) async throws -> [WebPageRow] {
        let wanted = rows.prefix(firstRows).compactMap(\.page.moments.first)
        let hits = try await WorkingOnItemModel.fetch(wanted, reader: reader)
        let byId = Dictionary(hits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.map { row in
            var row = row
            row.newest = row.page.moments.first.flatMap { byId[$0] }
            return row
        }
    }

    // MARK: What the page shows

    /// The browsers in the list, in the order their pages come.
    public var browsers: [String] {
        var seen: [String] = []
        for row in rows where !seen.contains(row.page.app) {
            seen.append(row.page.app)
        }
        return seen
    }

    /// The rows the filter shows.
    public var shownRows: [WebPageRow] {
        guard let browser else { return rows }
        return rows.filter { $0.page.app == browser }
    }

    public var sections: [(title: String, rows: [WebPageRow])] {
        DateSections.group(shownRows, time: \.lastUs, now: now(), calendar: calendar)
    }

    /// Whether no page has an address: the line about browsers you allowed
    /// shows, once, under the header.
    public var hasNoAddresses: Bool {
        !rows.isEmpty && rows.allSatisfy { $0.page.host == nil }
    }

    public var selected: WebPageRow? { rows.first { $0.id == selectedId } }

    /// Read the selected page's moments for its "Read on" line.
    public func select(_ id: String?) async {
        selectedId = id
        selectedMoments = []
        guard let row = selected else { return }
        let hits = (try? await WorkingOnItemModel.fetch(Array(row.page.moments.prefix(12)), reader: reader)) ?? []
        guard selectedId == id else { return }
        selectedMoments = hits
    }

    /// "Read on 3 days:" or "Read 2 times today:", and the moments it
    /// names, one per day, newest first. Nil when it was read once.
    public func readOn(_ row: WebPageRow) -> (lead: String, moments: [Hit])? {
        let moments = row.id == selectedId ? selectedMoments : []
        guard moments.count >= 2 else { return nil }
        var byDay: [String: Hit] = [:]
        var order: [String] = []
        for hit in moments {
            let day = MemoryDay(date: Date(timeIntervalSince1970: Double(hit.tsUs) / 1_000_000), calendar: calendar).dateLocal
            if byDay[day] == nil {
                order.append(day)
                byDay[day] = hit
            }
        }
        if order.count > 1 {
            return (WorkCopy.readOnDays(max(order.count, row.page.days)), order.compactMap { byDay[$0] })
        }
        let date = Date(timeIntervalSince1970: Double(moments[0].tsUs) / 1_000_000)
        let when: String
        if calendar.isDate(date, inSameDayAs: now()) {
            when = WorkCopy.today.lowercased()
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now()),
                  calendar.isDate(date, inSameDayAs: yesterday) {
            when = WorkCopy.yesterday.lowercased()
        } else {
            when = "on " + WorkFormat.whenShort(us: moments[0].tsUs, now: now(), calendar: calendar)
        }
        // Each moment one window: repeats of the same visit count once.
        let visits = Self.visits(moments)
        guard visits.count >= 2 else { return nil }
        return (WorkCopy.readTimes(visits.count, when), visits)
    }

    /// Moments as visits: one per run more than five minutes apart.
    static func visits(_ moments: [Hit]) -> [Hit] {
        var visits: [Hit] = []
        for hit in moments.sorted(by: { $0.tsUs > $1.tsUs }) {
            if let last = visits.last, last.tsUs - hit.tsUs < 5 * 60 * 1_000_000 { continue }
            visits.append(hit)
        }
        return visits
    }

    /// The row's second line: "Chrome · devnotes.example · on 3 days".
    public static func origin(_ row: WebPageRow) -> (place: String, days: String?) {
        let place = [Formatters.appDisplayName(row.page.app), row.page.host].compactMap { $0 }
            .joined(separator: " \u{00B7} ")
        return (place, row.page.days > 1 ? WorkCopy.onDays(row.page.days) : nil)
    }

    /// The page's address as a link opens it: host and path, never the
    /// query or fragment, which can carry sign-in tokens.
    public static func link(_ row: WebPageRow) -> URL? {
        guard let host = row.page.host else { return nil }
        let scheme = row.newest?.url.flatMap { URLComponents(string: $0)?.scheme } ?? "https"
        return URL(string: "\(scheme)://\(host)\(row.page.path ?? "")")
    }
}
