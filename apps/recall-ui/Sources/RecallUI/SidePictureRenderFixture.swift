#if DEBUG
import AppKit
import RecallUIKit

/// History with pictures of the windows beside the one in front (SPEC 6), for
/// the off-screen renderer: the made-up afternoon of Sam, with the windows
/// beside the one in front pictured as the capture helper keeps them now,
/// drawn, sealed with the helper's codec and opened by the window's own
/// provider. Every word and every pixel is made up.
///
/// Each side picture looks as the helper makes it: the window's own part of
/// the display, at most 1,600 pixels across, its rounded corners and every
/// part another window covered filled flat with the helper's neutral grey.
/// The moments follow the brain's borrowing rule: a side moment shows its
/// own picture or its window's newest side picture at most five minutes
/// older, never a front-window screenshot.
@MainActor
final class SidePictureRenderFixture {
    /// Slack beside the article, its picture kept with this moment.
    static let slackId: UInt64 = 72_003
    /// Figma beside the editor: the editor covered part of it.
    static let figmaId: UInt64 = 72_006
    /// Three days ago, Slack beside the editor: its picture thinned out.
    static let thinnedId: UInt64 = 72_104

    let reader: SidePictureRenderReader
    let screenshots: PreopenedScreenshots
    /// The day History opens on for the thinned scene.
    let thinnedDay: Date
    private let store: SyntheticScreenshotStore

