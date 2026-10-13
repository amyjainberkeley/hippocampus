#if DEBUG
import AppKit
import RecallUIKit
import SwiftUI

/// Draws the window's places and Ask's states to PNGs from fixtures:
/// `recall-ui --synthetic-preview --render-window=<dir>`.
///
/// It runs from `RecallEntryPoint` before the app starts, so no scene, no
/// window on screen, no menu-bar item and no activation is ever created: the
/// app is set to `.prohibited` first, each view is laid out in a borderless
/// window that is never ordered in, and drawn into a bitmap of its own size.
/// It reads fixtures only (`NativePreviewReader`, `PreviewUnderstandingReader`
/// and the moments below), never the person's memory.
@MainActor
enum WindowRenderer {
    static let flag = "--render-window="

    static func renderIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard arguments.contains("--synthetic-preview"),
              let value = arguments.first(where: { $0.hasPrefix(flag) })?.dropFirst(flag.count),
              !value.isEmpty
        else { return false }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: String(value), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let done = Flag()
        Task { @MainActor in
            for scene in scenes() {
                await render(scene, to: directory)
            }
            done.value = true
        }
        while !done.value {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return true
    }

    private final class Flag {
        var value = false
    }

    private struct Scene {
        let name: String
        var place: MemoryWorkspaceSelection = .ask
        var dark = false
        var understanding: PreviewUnderstandingReader.Scenario = .populated
        var size = CGSize(width: 1100, height: 720)
        var scale: CGFloat = 2
        var prepare: @MainActor (AskViewModel) async -> Void = { _ in }
    }

    private static func scenes() -> [Scene] {
        [
            Scene(name: "ask-history") { await $0.history.reload() },
            Scene(name: "ask-matches") { ask in
                ask.query = "rounding"
                await ask.search.runSearch()
            },
            Scene(name: "ask-answer") { ask in
                ask.query = "what changed in tax.rs"
                await ask.search.runSearch()
                ask.ask("what changed in tax.rs")
                await until { ask.answerState != .thinking(question: "what changed in tax.rs") }
            },
            Scene(name: "ask-answers-unavailable", understanding: .nomodel) { ask in
                ask.query = "what changed in tax.rs"
                await ask.search.runSearch()
                ask.ask("what changed in tax.rs")
                await until { ask.answerState != .thinking(question: "what changed in tax.rs") }
            },
            Scene(name: "ask-memory") { ask in
                ask.query = "rounding"
                await ask.search.runSearch()
                select(RenderFixtureReader.pageId, in: ask)
            },
            Scene(name: "ask-memory-also-open") { ask in
                ask.query = "subscribe"
                await ask.search.runSearch()
                select(RenderFixtureReader.pageId, in: ask)
            },
            Scene(name: "ask-code") { ask in
                ask.query = "order_total"
                await ask.search.runSearch()
                select(RenderFixtureReader.codeId, in: ask)
            },
            Scene(name: "ask-chat") { ask in
                ask.query = "running late"
                await ask.search.runSearch()
                select(RenderFixtureReader.chatId, in: ask)
            },
            // The public picture (assets/screenshots): a question answered with
            // its sources, and the moment it came from, read like the window.
            Scene(name: "hero-recall-ui", size: CGSize(width: 1280, height: 800), scale: 1) { ask in
                ask.query = "what changed in tax.rs"
                await ask.search.runSearch()
                ask.ask("what changed in tax.rs")
                await until { ask.answerState != .thinking(question: "what changed in tax.rs") }
                select(RenderFixtureReader.codeId, in: ask)
            },
            // The same, at the window's own size, for the website.
            Scene(name: "product-ask") { ask in
                ask.query = "what changed in tax.rs"
                await ask.search.runSearch()
                ask.ask("what changed in tax.rs")
                await until { ask.answerState != .thinking(question: "what changed in tax.rs") }
                select(RenderFixtureReader.codeId, in: ask)
            },
            Scene(name: "full-overview-light", place: .overview),
            Scene(name: "full-ask-light") { await $0.history.reload() },
            Scene(name: "full-you-light", place: .you),
            Scene(name: "full-overview-dark", place: .overview, dark: true),
            Scene(name: "full-ask-dark", dark: true) { await $0.history.reload() },
            Scene(name: "full-you-dark", place: .you, dark: true),
        ]
    }

    private static func select(_ id: UInt64, in ask: AskViewModel) {
        guard ask.search.hits.contains(where: { $0.id == id }) else { return }
        ask.search.selectedHitId = id
        ask.search.focusDetail()
    }

