import Foundation

/// Demo Memory's made-up calendar (SPEC-DELTA 6): the week's meetings, from
/// the file the seeder writes beside the demo store. It is shown as the
/// person's own calendar would be, with access allowed, since nothing asks
/// macOS and nothing of the person's is read. Only the title, the time, the
/// calendar's name and the location are in it, as for a real calendar.
public struct DemoCalendar: CalendarReader {
    /// The file, `demo-calendar.json`.
    public let url: URL

    /// The most the file may hold, and the most events read from it.
    static let maxBytes = 1_048_576
    static let maxEvents = 2_000

    public init(url: URL) {
        self.url = url
    }

    /// Allowed once the week's calendar is there; not asked otherwise, so
    /// Today simply shows no bars.
    public func access() async -> CalendarAccess {
        (try? load()) == nil ? .notAsked : .allowed
    }

    public func events(in interval: DateInterval) async throws -> [CalendarEvent] {
        try load()
            .filter { $0.start < interval.end && $0.end > interval.start }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    public enum DemoCalendarError: Error, Equatable {
        case unreadable
    }

    private struct File: Decodable {
        let version: Int
        let events: [Event]
    }

    private struct Event: Decodable {
        let id: String
        let title: String
        let startUs: UInt64
        let endUs: UInt64
        let calendar: String
        let location: String?

        enum CodingKeys: String, CodingKey {
            case id, title, calendar, location
            case startUs = "start_us"
            case endUs = "end_us"
        }
    }

    /// The week's events, as written: version 1, each ending after it starts.
    func load() throws -> [CalendarEvent] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw DemoCalendarError.unreadable }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maxBytes + 1), data.count <= Self.maxBytes,
              let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1,
              file.events.count <= Self.maxEvents
        else { throw DemoCalendarError.unreadable }
        return file.events.compactMap { event in
            guard event.endUs > event.startUs, !event.id.isEmpty, !event.title.isEmpty else { return nil }
            return CalendarEvent(
                id: event.id, title: event.title,
                start: Date(timeIntervalSince1970: TimeInterval(event.startUs) / 1_000_000),
                end: Date(timeIntervalSince1970: TimeInterval(event.endUs) / 1_000_000),
                calendarName: event.calendar,
                location: event.location.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }
}
