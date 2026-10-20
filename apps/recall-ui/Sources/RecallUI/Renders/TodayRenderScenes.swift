#if DEBUG
import AppKit
import RecallUIKit
import SwiftUI

extension WindowRenderer {
    /// Today in each of its states (SPEC 3.1, SPEC-DELTA 5), drawn as the
    /// page under the field, 900 pt wide as in the 1100 pt window: Now; where
    /// you left off the next morning; paused; the first day, before and after
    /// its first moments; another day; no model; today's calendar over the
    /// strip with a meeting named after its event (`nav-today-*`). Sam's
    /// Monday, made up, from fixtures only.
    static var todayScenes: [Scene] {
        var scenes: [Scene] = []
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            scenes += [
                TodayRenderFixture.scene("nav-today-now\(suffix)", dark: dark),
                TodayRenderFixture.scene("nav-today-now-window\(suffix)", dark: dark, height: 668),
                TodayRenderFixture.scene("nav-today-left-off\(suffix)", dark: dark, state: .nextMorning, height: 760),
                TodayRenderFixture.scene("nav-today-first-day\(suffix)", dark: dark, state: .firstDay, height: 760),
                TodayRenderFixture.scene("nav-today-first-day-saved\(suffix)", dark: dark, state: .firstDaySaved,
                                         height: 860),
                TodayRenderFixture.scene("nav-today-past-day\(suffix)", dark: dark, state: .pastDay),
                TodayRenderFixture.scene("nav-today-no-model\(suffix)", dark: dark, state: .noModel),
                TodayRenderFixture.scene("nav-today-calendar\(suffix)", dark: dark, state: .calendar),
            ]
        }
        scenes += [
            TodayRenderFixture.scene("nav-today-paused", state: .paused),
            TodayRenderFixture.scene("nav-today-first-day-paused", state: .firstDayPaused, height: 760),
            TodayRenderFixture.scene("nav-today-hover", state: .hover, height: 760),
        ]
        return scenes
    }
}

/// Sam's Monday, October 12, 2026, as Today reads it, for the renders: the
/// contract samples, the moments behind their sessions with what each
/// window said, Working On's items, and a calendar. Nothing here is real.
@MainActor
enum TodayRenderFixture {
    enum State {
        case now, nextMorning, paused, firstDay, firstDaySaved, firstDayPaused, pastDay, noModel, calendar, hover
    }

    static let now = PreviewUnderstandingReader.sampleNow
    static let calendar = PreviewUnderstandingReader.sampleCalendar
    /// 8:43 the next morning.
    static let nextMorning = OverviewPreviewUnderstanding.nextMorningNow

    static func scene(_ name: String, dark: Bool = false, state: State = .now, height: CGFloat = 1_180)
        -> WindowRenderer.Scene {
        .picture(name, size: CGSize(width: 900, height: height), dark: dark) {
            await page(state)
        }
    }

    /// The status Hippocampus saves while remembering, or while paused.
    static func receipt(at date: Date, remembering: Bool = true) -> CaptureHealthReceipt? {
        let stamp = ISO8601DateFormatter().string(from: date)
        let blocked = remembering ? "" : #", "blocked_reason": "capture_disabled""#
        return try? CaptureHealthReceipt.decode(Data("""
            {"schema_version": 1, "updated_at": "\(stamp)", "last_stored_frame_at": "\(stamp)",
             "stored_frame_count": 10, "stored_screenshot_count": 2\(blocked)}
            """.utf8))
    }

    static func page(_ state: State) async -> AnyView {
        let moments = OverviewPreviewBrainReader()
        let thumbnails = OverviewPreviewThumbnails(windows: moments.windows)
        let clock: Date = (state == .nextMorning || state == .pastDay) ? nextMorning : now
        let understanding: UnderstandingReader = switch state {
        case .nextMorning, .pastDay: OverviewPreviewUnderstanding(.nextMorning)
        case .firstDay, .firstDaySaved, .firstDayPaused: PreviewUnderstandingReader(scenario: .firstDay)
        case .noModel: PreviewUnderstandingReader(scenario: .nomodel)
        default: PreviewUnderstandingReader()
        }
        let firstDay = [.firstDay, .firstDaySaved, .firstDayPaused].contains(state)
        let reader = TodayRenderReader(base: moments, firstDay: firstDay, savedSoFar: state == .firstDaySaved)
        let calendarReader: any CalendarReader = state == .calendar
            ? FixtureCalendar(access: .allowed, events: events) : FixtureCalendar(access: .notAsked)
        let remembering = state != .paused && state != .firstDayPaused
        let receipt = receipt(at: clock, remembering: remembering)
        let model = OverviewViewModel(
            understanding: understanding,
            selectedDate: state == .pastDay ? now : clock,
            calendar: calendar,
            healthLoader: { receipt },
            now: { clock },
            deletions: MemoryDeletionSignal(center: NotificationCenter()),
            savedBefore: { _ in !firstDay },
            reader: reader,
            work: PreviewWorkReader(snapshot: work),
            calendarReader: calendarReader,
            offers: EphemeralKeyValueStore())
        await model.reload()
        if state == .calendar, let meeting = model.blocks.first(where: { $0.kind == .meetings }) {
            model.select(meeting)
        }
        let hover: StripHover? = state == .hover ? model.blocks.first { $0.kind == .code }.map { .session($0.id) } : nil
        let page = TodayPlace(model: model, reader: reader, open: { _ in }, search: { _ in },
                              lookedUp: { _ in }, hover: hover, noticedOpen: false)
            .environment(\.overviewThumbnails, thumbnails)
            .environment(\.screenshots, thumbnails)
            .environment(\.forget, ForgetAction { _ in })
            .environment(\.todayStop, remembering ? nil : .paused)
            .background(MCI.Color.background)
        return AnyView(page)
    }

