import Combine
import Foundation

/// A local calendar day, expressed as the inclusive microsecond range the FFI accepts.
public struct MemoryDay: Equatable, Sendable {
    /// The day as the agent and the store name it: `YYYY-MM-DD`, Gregorian.
    public let dateLocal: String
    public let startUs: UInt64
    public let endUs: UInt64

    public init(date: Date, calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        startUs = UInt64(max(0, start.timeIntervalSince1970 * 1_000_000))
        endUs = UInt64(max(1, end.timeIntervalSince1970 * 1_000_000)) - 1
        dateLocal = Self.dateFormatter(timeZone: calendar.timeZone).string(from: start)
    }

    /// Writes and reads `YYYY-MM-DD` in the Gregorian calendar whatever
    /// calendar the person uses: a Buddhist, Japanese or Persian one would
    /// name another year, or another date, and the agent would read a day
    /// with nothing in it. Where the day starts stays the person's calendar's.
    static func dateFormatter(timeZone: TimeZone) -> DateFormatter {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = gregorian
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    public func contains(_ timestamp: UInt64) -> Bool {
        timestamp >= startUs && timestamp <= endUs
    }
}

public extension TimelineEvent {
    /// IDs may be reused after deletion. Match acquisition identity before showing new content.
    func matches(_ hit: Hit) -> Bool {
        id == hit.id && tsUs == hit.tsUs && appBundleId == hit.appBundleId && sourceKind == hit.sourceKind
    }

    var hasScreenshot: Bool {
        !(thumbnailPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

public extension Episode {
    func evidence(from events: [TimelineEvent]) -> [TimelineEvent] {
        var seen = Set<UInt64>()
        return events.filter { $0.appBundleId == appBundleId && $0.tsUs >= tsStartUs && $0.tsUs <= tsEndUs }
            .sorted { $0.tsUs == $1.tsUs ? $0.id < $1.id : $0.tsUs < $1.tsUs }
            .filter { seen.insert($0.id).inserted }
    }
}
