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
/// It reads fixtures only (`NativePreviewReader`, `PreviewUnderstandingReader`,
/// `OverviewPreviewBrainReader` and the moments below), never the person's
/// memory, and verdicts go nowhere (`VerdictInbox(directory: nil)`).
///
/// A picture cannot be clicked, so controls are drawn as the app shows them
/// (`isSyntheticPreview` false, as `RecallPreviewRenderer` draws the places):
/// nothing here is ever clicked, no route is applied, and every reader and
/// model the window is given is a fixture.
@MainActor
enum WindowRenderer {
    static let flag = "--render-window="
    /// `--render-scenes=history,ask-`: only the scenes whose names start so.
    static let scenesFlag = "--render-scenes="
    /// `--render-only=history-meaning`: the same, for one prefix.
    static let onlyFlag = "--render-only="

    static func renderIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard arguments.contains("--synthetic-preview"),
              let value = arguments.first(where: { $0.hasPrefix(flag) })?.dropFirst(flag.count),
              !value.isEmpty
        else { return false }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: String(value), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefixes = arguments.filter { $0.hasPrefix(scenesFlag) || $0.hasPrefix(onlyFlag) }
            .flatMap { argument in
                argument.dropFirst(argument.hasPrefix(scenesFlag) ? scenesFlag.count : onlyFlag.count)
                    .split(separator: ",").map(String.init)
            }
        let done = Flag()
        Task { @MainActor in
            for scene in scenes() where prefixes.isEmpty || prefixes.contains(where: scene.name.hasPrefix) {
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

    /// One picture. The window's own scenes are listed in `scenes()`; every
    /// other package adds its own in its `Renders/*.swift` file
    /// (`WindowRenderer.workScenes`, …), which `scenes()` appends, so no
    /// package edits this file to add a picture. A sheet, a note or a
    /// reading drawn alone is a `Scene.picture`; a note in a picture comes
    /// from its own `BottomNotes()`, never `.shared`, so it can't reach the
    /// next scene.
    struct Scene {
        let name: String
        var place: MemoryWorkspaceSelection = .ask
        var dark = false
        var understanding: PreviewUnderstandingReader.Scenario = .populated
        var size = CGSize(width: 1100, height: 720)
        var scale: CGFloat = 2
        /// Nothing is saved before today: the first day's welcome.
        var firstDay = false
        /// History reads the synthetic afternoon (`HistoryRenderFixture`),
        /// whose screenshots are drawn, sealed and opened as the app opens
        /// the person's own.
        var history = false
        /// Draw from `MeaningFixtureReader`: a made-up afternoon of windows
        /// read with their chrome, cleaned and captioned.
        var meaning = false
        /// Draw from `ReviewRenderFixture`: ten windows stored with their
        /// chrome, read and captioned as the FFI reads them, some with the
        /// screenshot their window kept.
        var review = false
        /// The window on Demo Memory, with its Demo tag by the title.
        var demoMemory = false
        var prepare: @MainActor (AskViewModel) async -> Void = { _ in }
        /// Draws this view in place of the window, at `size`, `scale` and in
        /// `dark`, under the same locale and time zone as every scene: a
        /// sheet, a note, a reading or a page drawn on its own. It is made
        /// from fixtures only, like everything here.
        var view: (@MainActor () async -> AnyView)?
        /// Whether Hippocampus is remembering, as the pipe would say;
        /// nil draws "Remembering", last saved a moment ago.
        var status: WindowStatus?
        /// What Working On holds; nil is Sam a week in
        /// (`ShellRenderFixture.weekIn`).
        var work: WorkSnapshot?
        /// Library's kinds that hold something; nil is all of them.
        var kinds: Set<SidebarPlace>?
        /// What a person would have done: a menu open, the pointer resting
        /// on an item, the narrow sidebar shown.
        var preset = WindowShellPreset()
        /// A note at the bottom, from the scene's own `BottomNotes`.
        var note: (@MainActor (BottomNotes) -> Void)?

        /// A picture of `view` alone, made from fixtures.
        static func picture(
            _ name: String, size: CGSize = CGSize(width: 1100, height: 720), dark: Bool = false,
            view: @escaping @MainActor () async -> AnyView
        ) -> Scene {
            var scene = Scene(name: name, dark: dark, size: size)
            scene.view = view
            return scene
        }
    }

    /// Every scene: the window's own, then each package's, in a fixed order.
    private static func scenes() -> [Scene] {
        ownScenes() + shellScenes + workScenes + readingScenes + sidePictureScenes + handoffScenes + resumeScenes
            + calendarScenes + demoScenes + libraryScenes
    }

    private static func ownScenes() -> [Scene] {
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
            // Where the person lands after setup: the first day, nothing
            // saved yet, remembering, no AI tool connected (Oct 18).
            Scene(name: "first-landing-light", place: .overview, understanding: .firstDay, firstDay: true),
            Scene(name: "first-landing-dark", place: .overview, dark: true, understanding: .firstDay, firstDay: true),
            // History's screenshots: the list, a moment showing the screenshot
            // its window kept a few minutes before, a moment with its own, a
            // text-only moment and one whose screenshot is gone.
            Scene(name: "history-list", history: true) { await $0.history.reload() },
            Scene(name: "history-list-all-rows", size: CGSize(width: 1100, height: 1180), history: true) {
                await $0.history.reload()
            },
            Scene(name: "history-moment", history: true) { ask in
                await ask.history.reload()
                selectInHistory(HistoryRenderFixture.editorId, in: ask)
            },
            Scene(name: "history-moment-own-screenshot", history: true) { ask in
                await ask.history.reload()
                selectInHistory(HistoryRenderFixture.chatId, in: ask)
            },
            Scene(name: "history-moment-text-only", history: true) { ask in
                await ask.history.reload()
                selectInHistory(HistoryRenderFixture.mailId, in: ask)
            },
            Scene(name: "history-moment-screenshot-gone", history: true) { ask in
                await ask.history.reload()
                selectInHistory(HistoryRenderFixture.notesId, in: ask)
            },
            Scene(name: "history-list-dark", dark: true, history: true) { await $0.history.reload() },
            Scene(name: "history-moment-dark", dark: true, history: true) { ask in
                await ask.history.reload()
                selectInHistory(HistoryRenderFixture.editorId, in: ask)
            },
            // History says what each moment was about, over clean text; the
            // moment shows its whole cleaned text, and the window's tabs and
            // bars under "Also in this window".
            Scene(name: "history-meaning-light", meaning: true) { ask in
                await ask.history.reload()
                selectInHistory(MeaningFixtureReader.accentsId, in: ask)
            },
            Scene(name: "history-meaning-dark", dark: true, meaning: true) { ask in
                await ask.history.reload()
                selectInHistory(MeaningFixtureReader.accentsId, in: ask)
            },
            Scene(name: "history-meaning-code-light", meaning: true) { ask in
                await ask.history.reload()
                selectInHistory(MeaningFixtureReader.codeId, in: ask)
            },
            // A tab title still finds the moment: the match is in the rest of
            // the window, which opens by itself.
            Scene(name: "history-meaning-search-tab-light", meaning: true) { ask in
                ask.query = "Trailhead"
                await ask.search.runSearch()
                select(MeaningFixtureReader.accentsId, in: ask)
            },
            // The review: History as a person looks back over an afternoon,
            // screenshots and clean text together. The whole list, then a
            // moment with a screenshot its window kept, one with text only,
            // a document, and one whose screenshot is gone.
            Scene(name: "review-list", size: CGSize(width: 1100, height: 2100), review: true) {
                await $0.history.reload()
            },
            Scene(name: "review-list-dark", dark: true, size: CGSize(width: 1100, height: 2100), review: true) {
                await $0.history.reload()
            },
            Scene(name: "review-moment-article", size: CGSize(width: 1280, height: 860), review: true) { ask in
                await ask.history.reload()
                selectInHistory(ReviewRenderFixture.articleId, in: ask)
            },
            Scene(name: "review-moment-article-dark", dark: true, size: CGSize(width: 1280, height: 860),
                  review: true) { ask in
                await ask.history.reload()
                selectInHistory(ReviewRenderFixture.articleId, in: ask)
            },
            Scene(name: "review-moment-chat", size: CGSize(width: 1280, height: 860), review: true) { ask in
                await ask.history.reload()
                selectInHistory(ReviewRenderFixture.slackId, in: ask)
            },
            Scene(name: "review-moment-chat-dark", dark: true, size: CGSize(width: 1280, height: 860),
                  review: true) { ask in
                await ask.history.reload()
                selectInHistory(ReviewRenderFixture.slackId, in: ask)
            },
            Scene(name: "review-moment-document", size: CGSize(width: 1280, height: 860), review: true) { ask in
                await ask.history.reload()
                selectInHistory(ReviewRenderFixture.documentId, in: ask)
            },
            Scene(name: "review-list-narrow", size: CGSize(width: 820, height: 1400), review: true) {
                await $0.history.reload()
            },
            Scene(name: "review-moment-terminal", size: CGSize(width: 1280, height: 860), review: true) { ask in
                await ask.history.reload()
                selectInHistory(ReviewRenderFixture.assistantId, in: ask)
            },
            Scene(name: "review-moment-terminal-dark", dark: true, size: CGSize(width: 1280, height: 860),
                  review: true) { ask in
                await ask.history.reload()
                selectInHistory(ReviewRenderFixture.assistantId, in: ask)
            },
            Scene(name: "review-moment-notes", size: CGSize(width: 1280, height: 860), review: true) { ask in
                await ask.history.reload()
                selectInHistory(ReviewRenderFixture.tallNotesId, in: ask)
            },
            Scene(name: "review-moment-gmail", size: CGSize(width: 1280, height: 860), review: true) { ask in
                await ask.history.reload()
                selectInHistory(ReviewRenderFixture.gmailId, in: ask)
            },
            Scene(name: "review-moment-gone", size: CGSize(width: 1280, height: 860), review: true) { ask in
                await ask.history.reload()
                selectInHistory(ReviewRenderFixture.notesId, in: ask)
            },
        ]
    }

    private static func select(_ id: UInt64, in ask: AskViewModel) {
        guard ask.search.hits.contains(where: { $0.id == id }) else { return }
        ask.search.selectedHitId = id
        ask.search.focusDetail()
    }

    private static func selectInHistory(_ id: UInt64, in ask: AskViewModel) {
        guard ask.history.hits.contains(where: { $0.id == id }) else { return }
        ask.history.selectedHitId = id
        ask.history.focusDetail()
    }

    /// Waits for `condition`, at most two seconds.
    private static func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<40 where !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func render(_ scene: Scene, to directory: URL) async {
        if let make = scene.view {
            let view = await make()
                .environment(\.controlActiveState, .key)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.colorScheme, scene.dark ? .dark : .light)
                .environment(\.timeZone, PreviewUnderstandingReader.sampleCalendar.timeZone)
                .frame(width: scene.size.width, height: scene.size.height)
            await draw(view, scene: scene, served: { 0 }, to: directory)
            return
        }
        let base = NativePreviewReader(date: PreviewUnderstandingReader.sampleNow,
                                       now: PreviewUnderstandingReader.sampleNow,
                                       calendar: PreviewUnderstandingReader.sampleCalendar)
        let overviewMoments = OverviewPreviewBrainReader()
        let fixtures = RenderFixtureReader(base: base, overviewMoments: overviewMoments)
        let history = scene.history ? try? HistoryRenderFixture(base: fixtures, now: base.now) : nil
        defer { history?.remove() }
        let review = scene.review ? try? ReviewRenderFixture(base: fixtures, now: base.now) : nil
        defer { review?.remove() }
        let reader: any BrainReader = scene.meaning
            ? MeaningFixtureReader(now: base.now)
            : review?.reader ?? history?.reader ?? fixtures
        let thumbnails = OverviewPreviewThumbnails(windows: overviewMoments.windows)
        // The sidebar's little screenshots: drawn, sealed and opened as the
        // app opens the person's own.
        let shell = try? ShellRenderFixture()
        defer { shell?.remove() }
        // Every picture comes from a fixture: drawn windows for Overview, the
        // synthetic encrypted afternoon for History. Nothing reaches the
        // person's screenshots or Keychain.
        let screenshots: any ThumbnailDataProviding = review?.screenshots ?? history?.screenshots ?? thumbnails
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
        let remembering = scene.status ?? ShellRenderFixture.remembering(now: now)
        // Sam's Working On, its pages, searches and calendar (lane C's
        // fixture), its screenshots drawn, sealed and opened as the app opens
        // the person's own. The shell's pages read it beside the day.
        let workFixture = try? WorkRenderFixture(now: now, calendar: calendar)
        if let workFixture {
            WorkRenders.adopt(workFixture)
            await workFixture.prewarm()
        }
        let world: any BrainReader = workFixture.map { ShellWorldReader(base: reader, work: $0.reader) } ?? reader
        let snapshot = scene.work ?? workFixture?.snapshot ?? ShellRenderFixture.weekIn(now: now)
        let services = ShellWorld.services(now: now, calendar: calendar)
        // Overview and You, read before drawing. Their deletion signals are
        // their own, so nothing from the app reaches them. On the first day
        // nothing is saved before today.
        let firstDay = scene.firstDay
        let overview = OverviewViewModel(understanding: understanding, selectedDate: now, calendar: calendar,
                                         healthLoader: { receipt }, now: { now },
                                         deletions: MemoryDeletionSignal(center: NotificationCenter()),
                                         savedBefore: { _ in
                                             guard firstDay else { throw UnderstandingError.unavailable }
                                             return false
                                         },
                                         reader: world, work: PreviewWorkReader(snapshot: snapshot),
                                         calendarReader: firstDay ? FixtureCalendar(access: .notAsked)
                                             : services.calendar,
                                         offers: EphemeralKeyValueStore())
        await overview.reload()
        let you = UserModelViewModel(understanding: understanding, verdicts: VerdictInbox(directory: nil),
                                     deletions: MemoryDeletionSignal(center: NotificationCenter()))
        await you.reload()
        var preset = scene.preset
        if preset.sidebar == nil {
            preset.sidebar = SidebarModel.make(snapshot: snapshot, kinds: scene.kinds ?? Set(SidebarPlace.libraryKinds),
                                               hides: preset.choices)
        }
        let notes = BottomNotes()
        scene.note?(notes)
        let allScreenshots = CombinedScreenshots(
            [screenshots] + (workFixture.map { [$0.screenshots as any ThumbnailDataProviding] } ?? []))
        let view = MemoryWorkspaceView(
            reader: world, understanding: understanding,
            work: PreviewWorkReader(snapshot: snapshot),
            selection: .constant(scene.place),
            isSyntheticPreview: false,
            healthLoader: { receipt },
            contextExporter: { _ in "" },
            calendar: calendar,
            now: { now },
            ask: model,
            overview: overview,
            you: you,
            status: remembering,
            isDemoMemory: scene.demoMemory,
            hides: SidebarHides(defaults: nil),
            drawsWindowControls: true,
            preset: preset,
            pictures: workFixture.map(ShellWorld.pictures) ?? shell?.pictures,
            services: services,
            notes: notes
        )
        .environment(\.controlActiveState, .key)
        .environment(\.overviewThumbnails, thumbnails)
        .environment(\.screenshots, allScreenshots)
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.colorScheme, scene.dark ? .dark : .light)
        .environment(\.timeZone, calendar.timeZone)
        .frame(width: scene.size.width, height: scene.size.height)

