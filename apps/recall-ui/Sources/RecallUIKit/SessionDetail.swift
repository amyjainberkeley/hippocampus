import Foundation

/// The selected session on Overview, in the words and the order its detail
/// shows them (contract overview.md sections 7 and 17, RULINGS W4 and W8):
/// title, time and length, kind, apps with their minutes, up to two
/// sentences, what Hippocampus noticed with who wrote it, the screenshot, the
/// searches, then "Show in History", "Copy for your AI" and "Open Page" or
/// "Open {App}". Measured telemetry (keys, activity words) is not in the
/// overview at all, so it cannot reach this.
public struct SessionDetail: Equatable, Sendable {
    public struct AppTime: Equatable, Sendable, Identifiable {
        public let bundleId: String
        public let name: String
        public let duration: String

        public var id: String { bundleId + "\u{1F}" + name }
        /// "Notes 19 min", as Today's cards write an app's time.
        public var label: String { UserFacingCopy.Overview.appMinutes(name, duration) }

        public init(bundleId: String, name: String, duration: String) {
            self.bundleId = bundleId
            self.name = name
            self.duration = duration
        }

        /// A session's apps, longest first, at most three, with their time.
        public static func of(_ apps: [AppShare], locale: Locale = .autoupdatingCurrent) -> [AppTime] {
            apps.prefix(3).compactMap { app in
                let name = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return AppTime(bundleId: app.bundleId, name: name,
                               duration: UserFacingCopy.Overview.minutes(app.heldUs, locale: locale))
            }
        }
    }

    /// Sentence ids that count what the person did ("You switched between
    /// Figma and Notes five times", "You reworded a search twice"). Today
    /// never shows them (RULINGS W4, SPEC 3.1).
    public static let countingSentenceIds: Set<String> = ["switched_between", "reworded_search"]

    /// Whether a sentence counts keys, clicks, scrolls, switches or rewordings.
    public static func counts(_ sentence: String) -> Bool {
        let words = Set(sentence.lowercased().components(separatedBy: CharacterSet.letters.inverted))
        let counting: Set<String> = [
            "switched", "switch", "switches", "switching", "reworded", "reword", "rewording", "keys", "keystrokes",
            "keypresses", "clicks", "clicked", "clicking", "scrolls", "scrolled", "scrolling", "typed",
        ]
        return !words.isDisjoint(with: counting)
    }

    public struct Noticed: Equatable, Sendable {
        public let text: String
        /// "Written on this Mac by Apple Intelligence" (RULINGS I11).
        public let caption: String?
    }

    /// The session's id in this read: provisional for a session with no note
    /// yet, so the window finds a selection again by time (RULINGS I2).
    public let id: Int64
    /// The session's title; a call's or meeting's is its calendar event's.
    public let title: String
    /// "9:05 – 9:34 AM", in the person's format.
    public let time: String
    /// "29 min".
    public let length: String
    public let kind: WorkKind
    /// Its colour and legend word on the strip.
    public let stripKind: StripKind
    /// "Documents", or "Mostly Web Pages, some Documents" when no kind held
    /// half, in the sidebar's words (SPEC 2.14).
    public let kindLine: String
    /// Longest first, at most three.
    public let apps: [AppTime]
    /// Sentences about the session that count nothing the person did. The
    /// agent sends none now; one that counts switches or rewordings is
    /// dropped here too (RULINGS W4).
    public let sentences: [String]
    public let noticed: Noticed?
    /// Queries made during the session, oldest first, each once.
    public let searches: [String]
    public let screenshotEventId: Int64?
    public let reopen: ReopenAction?
    /// What "Copy for your AI" copies: the session's own moments (RULINGS I13).
    public let copyRange: ClosedRange<Int64>
    /// "Show in History": the session's own time, its newest moment selected.
    public let history: RecallRoute

