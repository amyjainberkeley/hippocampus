import Foundation

/// One day of an item's History, for the day buttons over its rows.
public struct ItemDay: Identifiable, Equatable, Sendable {
    /// `YYYY-MM-DD`.
    public let id: String
    /// "Today", "Yesterday", "Fri", "Oct 2".
    public let label: String
    public let startUs: UInt64
}

/// A row of Seen alongside or Conversations, with its moment when it could
/// be read: its time is the moment's own.
public struct NearRow: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case page, search, aiChat = "ai_chat", conversation
    }

    public let kind: Kind
    /// A page's or a chat's title, a search's query, a conversation's name.
    public let title: String
    /// "devnotes.example · Chrome · 2:35 PM", "Google · 11:18 AM".
    public let detail: String
    public let moment: UInt64

    public var id: String { "\(kind.rawValue)-\(moment)-\(title)" }
}

/// A Working On page (SPEC 3.2, SPEC-DELTA 3 and 4): everything about one
/// project or document. Where you left off and its screenshot; its files;
/// pages, searches and AI chats seen alongside; conversations by name; the
/// meetings that overlapped its sessions; and its own History by day,
/// History's rows read through the FFI by the item's moment ids, 200 at a
/// time.
@MainActor
public final class WorkingOnItemModel: ObservableObject {
    public enum State: Equatable, Sendable {
        case loading
        case loaded
        /// Everything forgotten or past retention: "Nothing left from …".
        case gone
        /// The agent didn't answer: "Couldn't load this. Nothing is lost."
        case failed
    }

    @Published public private(set) var state: State = .loading
    @Published public private(set) var item: WorkItem?
    /// The item's moments read so far, newest first.
    @Published public private(set) var hits: [Hit] = []
    @Published public private(set) var canLoadEarlier = false
    @Published public private(set) var isLoadingEarlier = false
    /// The day whose History shows; nil shows the newest day.
    @Published public var selectedDay: String?
    @Published public private(set) var alongside: [NearRow] = []
    @Published public private(set) var conversations: [NearRow] = []
    @Published public private(set) var meetings: [CalendarEvent] = []
    /// The moments Seen alongside and Conversations name, by id, for their
    /// detail.
    @Published public private(set) var nearHits: [UInt64: Hit] = [:]
    /// Files past the first six show after "And N More".
    @Published public var showsAllFiles = false

    public let itemId: String
    private let work: any WorkReader
    private let reader: any BrainReader
    private let calendarReader: (any CalendarReader)?
    public let calendar: Calendar
    private let now: @Sendable () -> Date

    /// Files shown before "And N More".
    public static let filesShown = 6

    public init(itemId: String, work: any WorkReader, reader: any BrainReader,
                calendarReader: (any CalendarReader)? = nil, calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.itemId = itemId
        self.work = work
        self.reader = reader
        self.calendarReader = calendarReader
        self.calendar = calendar
        self.now = now
    }

    /// Read the item and its newest moments.
    public func reload() async {
        do {
            guard let item = try await work.item(id: itemId, before: nil) else {
                self.item = nil
                hits = []
                state = .gone
                return
            }
            let hits = try await Self.fetch(item.moments, reader: reader)
            self.item = item
            self.hits = hits
            canLoadEarlier = item.moments.count >= 200
            if let selected = selectedDay, !days.contains(where: { $0.id == selected }) {
                selectedDay = nil
            }
            state = hits.isEmpty && item.moments.isEmpty ? .gone : .loaded
            await readAround(item)
        } catch is CancellationError {
            return
        } catch {
            if item == nil { state = .failed }
        }
    }

    /// The next 200 moments, older than the oldest read.
    public func loadEarlier() async {
        guard canLoadEarlier, !isLoadingEarlier, let oldest = hits.last else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        do {
            guard let older = try await work.item(id: itemId, before: oldest.tsUs) else {
                canLoadEarlier = false
                return
            }
            let more = try await Self.fetch(older.moments, reader: reader)
            let known = Set(hits.map(\.id))
            hits += more.filter { !known.contains($0.id) }
            canLoadEarlier = older.moments.count >= 200
        } catch {
            canLoadEarlier = false
        }
    }