    /// Waits for `condition`, at most two seconds.
    private static func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<40 where !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func render(_ scene: Scene, to directory: URL) async {
        let base = NativePreviewReader(date: PreviewUnderstandingReader.sampleNow,
                                       now: PreviewUnderstandingReader.sampleNow,
                                       calendar: PreviewUnderstandingReader.sampleCalendar)
        let reader = RenderFixtureReader(base: base)
        let understanding = PreviewUnderstandingReader(scenario: scene.understanding)
        let now = base.now
        let calendar = base.calendar
        let model = AskViewModel(search: SearchViewModel(
                                    reader: reader,
                                    persistence: QueryPersistence(environment: ["MCI_EPHEMERAL_UI_STATE": "1"],
                                                                  store: NothingKept()),
                                    userDictionaryLoader: { .empty }),
                                 history: TimelineViewModel(reader: reader, pageSize: 200,
                                                            day: MemoryDay(date: now, calendar: calendar),
                                                            now: { now }),
                                 understanding: understanding,
                                 calendar: calendar)
        await scene.prepare(model)
        // A fresh saved status, as Hippocampus writes it while remembering.
        let stamp = ISO8601DateFormatter().string(from: now)
        let receipt = try? CaptureHealthReceipt.decode(Data("""
            {"schema_version": 1, "updated_at": "\(stamp)", "last_stored_frame_at": "\(stamp)",
             "stored_frame_count": 10, "stored_screenshot_count": 2}
            """.utf8))
        let remembering = SidebarStatus(receipt: receipt, now: now)
        let view = MemoryWorkspaceView(
            reader: reader, understanding: understanding,
            selection: .constant(scene.place),
            isSyntheticPreview: true,
            healthLoader: { receipt },
            contextExporter: { _ in "" },
            calendar: calendar,
            now: { now },
            ask: model,
            status: remembering
        )
        .environment(\.colorScheme, scene.dark ? .dark : .light)
        .environment(\.timeZone, calendar.timeZone)
        .frame(width: scene.size.width, height: scene.size.height)

        let size = NSSize(width: scene.size.width, height: scene.size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        // Never ordered in: the window only gives the views a place to lay out.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: scene.dark ? .darkAqua : .aqua)
        hosting.appearance = window.appearance
        window.contentView = hosting
        for _ in 0..<12 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
        hosting.layoutSubtreeIfNeeded()
        let scale = scene.scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? withoutMetadata(png).write(to: directory.appendingPathComponent("\(scene.name).png"))
        }
        window.contentView = nil
    }
}

/// The PNG without its metadata chunks (EXIF and text), so a picture that
/// is published says nothing but its pixels.
private func withoutMetadata(_ png: Data) -> Data {
    let bytes = [UInt8](png)
    guard bytes.count > 8 else { return png }
    var out = Array(bytes[0..<8])
    var offset = 8
    while offset + 12 <= bytes.count {
        let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        let end = offset + 12 + length
        guard end <= bytes.count else { return png }
        let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
        if !["eXIf", "tEXt", "iTXt", "zTXt"].contains(type) {
            out.append(contentsOf: bytes[offset..<end])
        }
        offset = end
    }
    return Data(out)
}

private final class NothingKept: KeyValueStore, Sendable {
    func data(forKey key: String) -> Data? { nil }
    func set(_ data: Data?, forKey key: String) {}
    func removeObject(forKey key: String) {}
}

/// The preview's moments plus three made-up windows whose text is stored the
/// way a classified window is (content, the separator, then the window's
/// chrome): a code editor, a chat and a web page. Nothing here is real.
struct RenderFixtureReader: BrainReader {
    // The code and the page are the two sources of the fixture answer
    // (`PreviewUnderstandingFixtures.answer`): same ids, times and titles.
    static let codeId: UInt64 = 90_188
    static let chatId: UInt64 = 90_302
    static let pageId: UInt64 = 90_175

    let base: NativePreviewReader
    private let extra: [Hit]

    init(base: NativePreviewReader) {
        self.base = base
        let nowUs = UInt64(base.now.timeIntervalSince1970 * 1_000_000)
        let separator = ReadableText.chromeSeparator
        let code = """
            use std::time::Duration;

            pub fn order_total(lines: &[Line]) -> Money {
                let subtotal: Money = lines.iter().map(|l| l.price * l.qty).sum();
                let tax = subtotal * TAX_RATE;
                round_half_even(subtotal + tax)
            }
            """ + separator + """
            EXPLORER
            TRAILHEAD-SHOP
            src
            cart.rs
            tax.rs
            main 0 errors, 2 warnings Ln 14, Col 37 UTF-8 Rust
            """
        let chat = """
            Are we still on for 3?
                Yes, running five minutes late
            See you there
            """ + separator + """
            Sam Lee
            iMessage
            """
        let page = """
            Rounding half to even
            Round half to even keeps order totals from drifting by a cent. Each tie goes to the even neighbour, so over many orders the errors cancel out.
            """ + separator + """
            Dev Notes
            Articles
            Subscribe
            """
        extra = [
            Hit(eventId: Self.pageId, tsUs: 1_791_828_960_000_000, appBundleId: "com.apple.Safari",
                windowTitle: "Rounding half to even \u{00B7} Dev Notes", url: "https://devnotes.example/rounding",
                ocrTextSnippet: page, source: "lexical", score: nil, sourceKind: "browser_page"),
            Hit(eventId: Self.codeId, tsUs: 1_791_829_940_000_000, appBundleId: "com.microsoft.VSCode",
                windowTitle: "tax.rs \u{2014} trailhead-shop", url: nil,
                ocrTextSnippet: code, source: "lexical", score: nil, sourceKind: "screen_ocr"),
            Hit(eventId: Self.chatId, tsUs: nowUs - 25 * 60_000_000, appBundleId: "com.apple.MobileSMS",
                windowTitle: "Sam Lee", url: nil,
                ocrTextSnippet: chat, source: "lexical", score: nil, sourceKind: "screen_ocr"),
        ]
    }

