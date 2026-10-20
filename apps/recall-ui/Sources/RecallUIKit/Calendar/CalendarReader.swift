import Foundation

/// One event from the person's calendar, as Today's day strip, a session's
/// name and an item page use it (SPEC-DELTA 5). Only the title, the time,
/// the calendar's name and the location are ever read: attendee lists are
/// never read or stored.
public struct CalendarEvent: Equatable, Hashable, Sendable, Identifiable {
    /// The calendar's own id for the event, on this Mac.
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let calendarName: String
    public let location: String?

    public init(id: String, title: String, start: Date, end: Date, calendarName: String, location: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.calendarName = calendarName
        self.location = location
    }
}

/// Whether the window may read the calendar.
public enum CalendarAccess: Equatable, Sendable {
    /// Not offered yet, or turned off in Preferences.
    case notAsked
    /// The person said yes and macOS allows it.
    case allowed
    /// macOS said no, or it was taken back later. Nothing breaks: Today drops
    /// the bars, and Preferences says how to turn it back on.
    case denied
}

/// The person's calendar, read-only, on this Mac only. The app reads it
/// through EventKit; tests, renders and the synthetic preview read a fake
/// and never ask the real system for access.
public protocol CalendarReader: Sendable {
    /// Whether the calendar can be read now.
    func access() async -> CalendarAccess
    /// The events that overlap `interval`, earliest first. Empty unless
    /// access is allowed.
    func events(in interval: DateInterval) async throws -> [CalendarEvent]
}

/// A calendar from fixtures; empty by default, as on a Mac whose calendar
/// isn't shown. It never touches EventKit.
public struct FixtureCalendar: CalendarReader {
    public let state: CalendarAccess
    public let fixtures: [CalendarEvent]

    public init(access: CalendarAccess = .notAsked, events: [CalendarEvent] = []) {
        self.state = access
        self.fixtures = events
    }

    public func access() async -> CalendarAccess { state }

    public func events(in interval: DateInterval) async throws -> [CalendarEvent] {
        guard state == .allowed else { return [] }
        return fixtures
            .filter { $0.start < interval.end && $0.end > interval.start }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
}
