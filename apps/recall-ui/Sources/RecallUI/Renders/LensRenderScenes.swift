#if DEBUG
import AppKit
import RecallUIKit
import SwiftUI

extension WindowRenderer {
    /// Library's lenses over History (SPEC-DELTA 1), drawn as the page under
    /// the field, 900 pt wide: Documents, Code with a moment open, and
    /// Conversations with its chips, light and dark; Conversations on Email;
    /// a lens with nothing in it yet. Sam's week, made up: the review's
    /// afternoon and a few windows from earlier days.
    static var lensScenes: [Scene] {
        var scenes: [Scene] = []
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            scenes += [
                LensRenderScene.scene("library-documents\(suffix)", dark: dark, .documents),
                LensRenderScene.scene("library-code\(suffix)", dark: dark, .code, opening: 71_005),
                LensRenderScene.scene("library-conversations\(suffix)", dark: dark, .conversations),
            ]
        }
        scenes += [
            LensRenderScene.scene("library-conversations-email", .conversations, filter: .email),
            LensRenderScene.scene("library-code-empty", .code, empty: true),
        ]
        return scenes
    }
}

@MainActor
enum LensRenderScene {
    static func scene(_ name: String, dark: Bool = false, _ lens: LibraryLens, opening: UInt64? = nil,
                      filter: ConversationFilter = .all, empty: Bool = false) -> WindowRenderer.Scene {
        .picture(name, size: CGSize(width: 900, height: 720), dark: dark) {
            await page(lens, opening: opening, filter: filter, empty: empty)
        }
    }

    static func page(_ lens: LibraryLens, opening: UInt64?, filter: ConversationFilter, empty: Bool) async -> AnyView {
        let now = PreviewUnderstandingReader.sampleNow
        let calendar = PreviewUnderstandingReader.sampleCalendar
        let base = NativePreviewReader(date: now, now: now, calendar: calendar)
        let fixtures = RenderFixtureReader(base: base, overviewMoments: OverviewPreviewBrainReader())
        guard let review = try? ReviewRenderFixture(base: fixtures, now: now) else { return AnyView(EmptyView()) }
        RenderLeftovers.keep(review)
        let reader = LensRenderReader(moments: empty ? [] : review.reader.moments + earlier(review.reader, now: now))
        let model = LibraryLensModel(lens: lens, reader: reader,
                                     deletions: MemoryDeletionSignal(center: NotificationCenter()))
        await model.reload()
        model.filter = filter
        if let opening {
            model.selectedHitId = opening
            model.focusDetail()
        }
        let page = LibraryLensView(model: model, reader: reader, work: PreviewWorkReader(snapshot: HistoryRenderScene.work),
                                   calendar: calendar, now: { now })
            .environment(\.screenshots, review.screenshots)
            .environment(\.forget, ForgetAction { _ in })
            .background(MCI.Color.background)
        return AnyView(page)
    }