    /// The day's events: a stand-up, the design review's call, and an
    /// investor update later on.
    static var events: [CalendarEvent] {
        func at(_ hour: Int, _ minute: Int) -> Date {
            let day = calendar.startOfDay(for: now)
            return day.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
        }
        return [
            CalendarEvent(id: "standup", title: "Stand-up", start: at(9, 0), end: at(9, 15), calendarName: "Work"),
            CalendarEvent(id: "sync", title: "Team sync", start: at(13, 0), end: at(13, 30), calendarName: "Work",
                          location: "Zoom"),
            CalendarEvent(id: "investors", title: "Investor update", start: at(16, 0), end: at(16, 30),
                          calendarName: "Work"),
        ]
    }

    /// Working On, as the `work` read gives it for Sam's week.
    static var work: WorkSnapshot {
        func us(_ hour: Int, _ minute: Int) -> UInt64 {
            UInt64(calendar.startOfDay(for: now).timeIntervalSince1970 * 1_000_000)
                + UInt64(hour * 3_600 + minute * 60) * 1_000_000
        }
        let items = [
            WorkItem(id: "w_pricing_v3", kind: .design, name: "Trailhead pricing v3", apps: ["com.figma.Desktop"],
                     lastUs: us(14, 36), weekMinutes: 115, daysThisWeek: 3, moments: [90_269, 90_255, 90_253, 90_159],
                     thumbnailMoment: 90_253),
            WorkItem(id: "w_trailhead_shop", kind: .code, name: "trailhead-shop",
                     apps: ["com.microsoft.VSCode", "com.apple.Terminal"], lastUs: us(12, 19), weekMinutes: 160,
                     daysThisWeek: 3, folderGuess: "~/dev/trailhead-shop",
                     moments: [90_209, 90_207, 90_193, 90_188, 90_185, 90_170, 90_169], thumbnailMoment: 90_207),
            WorkItem(id: "w_q4_planning", kind: .document, name: "Q4 planning", apps: ["com.google.Chrome"],
                     lastUs: us(11, 5), weekMinutes: 70, daysThisWeek: 2),
            WorkItem(id: "w_launch_checklist", kind: .document, name: "Launch checklist", apps: ["com.apple.Notes"],
                     lastUs: us(10, 40), weekMinutes: 45, daysThisWeek: 2),
            WorkItem(id: "w_pricing_draft", kind: .document, name: "Pricing page draft", apps: ["com.apple.Notes"],
                     lastUs: us(14, 30), weekMinutes: 40, daysThisWeek: 2, moments: [90_258, 90_246, 90_165]),
        ]
        var lookups: [UInt64: String] = [:]
        for item in items { for moment in item.moments { lookups[moment] = item.id } }
        return WorkSnapshot(items: items, momentItems: lookups)
    }
}

/// The moments behind Sam's sessions, with what each window said and what it
/// was about, as History draws them. On the first day, the moments setup's
/// Try It read; before them, nothing.
struct TodayRenderReader: BrainReader {
    let base: OverviewPreviewBrainReader
    let firstDay: Bool
    let savedSoFar: Bool

