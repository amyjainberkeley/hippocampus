import AppKit
import Foundation

/// What "Open {App}" or "Open Page" opens for a session or the Right now card
/// (RULINGS W5). The agent names the moment's page and app (contract
/// overview.md section 7, `reopen`); only an http or https page is opened as
/// a page.
public enum ReopenAction: Equatable, Sendable {
    case page(URL)
    case app(bundleId: String, name: String)

    /// Nil when there is nothing to reopen: no moment, or a moment with no app.
    public init?(_ reopen: Reopen?) {
        guard let reopen else { return nil }
        if let text = reopen.url, let url = URL(string: text),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
           url.host?.isEmpty == false {
            self = .page(url)
            return
        }
        let bundleId = reopen.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleId.isEmpty, bundleId != "unknown" else { return nil }
        let name = reopen.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        self = .app(bundleId: bundleId, name: name.isEmpty ? Formatters.appDisplayName(bundleId) : name)
    }

    /// "Open Page" or "Open {App}".
    public var label: String {
        switch self {
        case .page: UserFacingCopy.openPage
        case let .app(_, name): UserFacingCopy.openApp(name)
        }
    }

    /// Whether it can open on this Mac (SPEC 3.1): a page always; an app
    /// only while it is installed, so a removed app gets no Open button
    /// that would do nothing, as a Working On page already does.
    public func canOpen(appInstalled: (String) -> Bool = ReopenAction.isInstalled) -> Bool {
        switch self {
        case .page: true
        case let .app(bundleId, _): appInstalled(bundleId)
        }
    }

    /// Whether an app with `bundleId` is on this Mac.
    public static func isInstalled(_ bundleId: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }
}

/// The card at the top of Today (SPEC 3.1): what you are doing now, or where
/// you left off.
///
/// - "Now · since 2:12 PM", with the blue dot, while Hippocampus is
///   remembering and the newest moment saved is under 20 minutes old.
/// - "Where you left off · Yesterday at 6:12 PM" when the newest moment is
///   20 minutes old or more, or remembering is paused or off. It shows the
///   last session before that gap; overnight is a gap, so the morning opens
///   on yesterday's last session.
public struct RightNowCard: Equatable, Sendable {
    public enum Moment: Equatable, Sendable {
        /// Working now: "Now · since {time}", from the start of the run of
        /// touching sessions.
        case now(sinceUs: Int64)
        /// After a gap: "Where you left off · {day} at {time}", when the
        /// newest moment was saved.
        case leftOff(atUs: Int64)
    }

    /// "Now" lasts while the newest moment is younger than this.
    public static let nowWindowUs: Int64 = 20 * 60 * 1_000_000

    /// What sits under the card.
    public enum AIKnowsSection: Equatable, Sendable {
        /// "What your AI starts with": the lines a new session of a connected
        /// AI is given, exactly as sent. Either list may be empty.
        case lines(recentWork: [TemplateText], aboutYou: [AboutYouLine])
        /// No session hook is installed, so nothing is sent when a session
        /// starts: one line and "Connect" instead.
        case connect
    }

    public let moment: Moment
    public let title: String
    /// What "Copy for Your AI" copies: that session's own moments, over the
    /// same time the caption names (RULINGS W5, I13).
    public let copyRange: ClosedRange<Int64>
    /// "Open {App}" or "Open Page"; nil when there is nothing to reopen.
    public let reopen: ReopenAction?
    /// The session in the day's blocks; nil for one from before midnight.
    public let blockId: Int64?
    /// The session's newest saved moment.
    public let openEventId: Int64?
    /// What a connected AI starts with. AI Tools shows it now (SPEC 3.8); the
    /// card keeps it only to know whether a tool is connected.
    public let aiKnows: AIKnowsSection
    /// The card's session, for its apps and screenshot; nil when it isn't
    /// among the day's sessions.
    public let block: DayBlock?
    /// When the card was made, so "Today" and "Yesterday" are said from it.
    public let madeAtUs: Int64

    /// The card for today's `overview`, or nil when there is none: another
    /// day, or nothing saved since yesterday evening (contract
    /// `now.state: none`).
    ///
    /// The agent decides "Now" from the saved status when it answered, and its
    /// answer is kept for up to two minutes. The window's own read of that
    /// status is newer, so when it says Hippocampus is not remembering right
    /// now (paused, off, skipping, or not responding), or the newest moment is
    /// 20 minutes old, the card says "Where you left off" instead: it never
    /// claims "Now" while nothing is being saved.
    public init?(overview: DayOverview, receipt: CaptureHealthReceipt?, now: Date) {
        let card = overview.now
        guard overview.isToday, card.state != .none, let lastSaved = card.lastSavedUs else { return nil }
        let start = card.startUs ?? lastSaved
        let remembering = receipt.map { $0.isRememberingNow(now: now) } ?? true
        let nowUs = Int64((now.timeIntervalSince1970 * 1_000_000).rounded())
        let fresh = nowUs - lastSaved < Self.nowWindowUs
        if card.state == .inProgress, remembering, fresh {
            let since = min(card.sinceUs ?? start, start)
            moment = .now(sinceUs: since)
            copyRange = min(since, lastSaved)...lastSaved
        } else {
            moment = .leftOff(atUs: lastSaved)
            copyRange = min(start, lastSaved)...lastSaved
        }
        let title = card.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let app = card.appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = title.isEmpty ? app : title
        reopen = ReopenAction(card.reopen)
        blockId = card.blockId
        openEventId = card.openEventId
        block = card.blockId.flatMap { id in overview.blocks.first { $0.id == id } }
            ?? SessionMatch.best(for: start...lastSaved, in: overview.blocks)
        madeAtUs = nowUs
        aiKnows = Self.section(overview.aiKnows)
    }

