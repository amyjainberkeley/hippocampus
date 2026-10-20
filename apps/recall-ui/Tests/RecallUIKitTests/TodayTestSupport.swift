import Foundation
import os
@testable import RecallUIKit

/// Moments a test makes up, read the way the FFI reads them: a browse is
/// newest first, inside its time window and its apps, at most `limit`. It
/// counts its reads. No memory, no files.
final class MomentsReader: BrainReader, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [SearchOptions]())
    let moments: [Hit]
    var stats: SummaryStats?

    init(_ moments: [Hit], stats: SummaryStats? = nil) {
        self.moments = moments
        self.stats = stats
    }

    /// Every search asked for, in order.
    var searches: [SearchOptions] { lock.withLock { $0 } }

    func search(_ options: SearchOptions) async throws -> [Hit] {
        lock.withLock { $0.append(options) }
        guard options.browse else { return [] }
        return Array(moments.filter { hit in
            (options.appFilters.isEmpty || options.appFilters.contains(hit.appBundleId ?? ""))
                && (options.timeFromUs.map { hit.tsUs >= $0 } ?? true)
                && (options.timeToUs.map { hit.tsUs <= $0 } ?? true)
        }.sorted { $0.tsUs == $1.tsUs ? $0.id > $1.id : $0.tsUs > $1.tsUs }.prefix(max(0, options.limit)))
    }

    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] { moments.filter { ids.contains($0.id) } }
    func recentEvents(limit: Int) async throws -> [Hit] {
        Array(moments.sorted { $0.tsUs > $1.tsUs }.prefix(limit))
    }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }
    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }
    func summaryStats() async throws -> SummaryStats {
        if let stats { return stats }
        return SummaryStats(totalEvents: UInt64(moments.count), oldestTsUs: moments.map(\.tsUs).min(),
                            newestTsUs: moments.map(\.tsUs).max(), diskBytes: 0)
    }
}

enum MomentFactory {
    /// One moment in `app`, `minutesAgo` before the samples' clock.
    static func hit(_ id: UInt64, _ app: String, title: String = "Window", url: String? = nil,
                    at us: UInt64? = nil, minutesAgo: Double = 0, caption: String? = nil) -> Hit {
        let now = UInt64(SampleDay.now.timeIntervalSince1970 * 1_000_000)
        return Hit(eventId: id, tsUs: us ?? now - UInt64(minutesAgo * 60_000_000), appBundleId: app,
                   windowTitle: title, url: url, ocrTextSnippet: "Text of \(title)", source: "recent", score: nil,
                   sourceKind: "screen_ocr", caption: caption)
    }
}

/// A calendar event on the samples' Monday, from hour and minute to hour and minute.
func event(_ id: String, _ title: String, _ from: (Int, Int), _ to: (Int, Int)) -> CalendarEvent {
    let day = SampleDay.calendar.startOfDay(for: SampleDay.now)
    func at(_ time: (Int, Int)) -> Date { day.addingTimeInterval(TimeInterval(time.0 * 3_600 + time.1 * 60)) }
    return CalendarEvent(id: id, title: title, start: at(from), end: at(to), calendarName: "Work")
}

/// Microseconds at an hour and minute of the samples' Monday.
func mondayUs(_ hour: Int, _ minute: Int) -> Int64 {
    let day = SampleDay.calendar.startOfDay(for: SampleDay.now)
    return Int64((day.timeIntervalSince1970 + TimeInterval(hour * 3_600 + minute * 60)) * 1_000_000)
}
