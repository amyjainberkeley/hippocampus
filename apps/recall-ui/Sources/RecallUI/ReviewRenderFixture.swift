#if DEBUG
import AppKit
import RecallUIKit

/// History as a person looks back over an afternoon: ten windows, stored as
/// the reader before 0.3 stored them, chrome and all (Chrome's tab strip with
/// its close marks and favicons read as letters, the address bar, a site's
/// menu, Google's results bar, Docs' menus, Slack's top bar and message box,
/// VS Code's tabs and status bar), then read as the window reads them today:
/// cleaned by the Rust reader (`StatelessReading`, the reading the FFI gives a
/// moment the re-clean job has not reached) and captioned from the title as
/// the FFI captions it.
///
/// Five windows kept a screenshot, drawn (`SyntheticScreens`), sealed with the
/// capture helper's codec and opened by the window's own provider; a window's
/// later moment shows the one it kept when it came to the front. Windows
/// beside the front one and mail are text only, and one screenshot is gone
/// from disk. Nothing here is real.
@MainActor
final class ReviewRenderFixture {
    /// The article's newest moment: its screenshot was kept four minutes before.
    static let articleId: UInt64 = 71_001
    /// Slack beside the front window: text only.
    static let slackId: UInt64 = 71_003
    /// The document's newest moment, showing the screenshot kept when it came
    /// to the front.
    static let documentId: UInt64 = 71_009
    /// A note whose screenshot is gone from disk.
    static let notesId: UInt64 = 71_013
    /// Notes in a tall window titled "Notes", its heading at the top.
    static let tallNotesId: UInt64 = 71_014
    /// A terminal running a coding assistant.
    static let assistantId: UInt64 = 71_015
    /// Gmail in Chrome, its side bar read before the message.
    static let gmailId: UInt64 = 71_016

    let reader: ReviewRenderReader
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

        var moments: [ReviewRenderReader.Moment] = []
        /// One moment, read the way the FFI reads a stored moment: `main`
        /// and `rest` from the reader, the row's text the start of `main`,
        /// and the caption made from the title.
        func add(_ id: UInt64, _ minutes: Double, _ app: String, _ title: String, url: String? = nil,
                 kind: String = "screen_ocr", screen: SyntheticScreens.Screen? = nil, takenMinutes: Double? = nil,
                 path: String? = nil, text: String) {
            let stored = "[app=\(app) | title=\(title) | url=\(url ?? "?") | ts=2026-10-12T14:00:00.000Z]\n" + text
            let read = StatelessReading.read(stored: stored, source: kind, app: app, title: title, url: url)
            let main = read?.main ?? ReadableText.guarded(text)
            let rest = read?.rest ?? ""
            let shot = path ?? screen.flatMap { paths[$0] }
            let hit = Hit(eventId: id, tsUs: ago(minutes), appBundleId: app, windowTitle: title, url: url,
                          ocrTextSnippet: ReadableText.guarded(String((main.isEmpty ? rest : main).prefix(280))),
                          source: "recent", score: nil, thumbnailPath: shot, sourceKind: kind,
                          thumbnailTsUs: shot == nil ? nil : ago(takenMinutes ?? minutes),
                          caption: MomentRowText.caption(read?.caption))
            moments.append(ReviewRenderReader.Moment(hit: hit, stored: stored, main: main, rest: rest))
        }

        // Chrome, in front: an article, read twice. It kept its screenshot
        // when it came to the front; the newer moment shows that one.
        let tabs = "D Rounding half to even \u{00B7} Dev No \u{00D7} 31 Northwind - Calen \u{00D7} \u{2713} "
            + "Q4 planning - Google Do\u{2026} \u{00D7} # #launch - Slack \u{00D7} +"
        let article = """
            \(tabs)
            < > C devnotes.example/rounding \u{2606}
            Dev Notes Articles Topics About Subscribe
            MONEY & ROUNDING
            Rounding half to even
            Why banker\u{2019}s rounding keeps order totals from drifting by a cent
            Priya Shah \u{00B7} Oct 12, 2026 \u{00B7} 6 min read
            Round half up looks fair, but every tie goes the same way. Over thousands of orders the extra
            half cents add up, and the books stop matching the bank by a few dollars a month.
            Round half to even sends each tie to the even neighbour instead, so half the ties go down and
            half go up. The errors cancel out:
            round_half_even(2.5) // 2.0
            round_half_even(3.5) // 4.0
            Most payment processors already round this way. Matching them means the total a customer sees
            is the total that settles, to the cent.
            Next: Currency math without floats
            """
        for (id, minutes) in [(Self.articleId, 2.0), (71_002, 6.0)] {
            add(id, minutes, "com.google.Chrome", "Rounding half to even \u{00B7} Dev Notes",
                url: "https://devnotes.example/rounding", screen: .article, takenMinutes: 6, text: article)
        }

