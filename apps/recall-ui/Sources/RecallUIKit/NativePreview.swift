#if DEBUG
import Foundation

public struct NativePreviewConfiguration: Sendable {
    public enum Scenario: String, Sendable { case populated, empty, unavailable }
    public let tab: RecallTab
    public let query: String
    public let scenario: Scenario

    public init?(arguments: [String]) {
        guard arguments.contains("--synthetic-preview") else { return nil }
        func value(_ name: String) -> String? {
            arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
        }
        let requested = value("--preview-tab").flatMap(RecallTab.from) ?? .now
        tab = [.now, .search, .timeline, .episodes].contains(requested.workspaceTab) ? requested.workspaceTab : .now
        query = value("--preview-query") ?? ""
        scenario = value("--preview-state").flatMap(Scenario.init(rawValue:)) ?? .populated
    }
}

/// Debug-only in-memory records. No key resolution, files, images, or capture-health reads.
public struct NativePreviewReader: BrainReader {
    public let date: Date
    public let now: Date
    private let scenario: NativePreviewConfiguration.Scenario
    private let start: UInt64
    private let hits: [Hit]

    public init(date: Date = Date(), scenario: NativePreviewConfiguration.Scenario = .populated) {
        self.date = date
        self.scenario = scenario
        let day = MemoryDay(date: date)
        start = day.startUs
        now = Date(timeIntervalSince1970: Double(day.startUs) / 1_000_000 + 12 * 3600)
        let samples: [(UInt64, String, String, String, String)] = [
            (9 * 3600, "com.apple.Safari", "Launch checklist", "Question: which launch checks still need a source?", "browser_page_with_ocr"),
            (9 * 3600 + 120, "com.apple.dt.Xcode", "ReviewTests.swift", "Expected: deleted evidence cannot be exported.", "screen_ocr"),
            (9 * 3600 + 240, "com.apple.Safari", "Launch checklist", "Launch notes: compare the saved draft with the cited test output.", "browser_page_with_ocr"),
            (11 * 3600, "com.apple.Notes", "Imported meeting notes", "Open question in imported notes: who will review the launch wording?", "transcript_import"),
        ]
        hits = samples.enumerated().map { index, row in
            Hit(eventId: UInt64(index + 1), tsUs: day.startUs + row.0 * 1_000_000,
                appBundleId: row.1, windowTitle: row.2, url: nil, ocrTextSnippet: row.3,
                source: "timeline", score: nil, sourceKind: row.4)
        }
    }

    private func records() throws -> [Hit] {
        if scenario == .unavailable { throw BrainReaderError.queryFailed("Synthetic unavailable state") }
        return scenario == .empty ? [] : hits
    }

    public func search(_ options: SearchOptions) async throws -> [Hit] {
        let rows = try records()
        let query = options.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return Array(rows.filter {
            ($0.ocrTextSnippet.localizedCaseInsensitiveContains(query) || ($0.windowTitle?.localizedCaseInsensitiveContains(query) ?? false))
                && (options.appFilter == nil || options.appFilter == $0.appBundleId)
                && (options.appFilters.isEmpty || options.appFilters.contains($0.appBundleId ?? ""))
                && (!options.hasUrl || $0.url?.isEmpty == false)
                && (options.timeFromUs == nil || $0.tsUs >= options.timeFromUs!)
                && (options.timeToUs == nil || $0.tsUs <= options.timeToUs!)
        }.prefix(options.limit))
    }

    public func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] {
        let rows = try records()
        return ids.prefix(32).compactMap { id in rows.first { $0.id == id } }
    }

    public func eventText(eventId: UInt64) async throws -> EventText? {
        guard let hit = try records().first(where: { $0.id == eventId }) else { return nil }
        return try EventText(eventId: hit.id, tsUs: hit.tsUs, appBundleId: hit.appBundleId,
                             text: hit.ocrTextSnippet, isTruncated: false)
    }

    public func recentEvents(limit: Int) async throws -> [Hit] { Array(try records().reversed().prefix(limit)) }
    public func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    public func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    public func listEpisodes(limit: Int) async throws -> [Episode] {
        Array(try records().reversed().prefix(limit).map {
            Episode(episodeId: $0.id, appBundleId: $0.appBundleId, tsStartUs: $0.tsUs,
                    tsEndUs: $0.tsUs, eventCount: 1)
        })
    }
    public func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    public func latestBrief() async throws -> Brief? { nil }
    public func briefDates(limit: Int) async throws -> [String] { [] }
    public func summaryStats() async throws -> SummaryStats {
        let rows = try records()
        return SummaryStats(totalEvents: UInt64(rows.count), oldestTsUs: rows.first?.tsUs,
                            newestTsUs: rows.last?.tsUs, diskBytes: 0)
    }
    public func activityIntervals(startUs: UInt64, endUs: UInt64, limit: UInt32) async throws -> ActivityPage {
        guard !(try records()).isEmpty else { return ActivityPage(intervals: [], truncated: false) }
        let intervals = [
            ActivityInterval(startUs: start + 9 * 3_600_000_000, endUs: start + 10 * 3_600_000_000,
                             state: "input_active", appBundleId: "com.apple.dt.Xcode"),
            ActivityInterval(startUs: start + 10 * 3_600_000_000, endUs: start + 11 * 3_600_000_000,
                             state: "input_idle", appBundleId: "com.apple.Safari"),
        ].filter { $0.startUs < endUs && $0.endUs > startUs }
        return ActivityPage(intervals: Array(intervals.prefix(Int(limit))), truncated: intervals.count > Int(limit))
    }
}
#endif
