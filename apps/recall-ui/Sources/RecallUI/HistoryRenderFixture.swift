#if DEBUG
import AppKit
import RecallUIKit

/// History for the off-screen renderer: one synthetic afternoon whose
/// screenshots are drawn (`SyntheticScreens`), sealed the way the capture
/// helper seals them and opened by the window's own `ThumbnailDataProvider`.
///
/// The moments are shaped like the real ones: a window keeps a screenshot
/// when it comes to the front and its later moments show that one (with the
/// time it was taken), windows beside the front one and mail are text only,
/// and one screenshot is gone from disk. Nothing here is real.
@MainActor
final class HistoryRenderFixture {
    /// A chat whose newest moment kept its own screenshot.
    static let chatId: UInt64 = 70_100
    /// The editor's newest moment: its screenshot was kept five minutes before.
    static let editorId: UInt64 = 70_103
    static let articleId: UInt64 = 70_108
    static let mailId: UInt64 = 70_110
    static let notesId: UInt64 = 70_111

    let reader: HistoryRenderReader
    let screenshots: CountingScreenshots
    private let store: SyntheticScreenshotStore

    init(base: RenderFixtureReader, now: Date) throws {
        let store = try SyntheticScreenshotStore()
        var paths: [SyntheticScreens.Screen: String] = [:]
        for screen in SyntheticScreens.Screen.allCases {
            guard let image = SyntheticScreens.jpeg(screen) else { continue }
            paths[screen] = try store.seal(image)
        }
        let nowUs = UInt64(now.timeIntervalSince1970 * 1_000_000)
        func ago(_ minutes: Double) -> UInt64 { nowUs - UInt64(minutes * 60_000_000) }

        let separator = ReadableText.chromeSeparator
        var moments: [(Hit, main: String, rest: String, stored: String)] = []
        /// A row as the FFI gives it: the start of what was read, never the
        /// window's chrome, and the caption made from the title.
        func add(_ id: UInt64, _ minutes: Double, _ app: String, _ title: String, url: String? = nil,
                 kind: String, screen: SyntheticScreens.Screen? = nil, takenMinutes: Double? = nil,
                 path: String? = nil, main: String, rest: String = "") {
            let shot = path ?? screen.flatMap { paths[$0] }
            let caption = StatelessReading.read(stored: "", source: kind, app: app, title: title, url: url)?.caption
            let hit = Hit(eventId: id, tsUs: ago(minutes), appBundleId: app, windowTitle: title, url: url,
                          ocrTextSnippet: String(main.prefix(280)), source: "recent",
                          score: nil, thumbnailPath: shot, sourceKind: kind,
                          thumbnailTsUs: shot == nil ? nil : ago(takenMinutes ?? minutes),
                          caption: MomentRowText.caption(caption))
            moments.append((hit, main, rest, rest.isEmpty ? main : main + separator + rest))
        }

        let chat = "Are we still on for 3?\nYes, running five minutes late\nNo rush. I grabbed the corner table\n"
            + "See you there\nBringing the printouts"
        add(Self.chatId, 9, "com.apple.MobileSMS", "Sam Lee", kind: "screen_ocr", screen: .chat,
            main: chat, rest: "Sam Lee\niMessage")
        add(70_101, 11, "com.apple.iCal", "Calendar", kind: "screen_context",
            main: "Design review 1:00 \u{2013} 2:00 PM\nLaunch sync 4:00 \u{2013} 4:30 PM\nDinner with Maya 7:00 PM",
            rest: "Day  Week  Month  Year\nToday")
        let code = """
            pub fn order_total(lines: &[Line]) -> Money {
                let subtotal: Money = lines.iter().map(|l| l.price * l.qty).sum();
                let tax = subtotal * TAX_RATE;
                round_half_even(subtotal + tax)
            }
            """
        let editorChrome = "EXPLORER\nTRAILHEAD-SHOP\nsrc\ncart.rs\ntax.rs\nmain 0 errors, 2 warnings Ln 21, Col 36 UTF-8 Rust"
        for (id, minutes) in [(Self.editorId, 14.0), (70_104, 16.0)] {
            add(id, minutes, "com.microsoft.VSCode", "tax.rs \u{2014} trailhead-shop", kind: "screen_ocr",
                screen: .editor, takenMinutes: 19, main: code, rest: editorChrome)
        }
        add(70_105, 19, "com.microsoft.VSCode", "tax.rs \u{2014} trailhead-shop", kind: "screen_ocr",
            screen: .editor, main: "/// Rounds half to even, so totals never drift by a cent.\n"
                + "pub fn round_half_even(amount: Money) -> Money {", rest: editorChrome)
        add(70_106, 21, "com.tinyspeck.slackmacgap", "#launch", kind: "screen_context",
            main: "Jordan: staging is green, shipping the rounding fix at 4\nPriya: I\u{2019}ll update the changelog",
            rest: "Threads\nChannels\n#launch")
        let article = """
            Rounding half to even
            Why banker\u{2019}s rounding keeps order totals from drifting by a cent
            Round half up looks fair, but every tie goes the same way. Over thousands of orders the extra half \
            cents add up, and the books stop matching the bank by a few dollars a month.
            """
        let articleChrome = "Dev Notes\nArticles\nTopics\nAbout\nSubscribe"
        add(70_107, 24, "com.google.Chrome", "Rounding half to even \u{00B7} Dev Notes",
            url: "https://devnotes.example/rounding", kind: "browser_page_with_ocr", screen: .article,
            takenMinutes: 27, main: article, rest: articleChrome)
        add(Self.articleId, 27, "com.google.Chrome", "Rounding half to even \u{00B7} Dev Notes",
            url: "https://devnotes.example/rounding", kind: "browser_page_with_ocr", screen: .article,
            main: article, rest: articleChrome)
        add(70_109, 35, "com.apple.Terminal", "trailhead-shop \u{2014} zsh", kind: "screen_ocr", screen: .terminal,
            main: "cargo test tax\nrunning 6 tests\ntest tax::tests::rounds_half_to_even ... ok\n"
                + "test result: ok. 6 passed; 0 failed")
        add(Self.mailId, 41, "com.apple.mail", "Invoice 1042 from Northwind Supplies", kind: "structured_app",
            main: "Invoice 1042 from Northwind Supplies\nAmount due: $1,240.00\nDue October 30\n"
                + "Thanks for your order. The invoice is attached.")
        add(Self.notesId, 48, "com.apple.Notes", "Launch checklist", kind: "screen_ocr", path: store.missingPath,
            main: "Launch checklist\nRounding fix merged\nChangelog updated\nGift card copy reviewed")
        add(70_112, 55, "com.google.Chrome", "Q4 planning - Google Docs",
            url: "https://docs.google.com/document/d/q4-planning/edit", kind: "browser_page_with_ocr",
            screen: .document,
            main: "Q4 planning\nGoals\nShip the rounding fix before the holiday sale\n"
                + "Cut checkout to under 30 seconds on mobile\nLaunch gift cards in two markets",
            rest: "File Edit View Insert Format Tools Extensions Help\nShare")

        self.store = store
        screenshots = CountingScreenshots(store.provider())
        reader = HistoryRenderReader(base: base, moments: moments.map {
            HistoryRenderReader.Moment(hit: $0.0, main: $0.main, rest: $0.rest, stored: $0.stored)
        })
    }