        // A coding assistant in a terminal: its title carries a status mark,
        // its last lines are its status line and empty input box.
        add(Self.assistantId, 3.5, "com.apple.Terminal",
            "\u{2733} Fix rounding in tax.rs \u{2014} claude \u{2014} 160\u{00D7}40", screen: .terminal, text: """
                \u{23FA} Update(src/tax.rs)
                  \u{23BF}  Updated src/tax.rs with 2 additions and 1 removal
                       14   pub fn order_total(lines: &[Line]) -> Money {
                       15 -     subtotal + tax
                       15 +     round_half_even(subtotal + tax)
                \u{23FA} Bash(cargo test tax)
                  \u{23BF}  test result: ok. 6 passed; 0 failed; 0 ignored
                \u{23FA} Rounding now goes to the even cent, and all six tax tests pass.
                \u{256D}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256E}
                \u{2502} >                                            \u{2502}
                \u{2570}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256F}
                  \u{23F5}\u{23F5} accept edits on (shift+tab to cycle)
                """)

        // Notes in a tall window: its title is the app's own name, and its
        // side bar was read first.
        add(Self.tallNotesId, 7.5, "com.apple.Notes", "Notes", path: try Self.tallNote().map { try store.seal($0) },
            text: """
                iCloud
                All iCloud 42
                Notes 38
                Quick Notes 4
                Launch checklist
                Rounding fix merged
                Changelog updated
                Gift card copy reviewed
                Beta group told about 0.4
                """)

        // Slack beside it: read by the whole-screen pass, so text only.
        add(Self.slackId, 9, "com.tinyspeck.slackmacgap", "launch (Channel) - Northwind Studio - Slack",
            kind: "screen_context", text: """
                Northwind Studio > Q Search Northwind Studio
                Threads
                Channels
                Jordan Lee 2:14 PM
                staging is green, shipping the rounding fix at 4
                Priya Shah 2:15 PM
                I\u{2019}ll update the changelog before then
                Maya Chen 2:21 PM
                Gift card copy is in the doc, ready for a last look
                Direct messages
                Message #launch
                """)

        // Messages, in front, with its own screenshot.
        add(71_004, 13, "com.apple.MobileSMS", "Sam Lee", screen: .chat, text: """
            Sam Lee
            Today 2:21 PM
            Are we still on for 3?
            Yes, running five minutes late
            No rush. I grabbed the corner table
            See you there
            Bringing the printouts
            Delivered
            iMessage
            """)

        // VS Code: the screenshot was kept when the editor came to the front.
        let editor = """
            tax.rs \u{00D7} cart.rs \u{00D7}
            EXPLORER
            src > tax.rs > order_total
            /// Rounds half to even, so totals never drift by a cent.
            pub fn round_half_even(amount: Money) -> Money {
                let cents = amount.cents_exact();
                let floor = cents.floor();
            pub fn order_total(lines: &[Line]) -> Money {
                let subtotal: Money = lines.iter().map(|l| l.price * l.qty).sum();
                let tax = subtotal * TAX_RATE;
                round_half_even(subtotal + tax)
            }
            OUTLINE
            TIMELINE
            main 0 errors, 2 warnings Ln 21, Col 36 Spaces: 4 UTF-8 LF Rust
            """
        for (id, minutes) in [(UInt64(71_005), 17.0), (71_006, 21.0)] {
            add(id, minutes, "com.microsoft.VSCode", "tax.rs \u{2014} trailhead-shop", screen: .editor,
                takenMinutes: 21, text: editor)
        }

        // Terminal: kept exactly as read.
        add(71_007, 25, "com.apple.Terminal", "trailhead-shop \u{2014} zsh \u{2014} 160\u{00D7}40", screen: .terminal,
            text: """
                dev@studio trailhead-shop % cargo test tax
                   Compiling trailhead-shop v0.4.2 (/Users/dev/trailhead-shop)
                    Finished `test` profile [unoptimized + debuginfo] target(s) in 3.41s
                running 6 tests
                test tax::tests::order_total_includes_tax ... ok
                test tax::tests::rounds_half_to_even ... ok
                test result: ok. 6 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
                """)

        // Google, beside the front window: text only.
        add(71_008, 31, "com.google.Chrome", "per seat vs tiered pricing - Google Search",
            url: "https://www.google.com/search?q=per+seat+vs+tiered+pricing", kind: "screen_context", text: """
                G per seat vs tiered pricing - Goo \u{00D7} \u{2713} Q4 planning - Google Docs \u{00D7} +
                < > C google.com/search?q=per+seat+vs+tiered+pricing \u{2606}
                Google per seat vs tiered pricing X Q
                All Images Videos News Shopping Short videos More Tools
                Per-seat or tiered? How to price a team plan
                pricingnotes.example \u{203A} team-plans
                Most teams choose between charging for every seat and charging by tier. A seat minimum is the
                usual compromise.
                Seat-based pricing: the pros and cons
                saasguide.example \u{203A} pricing \u{203A} seats
                Charging per seat grows with the customer, but it can slow adoption inside a company.
                """)

