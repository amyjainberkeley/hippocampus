import RecallUIKit
import SwiftUI

/// What the window's pages reach beyond the memory reader and the `work`
/// read: the searches Looked Up lists, the calendar Today and an item's page
/// show, Ask {Tool}, Resume, AI Tools, the Privacy page, and whether Claude
/// Code starts its sessions with recent work.
///
/// Each one left nil is this Mac's in the app's window: the bundled agent,
/// the person's own calendar when they turned it on, their AI tools and
/// macOS. The synthetic preview, Demo Memory and every picture pass their
/// own, so nothing there reaches the agent with the person's memory, their
/// calendar, their AI tools' settings or macOS.
struct WindowServices {
    /// Looked Up's searches; nil reads the bundled agent (none in the
    /// synthetic preview).
    var searches: (any SearchesReading)?
    /// The calendar for Today's bars and an item's meetings; nil shows none.
    var calendar: (any CalendarReader)?
    /// Ask {Tool}'s builder, tools and notes; nil is this Mac's.
    var handoff: HandoffServices?
    /// Resume's plan, Mac and tabs; nil is this Mac's.
    var resume: ResumeServices?
    /// AI Tools' read; nil reads this Mac's tools and the agent.
    var aiTools: AIToolsModel?
    /// Privacy's page; nil draws the page itself, which reads the activity
    /// log, the retention setting and the pictures' usage on this Mac.
    var privacy: (@MainActor () -> AnyView)?
    /// Whether Claude Code starts each session with recent work, for a code
    /// project's page; nil asks the agent's `clients` read once.
    var claudeCodeStarts: Bool?
    /// Today's Show Calendar asks macOS for the person's calendar. Only the
    /// app's own window, and never on Demo Memory.
    var asksForCalendar = false
    /// Whether the sidebar's kinds are read from the lens pages' own reads
    /// (a moment of the kind). Pictures pass the kinds they draw instead.
    var readsKinds = true

    /// Nothing reaches anything: the pages fall back to the synthetic
    /// preview's fixtures, or this Mac's in the app.
    init(
        searches: (any SearchesReading)? = nil,
        calendar: (any CalendarReader)? = nil,
        handoff: HandoffServices? = nil,
        resume: ResumeServices? = nil,
        aiTools: AIToolsModel? = nil,
        privacy: (@MainActor () -> AnyView)? = nil,
        claudeCodeStarts: Bool? = nil,
        asksForCalendar: Bool = false,
        readsKinds: Bool = true
    ) {
        self.searches = searches
        self.calendar = calendar
        self.handoff = handoff
        self.resume = resume
        self.aiTools = aiTools
        self.privacy = privacy
        self.claudeCodeStarts = claudeCodeStarts
        self.asksForCalendar = asksForCalendar
        self.readsKinds = readsKinds
    }

    /// The app's window: the person's calendar once they turned it on (or,
    /// on Demo Memory, the made-up week's, and nothing asks macOS), and
    /// this Mac's agent, tools and macOS for everything else.
    @MainActor
    static func app(environment: [String: String] = ProcessInfo.processInfo.environment) -> WindowServices {
        let demo = DemoMemoryMode.isOn(environment: environment)
        return WindowServices(
            searches: AgentWorkReader.shared,
            calendar: DemoMemoryMode.calendarReader(environment: environment, fallback: SystemCalendar.live()),
            asksForCalendar: !demo
        )
    }

    /// The synthetic preview's: no agent, no calendar of the person's, the
    /// preview's AI tools, and nothing opened.
    @MainActor
    static func syntheticPreview(searches: (any SearchesReading)? = nil,
                                 calendar: (any CalendarReader)? = nil) -> WindowServices {
        WindowServices(
            searches: searches ?? PreviewSearchesReader(),
            calendar: calendar ?? FixtureCalendar(access: .notAsked),
            handoff: .preview,
            resume: ResumeServices.none,
            claudeCodeStarts: true
        )
    }
}