    private func all() async throws -> [Hit] {
        (try await base.recentEvents(limit: 1_000) + extra).sorted { $0.tsUs > $1.tsUs }
    }

    func search(_ opts: SearchOptions) async throws -> [Hit] {
        if opts.browse {
            return Array(try await all().filter { hit in
                (opts.timeFromUs.map { hit.tsUs >= $0 } ?? true) && (opts.timeToUs.map { hit.tsUs <= $0 } ?? true)
            }.prefix(max(0, opts.limit)))
        }
        // Any word that says something, as a search for a question does.
        let common: Set<String> = ["what", "when", "where", "who", "how", "did", "does", "the", "was", "and",
                                   "changed", "for", "with", "about"]
        let words = opts.text.lowercased().split(separator: " ").map(String.init)
            .filter { $0.count > 2 && !common.contains($0) }
        guard !words.isEmpty else { return [] }
        let fromBase = try await base.search(opts)
        let fromExtra = extra.filter { hit in
            let text = (hit.ocrTextSnippet + " " + (hit.windowTitle ?? "")).lowercased()
            return words.contains { text.contains($0) }
        }
        return Array((fromExtra.reversed() + fromBase.filter { hit in !fromExtra.contains { $0.id == hit.id } })
            .prefix(max(1, opts.limit)))
    }

    func recentEvents(limit: Int) async throws -> [Hit] { Array(try await all().prefix(limit)) }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { try await base.listEpisodes(limit: limit) }

    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] {
        let rows = try await all()
        return ids.prefix(32).compactMap { id in rows.first { $0.id == id } }
    }

    func eventText(eventId: UInt64) async throws -> EventText? {
        guard let hit = extra.first(where: { $0.id == eventId }) else {
            return try await base.eventText(eventId: eventId)
        }
        return try EventText(eventId: hit.id, tsUs: hit.tsUs, appBundleId: hit.appBundleId,
                             text: hit.ocrTextSnippet, isTruncated: false)
    }

    /// Cut where the store marked the window, and say where a search's words
    /// were, as the FFI's reading does.
    func eventReading(eventId: UInt64, query: String?) async throws -> EventReading? {
        guard let hit = extra.first(where: { $0.id == eventId }),
              let text = try await eventText(eventId: eventId) else {
            guard let text = try await base.eventText(eventId: eventId) else { return nil }
            return EventReading(stored: text)
        }
        let parts = ReadableText.parts(stored: text.text, sourceKind: hit.sourceKind)
        let words = (query ?? "").lowercased().split(separator: " ").map(String.init)
        var match: EventReading.Match?
        if !words.isEmpty {
            if words.allSatisfy({ parts.main.lowercased().contains($0) }) {
                match = .main
            } else if words.allSatisfy({ parts.rest.lowercased().contains($0) }) {
                match = .rest
            }
        }
        return try EventReading(eventId: hit.id, tsUs: hit.tsUs, appBundleId: hit.appBundleId,
                                sourceKind: hit.sourceKind, main: parts.main, rest: parts.rest,
                                matchIn: match, isTruncated: false)
    }

    func activityIntervals(startUs: UInt64, endUs: UInt64, limit: UInt32) async throws -> ActivityPage {
        try await base.activityIntervals(startUs: startUs, endUs: endUs, limit: limit)
    }

    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }
    func summaryStats() async throws -> SummaryStats { try await base.summaryStats() }
    func storageUsage() async throws -> StorageUsage? { nil }

    func timelineEvents(startTsUs: UInt64, endTsUs: UInt64, resolution: TimelineResolution) async throws -> [TimelineEvent] {
        try await base.timelineEvents(startTsUs: startTsUs, endTsUs: endTsUs, resolution: resolution)
    }
}
#endif
