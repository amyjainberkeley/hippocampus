import Foundation

/// Overview's strip on the first day of the person's memory, before its first
/// session (first landing, Oct 18): empty, with now marked.
///
/// It spans what the agent gives a day whose first session starts now
/// (`overview.rs`: the hour of the first session to the hour after now, at
/// least four hours, within the day), so the first session appears where now
/// is marked and the strip does not jump when it does.
public struct FirstDayStripLayout: Equatable, Sendable {
    public let startUs: Int64
    public let endUs: Int64
    /// Where now sits, from 0 to 1.
    public let nowX: Double
    public let ticks: [DayStripLayout.Tick]

    /// The agent's narrowest strip.
    static let minimumSpanUs: Int64 = 4 * 3_600_000_000

    /// Nil only for a calendar that cannot say which day or hour `now` is in.
    public init?(now: Date, calendar: Calendar) {
        guard let day = calendar.dateInterval(of: .day, for: now),
              let hour = calendar.dateInterval(of: .hour, for: now)
        else { return nil }
        let nowUs = Self.microseconds(now)
        let dayStart = Self.microseconds(day.start)
        let dayEnd = Self.microseconds(day.end)
        // Rounded up to the hour, as the agent rounds the day's reach.
        var end = min(hour.start == now ? nowUs : Self.microseconds(hour.end), dayEnd)
        var start = Self.microseconds(hour.start)
        if end - start < Self.minimumSpanUs {
            start = max(end - Self.minimumSpanUs, dayStart)
        }
        if end - start < Self.minimumSpanUs {
            end = min(start + Self.minimumSpanUs, dayEnd)
        }
        guard end > start else { return nil }
        startUs = start
        endUs = end
        let span = Double(end - start)
        func fraction(_ us: Int64) -> Double {
            min(max(Double(us - start) / span, 0), 1)
        }
        nowX = fraction(nowUs)
        ticks = DayStripLayout.ticks(from: start, to: end, calendar: calendar).map {
            DayStripLayout.Tick(atUs: $0, x: fraction($0))
        }
    }

    private static func microseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }
}