    /// Moments by id, newest first, 32 at a time (the FFI's bound).
    public static func fetch(_ ids: [UInt64], reader: any BrainReader) async throws -> [Hit] {
        var hits: [Hit] = []
        var start = 0
        while start < ids.count {
            let batch = Array(ids[start..<min(ids.count, start + 32)])
            hits += try await reader.fetchEventsByIds(batch)
            start += 32
        }
        return hits.sorted { $0.tsUs == $1.tsUs ? $0.id > $1.id : $0.tsUs > $1.tsUs }
    }

    /// Seen alongside and conversations with their moments' own times, and
    /// the meetings that overlapped its sessions, when the calendar is on.
    private func readAround(_ item: WorkItem) async {
        let ids = item.alongside.map(\.moment) + item.conversations.map(\.moment)
        let moments = (try? await Self.fetch(ids, reader: reader)) ?? []
        let byId = Dictionary(moments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        nearHits = byId
        alongside = item.alongside.map { near in
            let kind = NearRow.Kind(rawValue: near.kind) ?? .page
            let time = byId[near.moment]?.tsUs ?? near.lastUs
            let when = WorkFormat.whenShort(us: time, now: now(), calendar: calendar)
            let detail: String
            switch kind {
            case .search:
                detail = [near.host.flatMap(WorkFormat.engineName(host:)) ?? Formatters.appDisplayName(near.app),
                          when].joined(separator: " \u{00B7} ")
            case .aiChat:
                detail = [near.host.flatMap(WorkFormat.aiName(host:)) ?? Formatters.appDisplayName(near.app), when]
                    .joined(separator: " \u{00B7} ")
            default:
                detail = [near.host, Formatters.appDisplayName(near.app), when].compactMap { $0 }
                    .joined(separator: " \u{00B7} ")
            }
            let title = kind == .search ? "\u{201C}\(near.title)\u{201D}" : near.title
            return NearRow(kind: kind, title: title, detail: detail, moment: near.moment)
        }
        conversations = item.conversations.map { conversation in
            let time = byId[conversation.moment]?.tsUs ?? conversation.lastUs
            return NearRow(kind: .conversation, title: conversation.name,
                           detail: [Formatters.appDisplayName(conversation.app),
                                    WorkFormat.whenShort(us: time, now: now(), calendar: calendar)]
                               .joined(separator: " \u{00B7} "),
                           moment: conversation.moment)
        }
        meetings = await Self.meetings(for: item, calendar: calendarReader)
    }

    /// The meetings that overlapped the item's sessions, newest first, at
    /// most six: only their titles and times, from this Mac's calendar,
    /// when the person turned it on (SPEC-DELTA 5).
    static func meetings(for item: WorkItem, calendar: (any CalendarReader)?) async -> [CalendarEvent] {
        guard let calendar, await calendar.access() == .allowed, !item.sessions.isEmpty else { return [] }
        var found: [String: CalendarEvent] = [:]
        for session in item.sessions.prefix(60) {
            let start = Date(timeIntervalSince1970: Double(session.startUs) / 1_000_000)
            let end = Date(timeIntervalSince1970: Double(max(session.endUs, session.startUs + 1)) / 1_000_000)
            guard let events = try? await calendar.events(in: DateInterval(start: start, end: end)) else { continue }
            for event in events { found[event.id] = event }
        }
        return Array(found.values.sorted { $0.start > $1.start }.prefix(6))
    }

    // MARK: What the page shows

    /// The newest moment: where you left off.
    public var whereYouLeftOff: Hit? { hits.first }

    /// The screenshot "Where you left off" shows: the newest moment's own,
    /// else the newest of the same app's, else any.
    public var leftOffScreenshot: Hit? {
        guard let newest = hits.first else { return nil }
        if newest.thumbnailURL != nil { return newest }
        return hits.first { $0.thumbnailURL != nil && $0.appBundleId == newest.appBundleId }
            ?? hits.first { $0.thumbnailURL != nil }
    }

    /// The days the item's moments read so far fall on, newest first.
    public var days: [ItemDay] {
        var seen: [String: ItemDay] = [:]
        var order: [String] = []
        let today = now()
        for hit in hits {
            let date = Date(timeIntervalSince1970: Double(hit.tsUs) / 1_000_000)
            let day = MemoryDay(date: date, calendar: calendar)
            if seen[day.dateLocal] == nil {
                order.append(day.dateLocal)
                seen[day.dateLocal] = ItemDay(id: day.dateLocal, label: Self.dayLabel(date, now: today, calendar: calendar),
                                              startUs: day.startUs)
            }
        }
        return order.compactMap { seen[$0] }
    }

    /// The day the History shows.
    public var shownDay: ItemDay? {
        let all = days
        return all.first { $0.id == selectedDay } ?? all.first
    }

    /// History's rows for the day shown, newest first.
    public var dayHits: [Hit] {
        guard let day = shownDay else { return [] }
        let memoryDay = MemoryDay(date: Date(timeIntervalSince1970: Double(day.startUs) / 1_000_000),
                                  calendar: calendar)
        return hits.filter { memoryDay.contains($0.tsUs) }
    }

    /// The files shown: six, or all after "And N More".
    public var shownFiles: [WorkFile] {
        guard let files = item?.files else { return [] }
        return showsAllFiles ? files : Array(files.prefix(Self.filesShown))
    }

    /// How many files "And N More" holds.
    public var moreFiles: Int {
        showsAllFiles ? 0 : max(0, (item?.files.count ?? 0) - Self.filesShown)
    }

    /// "Today", "Yesterday", "Fri", "Oct 2": a day button's word.
    public nonisolated static func dayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return WorkCopy.today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return WorkCopy.yesterday
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        formatter.setLocalizedDateFormatFromTemplate(days < 7 ? "EEE" : "MMM d")
        return formatter.string(from: date)
    }
}