    init(base: RenderFixtureReader, now: Date) async throws {
        let store = try SyntheticScreenshotStore()
        func seal(_ data: Data?) throws -> String? { try data.map { try store.seal($0) } }
        let article = try seal(SyntheticScreens.jpeg(.article))
        let editor = try seal(SyntheticScreens.jpeg(.editor))
        let slack = try seal(SidePictures.slack(messages: SidePictures.launchToday))
        let notes = try seal(SidePictures.notes())
        let figma = try seal(SidePictures.figma(covered: CGRect(x: 0, y: 610, width: 720, height: 490)))
        let slackFriday = try seal(SidePictures.slack(messages: SidePictures.launchFriday))
        let calendar = try seal(SidePictures.calendar())

        let nowUs = UInt64(now.timeIntervalSince1970 * 1_000_000)
        func ago(_ minutes: Double) -> UInt64 { nowUs - UInt64(minutes * 60_000_000) }
        var moments: [SidePictureRenderReader.Moment] = []
        func add(_ id: UInt64, _ tsUs: UInt64, _ app: String, _ title: String, url: String? = nil,
                 kind: String, shot: String? = nil, takenUs: UInt64? = nil, text: String) {
            let stored = "[app=\(app) | title=\(title) | url=\(url ?? "?") | ts=2026-10-12T14:00:00.000Z]\n" + text
            let read = StatelessReading.read(stored: stored, source: kind, app: app, title: title, url: url)
            let main = read?.main ?? ReadableText.guarded(text)
            let rest = read?.rest ?? ""
            let hit = Hit(eventId: id, tsUs: tsUs, appBundleId: app, windowTitle: title, url: url,
                          ocrTextSnippet: ReadableText.guarded(String((main.isEmpty ? rest : main).prefix(280))),
                          source: "recent", score: nil, thumbnailPath: shot, sourceKind: kind,
                          thumbnailTsUs: shot == nil ? nil : (takenUs ?? tsUs),
                          caption: MomentRowText.caption(read?.caption))
            moments.append(SidePictureRenderReader.Moment(hit: hit, stored: stored, main: main, rest: rest,
                                                     blocks: read?.blocks ?? []))
        }

        // Today. Chrome in front with its own screenshot.
        let articleText = """
            Rounding half to even
            Why banker\u{2019}s rounding keeps order totals from drifting by a cent
            Round half up looks fair, but every tie goes the same way. Over thousands of orders the extra
            half cents add up, and the books stop matching the bank by a few dollars a month.
            """
        add(72_001, ago(1.5), "com.google.Chrome", "Rounding half to even \u{00B7} Dev Notes",
            url: "https://devnotes.example/rounding", kind: "browser_page_with_ocr", shot: article,
            text: articleText)
        // Slack beside it: its own picture.
        add(Self.slackId, ago(4), "com.tinyspeck.slackmacgap", "launch (Channel) - Northwind Studio - Slack",
            kind: "screen_context", shot: slack, text: SidePictures.launchTodayText)
        // Notes beside it.
        add(72_004, ago(6.5), "com.apple.Notes", "Launch checklist", kind: "screen_context", shot: notes, text: """
            Launch checklist
            Rounding fix merged
            Changelog updated
            Gift card copy reviewed
            Beta group told about 0.4
            """)
        // The editor in front.
        add(72_005, ago(9), "com.microsoft.VSCode", "tax.rs \u{2014} trailhead-shop", kind: "screen_ocr",
            shot: editor, text: """
                pub fn order_total(lines: &[Line]) -> Money {
                    let subtotal: Money = lines.iter().map(|l| l.price * l.qty).sum();
                    let tax = subtotal * TAX_RATE;
                    round_half_even(subtotal + tax)
                }
                """)
        // Figma beside the editor, which covered part of it.
        add(Self.figmaId, ago(11), "com.figma.Desktop", "Pricing page", kind: "screen_context", shot: figma, text: """
            Pricing page
            One plan for every team
            Start free, then $18 a seat each month, billed annually
            Free \u{00B7} Team \u{00B7} Business
            Three plans side by side, the team plan in the middle
            """)
        // Calendar beside the editor: its text did not change enough for a
        // new picture, so it shows the one its window kept three minutes
        // before (a side moment borrows only its own window's side picture).
        add(72_007, ago(13), "com.apple.iCal", "Calendar", kind: "screen_context", shot: calendar,
            takenUs: ago(16), text: """
            Design review 3:00 \u{2013} 3:30 PM
            Launch sync 4:00 \u{2013} 4:30 PM
            Dinner with Maya 7:00 PM
            """)
        add(72_008, ago(16), "com.apple.iCal", "Calendar", kind: "screen_context", shot: calendar, text: """
            Design review 3:00 \u{2013} 3:30 PM
            Launch sync 4:00 \u{2013} 4:30 PM
            """)

        // Three days ago: older pictures are thinned out, one per window per
        // 15 minutes. A thinned moment shows the app tile; its text stays.
        let friday = now.addingTimeInterval(-3 * 86_400)
        let fridayUs = UInt64(friday.timeIntervalSince1970 * 1_000_000)
        func fridayAt(_ minutes: Double) -> UInt64 { fridayUs - UInt64(minutes * 60_000_000) }
        add(72_101, fridayAt(20), "com.microsoft.VSCode", "cart.rs \u{2014} trailhead-shop", kind: "screen_ocr",
            shot: editor, text: "pub fn add_line(cart: &mut Cart, line: Line) {\n    cart.lines.push(line);\n}")
        add(72_102, fridayAt(24), "com.tinyspeck.slackmacgap", "launch (Channel) - Northwind Studio - Slack",
            kind: "screen_context", shot: slackFriday, text: SidePictures.launchFridayText)
        add(72_103, fridayAt(27), "com.apple.Notes", "Launch checklist", kind: "screen_context", text: """
            Launch checklist
            Rounding fix merged
            Changelog updated
            """)
        add(Self.thinnedId, fridayAt(33), "com.tinyspeck.slackmacgap", "launch (Channel) - Northwind Studio - Slack",
            kind: "screen_context", text: """
                Jordan Lee 1:58 PM
                Rounding fix is in review, should land today
                Priya Shah 2:01 PM
                I\u{2019}ll draft the changelog once it does
                """)
        add(72_105, fridayAt(41), "com.google.Chrome", "per seat vs tiered pricing - Google Search",
            url: "https://www.google.com/search?q=per+seat+vs+tiered+pricing", kind: "screen_context", text: """
                Per-seat or tiered? How to price a team plan
                Most teams choose between charging for every seat and charging by tier.
                """)

        self.store = store
        thinnedDay = friday
        reader = SidePictureRenderReader(base: base, moments: moments)
        // Every picture is opened once through the window's own provider,
        // as the app opens the person's screenshots, before anything draws.
        let provider = store.provider()
        var opened: [String: Data] = [:]
        for path in [article, editor, slack, notes, figma, slackFriday, calendar].compactMap({ $0 }) {
            if let data = await provider.screenshotData(for: URL(fileURLWithPath: path)) { opened[path] = data }
        }
        screenshots = PreopenedScreenshots(opened)
    }

