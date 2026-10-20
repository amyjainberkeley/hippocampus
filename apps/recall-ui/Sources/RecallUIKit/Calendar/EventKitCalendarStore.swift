import CryptoKit
import Foundation
#if canImport(EventKit)
import EventKit
#endif

/// The window's calendar store: EventKit, read-only (SPEC-DELTA 5).
///
/// `event(from:)` is the one place an EventKit event is read: its title, its
/// time, whether it lasts all day, its calendar's name and its location. Who
/// is invited, the organizer, notes and links are never read, and a test
/// holds this file to that.
///
/// The `EKEventStore` is made only when macOS is asked or once it allows
/// reading, never before: making one can start the calendar's services.
public final class EventKitCalendarStore: CalendarStore, @unchecked Sendable {
    public static let shared = EventKitCalendarStore()

    private let lock = NSLock()
    /// One read at a time.
    private let readLock = NSLock()
    #if canImport(EventKit)
    private var store: EKEventStore?
    /// What macOS allowed when `store` was made.
    private var madeWith: CalendarPermission?
    #endif

    public init() {}

    public func permission() -> CalendarPermission {
        #if canImport(EventKit)
        Self.permission(EKEventStore.authorizationStatus(for: .event))
        #else
        .restricted
        #endif
    }

    public func requestFullAccess() async throws -> Bool {
        #if canImport(EventKit)
        let store = eventStore(for: permission())
        return try await store.requestFullAccessToEvents()
        #else
        false
        #endif
    }

    public func events(in interval: DateInterval) throws -> [CalendarEvent] {
        #if canImport(EventKit)
        let permission = permission()
        guard permission == .fullAccess else {
            // Taken back, or never given: a store made earlier is let go, so
            // reading starts fresh once it is allowed again.
            lock.withLock { self.store = nil; self.madeWith = nil }
            return []
        }
        let store = eventStore(for: permission)
        return readLock.withLock {
            let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
            return store.events(matching: predicate).compactMap(Self.event(from:))
        }
        #else
        []
        #endif
    }

    #if canImport(EventKit)
    /// What macOS's answer means here. Anything new reads nothing.
    static func permission(_ status: EKAuthorizationStatus) -> CalendarPermission {
        switch status {
        case .notDetermined: .notDetermined
        case .fullAccess: .fullAccess
        case .writeOnly: .addOnly
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    /// The one place an EventKit event is read. A cancelled event, or one
    /// without a title or a time, isn't kept.
    static func event(from event: EKEvent) -> CalendarEvent? {
        guard event.status != .canceled,
              let start = event.startDate, let end = event.endDate, end > start
        else { return nil }
        let title = CalendarText.line(event.title)
        guard !title.isEmpty else { return nil }
        return CalendarEvent(
            id: CalendarEventID.make(event.calendarItemIdentifier, start: start),
            title: title,
            start: start,
            end: end,
            calendarName: CalendarText.line(event.calendar?.title),
            location: CalendarText.place(event.location),
            isAllDay: event.isAllDay
        )
    }

    /// The store, made again whenever macOS's answer has changed since it was
    /// made: one made before reading was allowed may not see the events.
    private func eventStore(for permission: CalendarPermission) -> EKEventStore {
        lock.withLock {
            if let store, madeWith == permission { return store }
            let made = EKEventStore()
            store = made
            madeWith = permission
            return made
        }
    }
    #endif
}

/// An event's words as a person reads them: on one line, a link cut to its
/// site so a meeting's code and passcode are never kept, and never longer
/// than a line or two.
enum CalendarText {
    static let longestLine = 200
    static let longestPlace = 120

    /// A title or a calendar's name, on one line.
    static func line(_ raw: String?) -> String {
        let line = (raw ?? "").split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return cut(line, to: longestLine)
    }

    /// A place as a person would say it ("Room 4", "zoom.us"); nil when empty.
    static func place(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lines = raw.split(whereSeparator: \.isNewline).map { line in
            line.split(whereSeparator: \.isWhitespace).map(site).joined(separator: " ")
        }
        let place = lines.filter { !$0.isEmpty }.joined(separator: ", ")
        return place.isEmpty ? nil : cut(place, to: longestPlace)
    }

    /// A word, or only a link's site when the word is a link.
    private static func site(_ word: Substring) -> String {
        let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "()[]<>{}\"'.,;:"))
        let spelled = bare.contains("://") ? bare : "https://" + bare
        guard bare.contains("://") || looksLikeSite(bare),
              let link = URL(string: spelled), let host = link.host(), !host.isEmpty
        else { return String(word) }
        return host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// "meet.example.com/abc-defg" without its scheme: a name ending in
    /// letters, then a path.
    private static func looksLikeSite(_ word: String) -> Bool {
        guard let slash = word.firstIndex(of: "/") else { return false }
        let name = word[..<slash]
        guard let dot = name.lastIndex(of: "."), name.firstIndex(of: "@") == nil else { return false }
        let ending = name[name.index(after: dot)...]
        return ending.count >= 2 && ending.allSatisfy(\.isLetter)
    }

    private static func cut(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

/// The id an event has in the window: "cal-" and 16 hex digits made from its
/// id on this Mac and its start, so each day of a repeating event has its
/// own and nothing of the event shows in it.
enum CalendarEventID {
    static func make(_ source: String, start: Date) -> String {
        let seconds = Int64(start.timeIntervalSince1970.rounded())
        let digest = SHA256.hash(data: Data("\(source)\u{1F}\(seconds)".utf8))
        return "cal-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
