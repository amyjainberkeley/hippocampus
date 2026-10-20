import Foundation
@testable import RecallUIKit

/// Sam's clock for Working On's tests: Monday, October 12, 2026 at 3 PM, a
/// fixed seven hours behind UTC, in US English. Every name and address in
/// these tests is made up.
enum WorkClock {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -7 * 3_600) ?? .gmt
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    static let now: Date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)) ?? Date()

    /// A moment `daysAgo` days before today at `hour`:`minute`, local.
    static func us(_ daysAgo: Int, _ hour: Int, _ minute: Int = 0) -> UInt64 {
        let start = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: start) ?? start
        return UInt64((day.timeIntervalSince1970 + Double(hour * 3_600 + minute * 60)) * 1_000_000)
    }
}

/// One made-up moment.
func workMoment(_ id: UInt64, _ tsUs: UInt64, app: String = "com.google.Chrome", title: String? = nil,
                url: String? = nil, text: String = "", screenshot: String? = nil) -> Hit {
    Hit(eventId: id, tsUs: tsUs, appBundleId: app, windowTitle: title, url: url, ocrTextSnippet: text,
        source: "timeline", score: nil, thumbnailPath: screenshot,
        sourceKind: url == nil ? "screen_ocr" : "browser_page")
}

/// Moments read as the FFI reads them: by id, and browsed by time, app and
/// address, newest first. It keeps what it was asked.
final class WorkMomentsReader: BrainReader, @unchecked Sendable {
    let hits: [Hit]
    private let lock = NSLock()
    private var asked: [SearchOptions] = []
    private var failing = false

    init(_ hits: [Hit]) {
        self.hits = hits
    }

    var searches: [SearchOptions] { lock.withLock { asked } }

    func failSearches() {
        lock.withLock { failing = true }
    }

    func search(_ opts: SearchOptions) async throws -> [Hit] {
        let fails = lock.withLock { () -> Bool in
            asked.append(opts)
            return failing
        }
        if fails { throw UnderstandingError.unavailable }
        let found = hits.filter { hit in
            (opts.timeFromUs.map { hit.tsUs >= $0 } ?? true) && (opts.timeToUs.map { hit.tsUs <= $0 } ?? true)
                && (opts.appFilter.map { hit.appBundleId == $0 } ?? true) && (!opts.hasUrl || hit.url != nil)
        }
        return Array(found.sorted { $0.tsUs > $1.tsUs }.prefix(max(0, opts.limit)))
    }

    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] {
        ids.compactMap { id in hits.first { $0.id == id } }
    }

    func recentEvents(limit: Int) async throws -> [Hit] { Array(hits.prefix(limit)) }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }
    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }
    func summaryStats() async throws -> SummaryStats {
        SummaryStats(totalEvents: UInt64(hits.count), oldestTsUs: nil, newestTsUs: nil, diskBytes: 0)
    }
}

/// A work read that answers, then fails when told to.
final class SwitchingWorkReader: WorkReader, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: WorkSnapshot
    private var failing = false

    init(snapshot: WorkSnapshot) {
        self.snapshot = snapshot
    }

    func fail() {
        lock.withLock { failing = true }
    }

    private func answer() throws -> WorkSnapshot {
        try lock.withLock {
            if failing { throw UnderstandingError.unavailable }
            return snapshot
        }
    }

    func work(days: Int) async throws -> WorkSnapshot { try answer() }

    func item(id: String, before: UInt64?) async throws -> WorkItem? {
        try answer().items.first { $0.id == id }
    }

    func items(forMoments moments: [UInt64]) async throws -> [UInt64: String] {
        try answer().momentItems.filter { moments.contains($0.key) }
    }
}