    func remove() {
        store.remove()
    }
}

/// The pictures, already opened: drawing never waits on one.
final class PreopenedScreenshots: ThumbnailDataProviding, @unchecked Sendable {
    private let images: [String: Data]

    init(_ images: [String: Data]) {
        self.images = images
    }

    func thumbnailData(for url: URL, maxPixelSize: Int) async -> Data? { images[url.path] }
    func screenshotData(for url: URL) async -> Data? { images[url.path] }
}

/// The side-picture afternoon as a reader: newest first, a day at a time,
/// by id, as stored text and as the reading the FFI gives.
struct SidePictureRenderReader: BrainReader {
    struct Moment: Sendable {
        let hit: Hit
        let stored: String
        let main: String
        let rest: String
        /// `main` as the reader's typed blocks (SPEC 4.2).
        var blocks: [ReadingBlock] = []
    }

    let base: RenderFixtureReader
    let moments: [Moment]

    private var hits: [Hit] { moments.map(\.hit).sorted { $0.tsUs > $1.tsUs } }

    func search(_ opts: SearchOptions) async throws -> [Hit] {
        guard opts.browse else { return [] }
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
                                matchIn: nil, isTruncated: false, caption: moment.hit.caption,
                                blocks: moment.blocks)
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

/// Drawn pictures of side windows, as the capture helper keeps them. Each
/// window is 1,600 pixels across, its corners and any covered part filled
/// with the helper's neutral grey (142, 142, 147).
@MainActor
enum SidePictures {
    static let size = CGSize(width: 1600, height: 1100)
    /// The helper's mask colour and its corner radius at this scale.
    private static let mask = NSColor(srgbRed: 142 / 255, green: 142 / 255, blue: 147 / 255, alpha: 1)
    private static let cornerRadius: CGFloat = 38

    static let launchToday: [(String, String, String, UInt32)] = [
        ("Jordan Lee", "2:14 PM", "staging is green, shipping the rounding fix at 4", 0x2F7D6D),
        ("Priya Shah", "2:15 PM", "I\u{2019}ll update the changelog before then", 0x7A4FA0),
        ("Maya Chen", "2:21 PM", "Gift card copy is in the doc, ready for a last look", 0xC2573A),
        ("Ravi Patel", "2:24 PM", "Pricing page is up for review, the team plan in the middle", 0x2563EB),
        ("Jordan Lee", "2:30 PM", "Rounding fix is out. Totals match the processor to the cent now", 0x2F7D6D),
        ("Maya Chen", "2:31 PM", "Nice. I\u{2019}ll post the gift card copy in #pricing", 0xC2573A),
    ]
    static let launchTodayText = launchToday.map { "\($0.0) \($0.1)\n\($0.2)" }.joined(separator: "\n")

    static let launchFriday: [(String, String, String, UInt32)] = [
        ("Maya Chen", "1:58 PM", "Pushed the gift card designs to the pricing file", 0xC2573A),
        ("Jordan Lee", "2:06 PM", "Rounding fix is up for review", 0x2F7D6D),
        ("Priya Shah", "2:09 PM", "Looking now. Tests are green on my side", 0x7A4FA0),
    ]
    static let launchFridayText = launchFriday.map { "\($0.0) \($0.1)\n\($0.2)" }.joined(separator: "\n")