        // Google Docs, in front: its screenshot was kept four minutes before.
        let document = """
            E Q4 planning - Google Docs \u{00D7} D Rounding half to even \u{00B7} Dev No \u{00D7} 31 Northwind - Calen \u{00D7} +
            < > C docs.google.com/document/d/q4-planning/edit \u{2606}
            Q4 planning \u{2606}
            File Edit View Insert Format Tools Extensions Help
            Share
            Q4 planning
            Owner: Priya Shah \u{00B7} Updated Oct 12
            Goals
            Ship the rounding fix before the holiday sale
            Cut checkout to under 30 seconds on mobile
            Launch gift cards in two markets
            Close the books each month with no cent drift
            Owners
            Rounding fix Sam
            Checkout speed Maya
            Gift cards Jordan
            Rounding ships first: every other goal depends on totals that match the processor to the cent.
            """
        for (id, minutes) in [(Self.documentId, 38.0), (71_010, 42.0)] {
            add(id, minutes, "com.google.Chrome", "Q4 planning - Google Docs",
                url: "https://docs.google.com/document/d/q4-planning/edit", screen: .document, takenMinutes: 42,
                text: document)
        }

        // Figma beside the front window; it is not on this Mac.
        add(71_011, 51, "com.figma.Desktop", "Pricing page", kind: "screen_context", text: """
            Pricing page
            Hero
            One plan for every team
            Start free, then $18 a seat each month, billed annually
            Three plans side by side, the team plan in the middle
            Footer with the install line
            """)

        // Gmail in Chrome, read before windows were classified.
        add(Self.gmailId, 54, "com.google.Chrome", "Re: Invoice 1042 - sam@northwind.example - Northwind Mail",
            url: "https://mail.google.com/mail/u/0/#inbox/invoice-1042", text: """
                M Inbox (1,204) - sam@northwind \u{00D7} D Rounding half to even \u{00B7} Dev No \u{00D7} +
                < > C mail.google.com/mail/u/0/#inbox/invoice-1042 \u{2606}
                Gmail Q Search mail
                Compose
                Inbox 1,204
                Starred
                Snoozed
                Sent
                Drafts 3
                More
                Re: Invoice 1042 Inbox \u{00D7}
                Dana Whitfield <dana@northwind.example>
                to me
                Thanks for sending this over. The October invoice is attached; the amount due is $1,240.00
                by October 30, and the purchase order number has not changed.
                """)

        // Zoom's home window: no call.
        add(71_017, 55.5, "us.zoom.xos", "Zoom Workplace", text: """
            Home Team Chat Meetings Contacts
            New meeting
            Join
            Schedule
            Upcoming
            Design review 3:00 PM - 3:30 PM
            """)

        // Mail, read by its own reader: text only.
        add(71_012, 57, "com.apple.mail", "Invoice 1042 from Northwind Supplies", kind: "structured_app", text: """
            Invoice 1042 from Northwind Supplies
            Dana Whitfield
            Thanks for your order. The invoice for October is attached.
            Amount due: $1,240.00, due October 30.
            """)

        // Notes: its screenshot was kept, then removed from disk.
        add(Self.notesId, 63, "com.apple.Notes", "Launch checklist", path: store.missingPath, text: """
            Launch checklist
            Rounding fix merged
            Changelog updated
            Gift card copy reviewed
            Beta group told about 0.4
            """)

        self.store = store
        screenshots = CountingScreenshots(store.provider())
        reader = ReviewRenderReader(base: base, moments: moments)
    }

    func remove() {
        store.remove()
    }

    /// A tall window, 900 by 1400 like a narrow Notes window, drawn with its
    /// heading at the top.
    private static func tallNote() -> Data? {
        let size = NSSize(width: 900, height: 1400)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
                                         pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.98, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(white: 0.9, alpha: 1).setFill()
        NSRect(x: 0, y: size.height - 64, width: size.width, height: 64).fill()
        func text(_ string: String, _ y: CGFloat, _ font: NSFont) {
            (string as NSString).draw(at: NSPoint(x: 64, y: size.height - y),
                                      withAttributes: [.font: font, .foregroundColor: NSColor(white: 0.1, alpha: 1)])
        }
        text("Launch checklist", 170, .boldSystemFont(ofSize: 60))
        var y: CGFloat = 280
        for line in ["Rounding fix merged", "Changelog updated", "Gift card copy reviewed", "Beta group told about 0.4"] {
            text("\u{2610}  " + line, y, .systemFont(ofSize: 38))
            y += 84
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// The review afternoon as a reader: newest first, a day at a time, by id,
/// as stored text and as the reading the FFI gives.
struct ReviewRenderReader: BrainReader {
    struct Moment: Sendable {
        let hit: Hit
        let stored: String
        let main: String
        let rest: String
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
