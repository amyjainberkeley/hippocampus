#if DEBUG
import AppKit
import HippocampusKit
import SwiftUI

/// Debug only: `HIPPOCAMPUS_RENDER_BAR=<dir>` renders the command bar's states
/// from fixture data (no brain, no real memories) to PNGs and exits.
@MainActor
enum CommandBarPreviewRenderer {
    static func renderIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["HIPPOCAMPUS_RENDER_BAR"] else { return }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let context = FrontmostContext(bundleId: "com.apple.Safari", appName: "Safari", windowTitle: "Pricing | Stripe Documentation")
        func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
            // swiftlint:disable:next force_try
            try! JSONDecoder().decode(T.self, from: Data(json.utf8))
        }
        let suggestions = decode([BarSuggestion].self, """
        [{"kind":"resume","title":"Resume: Pricing the Team plan","why":"2:09 PM · You set Team at $18 a seat in the launch plan","action":{"open_session":1},"score":7},
         {"kind":"predicted","title":"Draft the pricing page update","why":"Maya agreed to update the pricing page today","action":{"ask":"what did we decide about team pricing?"},"score":7},
         {"kind":"searched","title":"“stripe per seat vs tiered pricing”","why":"You searched this at 2:03 PM","action":{"query":"stripe per seat vs tiered pricing"},"score":6},
         {"kind":"related","title":"More about Pricing | Stripe Documentation","why":"Everything you saw on this, across apps","action":{"query":"Pricing Stripe"},"score":5},
         {"kind":"day","title":"Your day so far","why":"Time, focus, searches and where you got stuck","action":{"view":"day"},"score":4}]
        """)
        let hits = decode([BarHit].self, """
        [{"event_id":11,"ts_us":\(now(-26)),"app_bundle_id":"com.tinyspeck.slackmacgap","window_title":"#pricing","url":null,"text_snippet":"[app=Slack]\\nRavi: Let's land Team at $18 a seat, billed annually. Maya: Agreed."},
         {"event_id":12,"ts_us":\(now(-33)),"app_bundle_id":"com.apple.Notes","window_title":"Launch plan","url":null,"text_snippet":"[app=Notes]\\nBeta ships to 40 design partners on Oct 21. Open question: Team plan price?"},
         {"event_id":13,"ts_us":\(now(-40)),"app_bundle_id":"com.apple.Safari","window_title":"Pricing | Stripe Documentation","url":"https://stripe.com/docs/billing","text_snippet":"[app=Safari]\\nPer-seat pricing. Tiered pricing. Volume pricing charges the same price per unit."}]
        """)
        let answer = decode(BarAnswer.self, """
        {"answer":"You and Ravi settled on $18 a seat for Team, billed annually, and Maya said she'd update the pricing page today.","sources":[
          {"n":1,"event_id":11,"ts_us":\(now(-26)),"app":"Slack","title":"#pricing","url":null,"text":"[app=Slack]\\nRavi: Let's land Team at $18 a seat, billed annually."},
          {"n":2,"event_id":12,"ts_us":\(now(-33)),"app":"Notes","title":"Launch plan","url":null,"text":"[app=Notes]\\nOpen question: Team plan price before the beta?"}],"unavailable":null}
        """)
        let day = decode(BarDay.self, """
        {"facts":"","day":{"written_by":"apple-foundation-models","breakdown":{"date_local":"2026-10-11","basis":"measured","active_us":19800000000,
          "apps":[{"bundle_id":"com.microsoft.VSCode","name":"VS Code","active_us":8100000000}],
          "kinds":[{"kind":"code","label":"Code","active_us":8100000000},{"kind":"writing","label":"Writing","active_us":4300000000},{"kind":"communication","label":"Communication","active_us":3600000000},{"kind":"research","label":"Research","active_us":2700000000},{"kind":"meetings","label":"Meetings","active_us":1100000000}],
          "focus_blocks":[{"start_us":1,"end_us":5400000001,"kind":"code","app":"VS Code"}],"switches":212,"switches_per_hour":38.5,
          "searches":[{"query":"stripe per seat vs tiered pricing","ts_us":1},{"query":"swiftui glass effect","ts_us":2},{"query":"sqlite fts5 bm25","ts_us":3}],
          "sessions":[{"start_us":\(now(-300)),"end_us":\(now(-210)),"title":"Command bar in SwiftUI","beneath":"Nothing notable."},
                      {"start_us":\(now(-120)),"end_us":\(now(-60)),"title":"Pricing the Team plan","beneath":"You paused 3 min in Notes before typing the price, after switching with Slack 5 times."}]},
          "narrative":{"headline":"5 h 30 min at the computer, mostly building the command bar and settling Team pricing.",
            "narrative":"You held one 90-minute block of code in VS Code in the morning. The afternoon broke up around 3 PM, when you moved between Slack and Notes on pricing.",
            "insights":["Longest focus: 9:40–11:10, code in VS Code.","Most switching around 15:00 (64 app switches).","You searched pricing models twice before deciding."],
            "suggestion":"Batch Slack around 3 PM so the afternoon has one long block."}}}
        """)
        let propositions = decode([BarProposition].self, """
        [{"id":1,"text":"Sam is setting per-seat pricing for the Team plan with Ravi and Maya.","reasoning":"","kind":"project","confidence":0.8,"evidence":[1,2,3]},
         {"id":2,"text":"Amy writes in the morning and handles messages after 3 PM.","reasoning":"","kind":"habit","confidence":0.6,"evidence":[4,5]},
         {"id":3,"text":"Amy hesitates before committing a price, switching between notes and chat.","reasoning":"","kind":"struggle","confidence":0.5,"evidence":[6]},
         {"id":4,"text":"Sam is learning SwiftUI layout and Liquid Glass.","reasoning":"","kind":"skill","confidence":0.6,"evidence":[7,8]}]
        """)
        let states: [(String, (CommandBarModel) -> Void)] = [
            ("model", { $0.preview(mode: .model, context: context, propositions: propositions) }),
            ("home", { $0.preview(mode: .home, context: context, suggestions: suggestions) }),
            ("results", { $0.preview(mode: .results, query: "team pricing", context: context, hits: hits) }),
            ("answer", { $0.preview(mode: .answer, query: "what did we decide on team pricing?", context: context, answer: answer, question: "what did we decide on team pricing?") }),
            ("thinking", { $0.preview(mode: .answer, query: "q", context: context, question: "what did we decide on team pricing?", working: true) }),
            ("day", { $0.preview(mode: .day, context: context, day: day) }),
        ]
        for (name, configure) in states {
            let model = CommandBarModel(launch: { _ in nil })
            configure(model)
            let view = CommandBarView(model: model, perform: { _ in }, close: {}, heightChanged: { _ in })
                .padding(40)
                .background(LinearGradient(colors: [Color(red: 0.32, green: 0.45, blue: 0.62), Color(red: 0.62, green: 0.52, blue: 0.70)], startPoint: .topLeading, endPoint: .bottomTrailing))
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: out.appendingPathComponent("bar-\(name).png"))
                }
            }
            window.orderOut(nil)
        }
        exit(0)
    }

    private static func now(_ minutes: Int) -> UInt64 {
        UInt64((Date().timeIntervalSince1970 + Double(minutes) * 60) * 1_000_000)
    }
}
#endif
