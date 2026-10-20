import Foundation

/// A forget a page asked for that needs a yes first (SPEC 3.11): more than
/// 20 picked moments, a session, an hour, a page or a search. Its words, the
/// line said the first time anyone forgets, and what it removes, by ids and
/// times only.
public struct ForgetConfirmation: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let body: String
    /// "Forgetting removes it from this Mac. What you already sent to an AI
    /// tool stays in that tool." The first time only.
    public let firstForget: Bool
    public let request: ForgetRequest
    /// The audit log's line once it's done.
    public let audit: ForgetAudit

    public init(title: String, body: String, firstForget: Bool, request: ForgetRequest, audit: ForgetAudit) {
        self.title = title
        self.body = body
        self.firstForget = firstForget
        self.request = request
        self.audit = audit
    }

    /// What the alert says under its title.
    public var message: String {
        firstForget ? body + "\n\n" + NavigationCopy.firstForget : body
    }
}

/// The audit log's line for a forget (SPEC 3.9's Activity): what kind of
/// forget it was and how many moments went, never content.
public enum ForgetAudit: Equatable, Sendable {
    /// Picked moments, a page's or a search's.
    case moments(Int)
    /// A span of time: a session, an hour, the last 24 hours.
    case span(ForgetRequest.Span)
    /// Forget Recent's choice.
    case recent(ForgetRecentChoice)

    /// The details the Activity list reads: `count`, and for recent time
    /// `range_minutes`, `range_hours` or `range: today`.
    public func details(count: UInt64, now: Date) -> (action: AuditAction, details: [String: String]) {
        switch self {
        case .moments:
            return (.deleteEvent, ["count": "\(count)"])
        case let .recent(choice):
            var details = ["count": "\(count)"]
            switch choice {
            case .tenMinutes: details["range_minutes"] = "10"
            case .hour: details["range_minutes"] = "60"
            case .today: details["range"] = "today"
            }
            return (.deleteEventsInRange, details)
        case let .span(span):
            var details = ["count": "\(count)"]
            // The last 24 hours, up to the click: Privacy's own forget.
            let nowUs = UInt64(max(0, now.timeIntervalSince1970 * 1_000_000))
            let length = span.endUs >= span.startUs ? span.endUs - span.startUs : 0
            let hour: UInt64 = 3_600_000_000
            if nowUs >= span.endUs, nowUs - span.endUs < 5 * 60_000_000,
               length > 24 * hour - 5 * 60_000_000, length <= 24 * hour + 5 * 60_000_000 {
                details["range_hours"] = "24"
            }
            return (.deleteEventsInRange, details)
        }
    }

    /// Writes the line. Only after a forget that deleted something real:
    /// the preview and pictures never get this far.
    public func record(count: UInt64, now: Date, log: AuditLog = .shared) {
        let line = details(count: count, now: now)
        log.record(action: line.action, details: line.details)
    }
}
