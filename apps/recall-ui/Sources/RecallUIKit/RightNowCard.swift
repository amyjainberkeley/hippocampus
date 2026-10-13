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
}

/// The Right now card on today's Overview (RULINGS W5, contract overview.md
/// section 5): what you are working on, or what was saved last.
public struct RightNowCard: Equatable, Sendable {
    public enum Moment: Equatable, Sendable {
        /// Working now: "Now · since {time}", from the start of the run of
        /// touching sessions.
        case now(sinceUs: Int64)
        /// Not working: "Last saved {time}".
        case lastSaved(atUs: Int64)
    }

    /// What sits under the card.
    public enum AIKnowsSection: Equatable, Sendable {
        /// "Your AI already knows": the lines a new session of a connected AI
        /// is given, exactly as sent. Either list may be empty.
        case lines(recentWork: [TemplateText], aboutYou: [AboutYouLine])
        /// No session hook is installed, so nothing is sent when a session
        /// starts: one line and "Connect" instead.
        case connect
    }

    public let moment: Moment
    public let title: String
    /// What "Copy for your AI" copies: that session's own moments, over the
    /// same time the caption names (RULINGS W5, I13).
    public let copyRange: ClosedRange<Int64>
    /// "Open {App}" or "Open Page"; nil when there is nothing to reopen.
    public let reopen: ReopenAction?
    /// The session in the day's blocks; nil for one from before midnight.
    public let blockId: Int64?
    /// The session's newest saved moment.
    public let openEventId: Int64?
    public let aiKnows: AIKnowsSection

    /// The card for `overview`, or nil when there is none: another day, or
    /// nothing saved since yesterday evening (contract `now.state: none`).
    ///
    /// The agent decides "Now" from the saved status when it answered, and its
    /// answer is kept for up to two minutes. The window's own read of that
    /// status is newer, so when it says Hippocampus is not remembering right
    /// now (paused, off, skipping, or not responding), the card says "Last
    /// saved" instead: it never claims "Now" while nothing is being saved.
    public init?(overview: DayOverview, receipt: CaptureHealthReceipt?, now: Date) {
        let card = overview.now
        guard overview.isToday, card.state != .none, let lastSaved = card.lastSavedUs else { return nil }
        let start = card.startUs ?? lastSaved
        let remembering = receipt.map { $0.isRememberingNow(now: now) } ?? true
        if card.state == .inProgress, remembering {
            let since = min(card.sinceUs ?? start, start)
            moment = .now(sinceUs: since)
            copyRange = min(since, lastSaved)...lastSaved
        } else {
            moment = .lastSaved(atUs: lastSaved)
            copyRange = min(start, lastSaved)...lastSaved
        }
        let title = card.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let app = card.appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = title.isEmpty ? app : title
        reopen = ReopenAction(card.reopen)
        blockId = card.blockId
        openEventId = card.openEventId
        let knows = overview.aiKnows
        aiKnows = knows.hookInstalled ? .lines(recentWork: knows.recentWork, aboutYou: knows.aboutYou) : .connect
    }

    /// "Now · since 2:12 PM" or "Last saved 2:36 PM", in the person's format.
    public func caption(locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        switch moment {
        case let .now(since):
            UserFacingCopy.rightNowSince(Formatters.clockTime(us: since, locale: locale, timeZone: timeZone))
        case let .lastSaved(at):
            UserFacingCopy.lastSavedAt(Formatters.clockTime(us: at, locale: locale, timeZone: timeZone))
        }
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
