#if DEBUG
import AppKit
import RecallUIKit
import SwiftUI

/// Sam's whole made-up world in one window, for the shell's pictures: the
/// day and History from their fixtures, Working On, its pages, Web Pages,
/// Looked Up, the calendar and AI Tools from theirs (SPEC 8.7). Every
/// screenshot is drawn, sealed with the capture helper's codec in a
/// temporary folder and opened as the app opens the person's own; nothing
/// is read from the person's memory, calendar, AI tools or Mac.
@MainActor
enum ShellWorld {
    /// What the pages reach in a picture: Sam's searches, calendar, AI
    /// tools and Privacy; the preview's Ask {Tool} and Resume, which open
    /// nothing.
    static func services(now: Date, calendar: Calendar) -> WindowServices {
        var services = WindowServices.syntheticPreview(
            searches: PreviewSearchesReader(records: WorkFixtures.searches(now: now, calendar: calendar)),
            calendar: FixtureCalendar(access: .allowed, events: WorkFixtures.calendarEvents(now: now,
                                                                                            calendar: calendar)))
        services.aiTools = HandoffFixtures.aiToolsModel(.connected)
        services.privacy = { PrivacyRenderScene.page() }
        services.readsKinds = false
        return services
    }

    /// The sidebar's little screenshots: each item's newest kept moment.
    static func pictures(_ fixture: WorkRenderFixture) -> SidebarPictures {
        let paths = Dictionary(fixture.reader.hits.compactMap { hit in hit.thumbnailPath.map { (hit.id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        return SidebarPictures(url: { moment in paths[moment].map { URL(fileURLWithPath: $0) } },
                               provider: fixture.screenshots)
    }
}

/// The day's reader with Working On's moments beside it: History and its
/// lenses list the day's moments only, and a moment asked for by id (an
/// item's page, Web Pages, Looked Up) is found in either.
struct ShellWorldReader: BrainReader {
    let base: any BrainReader
    let work: WorkFixtureReader

    func search(_ opts: SearchOptions) async throws -> [Hit] { try await base.search(opts) }
    func recentEvents(limit: Int) async throws -> [Hit] { try await base.recentEvents(limit: limit) }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] {
        try await base.recentPrivacyMoments(limit: limit)
    }

    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] {
        try await base.listObservedApps(limit: limit, timeFromUs: timeFromUs)
    }

    func listEpisodes(limit: Int) async throws -> [Episode] { try await base.listEpisodes(limit: limit) }

    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] {
        let found = (try? await base.fetchEventsByIds(ids)) ?? []
        let known = Set(found.map(\.id))
        let missing = ids.filter { !known.contains($0) }
        let more = missing.isEmpty ? [] : ((try? await work.fetchEventsByIds(missing)) ?? [])
        let all = found + more
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    func eventText(eventId: UInt64) async throws -> EventText? {
        if let text = try await base.eventText(eventId: eventId) { return text }
        return try await work.eventText(eventId: eventId)
    }

    func eventReading(eventId: UInt64, query: String?) async throws -> EventReading? {
        if let reading = try await base.eventReading(eventId: eventId, query: query) { return reading }
        return try await work.eventReading(eventId: eventId, query: query)
    }

    func activityIntervals(startUs: UInt64, endUs: UInt64, limit: UInt32) async throws -> ActivityPage {
        try await base.activityIntervals(startUs: startUs, endUs: endUs, limit: limit)
    }

    func briefForDate(_ dateLocal: String) async throws -> Brief? { try await base.briefForDate(dateLocal) }
    func latestBrief() async throws -> Brief? { try await base.latestBrief() }
    func briefDates(limit: Int) async throws -> [String] { try await base.briefDates(limit: limit) }
    func summaryStats() async throws -> SummaryStats { try await base.summaryStats() }
    func storageUsage() async throws -> StorageUsage? { try await base.storageUsage() }

    func timelineEvents(startTsUs: UInt64, endTsUs: UInt64, resolution: TimelineResolution) async throws
        -> [TimelineEvent] {
        try await base.timelineEvents(startTsUs: startTsUs, endTsUs: endTsUs, resolution: resolution)
    }
}

/// Screenshots from several sealed folders: each is asked in turn, and the
/// first that opens the file answers. Every folder is a fixture's own.
final class CombinedScreenshots: ThumbnailDataProviding, @unchecked Sendable {
    private let providers: [any ThumbnailDataProviding]

    init(_ providers: [any ThumbnailDataProviding]) {
        self.providers = providers
    }

    func thumbnailData(for url: URL, maxPixelSize: Int) async -> Data? {
        for provider in providers {
            if let data = await provider.thumbnailData(for: url, maxPixelSize: maxPixelSize) { return data }
        }
        return nil
    }

    func screenshotData(for url: URL) async -> Data? {
        for provider in providers {
            if let data = await provider.screenshotData(for: url) { return data }
        }
        return nil
    }
}
#endif