public extension WorkFormat {
    /// A search engine's name by its host: "Google", "DuckDuckGo".
    static func engineName(host: String) -> String? {
        let host = host.lowercased()
        let table: [(String, String)] = [
            ("google.", "Google"), ("bing.com", "Bing"), ("duckduckgo.com", "DuckDuckGo"),
            ("search.brave.com", "Brave Search"), ("kagi.com", "Kagi"), ("ecosia.org", "Ecosia"),
            ("search.yahoo.com", "Yahoo"), ("perplexity.ai", "Perplexity"), ("youtube.com", "YouTube"),
            ("github.com", "GitHub"), ("stackoverflow.com", "Stack Overflow"), ("wikipedia.org", "Wikipedia"),
        ]
        return table.first { host.hasPrefix($0.0) || host.contains("." + $0.0) || host.hasSuffix($0.0) }?.1
    }

    /// An AI tool's name by its host: "Claude", "ChatGPT".
    static func aiName(host: String) -> String? {
        switch host.lowercased() {
        case "claude.ai": "Claude"
        case "chatgpt.com", "chat.openai.com": "ChatGPT"
        case "gemini.google.com": "Gemini"
        case "perplexity.ai", "www.perplexity.ai": "Perplexity"
        default: nil
        }
    }

    /// A search engine's name by the agent's short name: "google" is
    /// Google, "stackoverflow" Stack Overflow.
    static func engineName(id: String) -> String {
        let names: [String: String] = [
            "google": "Google", "google_maps": "Google Maps", "google_scholar": "Google Scholar", "bing": "Bing",
            "duckduckgo": "DuckDuckGo", "brave": "Brave Search", "kagi": "Kagi", "ecosia": "Ecosia",
            "yahoo": "Yahoo", "perplexity": "Perplexity", "chatgpt": "ChatGPT", "claude": "Claude",
            "youtube": "YouTube", "github": "GitHub", "stackoverflow": "Stack Overflow", "wikipedia": "Wikipedia",
            "amazon": "Amazon", "reddit": "Reddit", "x": "X", "linkedin": "LinkedIn", "arxiv": "arXiv",
            "npm": "npm", "crates": "crates.io", "apple_developer": "Apple Developer", "mdn": "MDN",
        ]
        if let name = names[id] { return name }
        return id.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
