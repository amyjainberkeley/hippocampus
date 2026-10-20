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
        services.handoff = samsHandoff
        services.aiTools = HandoffFixtures.aiToolsModel(.connected)
        services.privacy = { PrivacyRenderScene.page() }
        services.readsKinds = false
        return services
    }

    /// Ask {Tool} as Sam has it: Claude was asked last, so the buttons read
    /// Ask Claude, as the prototype draws them. Nothing is kept past the
    /// picture, no agent is reached and nothing opens.
    static var samsHandoff: HandoffServices {
        var handoff = HandoffServices.preview
        handoff.choices = .ephemeral()
        handoff.choices.lastTool = .claude
        handoff.choices.markTold(.claude)
        return handoff
    }

    /// Sam's Working On, its pages and searches (`WorkFixtures`), with
    /// Today's moments (`TodayRenderFixture`) said to belong to the same
    /// items by name, so Today's card shows "Part of" and Resume.
    static func snapshot(now: Date, calendar: Calendar) -> WorkSnapshot {
        let work = WorkFixtures.snapshot(now: now, calendar: calendar)
        var lookups = work.momentItems
        for item in TodayRenderFixture.work.items {
            guard let same = work.items.first(where: { $0.name == item.name }) else { continue }
            for moment in item.moments where lookups[moment] == nil { lookups[moment] = same.id }
        }
        for (moment, item) in historyItems where lookups[moment] == nil { lookups[moment] = item }
        // A page, search or AI chat read in an item's sessions is part of
        // it, as the agent says (`moment_items`): what each item saw
        // alongside.
        for item in work.items {
            for seen in item.alongside where lookups[seen.moment] == nil { lookups[seen.moment] = item.id }
        }
        return WorkSnapshot(generatedUs: work.generatedUs, items: work.items, pages: work.pages,
                            momentItems: lookups)
    }

    /// History's afternoon (`HistoryRenderFixture`) in the same items: the
    /// shop's editor, article and terminal, the checklist and the plan, so
    /// a moment's detail says "Part of trailhead-shop" where its caption
    /// doesn't already.
    static let historyItems: [UInt64: String] = [
        HistoryRenderFixture.editorId: WorkFixtures.trailheadShop, 70_104: WorkFixtures.trailheadShop,
        70_105: WorkFixtures.trailheadShop, 70_107: WorkFixtures.trailheadShop,
        HistoryRenderFixture.articleId: WorkFixtures.trailheadShop, 70_109: WorkFixtures.trailheadShop,
        HistoryRenderFixture.notesId: WorkFixtures.launchChecklist, 70_112: WorkFixtures.q4Planning,
    ]

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
    /// Today's moments, with what each window said and its screenshot.
    var today: (any BrainReader)?

    /// History and its lenses browse the day's moments. A browse of one app
    /// in a short window (Looked Up's "Opened next") reads Working On's
    /// moments too, where those pages are.
    func search(_ opts: SearchOptions) async throws -> [Hit] {
        let found = try await base.search(opts)
        guard opts.browse, opts.appFilter != nil, let from = opts.timeFromUs, let to = opts.timeToUs,
              to > from, to - from <= 3_600_000_000 else { return found }
        let known = Set(found.map(\.id))
        let more = ((try? await work.search(opts)) ?? []).filter { !known.contains($0.id) }
        return Array((found + more).sorted { $0.tsUs > $1.tsUs }.prefix(max(0, opts.limit)))
    }
    func recentEvents(limit: Int) async throws -> [Hit] { try await base.recentEvents(limit: limit) }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] {
        try await base.recentPrivacyMoments(limit: limit)
    }

    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] {
        try await base.listObservedApps(limit: limit, timeFromUs: timeFromUs)
    }

    func listEpisodes(limit: Int) async throws -> [Episode] { try await base.listEpisodes(limit: limit) }

    /// The readers asked by id, in order: Today's, the day's, Working On's.
    private var byId: [any BrainReader] { (today.map { [$0] } ?? []) + [base, work] }

    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] {
        var found: [UInt64: Hit] = [:]
        for reader in byId {
            let missing = ids.filter { found[$0] == nil }
            guard !missing.isEmpty else { break }
            for hit in (try? await reader.fetchEventsByIds(missing)) ?? [] where found[hit.id] == nil {
                found[hit.id] = hit
            }
        }
        return ids.compactMap { found[$0] }
    }

    func eventText(eventId: UInt64) async throws -> EventText? {
        for reader in byId {
            if let text = try? await reader.eventText(eventId: eventId) { return text }
        }
        return nil
    }

    func eventReading(eventId: UInt64, query: String?) async throws -> EventReading? {
        for reader in byId {
            if let reading = try? await reader.eventReading(eventId: eventId, query: query) { return reading }
        }
        return nil
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
