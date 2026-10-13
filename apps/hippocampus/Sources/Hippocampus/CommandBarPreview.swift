#if DEBUG
import AppKit
import HippocampusKit
import SwiftUI

/// Debug only: `HIPPOCAMPUS_RENDER_BAR=<dir>` draws Ask's states from fixture
/// data (no memory, no real moments) to `panel-<state>.png` at 2x, then
/// returns from `main` before the app starts.
///
/// Nothing reaches the screen. `HippocampusEntryPoint.main` calls this before
/// `HippocampusApp.main()`, so no scene, menu-bar item or app delegate
/// exists. The application object is given the `.prohibited` policy (no Dock
/// icon, no menu bar, never active) and is never run. Each state is hosted in
/// an `NSHostingView` that is never put in a window, and drawn into a bitmap
/// allocated at twice its size, with a solid fill where the glass would be.
@MainActor
enum CommandBarPreviewRenderer {
    /// True when it rendered; `main` then returns.
    static func renderIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["HIPPOCAMPUS_RENDER_BAR"] else { return false }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for state in states() {
            let model = CommandBarModel(
                memory: NoMemory(), availability: AnswerAvailability(systemSupportsAnswers: true)
            )
            state.configure(model)
            if let png = render(model: model, dark: state.dark) {
                try? png.write(to: out.appendingPathComponent("panel-\(state.name).png"))
            }
        }
        return true
    }

    private struct State {
        let name: String
        var dark = false
        let configure: (CommandBarModel) -> Void
    }

    private static func states() -> [State] {
        let safari = FrontmostContext(
            bundleId: "com.apple.Safari", appName: "Safari", windowTitle: "Pricing | Stripe Documentation"
        )
        // What `mci_suggest` sends with `model: false`, after Ask keeps its
        // three kinds: no past search, no day, nothing about you.
        let suggestions = decode([BarSuggestion].self, """
        [{"kind":"screen","title":"What’s on this screen?","why":"Safari · Pricing | Stripe Documentation","action":{"ask":"What is on my screen right now, and what matters in it?"},"score":8},
         {"kind":"resume","title":"Resume: Pricing the Team plan","why":"2:09 PM · You set Team at $18 a seat in the launch plan","action":{"open_session":1},"score":7},
         {"kind":"searched","title":"“stripe per seat vs tiered pricing”","why":"You searched for this at 2:03 PM","action":{"query":"stripe per seat vs tiered pricing"},"score":6},
         {"kind":"related","title":"More about Pricing | Stripe Documentation","why":"Everything else you saw about this","action":{"query":"Pricing Stripe"},"score":5},
         {"kind":"day","title":"Your day so far","why":"Time, focus, searches and where you got stuck","action":{"view":"day"},"score":4}]
        """)
        let read = CommandBarModel.homeRows(from: suggestions, readsThisWindow: true)
        let readWithoutAnswers = CommandBarModel.homeRows(from: suggestions, readsThisWindow: true, answersAvailable: false)
        // Read before a pause: the agent still offers the screen and more
        // about it, and Ask offers no screen row while nothing is read.
        let readButNotReading = CommandBarModel.homeRows(from: suggestions, readsThisWindow: false)
        // Never read: the agent offers neither the screen nor more about it
        // (`suggest` in `query.rs`), so only the last session is left.
        let unread = CommandBarModel.homeRows(
            from: suggestions.filter { $0.kind != "screen" && $0.kind != "related" }, readsThisWindow: true
        )
        let hits = decode([BarHit].self, """
        [{"event_id":11,"ts_us":\(minutesAgo(26)),"app_bundle_id":"com.tinyspeck.slackmacgap","window_title":"#pricing","url":null,"text_snippet":"[app=Slack]\\nRavi: Let's land Team at $18 a seat, billed annually. Maya: Agreed."},
         {"event_id":12,"ts_us":\(minutesAgo(33)),"app_bundle_id":"com.apple.Notes","window_title":"Launch plan","url":null,"text_snippet":"[app=Notes]\\nBeta ships to 40 design partners on Oct 21. Open question: Team plan price?"},
         {"event_id":13,"ts_us":\(minutesAgo(40)),"app_bundle_id":"com.apple.Safari","window_title":"Pricing | Stripe Documentation","url":"https://stripe.com/docs/billing","text_snippet":"[app=Safari]\\nPer-seat pricing. Tiered pricing. Volume pricing charges the same price per unit."}]
        """)
        let sources = """
          [{"n":1,"event_id":14,"ts_us":\(minutesAgo(0.15)),"app":"Safari","title":"Pricing | Stripe Documentation","url":null,"text":"[app=com.apple.Safari | title=Pricing | Stripe Documentation]\\nPer-seat pricing charges for each user."},
           {"n":2,"event_id":11,"ts_us":\(minutesAgo(26)),"app":"Slack","title":"#pricing","url":null,"text":"[app=Slack]\\nRavi: Let's land Team at $18 a seat, billed annually."},
           {"n":3,"event_id":12,"ts_us":\(minutesAgo(33)),"app":"Notes","title":"Launch plan","url":null,"text":"Open question: Team plan price before the beta?"}]
        """
        let answer = decode(BarAnswer.self, """
        {"answer":"You and Ravi settled on $18 a seat for Team, billed annually. Maya said she would update the pricing page today.","sources":\(sources),"unavailable":null}
        """)
        let unavailable = decode(BarAnswer.self, """
        {"answer":null,"sources":\(sources),"unavailable":"apple_intelligence_off"}
        """)
        let question = "What did we decide on Team pricing?"
        let paused = AskPanelStatus(.paused)
        let permission = AskPanelStatus(.needsPermission(.screenRecording))
        let notSetUp = AskPanelStatus(.idle, setup: .notFinished)
        return [
            State(name: "home") { $0.preview(mode: .home, context: safari, homeRows: read) },
            State(name: "home-dark", dark: true) { $0.preview(mode: .home, context: safari, homeRows: read) },
            State(name: "home-unread") { $0.preview(mode: .home, context: safari, savedRead: false, homeRows: unread) },
            State(name: "home-paused") {
                $0.preview(mode: .home, context: safari, status: paused, homeRows: readButNotReading)
            },
            State(name: "home-needs-permission") {
                $0.preview(mode: .home, context: safari, status: permission, homeRows: readButNotReading)
            },
            // Before setup there is nothing saved, so nothing to offer.
            State(name: "home-not-set-up") {
                $0.preview(mode: .home, context: safari, status: notSetUp, savedRead: false)
            },
            State(name: "home-no-answers") {
                $0.preview(mode: .home, context: safari, answersAvailable: false, homeRows: readWithoutAnswers)
            },
            State(name: "results") { $0.preview(mode: .results, query: "team pricing", context: safari, hits: hits) },
            State(name: "results-no-answers") {
                $0.preview(mode: .results, query: "team pricing", context: safari, answersAvailable: false, hits: hits)
            },
            State(name: "thinking") { $0.preview(mode: .answer, query: question, context: safari, working: true) },
            State(name: "searching") {
                $0.preview(mode: .answer, query: "team pricing", context: safari, answersAvailable: false, working: true)
            },
            State(name: "answer") {
                $0.preview(mode: .answer, query: question, context: safari, answer: answer, askedAt: Date())
            },
            State(name: "answer-dark", dark: true) {
                $0.preview(mode: .answer, query: question, context: safari, answer: answer, askedAt: Date())
            },
            State(name: "answer-unavailable") {
                $0.preview(
                    mode: .answer, query: question, context: safari, answersAvailable: false,
                    answer: unavailable, askedAt: Date()
                )
            },
            State(name: "answer-failed") {
                $0.preview(mode: .answer, query: question, context: safari, notice: "Couldn’t answer that. Try again.")
            },
            State(name: "copied") {
                $0.preview(
                    mode: .answer, query: question, context: safari, answer: answer, flash: "Copied", askedAt: Date()
                )
            },
        ]
    }

    private static func render(model: CommandBarModel, dark: Bool) -> Data? {
        let backdrop = dark
            ? [Color(red: 0.12, green: 0.15, blue: 0.21), Color(red: 0.21, green: 0.17, blue: 0.26)]
            : [Color(red: 0.78, green: 0.84, blue: 0.92), Color(red: 0.89, green: 0.85, blue: 0.93)]
        let view = CommandBarView(model: model, perform: { _ in }, close: {}, heightChanged: { _ in })
            .frame(width: AskPanelPlacement.preferredWidth)
            .environment(\.askSolidBackground, true)
            .padding(32)
            .background(LinearGradient(colors: backdrop, startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: Int((size.width * scale).rounded()),
                  pixelsHigh: Int((size.height * scale).rounded()),
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              )
        else { return nil }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private static func minutesAgo(_ minutes: Double) -> UInt64 {
        UInt64((Date().timeIntervalSince1970 - minutes * 60) * 1_000_000)
    }
}

/// Memory that is never there: the renderer draws fixtures only.
@MainActor
private final class NoMemory: AskMemory {
    func call(_ session: AskSession, _ tool: String, arguments: Data, timeout: Duration) async throws -> Data {
        throw MemorySessionError.unavailable
    }

    func stop() async {}
}
#endif
