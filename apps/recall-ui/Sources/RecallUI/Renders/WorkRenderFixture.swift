#if DEBUG
import AppKit
import RecallUIKit

/// Sam's week for the Working On renders (`WorkFixtures`): every moment's
/// drawn screen (`WorkScreens`) sealed with the capture helper's codec in a
/// private temporary folder, and opened by the window's own provider, as
/// History's renders open theirs. Nothing here is real, and the folder goes
/// when the scene is drawn.
@MainActor
final class WorkRenderFixture {
    let reader: WorkFixtureReader
    let screenshots: PrewarmedScreenshots
    let snapshot: WorkSnapshot
    let now: Date
    let calendar: Calendar
    private let store: SyntheticScreenshotStore

    init(now: Date = PreviewUnderstandingReader.sampleNow,
         calendar: Calendar = PreviewUnderstandingReader.sampleCalendar) throws {
        self.now = now
        self.calendar = calendar
        let store = try SyntheticScreenshotStore()
        self.store = store
        var sealed: [String: String] = [:]
        let moments = WorkFixtures.moments(now: now, calendar: calendar)
        for screen in Set(moments.compactMap(\.screen)) {
            if let image = WorkScreens.jpeg(screen) {
                sealed[screen] = try store.seal(image)
            }
        }
        let hits = moments.map { moment -> Hit in
            let hit = moment.hit
            let path = moment.screen.flatMap { sealed[$0] }
            return Hit(eventId: hit.eventId, tsUs: hit.tsUs, appBundleId: hit.appBundleId, windowTitle: hit.windowTitle,
                       url: hit.url, ocrTextSnippet: hit.ocrTextSnippet, source: hit.source, score: nil,
                       thumbnailPath: path, sourceKind: hit.sourceKind, thumbnailTsUs: path == nil ? nil : hit.tsUs,
                       caption: hit.caption)
        }
        // The article read as the FFI reads it: the golden blocks the Rust
        // tests check, so its detail is formatted as the prototype draws it.
        let article = ReadingRenderFixture.blocks("article.new")
        let blocks = Dictionary(moments.filter { $0.screen == "article" }.map { ($0.hit.eventId, article) },
                                uniquingKeysWith: { first, _ in first })
        reader = WorkFixtureReader(hits: hits, blocks: blocks)
        screenshots = PrewarmedScreenshots(store.provider())
        snapshot = WorkFixtures.snapshot(now: now, calendar: calendar)
    }

    /// Open every sealed screen once, through the window's own provider, so
    /// the picture is taken with every screenshot in place.
    func prewarm() async {
        for path in Set(reader.hits.compactMap(\.thumbnailPath)) {
            await screenshots.prewarm(URL(fileURLWithPath: path))
        }
    }

    /// Where the sealed screens are.
    var folder: URL { store.root }

    func remove() {
        store.remove()
    }
}

/// The renders' screenshots: each sealed screen opened once through the
/// window's provider (authenticated and decrypted as the person's are), then
/// handed out at once for any size, so a picture never waits on one.
final class PrewarmedScreenshots: ThumbnailDataProviding, @unchecked Sendable {
    private let inner: ThumbnailDataProvider
    private let lock = NSLock()
    private var opened: [String: Data] = [:]

    init(_ inner: ThumbnailDataProvider) {
        self.inner = inner
    }

    func prewarm(_ url: URL) async {
        guard let data = await inner.screenshotData(for: url) else { return }
        lock.withLock { opened[url.path] = data }
    }

    func thumbnailData(for url: URL, maxPixelSize: Int) async -> Data? {
        if let data = lock.withLock({ opened[url.path] }) { return data }
        return await inner.thumbnailData(for: url, maxPixelSize: maxPixelSize)
    }

    func screenshotData(for url: URL) async -> Data? {
        if let data = lock.withLock({ opened[url.path] }) { return data }
        return await inner.screenshotData(for: url)
    }
}

/// The renders' moments, read as the FFI reads them: by id, by time (newest
/// first, for Web Pages' fallback and Looked Up's "Opened next"), and as
/// text for the detail.
struct WorkFixtureReader: BrainReader {
    let hits: [Hit]
    /// What a moment read as the FFI's blocks, when the fixture has them.
    var blocks: [UInt64: [ReadingBlock]] = [:]

    func search(_ opts: SearchOptions) async throws -> [Hit] {
        let filtered = hits.filter { hit in
            (opts.timeFromUs.map { hit.tsUs >= $0 } ?? true) && (opts.timeToUs.map { hit.tsUs <= $0 } ?? true)
                && (opts.appFilter.map { hit.appBundleId == $0 } ?? true) && (!opts.hasUrl || hit.url != nil)
        }
        return Array(filtered.sorted { $0.tsUs > $1.tsUs }.prefix(max(0, opts.limit)))
    }

    func recentEvents(limit: Int) async throws -> [Hit] { Array(hits.prefix(limit)) }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }

    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] {
        ids.prefix(32).compactMap { id in hits.first { $0.id == id } }
    }

    func eventReading(eventId: UInt64, query: String?) async throws -> EventReading? {
        guard let hit = hits.first(where: { $0.id == eventId }) else { return nil }
        if let blocks = blocks[eventId], !blocks.isEmpty {
            return try EventReading(eventId: hit.id, tsUs: hit.tsUs, appBundleId: hit.appBundleId,
                                    sourceKind: hit.sourceKind, main: ReadingBlocks.plainText(blocks), rest: "",
                                    isTruncated: false, caption: hit.caption, blocks: blocks)
        }
        return try EventReading(eventId: hit.id, tsUs: hit.tsUs, appBundleId: hit.appBundleId,
                                sourceKind: hit.sourceKind, main: hit.ocrTextSnippet.replacingOccurrences(of: " \u{00B7} ", with: "\n"),
                                rest: "", isTruncated: false, caption: hit.caption)
    }

    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }

    func summaryStats() async throws -> SummaryStats {
        SummaryStats(totalEvents: UInt64(hits.count), oldestTsUs: hits.last?.tsUs, newestTsUs: hits.first?.tsUs,
                     diskBytes: 0)
    }
}
#endif