    /// Slack's #launch channel.
    static func slack(messages: [(String, String, String, UInt32)]) -> Data? {
        picture { _ in
            fill(CGRect(origin: .zero, size: size), hex(0xFFFFFF))
            // Workspace bar and channel list.
            fill(CGRect(x: 0, y: 0, width: size.width, height: 56), hex(0x3F0E40))
            trafficLights(x: 26, y: 20)
            round(CGRect(x: 520, y: 12, width: 560, height: 32), 7, hex(0x5D3A5E))
            text("Search Northwind Studio", 545, 18, size: 17, color: hex(0xD8C8D8))
            fill(CGRect(x: 0, y: 56, width: 360, height: size.height - 56), hex(0x3F0E40))
            text("Northwind Studio", 32, 84, size: 24, weight: .bold, color: .white)
            for (row, item) in ["Threads", "Huddles", "Drafts & sent"].enumerated() {
                text(item, 40, 140 + CGFloat(row) * 40, size: 18, color: hex(0xCFC3CF))
            }
            text("Channels", 32, 282, size: 18, weight: .semibold, color: hex(0xCFC3CF))
            for (row, channel) in ["design", "general", "launch", "pricing", "support"].enumerated() {
                let y = 322 + CGFloat(row) * 40
                if channel == "launch" { round(CGRect(x: 16, y: y - 6, width: 328, height: 36), 7, hex(0x1164A3)) }
                text("#  \(channel)", 40, y, size: 18, weight: channel == "launch" ? .semibold : .regular,
                     color: channel == "launch" ? .white : hex(0xCFC3CF))
            }
            text("Direct messages", 32, 560, size: 18, weight: .semibold, color: hex(0xCFC3CF))
            for (row, name) in ["Jordan Lee", "Maya Chen", "Priya Shah"].enumerated() {
                text(name, 40, 600 + CGFloat(row) * 40, size: 18, color: hex(0xCFC3CF))
            }
            // The channel.
            text("# launch", 392, 84, size: 24, weight: .bold, color: hex(0x1D1C1D))
            fill(CGRect(x: 360, y: 130, width: size.width - 360, height: 1), hex(0xE2E2E2))
            var y: CGFloat = 162
            for (name, time, body, colour) in messages {
                round(CGRect(x: 392, y: y, width: 56, height: 56), 9, hex(colour))
                text(String(name.prefix(1)), 410, y + 12, size: 26, weight: .bold, color: .white)
                text(name, 470, y - 3, size: 21, weight: .bold, color: hex(0x1D1C1D))
                let nameWidth = (name as NSString).size(withAttributes: [
                    .font: NSFont.systemFont(ofSize: 21, weight: .bold),
                ]).width
                text(time, 470 + nameWidth + 12, y + 1, size: 16, color: hex(0x616061))
                text(body, 470, y + 29, size: 21, color: hex(0x1D1C1D))
                y += 112
            }
            round(CGRect(x: 392, y: size.height - 150, width: size.width - 424, height: 104), 10, hex(0xFFFFFF))
            stroke(CGRect(x: 392, y: size.height - 150, width: size.width - 424, height: 104), 10, hex(0xBBBBBB))
            text("Message #launch", 414, size.height - 128, size: 19, color: hex(0x868686))
        }
    }

    /// Notes with the launch checklist open.
    static func notes() -> Data? {
        picture { _ in
            fill(CGRect(origin: .zero, size: size), hex(0xFFFFFF))
            fill(CGRect(x: 0, y: 0, width: 330, height: size.height), hex(0xEFEDEA))
            trafficLights(x: 26, y: 26)
            text("iCloud", 30, 90, size: 15, weight: .semibold, color: hex(0x8A8784))
            for (row, folder) in [("All iCloud", "42"), ("Notes", "38"), ("Launch", "4"), ("Recently Deleted", "2")]
                .enumerated() {
                let y = 124 + CGFloat(row) * 44
                if row == 2 { round(CGRect(x: 14, y: y - 8, width: 302, height: 40), 8, hex(0xDCD8D2)) }
                text(folder.0, 50, y, size: 19, color: hex(0x2A2826))
                text(folder.1, 280, y, size: 17, color: hex(0x8A8784))
            }
            fill(CGRect(x: 330, y: 0, width: 360, height: size.height), hex(0xF7F6F4))
            for (row, note) in [("Launch checklist", "Today"), ("Gift card copy", "Today"),
                                ("Beta invite list", "Yesterday"), ("Pricing questions", "Friday")].enumerated() {
                let y = 80 + CGFloat(row) * 96
                if row == 0 { round(CGRect(x: 342, y: y - 12, width: 336, height: 86), 8, hex(0xE3E1DD)) }
                text(note.0, 362, y, size: 19, weight: .semibold, color: hex(0x2A2826))
                text(note.1, 362, y + 32, size: 16, color: hex(0x6E6B67))
            }
            text("Launch checklist", 740, 96, size: 40, weight: .bold, color: hex(0x1F1E1D))
            for (row, item) in ["Rounding fix merged", "Changelog updated", "Gift card copy reviewed",
                                "Beta group told about 0.4"].enumerated() {
                let y = 186 + CGFloat(row) * 64
                let done = row < 2
                circle(CGRect(x: 744, y: y + 2, width: 28, height: 28), done ? hex(0x3B82F6) : hex(0xB8B5B0),
                       filled: done)
                text(item, 792, y, size: 24, color: done ? hex(0x8A8784) : hex(0x1F1E1D))
            }
        }
    }

