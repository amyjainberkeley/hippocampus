#if DEBUG
import AppKit
import RecallUIKit
import SwiftUI

extension WindowRenderer {
    /// History as Sam looks back over Monday afternoon (SPEC 3.4), drawn as
    /// the page under the field, 900 pt wide as in the 1100 pt window: one
    /// moment's detail with "Part of", its actions and the trash; four
    /// moments picked; another day with its Today button and Whole Day.
    /// From the review's fixture only: ten windows stored with their chrome,
    /// read and captioned as the FFI reads them.
    static var historyScenes: [Scene] {
        var scenes: [Scene] = []
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            scenes += [
                HistoryRenderScene.scene("nav-history-detail\(suffix)", dark: dark, .detail),
                HistoryRenderScene.scene("nav-history-multi\(suffix)", dark: dark, .multi),
            ]
        }
        scenes += [
            HistoryRenderScene.scene("nav-history-session", .session),
            HistoryRenderScene.scene("nav-history-empty-today", .emptyToday),
            HistoryRenderScene.scene("nav-history-oldest-day", .oldestDay),
        ]
        return scenes
    }
}

@MainActor
enum HistoryRenderScene {
    enum State { case detail, multi, session, emptyToday, oldestDay }

    static let now = PreviewUnderstandingReader.sampleNow
    static let calendar = PreviewUnderstandingReader.sampleCalendar

    static func scene(_ name: String, dark: Bool = false, _ state: State) -> WindowRenderer.Scene {
        .picture(name, size: CGSize(width: 900, height: 720), dark: dark) {
            await page(state)
        }
    }

    static func page(_ state: State) async -> AnyView {
        let now = PreviewUnderstandingReader.sampleNow
        let base = NativePreviewReader(date: now, now: now, calendar: calendar)
        let fixtures = RenderFixtureReader(base: base, overviewMoments: OverviewPreviewBrainReader())
        guard let review = try? ReviewRenderFixture(base: fixtures, now: now) else { return AnyView(EmptyView()) }
        RenderLeftovers.keep(review)
        let reader: any BrainReader = state == .emptyToday ? MomentlessReader() : review.reader
        let history = TimelineViewModel(reader: reader, pageSize: 200, day: MemoryDay(date: now, calendar: calendar),
                                        now: { now }, deletions: MemoryDeletionSignal(center: NotificationCenter()))
        switch state {
        case .detail:
            await history.reload()
            history.selectedHitId = ReviewRenderFixture.articleId
        case .multi:
            await history.reload()
            history.selection = [ReviewRenderFixture.articleId, ReviewRenderFixture.slackId, 71_004]
        case .session:
            // A session opened from Today: its own time, its newest moment picked.
            let nowUs = UInt64(now.timeIntervalSince1970 * 1_000_000)
            await history.show(day: MemoryDay(date: now, calendar: calendar),
                               around: (nowUs - 30 * 60_000_000)...(nowUs - 15 * 60_000_000), selecting: 71_005)
        case .emptyToday:
            await history.reload()
        case .oldestDay:
            // The day before Sam's first moment: nothing saved, and nothing older.
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
            await history.show(day: MemoryDay(date: yesterday, calendar: calendar))
        }
        history.focusDetail()
        let page = HistoryView(history: history, reader: reader, calendar: calendar, now: { now },
                               work: PreviewWorkReader(snapshot: work), open: { _ in }, retention: { .standard })
            .environment(\.screenshots, review.screenshots)
            .environment(\.forget, ForgetAction { _ in })
            .background(MCI.Color.background)
        return AnyView(page)
    }

    /// Working On for the afternoon: the article and the editor were part
    /// of trailhead-shop.
    static var work: WorkSnapshot {
        var snapshot = TodayRenderFixture.work
        snapshot.momentItems = [
            ReviewRenderFixture.articleId: "w_trailhead_shop", 71_002: "w_trailhead_shop",
            71_005: "w_trailhead_shop", 71_006: "w_trailhead_shop", 71_007: "w_trailhead_shop",
            ReviewRenderFixture.documentId: "w_q4_planning",
        ]
        return snapshot
    }
}

/// The review's afternoon with nothing saved yet today.
private struct MomentlessReader: BrainReader {
    func search(_ options: SearchOptions) async throws -> [Hit] { [] }
    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] { [] }
    func recentEvents(limit: Int) async throws -> [Hit] { [] }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }
    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }
    func summaryStats() async throws -> SummaryStats {
        SummaryStats(totalEvents: 0, oldestTsUs: nil, newestTsUs: nil, diskBytes: 0)
    }
}

/// The synthetic screenshots sealed for History's pictures. Scenes draw one
/// at a time, so a scene's folder is removed when the next one is made, and
/// the last when the renderer ends.
@MainActor
enum RenderLeftovers {
    private static var fixtures: [ReviewRenderFixture] = []
    private static var removesAtExit = false

    static func keep(_ fixture: ReviewRenderFixture) {
        removeAll()
        fixtures.append(fixture)
        guard !removesAtExit else { return }
        removesAtExit = true
        atexit {
            MainActor.assumeIsolated { RenderLeftovers.removeAll() }
        }
    }

    static func removeAll() {
        for fixture in fixtures { fixture.remove() }
        fixtures = []
    }
}
#endif
