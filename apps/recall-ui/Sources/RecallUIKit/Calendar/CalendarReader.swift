import Foundation

/// One event from the person's calendar, as Today's day strip, a session's
/// name and an item page use it (SPEC-DELTA 5). Only the title, the time,
/// the calendar's name and the location are ever read: attendee lists and
/// notes are never read or stored.
public struct CalendarEvent: Equatable, Hashable, Sendable, Identifiable {
    /// An id for this one occurrence, made on this Mac. It says nothing
    /// about the event, and a repeating event's days each have their own.
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    /// A holiday, a trip or a birthday: never a bar, never a meeting's name.
    public let isAllDay: Bool
    public let calendarName: String
    public let location: String?

    public init(
        id: String, title: String, start: Date, end: Date, calendarName: String,
        location: String? = nil, isAllDay: Bool = false
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarName = calendarName
        self.location = location
    }
}

/// Whether the window may read the calendar.
public enum CalendarAccess: Equatable, Sendable {
    /// Not offered yet, turned off in Preferences, or turned on before macOS
    /// was asked. Nothing is read.
    case notAsked
    /// The person turned it on and macOS allows it.
    case allowed
    /// The person turned it on, but macOS said no or took it back later, or
    /// allows adding events only; or this Mac doesn't let apps read calendars
    /// at all, whatever the person chose, so Today doesn't offer it. Nothing
    /// breaks: Today drops the bars, and Preferences says how to turn it back
    /// on.
    case denied
}

/// The person's calendar, read-only, on this Mac only. The window reads it
/// through `SystemCalendar` (EventKit); tests, renders and the synthetic
/// preview read a fake and never ask the real system for access.
public protocol CalendarReader: Sendable {
    /// Whether the calendar can be read now. Never asks macOS.
    func access() async -> CalendarAccess
    /// The events that overlap `interval`, earliest first. Empty unless
    /// access is allowed. Never asks macOS.
    func events(in interval: DateInterval) async throws -> [CalendarEvent]
}

public extension CalendarReader {
    /// The events of the day `date` falls on, in `calendar`'s time zone:
    /// today's, unless another day is asked for.
    func events(onDayOf date: Date = Date(), calendar: Calendar = .current) async throws -> [CalendarEvent] {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return [] }
        return try await events(in: day)
    }
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