    /// Windows from Sam's earlier days, text as read, some with the
    /// screenshot their kind of window keeps. Nothing here is real.
    static func earlier(_ review: ReviewRenderReader, now: Date) -> [ReviewRenderReader.Moment] {
        let nowUs = UInt64(now.timeIntervalSince1970 * 1_000_000)
        let hour: UInt64 = 3_600_000_000
        func shot(_ id: UInt64) -> String? { review.moments.first { $0.hit.id == id }?.hit.thumbnailPath }
        func moment(_ id: UInt64, hoursAgo: UInt64, _ app: String, _ title: String, caption: String,
                    url: String? = nil, picture: String? = nil, text: String) -> ReviewRenderReader.Moment {
            let ts = nowUs - hoursAgo * hour
            let hit = Hit(eventId: id, tsUs: ts, appBundleId: app, windowTitle: title, url: url,
                          ocrTextSnippet: String(text.prefix(280)), source: "recent", score: nil,
                          thumbnailPath: picture, sourceKind: "screen_ocr", thumbnailTsUs: picture == nil ? nil : ts,
                          caption: caption)
            return ReviewRenderReader.Moment(hit: hit, stored: text, main: text, rest: "")
        }
        return [
            // Documents
            moment(72_001, hoursAgo: 22, "com.google.Chrome", "Launch plan - Google Docs",
                   caption: "Working on \u{201C}Launch plan\u{201D}", url: "https://docs.google.com/document/d/launch",
                   picture: shot(ReviewRenderFixture.documentId),
                   text: "Launch plan\nBeta on October 20, everyone on October 27\nGift cards in two markets\nChangelog and a short video"),
            moment(72_002, hoursAgo: 75, "com.apple.iWork.Numbers", "Q4 budget",
                   caption: "Working on \u{201C}Q4 budget\u{201D}",
                   text: "Q4 budget\nHosting 1,200\nDesign 3,400\nLaunch video 2,000"),
            moment(72_003, hoursAgo: 340, "com.apple.Preview", "Northwind supply terms.pdf",
                   caption: "Reading \u{201C}Northwind supply terms\u{201D}",
                   text: "Northwind supply terms\nPayment is due 30 days after the invoice.\nPrices hold until March."),
            // Code
            moment(72_011, hoursAgo: 21, "com.microsoft.VSCode", "cart.rs \u{2014} trailhead-shop",
                   caption: "Working on cart.rs in trailhead-shop", picture: shot(71_005),
                   text: "pub fn add(&mut self, line: Line) {\n    self.lines.push(line);\n}"),
            moment(72_012, hoursAgo: 94, "com.apple.Terminal", "trailhead-shop \u{2014} zsh \u{2014} 160\u{00D7}40",
                   caption: "Working in Terminal: trailhead-shop", picture: shot(71_007),
                   text: "dev@studio trailhead-shop % cargo build\n   Compiling trailhead-shop v0.4.1"),
            moment(72_013, hoursAgo: 98, "com.google.Chrome", "Round order totals half to even \u{00B7} Pull Request #42",
                   caption: "Reviewing \u{201C}Round order totals half to even\u{201D}",
                   url: "https://github.com/northwind/trailhead-shop/pull/42",
                   text: "Round order totals half to even\nTotals now round once, at the end.\n6 checks passed"),
            // Conversations
            moment(72_021, hoursAgo: 29, "com.tinyspeck.slackmacgap", "design (Channel) - Northwind Studio - Slack",
                   caption: "Chatting in #design",
                   text: "Maya Chen 9:02 AM the new pricing mockups are up \u{00B7} Sam Lee 9:05 AM they look great"),
            moment(72_022, hoursAgo: 52, "com.anthropic.claudefordesktop", "Rounding modes for money",
                   caption: "Asking Claude about rounding modes",
                   text: "Which rounding mode should a checkout use for sales tax?\nMost payment processors round half to even on the final total."),
            moment(72_023, hoursAgo: 120, "com.apple.mail", "Re: Dinner after the launch",
                   caption: "Reading email: Re: Dinner after the launch",
                   text: "Jordan Lee\nThe corner table is booked for 7. See you there."),
        ]
    }
}

/// The review's afternoon and Sam's earlier days, read as the FFI reads
/// them: a browse is newest first, inside its time window and its apps.
struct LensRenderReader: BrainReader {
    let moments: [ReviewRenderReader.Moment]

    private var hits: [Hit] {
        moments.map(\.hit).sorted { $0.tsUs == $1.tsUs ? $0.id > $1.id : $0.tsUs > $1.tsUs }
    }

    func search(_ opts: SearchOptions) async throws -> [Hit] {
        guard opts.browse else { return [] }
        return Array(hits.filter { hit in
            (opts.appFilters.isEmpty || opts.appFilters.contains(hit.appBundleId ?? ""))
                && (opts.timeFromUs.map { hit.tsUs >= $0 } ?? true) && (opts.timeToUs.map { hit.tsUs <= $0 } ?? true)
        }.prefix(max(0, opts.limit)))
    }

    func recentEvents(limit: Int) async throws -> [Hit] { Array(hits.prefix(limit)) }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }
    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] { ids.compactMap { id in hits.first { $0.id == id } } }

    func eventReading(eventId: UInt64, query: String?) async throws -> EventReading? {
        guard let moment = moments.first(where: { $0.hit.id == eventId }) else { return nil }
        return try EventReading(eventId: eventId, tsUs: moment.hit.tsUs, appBundleId: moment.hit.appBundleId,
                                sourceKind: moment.hit.sourceKind, main: moment.main, rest: moment.rest,
                                matchIn: nil, isTruncated: false, caption: moment.hit.caption)
    }

    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }
    func summaryStats() async throws -> SummaryStats {
        SummaryStats(totalEvents: UInt64(moments.count), oldestTsUs: hits.last?.tsUs, newestTsUs: hits.first?.tsUs,
                     diskBytes: 0)
    }
}
#endif