    /// Figma with the pricing page, `covered` (picture pixels) masked where
    /// the editor stood in front of it.
    static func figma(covered: CGRect) -> Data? {
        picture { _ in
            fill(CGRect(origin: .zero, size: size), hex(0xE5E5E5))
            fill(CGRect(x: 0, y: 0, width: size.width, height: 64), hex(0x2C2C2C))
            trafficLights(x: 26, y: 24)
            text("Drafts / Pricing page", 640, 20, size: 17, color: hex(0xEDEDED))
            fill(CGRect(x: 0, y: 64, width: 300, height: size.height - 64), hex(0xFFFFFF))
            text("Layers", 24, 90, size: 16, weight: .semibold, color: hex(0x333333))
            for (row, layer) in ["Pricing page", "Hero", "Plans", "Free", "Team", "Business", "Footer"].enumerated() {
                text(layer, 24 + (row > 2 && row < 6 ? 24 : 0), 136 + CGFloat(row) * 36, size: 16,
                     color: hex(0x333333))
            }
            fill(CGRect(x: size.width - 280, y: 64, width: 280, height: size.height - 64), hex(0xFFFFFF))
            text("Design", size.width - 256, 90, size: 16, weight: .semibold, color: hex(0x333333))
            for (row, line) in ["Frame  1440 \u{00D7} 2200", "Fill  #FFFFFF", "Auto layout", "Grid  12 col"]
                .enumerated() {
                text(line, size.width - 256, 136 + CGFloat(row) * 36, size: 15, color: hex(0x555555))
            }
            // The page on the canvas.
            let page = CGRect(x: 360, y: 120, width: 900, height: 900)
            fill(page, hex(0xFFFFFF))
            text("One plan for every team", page.minX + 170, page.minY + 70, size: 40, weight: .bold,
                 color: hex(0x16233A))
            text("Start free, then $18 a seat each month, billed annually", page.minX + 150, page.minY + 136,
                 size: 20, color: hex(0x4A5568))
            for (index, plan) in [("Free", "$0"), ("Team", "$18"), ("Business", "$32")].enumerated() {
                let card = CGRect(x: page.minX + 60 + CGFloat(index) * 270, y: page.minY + 230, width: 240,
                                  height: 360)
                round(card, 16, index == 1 ? hex(0x1D4ED8) : hex(0xF1F5F9))
                let ink = index == 1 ? NSColor.white : hex(0x16233A)
                text(plan.0, card.minX + 28, card.minY + 30, size: 22, weight: .semibold, color: ink)
                text(plan.1, card.minX + 28, card.minY + 80, size: 46, weight: .bold, color: ink)
                text("a seat a month", card.minX + 28, card.minY + 146, size: 16, color: ink)
                for line in 0..<4 {
                    round(CGRect(x: card.minX + 28, y: card.minY + 200 + CGFloat(line) * 32, width: 170 - CGFloat(line) * 18,
                                 height: 10), 5, ink.withAlphaComponent(0.35))
                }
            }
            text("Footer with the install line", page.minX + 300, page.minY + 700, size: 18, color: hex(0x718096))
        } mask: { covered }
    }