        await draw(view, scene: scene, served: {
            thumbnails.count + (history?.screenshots.count ?? 0) + (review?.screenshots.count ?? 0)
                + (shell?.screenshots.count ?? 0)
        }, to: directory)
    }

    /// Lays `view` out off screen and writes it as `<name>.png`. `served`
    /// counts the screenshots handed out so far: the picture is taken once
    /// they have stopped arriving.
    private static func draw(
        _ view: some View, scene: Scene, served: () -> Int, to directory: URL
    ) async {
        let size = NSSize(width: scene.size.width, height: scene.size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        // Never ordered in: the window only gives the views a place to lay out.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: scene.dark ? .darkAqua : .aqua)
        hosting.appearance = window.appearance
        window.contentView = hosting
        // Ready when the screenshots have stopped arriving (a screenshot is
        // read in two steps, its moment then its image), and never before
        // the views have had time to read their models.
        let started = Date()
        var drawn = -1
        var stableSince = started
        while Date().timeIntervalSince(started) < 8 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
            let count = served()
            if count != drawn {
                drawn = count
                stableSince = Date()
            } else if Date().timeIntervalSince(started) >= 1, Date().timeIntervalSince(stableSince) >= 0.5 {
                break
            }
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
    /// The moments behind Overview's sessions, with their screenshots.
    let overviewMoments: OverviewPreviewBrainReader
    private let extra: [Hit]

    init(base: NativePreviewReader, overviewMoments: OverviewPreviewBrainReader = OverviewPreviewBrainReader()) {
        self.base = base
        self.overviewMoments = overviewMoments
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
        return ids.prefix(32).compactMap { id in
            rows.first { $0.id == id } ?? overviewMoments.moments.first { $0.id == id }
        }
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

/// A made-up afternoon for the History renders. Each window's text is stored
/// the way the reader stored it, chrome and all: Chrome's tab strip from the
/// report, address and bookmarks bars, Slack's top bar and message box, VS
/// Code's tabs, side bar and status bar, and one window classified by the 0.3
/// reader. The Rust reader cleans it (`StatelessReading`), and captions are
/// what the re-clean job stores: two written by the on-device model, the rest
/// made from the title. Nothing here is real.
struct MeaningFixtureReader: BrainReader {
    static let accentsId: UInt64 = 7_001
    static let codeId: UInt64 = 7_004

    private struct Moment {
        let hit: Hit
        let reading: EventReading
    }

    private struct Window {
        let id: UInt64
        let minutesAgo: UInt64
        let app: String
        let title: String
        var url: String?
        var source = "screen_ocr"
        let text: String
        /// A line the on-device model wrote and the job kept (grounded in
        /// the text above); nil keeps the caption made from the title.
        var written: String?
    }

    private let moments: [Moment]

    init(now: Date) {
        let nowUs = UInt64(max(0, now.timeIntervalSince1970 * 1_000_000))
        let tabs = "T N 27 Trailhead - Sched \u{00D7} \u{2713} Q4 planning - Goo # launch-plan (Chan\u{2026}"
        let accents = """
            How to type accents on a Mac
            Click where you want to type, in any app.
            Press and hold a letter key, such as e or a.
            Choose an accent from the menu, or press its number.
            Or release the key to keep the plain letter.
            """
        let windows = [
            Window(id: Self.accentsId, minutesAgo: 2, app: "com.google.Chrome",
                   title: "How to type accents on a Mac - Apple Support", url: "https://support.example/type-accents",
                   text: "\(tabs)\n< > C support.example/type-accents \u{2606}\n\(accents)",
                   written: "Looking up how to type accents"),
            Window(id: 7_007, minutesAgo: 3, app: "com.google.Chrome",
                   title: "How to type accents on a Mac - Apple Support", url: "https://support.example/type-accents",
                   text: "\(tabs)\n< > C support.example/type-accents \u{2606}\nHow to type accents on a Mac\nClick where you want to type, in any app.",
                   written: "Looking up how to type accents"),
            Window(id: 7_002, minutesAgo: 9, app: "com.figma.Desktop", title: "Checkout redesign",
                   text: """
                       Hero
                       Big headline, one line of copy, one button
                       Three columns: what it reads, where it stays, what it costs
                       Pricing table below the fold
                       Footer with the install line
                       """ + ReadableText.chromeSeparator + "Drafts / Checkout redesign\nDesign Prototype Inspect",
                   written: "Planning a checkout redesign"),
            Window(id: 7_003, minutesAgo: 18, app: "com.tinyspeck.slackmacgap",
                   title: "launch-plan (Channel) - Northwind Studio - Slack",
                   text: """
                       Northwind Studio > Q Search Northwind Studio
                       Threads
                       Maya Chen 10:42 AM
                       Pushed the new onboarding flow to staging. The permissions step is now one screen.
                       Ravi Patel 10:47 AM
                       Looks good. One nit: the menu should say Turn on memory.
                       Direct messages
                       Message #launch-plan
                       """),
            Window(id: Self.codeId, minutesAgo: 31, app: "com.microsoft.VSCode", title: "tax.rs \u{2014} trailhead-shop",
                   text: """
                       tax.rs \u{00D7} cart.rs \u{00D7} main.rs \u{00D7}
                       EXPLORER
                       src > cart > tax.rs
                       pub fn order_total(lines: &[Line]) -> Money {
                           let subtotal: Money = lines.iter().map(|l| l.price * l.qty).sum();
                           round_half_even(subtotal + subtotal * TAX_RATE)
                       }
                       main 0 errors, 2 warnings Ln 14, Col 37 UTF-8 Rust
                       """),
            Window(id: 7_005, minutesAgo: 44, app: "com.google.Chrome",
                   title: "per seat vs tiered pricing - Google Search",
                   url: "https://www.google.com/search?q=per+seat+vs+tiered+pricing",
                   text: """
                       Pricing notes \u{00D7} Stripe Docs \u{00D7} Inbox (12) \u{00D7} +
                       < > C google.com/search?q=per+seat+vs+tiered+pricing \u{2606}
                       Gmail Images All Bookmarks
                       Per-seat or tiered? How to price a team plan
                       Most teams choose between charging for every seat and charging by tier.
                       A seat minimum is the usual compromise.
                       """),
            Window(id: 7_006, minutesAgo: 58, app: "com.apple.mail", title: "Invoice 4471 for phase two",
                   text: """
                       Invoice 4471 for phase two
                       Dana Whitfield
                       Phase two of the brand refresh is wrapped up, and the final files are in the shared folder.
                       The invoice for this phase is attached. Payment is due October 30.
                       """),
        ]
        moments = windows.compactMap { window in
            let tsUs = nowUs - window.minutesAgo * 60_000_000
            let stored = "[app=\(window.app) | title=\(window.title) | url=\(window.url ?? "?") | ts=2026-10-12T14:00:00.000Z]\n"
                + window.text
            let read = StatelessReading.read(stored: stored, source: window.source, app: window.app,
                                             title: window.title, url: window.url)
            let main = read?.main ?? window.text
            let rest = read?.rest ?? ""
            let caption = window.written ?? read?.caption
            let hit = Hit(eventId: window.id, tsUs: tsUs, appBundleId: window.app, windowTitle: window.title,
                          url: window.url, ocrTextSnippet: String(main.prefix(280)), source: "recent", score: nil,
                          sourceKind: window.source, caption: caption)
            guard let reading = try? EventReading(eventId: window.id, tsUs: tsUs, appBundleId: window.app,
                                                  sourceKind: window.source, main: main, rest: rest,
                                                  isTruncated: false, caption: caption,
                                                  blocks: read?.blocks ?? []) else { return nil }
            return Moment(hit: hit, reading: reading)
        }
    }

    private func found(_ query: String, in moment: Moment) -> EventReading.Match? {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        if words.allSatisfy({ moment.reading.main.lowercased().contains($0) }) { return .main }
        if words.allSatisfy({ moment.reading.rest.lowercased().contains($0) }) { return .rest }
        return nil
    }

    func search(_ opts: SearchOptions) async throws -> [Hit] {
        if opts.browse {
            return Array(moments.map(\.hit).filter { hit in
                (opts.timeFromUs.map { hit.tsUs >= $0 } ?? true) && (opts.timeToUs.map { hit.tsUs <= $0 } ?? true)
            }.prefix(max(0, opts.limit)))
        }
        // A match shows the line that holds the words, from the text or the
        // rest of the window, as the FFI's passage does.
        return moments.compactMap { moment -> Hit? in
            guard let match = found(opts.text, in: moment) else { return nil }
            let part = match == .main ? moment.reading.main : moment.reading.rest
            let word = opts.text.lowercased().split(separator: " ").first.map(String.init) ?? ""
            let line = part.split(whereSeparator: \.isNewline).first { $0.lowercased().contains(word) }.map(String.init) ?? part
            let hit = moment.hit
            return Hit(eventId: hit.eventId, tsUs: hit.tsUs, appBundleId: hit.appBundleId, windowTitle: hit.windowTitle,
                       url: hit.url, ocrTextSnippet: line, source: "lexical", score: 1, sourceKind: hit.sourceKind,
                       caption: hit.caption)
        }
    }

    func recentEvents(limit: Int) async throws -> [Hit] { Array(moments.map(\.hit).prefix(limit)) }
    func recentPrivacyMoments(limit: Int) async throws -> [PrivacyMoment] { [] }
    func listObservedApps(limit: Int, timeFromUs: UInt64?) async throws -> [ObservedApp] { [] }
    func listEpisodes(limit: Int) async throws -> [Episode] { [] }

    func fetchEventsByIds(_ ids: [UInt64]) async throws -> [Hit] {
        ids.prefix(32).compactMap { id in moments.first { $0.hit.id == id }?.hit }
    }

    func eventText(eventId: UInt64) async throws -> EventText? {
        guard let moment = moments.first(where: { $0.hit.id == eventId }) else { return nil }
        return try EventText(eventId: eventId, tsUs: moment.hit.tsUs, appBundleId: moment.hit.appBundleId,
                             text: moment.reading.text(includingRest: true), isTruncated: false)
    }

    func eventReading(eventId: UInt64, query: String?) async throws -> EventReading? {
        guard let moment = moments.first(where: { $0.hit.id == eventId }) else { return nil }
        let reading = moment.reading
        return try EventReading(eventId: eventId, tsUs: reading.tsUs, appBundleId: reading.appBundleId,
                                sourceKind: reading.sourceKind, main: reading.main, rest: reading.rest,
                                matchIn: query.flatMap { found($0, in: moment) }, isTruncated: false,
                                caption: reading.caption)
    }

    func briefForDate(_ dateLocal: String) async throws -> Brief? { nil }
    func latestBrief() async throws -> Brief? { nil }
    func briefDates(limit: Int) async throws -> [String] { [] }
    func summaryStats() async throws -> SummaryStats {
        SummaryStats(totalEvents: UInt64(moments.count), oldestTsUs: moments.last?.hit.tsUs,
                     newestTsUs: moments.first?.hit.tsUs, diskBytes: 0)
    }
}
#endif