    /// What a window said, and what its moment was about, by its title.
    private static let words: [String: (caption: String, text: String)] = [
        "Trailhead pricing v3": ("Designing \u{201C}Trailhead pricing v3\u{201D}",
                                 "Hero \u{00B7} One plan for every rider \u{00B7} Start free, then $18 a month for "
                                     + "the whole team \u{00B7} Ride \u{00B7} Tour \u{00B7} Club"),
        "Pricing page draft": ("Working on \u{201C}Pricing page draft\u{201D}",
                               "Hero \u{00B7} One plan for every rider. Start free, then $18 a month. Plans \u{00B7} "
                                   + "Ride: free, one bike, rentals only"),
        "tax.rs \u{2014} trailhead-shop": ("Working on tax.rs in trailhead-shop",
                                           "/// Rounds half to even, so totals never drift by a cent.\n"
                                               + "pub fn round_half_even(amount: Money) -> Money {"),
        "tax_tests.rs \u{2014} trailhead-shop": ("Working on tax_tests.rs in trailhead-shop",
                                                 "#[test]\nfn rounds_half_to_even() {"),
        "trailhead-shop \u{2014} cargo test": ("Working in Terminal: trailhead-shop",
                                               "dev@studio trailhead-shop % cargo test tax\n"
                                                   + "test result: ok. 6 passed; 0 failed"),
        "Rounding half to even \u{00B7} Dev Notes": ("Reading \u{201C}Rounding half to even\u{201D}",
                                                     "Why banker\u{2019}s rounding keeps order totals from drifting "
                                                         + "by a cent. Round half up looks fair, but every tie goes "
                                                         + "the same way."),
        "Pricing \u{00B7} Velo Cycles": ("Reading \u{201C}Pricing \u{00B7} Velo Cycles\u{201D}",
                                         "Three tiers for shops of every size. Pay per bike, billed yearly, and "
                                             + "switch tiers any time."),
        "Plans and pricing \u{00B7} Spoke & Chain": ("Reading \u{201C}Plans and pricing\u{201D}",
                                                     "Annual plans save two months. Every plan includes free "
                                                         + "tune-ups."),
        "Invoice 2291 from Spokewise": ("Reading email: Invoice 2291 from Spokewise",
                                        "Hi Sam, your October order is on its way. The invoice is attached."),
        "October invoices": ("Working on \u{201C}October invoices\u{201D}",
                             "Spokewise 2291 \u{00B7} $1,028.00 \u{00B7} due Oct 31"),
        "#shop-ops": ("Chatting in #shop-ops", "Jordan Lee 8:58 AM the Spokewise order is in, invoice in Mail"),
        "#design": ("Chatting in #design", "Maya Chen 10:02 AM plan cards look great, one nit on the Club price"),
        "Zoom Meeting": ("On a call in Zoom", "Maya Chen \u{00B7} Jordan Lee \u{00B7} Priya Shah"),
    ]

    /// What setup's Try It read on the first day: six moments in Safari.
    private var firstMoments: [Hit] {
        guard savedSoFar else { return [] }
        let nowUs = UInt64(PreviewUnderstandingReader.sampleNow.timeIntervalSince1970 * 1_000_000)
        let text = "Start with per-seat pricing for each user on your team. Volume pricing charges the same price "
            + "for every unit. Tiered pricing lowers the price as more seats are added."
        return (0..<6).map { index in
            Hit(eventId: 95_001 + UInt64(index), tsUs: nowUs - UInt64(index) * 40_000_000,
                appBundleId: "com.apple.Safari", windowTitle: "Per-seat or tiered? How to price a team plan",
                url: "https://pricingnotes.example/team-plans", ocrTextSnippet: text, source: "recent", score: nil,
                thumbnailPath: "/preview/keyframes/90235.bin", sourceKind: "browser_page",
                caption: "Reading \u{201C}Per-seat or tiered? How to price a team plan\u{201D}")
        }
    }

    private func enriched(_ hit: Hit) -> Hit {
        guard let title = hit.windowTitle, let words = Self.words[title] else { return hit }
        return Hit(eventId: hit.eventId, tsUs: hit.tsUs, appBundleId: hit.appBundleId, windowTitle: hit.windowTitle,
                   url: hit.url, ocrTextSnippet: words.text, source: "recent", score: nil,
                   thumbnailPath: hit.thumbnailPath, sourceKind: hit.sourceKind, caption: words.caption)
    }

    private var all: [Hit] {
        firstDay ? firstMoments : base.moments.map(enriched)
    }

    func search(_ opts: SearchOptions) async throws -> [Hit] {
        guard opts.browse else { return [] }
        return Array(all.filter { hit in
            (opts.timeFromUs.map { hit.tsUs >= $0 } ?? true) && (opts.timeToUs.map { hit.tsUs <= $0 } ?? true)
        }.sorted { $0.tsUs > $1.tsUs }.prefix(opts.limit))
    }

    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] {
        all.filter { ids.contains($0.eventId) }
    }

    func recentEvents(limit: Int) async throws -> [Hit] {
        Array(all.sorted { $0.tsUs > $1.tsUs }.prefix(limit))
    }

    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }
    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }

    func summaryStats() async throws -> SummaryStats {
        let rows = all
        return SummaryStats(totalEvents: UInt64(rows.count), oldestTsUs: rows.map(\.tsUs).min(),
                            newestTsUs: rows.map(\.tsUs).max(), diskBytes: 0)
    }
}
#endif