    /// Calendar's week.
    static func calendar() -> Data? {
        picture { _ in
            fill(CGRect(origin: .zero, size: size), hex(0xFFFFFF))
            fill(CGRect(x: 0, y: 0, width: size.width, height: 70), hex(0xF5F5F5))
            trafficLights(x: 26, y: 26)
            text("October 2026", 160, 20, size: 26, weight: .bold, color: hex(0x1F1F1F))
            let days = ["Mon 12", "Tue 13", "Wed 14", "Thu 15", "Fri 16"]
            for (index, day) in days.enumerated() {
                let x = 120 + CGFloat(index) * 290
                text(day, x + 16, 92, size: 18, weight: index == 0 ? .bold : .regular,
                     color: index == 0 ? hex(0xE0453A) : hex(0x3A3A3A))
                fill(CGRect(x: x, y: 130, width: 1, height: size.height - 130), hex(0xE6E6E6))
            }
            for hour in 0..<8 {
                let y = 150 + CGFloat(hour) * 118
                text("\(hour + 9 > 12 ? hour - 3 : hour + 9) \(hour + 9 >= 12 ? "PM" : "AM")", 30, y - 10, size: 14,
                     color: hex(0x8E8E8E))
                fill(CGRect(x: 120, y: y, width: size.width - 120, height: 1), hex(0xEDEDED))
            }
            let events: [(Int, Double, Double, String, UInt32)] = [
                (0, 6, 0.5, "Design review", 0x3B82F6), (0, 7, 0.5, "Launch sync", 0x10B981),
                (1, 1, 1, "Pricing workshop", 0x8B5CF6), (2, 4, 0.5, "Beta check-in", 0x3B82F6),
                (4, 2, 1, "Team sync", 0x10B981),
            ]
            for (day, start, length, title, colour) in events {
                let rect = CGRect(x: 124 + CGFloat(day) * 290, y: 150 + CGFloat(start) * 118, width: 280,
                                  height: CGFloat(length) * 118 - 6)
                round(rect, 8, hex(colour).withAlphaComponent(0.18))
                fill(CGRect(x: rect.minX, y: rect.minY, width: 5, height: rect.height), hex(colour))
                text(title, rect.minX + 16, rect.minY + 10, size: 17, weight: .semibold, color: hex(colour))
            }
        }
    }

    // MARK: Drawing

    /// A JPEG of the window drawn by `draw`, with its corners outside the
    /// helper's corner radius, and `mask` when given, filled grey.
    private static func picture(_ draw: (CGContext) -> Void, mask: () -> CGRect? = { nil }) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0),
            let base = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        let cg = base.cgContext
        // Top-left origin, as a window is laid out.
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        fill(CGRect(origin: .zero, size: size), Self.mask)
        cg.saveGState()
        cg.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: cornerRadius,
                          cornerHeight: cornerRadius, transform: nil))
        cg.clip()
        draw(cg)
        cg.restoreGState()
        if let covered = mask() { fill(covered, Self.mask) }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    private static func trafficLights(x: CGFloat, y: CGFloat) {
        for (index, colour) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            circle(CGRect(x: x + CGFloat(index) * 26, y: y, width: 16, height: 16), hex(UInt32(colour)), filled: true)
        }
    }

    private static func fill(_ rect: CGRect, _ color: NSColor) {
        color.setFill()
        rect.fill()
    }

    private static func round(_ rect: CGRect, _ radius: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    private static func stroke(_ rect: CGRect, _ radius: CGFloat, _ color: NSColor) {
        color.setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = 2
        path.stroke()
    }

    private static func circle(_ rect: CGRect, _ color: NSColor, filled: Bool) {
        let path = NSBezierPath(ovalIn: rect)
        if filled {
            color.setFill()
            path.fill()
        } else {
            color.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }

    private static func text(_ string: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat,
                             weight: NSFont.Weight = .regular, color: NSColor) {
        (string as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        ])
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
#endif
