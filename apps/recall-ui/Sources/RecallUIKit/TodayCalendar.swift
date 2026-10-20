import Foundation

/// The person's calendar on Today (SPEC-DELTA 5), from what `CalendarReader`
/// gives: thin labelled bars over the day strip, and the name a call or
/// meeting session takes from the event it overlapped ("Team sync").
///
/// Only an event's title and time are used here; nothing about the person is
/// inferred from them, and nothing is sent anywhere. When the calendar can't
/// be read, there are no bars and sessions keep their own names.
public enum TodayCalendar {
    /// Events this long or longer are all-day or span days: never bars, never names.
    static let longestUs: Int64 = 12 * 3_600_000_000
    /// A session takes an event's name when they share at least this much
    /// time, or half the session if it is shorter.
    static let sharedUs: Int64 = 10 * 60_000_000

    /// An event's time, in microseconds since the epoch.
    static func span(_ event: CalendarEvent) -> ClosedRange<Int64> {
        let start = Int64((event.start.timeIntervalSince1970 * 1_000_000).rounded())
        let end = Int64((event.end.timeIntervalSince1970 * 1_000_000).rounded())
        return start...max(start, end)
    }

    /// Whether an event is a timed one, not all day.
    static func isTimed(_ event: CalendarEvent) -> Bool {
        let span = span(event)
        return span.upperBound > span.lowerBound && span.upperBound - span.lowerBound < longestUs
    }

    /// The event a call or meeting session is named after: the timed one
    /// sharing the most time with it, when they share ten minutes or half the
    /// session. Nil for any other kind of session.
    public static func event(naming block: DayBlock, among events: [CalendarEvent]) -> CalendarEvent? {
        guard SessionDetail.stripKind(of: block) == .calls, block.endUs > block.startUs else { return nil }
        let need = min(sharedUs, (block.endUs - block.startUs) / 2)
        var best: (event: CalendarEvent, shared: Int64)?
        for event in events where isTimed(event) {
            let span = span(event)
            let shared = min(span.upperBound, block.endUs) - max(span.lowerBound, block.startUs)
            guard shared >= need, shared > 0 else { continue }
            if let current = best, current.shared >= shared { continue }
            best = (event, shared)
        }
        return best?.event
    }

    /// A session's title on Today: its event's for a call or meeting, else its own.
    public static func title(of block: DayBlock, events: [CalendarEvent]) -> String {
        guard let event = event(naming: block, among: events) else { return block.title }
        let title = ReadableText.guarded(event.title).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? block.title : title
    }

    /// One event drawn over the strip.
    public struct Bar: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let startUs: Int64
        public let endUs: Int64
        /// Where it starts and how wide it is, from 0 to 1 of the strip.
        public let x: Double
        public let width: Double
        /// 0 for the first row of bars, 1 for the second.
        public let lane: Int
    }

    /// The most rows of bars: an event that would need a third is left off.
    public static let lanes = 2

    /// Bars for the timed events that touch `startUs...endUs`, earliest
    /// first, in two rows at most so that overlapping events never cover each
    /// other.
    public static func bars(_ events: [CalendarEvent], startUs: Int64, endUs: Int64) -> [Bar] {
        guard endUs > startUs else { return [] }
        let length = Double(endUs - startUs)
        var laneEnds = [Int64](repeating: .min, count: lanes)
        var bars: [Bar] = []
        let timed = events.filter(isTimed).sorted {
            span($0).lowerBound == span($1).lowerBound ? $0.id < $1.id : span($0).lowerBound < span($1).lowerBound
        }
        for event in timed {
            let span = span(event)
            guard span.upperBound > startUs, span.lowerBound < endUs,
                  let lane = laneEnds.firstIndex(where: { $0 <= span.lowerBound })
            else { continue }
            laneEnds[lane] = span.upperBound
            let from = max(span.lowerBound, startUs)
            let to = min(span.upperBound, endUs)
            let title = ReadableText.guarded(event.title).trimmingCharacters(in: .whitespacesAndNewlines)
            bars.append(Bar(id: event.id, title: title, startUs: span.lowerBound, endUs: span.upperBound,
                            x: Double(from - startUs) / length, width: Double(to - from) / length, lane: lane))
        }
        return bars
    }

    /// The time the day strip spans once today's events are on it: the
    /// sessions' span, widened to the whole hours of any timed event of the
    /// day, never past the day.
    public static func span(
        strip: DayStrip, events: [CalendarEvent], dayStartUs: Int64, dayEndUs: Int64, calendar: Calendar
    ) -> DayStrip {
        var start = strip.startUs
        var end = strip.endUs
        for event in events where isTimed(event) {
            let span = span(event)
            guard span.upperBound > dayStartUs, span.lowerBound < dayEndUs else { continue }
            start = min(start, max(dayStartUs, hour(span.lowerBound, calendar: calendar, up: false)))
            end = max(end, min(dayEndUs, hour(span.upperBound, calendar: calendar, up: true)))
        }
        return DayStrip(startUs: start, endUs: end)
    }

    private static func hour(_ us: Int64, calendar: Calendar, up: Bool) -> Int64 {
        let date = Date(timeIntervalSince1970: Double(us) / 1_000_000)
        guard let hour = calendar.dateInterval(of: .hour, for: date) else { return us }
        let edge = up && hour.start != date ? hour.end : hour.start
        return Int64((edge.timeIntervalSince1970 * 1_000_000).rounded())
    }
}
