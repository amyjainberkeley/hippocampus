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
        /// "Notes · 19m".
        public var label: String { UserFacingCopy.Overview.appTime(name, duration) }
    }

    public struct Noticed: Equatable, Sendable {
        public let text: String
        /// "Written on this Mac by Apple Intelligence" (RULINGS I11).
        public let caption: String?
    }

    /// The session's id in this read: provisional for a session with no note
    /// yet, so the window finds a selection again by time (RULINGS I2).
    public let id: Int64
    public let title: String
    /// "9:05 – 9:34 AM", in the person's format.
    public let time: String
    /// "29m".
    public let length: String
    public let kind: WorkKind
    /// "Writing", or "Mostly Writing, some Design" when no kind held half.
    public let kindLine: String
    /// Longest first, at most three.
    public let apps: [AppTime]
    /// At most two, with times filled in the person's format.
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

    public init(block: DayBlock, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) {
        id = block.id
        title = block.title
        time = Self.timeRange(startUs: block.startUs, endUs: block.endUs, locale: locale, timeZone: timeZone)
        length = Formatters.duration(us: max(0, block.endUs - block.startUs), locale: locale)
        kind = block.kind
        if block.mixed, block.kinds.count >= 2 {
            kindLine = UserFacingCopy.Overview.mostly(block.kinds[0].kindLabel, some: block.kinds[1].kindLabel)
        } else {
            kindLine = block.kindLabel
        }
        apps = block.apps.prefix(3).compactMap { app in
            let name = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return AppTime(bundleId: app.bundleId, name: name,
                           duration: Formatters.duration(us: app.heldUs, locale: locale))
        }
        sentences = block.sentences.prefix(2).map { $0.text.text(locale: locale, timeZone: timeZone) }
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