    /// The card for a morning, or a day back after time away: where you left
    /// off on `overview`, an earlier day, is its last session. Nil when that
    /// day has none.
    public init?(leftOffFrom overview: DayOverview, now: Date) {
        guard !overview.isToday, let last = overview.blocks.last else { return nil }
        let end = max(last.startUs, last.endUs)
        moment = .leftOff(atUs: end)
        title = last.title
        copyRange = last.startUs...end
        reopen = SessionDetail.reopen(for: last)
        blockId = last.id
        openEventId = last.openEventId
        block = last
        madeAtUs = Int64((now.timeIntervalSince1970 * 1_000_000).rounded())
        aiKnows = Self.section(overview.aiKnows)
    }

    private static func section(_ knows: AIKnows) -> AIKnowsSection {
        knows.hookInstalled ? .lines(recentWork: knows.recentWork, aboutYou: knows.aboutYou) : .connect
    }

    /// Whether the card is from a day before today, in `timeZone`.
    public func isFromEarlierDay(timeZone: TimeZone) -> Bool {
        guard case let .leftOff(at) = moment else { return false }
        return Self.daysBetween(at, madeAtUs, timeZone: timeZone) > 0
    }

    /// "Now · since 2:12 PM" or "Where you left off · Yesterday at 6:12 PM",
    /// in the person's format.
    public func caption(locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        switch moment {
        case let .now(since):
            UserFacingCopy.rightNowSince(Formatters.clockTime(us: since, locale: locale, timeZone: timeZone))
        case let .leftOff(at):
            UserFacingCopy.Overview.leftOff(Self.when(at, from: madeAtUs, locale: locale, timeZone: timeZone))
        }
    }

    /// When a moment was, said from `nowUs`: "Today at 2:35 PM", "Yesterday
    /// at 6:12 PM", "Friday at 6:12 PM" within the week, then "Oct 2 at 6:12 PM".
    public static func when(_ us: Int64, from nowUs: Int64, locale: Locale, timeZone: TimeZone) -> String {
        let time = Formatters.clockTime(us: us, locale: locale, timeZone: timeZone)
        return UserFacingCopy.Overview.at(day(us, from: nowUs, locale: locale, timeZone: timeZone), time)
    }

    /// The day of `us` said from `nowUs`: "Today", "Yesterday", "Friday",
    /// "Oct 2", or "Oct 2, 2025" in another year.
    public static func day(_ us: Int64, from nowUs: Int64, locale: Locale, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: Double(us) / 1_000_000)
        let now = Date(timeIntervalSince1970: Double(nowUs) / 1_000_000)
        let days = daysBetween(us, nowUs, timeZone: timeZone)
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
        switch days {
        case ...0: return UserFacingCopy.Overview.today
        case 1: return UserFacingCopy.Overview.yesterday
        case 2...6: return date.formatted(style.weekday(.wide))
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return date.formatted(sameYear ? style.month(.abbreviated).day() : style.month(.abbreviated).day().year())
        }
    }

    /// Whole days from the day of `from` to the day of `to`, in `timeZone`.
    static func daysBetween(_ from: Int64, _ to: Int64, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let a = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(from) / 1_000_000))
        let b = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(to) / 1_000_000))
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }
}

public extension CaptureHealthReceipt {
    /// Hippocampus is saving right now, by the agent's own rule for "Now"
    /// (contract overview.md section 5): the status was written within the
    /// last two minutes and names no block and no skip.
    func isRememberingNow(now: Date) -> Bool {
        abs(now.timeIntervalSince(updatedAt)) <= 120 && blockedReason == nil && suppressionReason == nil
    }
}

/// Finds a session again after a new read (RULINGS I2). A session with no note
/// yet has a provisional id that changes when its note lands, and its bounds
/// grow while it is under way, so a session is found by its time, never by id.
public enum SessionMatch {
    /// The block sharing the most time with `range`, then the one starting
    /// nearest it. Nil when none touches it.
    public static func best(for range: ClosedRange<Int64>, in blocks: [DayBlock]) -> DayBlock? {
        var best: (block: DayBlock, overlap: Int64, distance: Int64)?
        for block in blocks {
            let overlap = min(range.upperBound, block.endUs) - max(range.lowerBound, block.startUs)
            guard overlap >= 0 else { continue }
            let distance = abs(block.startUs - range.lowerBound)
            if let current = best,
               current.overlap > overlap || (current.overlap == overlap && current.distance <= distance) {
                continue
            }
            best = (block, overlap, distance)
        }
        return best?.block
    }
}