    func remove() {
        store.remove()
    }
}

/// The window's provider, counting the images it has served so the renderer
/// draws once they stop arriving.
final class CountingScreenshots: ThumbnailDataProviding, @unchecked Sendable {
    private let inner: ThumbnailDataProvider
    private let lock = NSLock()
    private var served = 0

    init(_ inner: ThumbnailDataProvider) {
        self.inner = inner
    }

    var count: Int { lock.withLock { served } }

    func thumbnailData(for url: URL, maxPixelSize: Int) async -> Data? {
        let data = await inner.thumbnailData(for: url, maxPixelSize: maxPixelSize)
        lock.withLock { served += 1 }
        return data
    }

    func screenshotData(for url: URL) async -> Data? {
        let data = await inner.screenshotData(for: url)
        lock.withLock { served += 1 }
        return data
    }
}

/// The renderer's fixtures, with History's moments read from the synthetic
/// afternoon: newest first, a day at a time, by id, and as text.
struct HistoryRenderReader: BrainReader {
    struct Moment: Sendable {
        let hit: Hit
        let main: String
        let rest: String
        /// The text as the store keeps it: what was read, then the chrome.
        let stored: String
    }

    let base: RenderFixtureReader
    let moments: [Moment]

    private var hits: [Hit] { moments.map(\.hit).sorted { $0.tsUs > $1.tsUs } }

    func search(_ opts: SearchOptions) async throws -> [Hit] {
        guard opts.browse else { return try await base.search(opts) }
        return Array(hits.filter { hit in
            (opts.timeFromUs.map { hit.tsUs >= $0 } ?? true) && (opts.timeToUs.map { hit.tsUs <= $0 } ?? true)
        }.prefix(max(0, opts.limit)))
    }

    func recentEvents(limit: Int) async throws -> [Hit] { Array(hits.prefix(limit)) }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { try await base.listEpisodes(limit: limit) }

    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] {
        ids.compactMap { id in hits.first { $0.id == id } }
    }

    func eventText(eventId: UInt64) async throws -> EventText? {
        guard let moment = moments.first(where: { $0.hit.id == eventId }) else { return nil }
        return try EventText(eventId: eventId, tsUs: moment.hit.tsUs, appBundleId: moment.hit.appBundleId,
                             text: moment.stored, isTruncated: false)
    }

    func eventReading(eventId: UInt64, query: String?) async throws -> EventReading? {
        guard let moment = moments.first(where: { $0.hit.id == eventId }) else { return nil }
        return try EventReading(eventId: eventId, tsUs: moment.hit.tsUs, appBundleId: moment.hit.appBundleId,
                                sourceKind: moment.hit.sourceKind, main: moment.main, rest: moment.rest,
                                matchIn: nil, isTruncated: false, caption: moment.hit.caption)
    }

    func activityIntervals(startUs: UInt64, endUs: UInt64, limit: UInt32) async throws -> ActivityPage {
        try await base.activityIntervals(startUs: startUs, endUs: endUs, limit: limit)
    }

    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }
    func summaryStats() async throws -> SummaryStats { try await base.summaryStats() }
    func storageUsage() async throws -> StorageUsage? { nil }

    func timelineEvents(startTsUs: UInt64, endTsUs: UInt64, resolution: TimelineResolution) async throws
        -> [TimelineEvent] {
        try await base.timelineEvents(startTsUs: startTsUs, endTsUs: endTsUs, resolution: resolution)
    }
}
#endif