    public init(
        block: DayBlock,
        events: [CalendarEvent] = [],
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        id = block.id
        title = TodayCalendar.title(of: block, events: events)
        time = Self.timeRange(startUs: block.startUs, endUs: block.endUs, locale: locale, timeZone: timeZone)
        length = UserFacingCopy.Overview.minutes(max(0, block.endUs - block.startUs), locale: locale)
        kind = block.kind
        stripKind = Self.stripKind(of: block)
        kindLine = Self.kindLine(block)
        apps = AppTime.of(block.apps, locale: locale)
        sentences = block.sentences
            .filter { !Self.countingSentenceIds.contains($0.id) }
            .map { $0.text.text(locale: locale, timeZone: timeZone) }
            .filter { !Self.counts($0) }
            .prefix(2).map { $0 }
        noticed = block.noticed.flatMap { noticed in
            let text = noticed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Noticed(text: text, caption: UserFacingCopy.writtenOnThisMac(by: noticed.writtenBy))
        }
        var seen = Set<String>()
        searches = block.searches.compactMap { search in
            let query = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, seen.insert(query.lowercased()).inserted else { return nil }
            return query
        }
        screenshotEventId = block.screenshotEventId
        reopen = Self.reopen(for: block)
        copyRange = min(block.startUs, block.endUs)...max(block.startUs, block.endUs)
        history = .history(of: copyRange, selecting: block.openEventId)
    }

    /// A session's kinds in the sidebar's words: its strip kind, or "Mostly
    /// Web Pages, some Documents" when the largest holds under half its time.
    /// The agent's kinds that fold into one word are added together first, so
    /// writing and design never read "Mostly Documents, some Documents".
    public static func kindLine(_ block: DayBlock) -> String {
        let ranked = rankedKinds(block)
        let total = ranked.reduce(0) { $0 + $1.held }
        guard total > 0, ranked.count >= 2, ranked[0].held * 2 < total else {
            return (ranked.first?.kind ?? StripKind(block.kind)).title
        }
        return UserFacingCopy.Overview.mostly(ranked[0].kind.title, some: ranked[1].kind.title)
    }

    /// The strip kind a session is drawn in: the one holding most of its time
    /// once the agent's kinds are folded into the sidebar's words, so its
    /// colour, its legend and its card always agree.
    public static func stripKind(of block: DayBlock) -> StripKind {
        rankedKinds(block).first?.kind ?? StripKind(block.kind)
    }

    /// A session's strip kinds by time held, most first; ties go in the
    /// legend's order.
    static func rankedKinds(_ block: DayBlock) -> [(kind: StripKind, held: Int64)] {
        var held: [StripKind: Int64] = [:]
        for share in block.kinds { held[StripKind(share.kind), default: 0] += max(0, share.heldUs) }
        let order = StripKind.allCases
        return held.map { (kind: $0.key, held: $0.value) }.sorted {
            $0.held == $1.held ? order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! : $0.held > $1.held
        }
    }

    /// "Open Page" or "Open {App}" for a session. The agent names the
    /// session's newest moment, which for a finished session is often a
    /// quick look elsewhere: a session in Notes that ended on Slack would
    /// offer "Open Slack". A finished session opens the app it spent the
    /// most time in, keeping the agent's page when that page is in the same
    /// app. A session still going keeps the newest moment: that is where the
    /// person is.
    public static func reopen(for block: DayBlock) -> ReopenAction? {
        let newest = ReopenAction(block.reopen)
        guard !block.inProgress, let main = block.apps.first else { return newest }
        if let reopen = block.reopen, reopen.bundleId == main.bundleId { return newest }
        return ReopenAction(Reopen(url: nil, bundleId: main.bundleId, appName: main.name)) ?? newest
    }

    /// A span of clock times in the person's format: "9:05 – 9:34 AM".
    public static func timeRange(
        startUs: Int64,
        endUs: Int64,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        formatter.calendar = calendar
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let start = Date(timeIntervalSince1970: Double(startUs) / 1_000_000)
        let end = Date(timeIntervalSince1970: Double(max(startUs, endUs)) / 1_000_000)
        return formatter.string(from: start, to: end)
    }

    /// A day and a span of clock times: "Oct 12, 2:02 – 2:31 PM".
    public static func dayAndTime(
        startUs: Int64,
        endUs: Int64,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone).month(.abbreviated).day()
        let day = Date(timeIntervalSince1970: Double(startUs) / 1_000_000).formatted(style)
        return UserFacingCopy.You.sessionRow(
            date: day, time: timeRange(startUs: startUs, endUs: endUs, locale: locale, timeZone: timeZone))
    }
}
