// Tab.swift — the Recall UI's top-level tab enum.
//
// Lives in RecallUIKit (not the executable) so the deep-link routing
// parser (`RecallTab.from(deepLinkValue:)`) is unit-testable without a
// SwiftUI scene. The four cases map 1-1 to the four tabs in
// MCIRecallApp.RootView.
//
// Named `RecallTab` (not `Tab`) so it does not collide with SwiftUI's
// generic `Tab<Value, Content, Label>` API on macOS 15+.

import Foundation

public enum RecallTab: Int, Hashable, Sendable {
    public static let defaultTab: RecallTab = .now
    case now = 0
    case search = 1
    case timeline = 2
    case episodes = 3
    case brief = 4
    case privacy = 5
    /// Cycle 8.42 — minimal Settings surface hosting the user-dictionary
    /// editor. Future settings can grow into the same scene.
    case settings = 6
    /// Privacy Dashboard (⌘7): shows what MCI has captured and gives the
    /// user delete and export controls over their brain. Amy's directive
    /// 2026-07-13: "show the full control, no collection."
    case privacyDashboard = 7
    /// **V2-P13 (Phase D scaffold)** — Rewind-style visual timeline
    /// strip (⌘8). Horizontally-scrolling row of capture cards with
    /// thumbnails + time markers. Distinct from `.timeline` (the flat
    /// chronological list); the two coexist during Phase D scaffold and
    /// may collapse into one tab in Phase D full impl (cycle 8.55+).
    case timelineStrip = 8
    /// You: what Hippocampus understands about the person, and their data
    /// (RULINGS G5, X9).
    case you = 9
    /// The sidebar's new names (SPEC 2.16, SPEC-DELTA 1).
    case webPages = 10
    case lookedUp = 11
    /// Working On, all of it (Show All); with an item, that item.
    case work = 12
    case aboutYou = 13
    case aiTools = 14
    case documents = 15
    case code = 16
    case conversations = 17

    /// Map a deep-link `?tab=…` query value (case-insensitive) to a
    /// `RecallTab`. Returns `nil` for unknown values so callers can
    /// ignore junk without crashing.
    ///
    /// Pinned by `BriefDeepLinkRoutingTests`.
    public static func from(deepLinkValue: String) -> RecallTab? {
        switch deepLinkValue.lowercased() {
        case "today", "now", "daily", "overview": return .now
        case "search", "ask": return .search
        case "timeline", "history": return .timeline
        case "episodes", "sessions": return .episodes
        case "privacy":  return .privacy
        case "brief", "briefs": return .brief
        case "settings": return .settings
        case "dashboard", "privacy-dashboard": return .privacyDashboard
        case "timeline-strip", "strip": return .timelineStrip
        case "you": return .you
        case "web-pages", "pages": return .webPages
        case "looked-up", "searches": return .lookedUp
        case "work", "working-on": return .work
        case "about-you": return .aboutYou
        case "ai-tools": return .aiTools
        case "documents": return .documents
        case "code": return .code
        case "conversations": return .conversations
        default:         return nil
        }
    }

    /// The env-var the recall-ui executable reads at launch to pick
    /// its initial tab. Hippocampus.app sets this when it handles a
    /// `hippocampus://recall?tab=…` URL.
    public static let initialTabEnvVar = "MCI_INITIAL_TAB"

    public var workspaceTab: RecallTab {
        switch self {
        case .brief: return .now
        case .timelineStrip: return .timeline
        case .privacyDashboard: return .privacy
        default: return self
        }
    }
}

/// The window's pages (SPEC 2.2 with SPEC-DELTA 1): Today; History and its
/// kinds; Working On (Show All); the pinned About You, AI Tools and
/// Privacy. A Working On item's page is a route's `workItem`.
public enum RecallPlace: String, CaseIterable, Sendable {
    case today
    case history
    case webPages
    case documents
    case code
    case conversations
    case lookedUp
    /// Working On, all of it: Show All (SPEC 3.3).
    case workingOn
    case aboutYou
    case aiTools
    case privacy

    /// The names the window's places had before the sidebar (SPEC 2.16):
    /// Overview became Today, Ask became History with the field over every
    /// page, You became About You.
    public static let overview = RecallPlace.today
    public static let ask = RecallPlace.history
    public static let you = RecallPlace.aboutYou

    /// The sidebar's row for this page; Show All is Working On's own row.
    public var sidebarPlace: SidebarPlace? {
        SidebarPlace(rawValue: rawValue)
    }

    public init(_ place: SidebarPlace) {
        self = RecallPlace(rawValue: place.rawValue) ?? .today
    }

    /// The page has the field (SPEC 2.8): every memory page. About You,
    /// AI Tools and Privacy have none; ⌘F there opens History's.
    public var hasField: Bool {
        ![.aboutYou, .aiTools, .privacy].contains(self)
    }
}

public extension RecallTab {
    /// The place every name opens (RULINGS X9, SPEC 2.16). Names are an
    /// outside contract: the app, links and old menus still send each of
    /// them. Settings opens Preferences and leaves the window where it is.
    var place: RecallPlace? {
        switch self {
        case .now, .brief, .episodes: .today
        case .search, .timeline, .timelineStrip: .history
        case .you, .aboutYou: .aboutYou
        case .privacy, .privacyDashboard: .privacy
        case .settings: nil
        case .webPages: .webPages
        case .lookedUp: .lookedUp
        case .work: .workingOn
        case .aiTools: .aiTools
        case .documents: .documents
        case .code: .code
        case .conversations: .conversations
        }
    }

    /// History with its field emptied, so the day shows.
    var opensHistory: Bool {
        [.timeline, .timelineStrip].contains(self)
    }

    /// Privacy, the page that shows what is kept and forgets it.
    var opensPrivacy: Bool {
        [.privacy, .privacyDashboard].contains(self)
    }
}

/// A page pushed inside About You.
public enum RecallYouPage: String, Hashable, Sendable {
    /// What is remembered, and deleting it. Privacy is its own page now;
    /// kept so an older route still reads.
    case privacy
    /// The names you use.
    case names
}

/// What Forget Recent… forgets (SPEC 3.11): its sheet opens with this
/// chosen, and still needs the person's click.
public enum ForgetRecentChoice: String, CaseIterable, Sendable {
    case tenMinutes = "10m"
    case hour = "1h"
    case today

    /// The moments it covers: the time it starts, fixed at the click, up to
    /// that click.
    public func start(at now: Date, calendar: Calendar) -> Date {
        switch self {
        case .tenMinutes: now.addingTimeInterval(-10 * 60)
        case .hour: now.addingTimeInterval(-60 * 60)
        case .today: calendar.startOfDay(for: now)
        }
    }

    /// Today asks for the typed word; the others ask once.
    public var needsTypedWord: Bool { self == .today }
}

/// Where the window goes, and what it shows there.
///
/// One value for every way a request arrives: at launch (`MCI_INITIAL_TAB`
/// and the other launch variables), from the app while the window is open
/// (its command notification or a link), and from inside the window ("Show in
/// History", a session on About You). The window applies a route the same way
/// in each case (critique-recall-engineering finding 5).
public struct RecallRoute: Equatable, Sendable {
    /// The place to show. Nil keeps the place on screen; a window that is
    /// only opening shows Today, or the page it was left on.
    public var place: RecallPlace?
    /// Pages pushed inside About You, in order. Empty shows About You itself.
    public var youPath: [RecallYouPage]
    /// Empty the field, so the page shows.
    public var clearsField: Bool
    /// Put the cursor in the field.
    public var focusesField: Bool
    /// A memory to show. With no `timeRange` it shows with its detail; with
    /// one, History selects it inside that range.
    public var focusEventId: UInt64?
    /// A moment in the day to show: Today's day, or History's.
    public var day: Date?
    /// A session's own time, in microseconds since the epoch. Today
    /// selects the session overlapping it; History loads it (RULINGS W8).
    public var timeRange: ClosedRange<Int64>?
    /// Open Ask from the menu bar rather than anything in the window: the
    /// window has no popup of its own (RULINGS W3).
    public var opensAskPanel: Bool
    /// A Working On item to show, by its id: ids, never names, travel in
    /// routes and links. The window shows the item's page.
    public var workItem: String?
    /// Show Resume's sheet for `workItem` (SPEC-DELTA 3). The sheet only
    /// lists what would open: nothing opens until the person clicks in it.
    public var showsResume: Bool
    /// Open the Preferences window; the window stays where it is.
    public var opensPreferences: Bool
    /// Open Forget Recent's sheet with this chosen. A link can open the
    /// sheet but never confirm it (SPEC 2.6.4).
    public var forgetRecent: ForgetRecentChoice?

    public init(
        place: RecallPlace? = nil,
        youPath: [RecallYouPage] = [],
        clearsField: Bool = false,
        focusesField: Bool = false,
        focusEventId: UInt64? = nil,
        day: Date? = nil,
        timeRange: ClosedRange<Int64>? = nil,
        opensAskPanel: Bool = false,
        workItem: String? = nil,
        showsResume: Bool = false,
        opensPreferences: Bool = false,
        forgetRecent: ForgetRecentChoice? = nil
    ) {
        self.place = place
        self.youPath = youPath
        self.clearsField = clearsField
        self.focusesField = focusesField
        self.focusEventId = focusEventId.flatMap { $0 == 0 ? nil : $0 }
        self.day = day
        self.timeRange = timeRange
        self.opensAskPanel = opensAskPanel
        self.workItem = workItem.flatMap { RecallLaunchRequest.isWorkItemId($0) ? $0 : nil }
        self.showsResume = showsResume && self.workItem != nil
        self.opensPreferences = opensPreferences
        self.forgetRecent = forgetRecent
    }

    /// Ask, opened from the menu bar: where a request for the window's old
    /// popup goes (RULINGS W3).
    public static let askPanelURL = URL(string: "hippocampus://ask")!

    /// The place this route shows when `current` is on screen. A window that
    /// is only opening passes `.today`, or the page it was left on.
    public func place(keeping current: RecallPlace) -> RecallPlace {
        place ?? current
    }

    /// The route for one of the window's names (RULINGS X9, SPEC 2.16).
    public init(tab: RecallTab) {
        switch tab {
        case .settings:
            self.init(opensPreferences: true)
        case .search:
            // History, with the cursor in the field.
            self.init(place: .history, focusesField: true)
        default:
            self.init(place: tab.place, clearsField: tab.opensHistory)
        }
    }

    /// Nil for a name the window does not know, so junk is ignored.
    public init?(tab: String) {
        guard let tab = RecallTab.from(
            deepLinkValue: tab.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else { return nil }
        self.init(tab: tab)
    }

    /// What a request from the app asks for, at launch or while the window is
    /// open. A memory to show lands in History, or on Today when the name
    /// says Today. A name opens its place. The old popup flag opens Ask from
    /// the menu bar and leaves the window where it is.
    public init(_ request: RecallLaunchRequest) {
        if let eventId = request.focusEventId {
            if request.tab == .now {
                self.init(place: .today, focusEventId: eventId)
            } else {
                self.init(place: .history, clearsField: true, focusEventId: eventId)
            }
        } else if let item = request.resumeItem {
            self = .resume(item: item)
        } else if let item = request.workItem {
            self = .item(item)
        } else if let start = request.sessionStartUs {
            self = .session(startUs: start)
        } else if let choice = request.forgetRecent {
            self.init(forgetRecent: choice)
        } else if let tab = request.tab {
            self.init(tab: tab)
        } else {
            self.init()
        }
        opensAskPanel = request.openPopup
    }

    /// The route the app asked for at launch: `MCI_INITIAL_TAB`,
    /// `MCI_INITIAL_FOCUS_EVENT_ID` and `MCI_OPEN_GLOBAL_POPUP`.
    public init(environment: [String: String]) {
        self.init(RecallLaunchRequest(environment: environment))
    }

    /// The route in a `hippocampus://recall?…` link; nil for any other link.
    public init?(url: URL) {
        guard let request = RecallLaunchRequest(url: url) else { return nil }
        self.init(request)
    }

    /// The route in the app's command to a window that is open.
    public init?(userInfo: [AnyHashable: Any]?) {
        guard let request = RecallLaunchRequest(userInfo: userInfo) else { return nil }
        self.init(request)
    }

    // MARK: Routes from inside the window

    /// ⌘N, New Question: the field emptied with the cursor in it. A page
    /// without a field goes to History's.
    public static let newQuestion = RecallRoute(clearsField: true, focusesField: true)
    /// "Show History": History with an empty field, so the day shows.
    public static let showHistory = RecallRoute(place: .history, clearsField: true)
    /// ⌘F: the cursor in this page's field, keeping what is typed. A page
    /// without a field goes to History's.
    public static let findInAsk = RecallRoute(focusesField: true)
    /// "Names You Use", inside About You.
    public static let names = RecallRoute(place: .aboutYou, youPath: [.names])

    /// A Working On item's page, by its id.
    public static func item(_ id: String) -> RecallRoute {
        RecallRoute(workItem: id)
    }

    /// Resume for a Working On item (SPEC-DELTA 3): the item, with Resume's
    /// sheet over it. From the item's Resume button, Today's card, Ask's ⌥↩
    /// and a `hippocampus://resume?item=<id>` link.
    public static func resume(item: String) -> RecallRoute {
        RecallRoute(workItem: item, showsResume: true)
    }

    /// Today with the session starting at `startUs` selected (`session=` in
    /// a link; the Ask panel's "Resume: …", SPEC 2.16).
    public static func session(startUs: Int64) -> RecallRoute {
        RecallRoute(place: .today, day: date(us: startUs), timeRange: startUs...startUs)
    }

    /// "Show in History" for a session: History on the session's own time,
    /// with `eventId` (its newest moment) selected (RULINGS W8).
    public static func history(
        of timeRange: ClosedRange<Int64>,
        selecting eventId: Int64? = nil
    ) -> RecallRoute {
        RecallRoute(place: .history, clearsField: true,
                    focusEventId: eventId.flatMap { UInt64(exactly: $0) },
                    day: Self.date(us: timeRange.lowerBound), timeRange: timeRange)
    }

    /// A session on Today: its day, with the session overlapping
    /// `timeRange` selected (a session row on About You).
    public static func overview(showing timeRange: ClosedRange<Int64>) -> RecallRoute {
        RecallRoute(place: .today, day: Self.date(us: timeRange.lowerBound), timeRange: timeRange)
    }

    private static func date(us: Int64) -> Date {
        Date(timeIntervalSince1970: Double(us) / 1_000_000)
    }
}

/// One launch/deep-link request for the Recall process. Keeping the parsing in
/// RecallUIKit makes the cross-process environment contract testable without
/// constructing a SwiftUI scene.
public struct RecallLaunchRequest: Equatable, Sendable {
    public static let focusEventEnvVar = "MCI_INITIAL_FOCUS_EVENT_ID"
    public static let openPopupEnvVar = "MCI_OPEN_GLOBAL_POPUP"
    public static let distributedCommandName = Notification.Name(
        "ai.hippocampus.recall.command.v1"
    )
    public static let localCommandName = Notification.Name(
        "ai.hippocampus.recall.command.received.v1"
    )
    /// The window's answer to a command: it shows itself. A process quitting
    /// after its last window closed never answers, so the app opens a fresh
    /// window once it has ended.
    public static let acknowledgementName = Notification.Name(
        "ai.hippocampus.recall.command.shown.v1"
    )
    /// The command's id, which the answer repeats. An older app sends none.
    public static let requestIDKey = "request_id"

    /// What the answer to the command `userInfo` carries: its id, nothing
    /// else. Nil when the command asked for no answer.
    public static func acknowledgement(for userInfo: [AnyHashable: Any]?) -> [String: String]? {
        guard let id = userInfo?[requestIDKey] as? String, !id.isEmpty else { return nil }
        return [requestIDKey: id]
    }

    /// Every command brings the window forward (from behind other windows,
    /// out of the Dock when minimized) but one for the old popup alone,
    /// which leaves it where it is.
    public var bringsWindowForward: Bool {
        navigationTab != nil || !openPopup
    }

    public let tab: RecallTab?
    public let focusEventId: UInt64?
    public let openPopup: Bool
    /// A Working On item whose Resume sheet to show, by its id
    /// (`hippocampus://resume?item=<id>`, SPEC-DELTA 3). The app passes it
    /// as the tab `resume:<id>` (`resumeTabPrefix`), so it travels the way
    /// every other request does, at launch and to a window that is open.
    public let resumeItem: String?
    /// A Working On item to show (`work` with `item=<id>`, SPEC 2.16), as
    /// the tab `work:<id>`.
    public let workItem: String?
    /// Today with the session starting then selected (`session=<start_us>`),
    /// as the tab `session:<start_us>`.
    public let sessionStartUs: Int64?
    /// Forget Recent's sheet with a choice (`forget=10m|1h|today`), as the
    /// tab `forget:<choice>`. It still needs the person's click.
    public let forgetRecent: ForgetRecentChoice?

    /// How the app names Resume for an item where a tab goes:
    /// `resume:<id>` (`HippocampusURLRoute.resumeTab` in the app; the two
    /// apps share no code, so tests on both sides pin this form).
    public static let resumeTabPrefix = "resume:"
    /// A Working On item's page: `work:<id>`.
    public static let workTabPrefix = "work:"
    /// A session on Today: `session:<start_us>`.
    public static let sessionTabPrefix = "session:"
    /// Forget Recent's sheet: `forget:10m`, `forget:1h`, `forget:today`.
    public static let forgetTabPrefix = "forget:"
    /// The longest id a Working On item can have.
    public static let maxWorkItemIdLength = 64

    /// Running workspaces change only for an explicit destination or focused event.
    public var navigationTab: RecallTab? {
        focusEventId == nil ? tab : .search
    }

    public var initialTab: RecallTab {
        if focusEventId != nil { return .search }
        return tab ?? (openPopup ? .search : RecallTab.defaultTab)
    }

    public init(
        tab: RecallTab?, focusEventId: UInt64?, openPopup: Bool, resumeItem: String? = nil,
        workItem: String? = nil, sessionStartUs: Int64? = nil, forgetRecent: ForgetRecentChoice? = nil
    ) {
        self.tab = tab
        self.focusEventId = focusEventId.flatMap { $0 == 0 ? nil : $0 }
        self.openPopup = openPopup
        self.resumeItem = resumeItem.flatMap { Self.isWorkItemId($0) ? $0 : nil }
        self.workItem = workItem.flatMap { Self.isWorkItemId($0) ? $0 : nil }
        self.sessionStartUs = sessionStartUs.flatMap { $0 > 0 ? $0 : nil }
        self.forgetRecent = forgetRecent
    }

    /// A request named by the app's tab: a plain name, or one of the
    /// prefixed forms the app writes for links that carry more.
    private init(rawTab: String?, focusEventId: UInt64?, openPopup: Bool) {
        let named = Self.prefixed(rawTab)
        self.init(
            tab: rawTab.flatMap(RecallTab.from),
            focusEventId: focusEventId,
            openPopup: openPopup,
            resumeItem: named.resume,
            workItem: named.work,
            sessionStartUs: named.session,
            forgetRecent: named.forget
        )
    }

    public init(environment: [String: String]) {
        let focus = environment[Self.focusEventEnvVar]
            .flatMap(UInt64.init)
            .flatMap { $0 == 0 ? nil : $0 }
        self.init(
            rawTab: environment[RecallTab.initialTabEnvVar],
            focusEventId: focus,
            openPopup: environment[Self.openPopupEnvVar] == "1"
        )
    }

    public init?(url: URL) {
        guard url.scheme == "hippocampus" else { return nil }
        if url.host == "resume" {
            guard let item = Self.resumeItem(link: url) else { return nil }
            self.init(tab: nil, focusEventId: nil, openPopup: false, resumeItem: item)
            return
        }
        guard url.host == "recall" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        let rawTab = value("tab")
        let tab = rawTab.flatMap(RecallTab.from)
        let focus = value("focus")
            .flatMap(UInt64.init)
            .flatMap { $0 == 0 ? nil : $0 }
        let named = Self.prefixed(rawTab)
        // A link names the rest in its own query: `item=` with `tab=work`,
        // `session=` and `forget=` (SPEC 2.16).
        self.init(
            tab: tab,
            focusEventId: focus,
            openPopup: items.contains { $0.name == "popup" && $0.value == "1" },
            resumeItem: named.resume,
            workItem: named.work ?? (tab == .work ? value("item") : nil),
            sessionStartUs: named.session ?? value("session").flatMap(Int64.init),
            forgetRecent: named.forget ?? value("forget").flatMap(ForgetRecentChoice.init(rawValue:))
        )
    }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo else { return nil }
        let rawTab = userInfo["tab"] as? String
        let focusNumber = userInfo["focus_event_id"] as? NSNumber
        let numericFocus = focusNumber.map(\.uint64Value)
        let focusString = userInfo["focus_event_id"] as? String
        let stringFocus = focusString.flatMap(UInt64.init)
        let parsedFocus = numericFocus ?? stringFocus
        let focus = parsedFocus.flatMap { $0 == 0 ? nil : $0 }
        let openPopup = (userInfo["open_popup"] as? Bool) == true
            || (userInfo["open_popup"] as? NSNumber)?.boolValue == true
        self.init(rawTab: rawTab, focusEventId: focus, openPopup: openPopup)
    }

    /// Whether `id` has the shape of a Working On item's id: 1 to 64 ASCII
    /// letters, digits, `_` and `-`, not starting with `-` (the agent's
    /// `work::is_item_id`). A name never passes, so no route or link can
    /// carry one in an id's place.
    public static func isWorkItemId(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= maxWorkItemIdLength && !id.hasPrefix("-")
            && id.utf8.allSatisfy { byte in
                (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                    || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte == 0x2D
            }
    }

    /// What a prefixed tab names: `resume:<id>`, `work:<id>`,
    /// `session:<start_us>` or `forget:<choice>`. Anything else names none.
    static func prefixed(_ tab: String?) -> (resume: String?, work: String?, session: Int64?,
                                             forget: ForgetRecentChoice?) {
        guard let tab = tab?.trimmingCharacters(in: .whitespacesAndNewlines) else { return (nil, nil, nil, nil) }
        func rest(_ prefix: String) -> String? {
            tab.hasPrefix(prefix) ? String(tab.dropFirst(prefix.count)) : nil
        }
        let resume = rest(resumeTabPrefix).flatMap { isWorkItemId($0) ? $0 : nil }
        let work = rest(workTabPrefix).flatMap { isWorkItemId($0) ? $0 : nil }
        let session = rest(sessionTabPrefix).flatMap { $0.count <= 19 ? Int64($0) : nil }.flatMap { $0 > 0 ? $0 : nil }
        let forget = rest(forgetTabPrefix).flatMap(ForgetRecentChoice.init(rawValue:))
        return (resume, work, session, forget)
    }

    /// The item in the app's `resume:<id>` tab; nil for any other tab.
    static func resumeItem(tab: String?) -> String? {
        prefixed(tab).resume
    }

    /// The item in exactly `hippocampus://resume?item=<id>`: one `item`, an
    /// id, and nothing else (no path, user, port, fragment or other query).
    static func resumeItem(link url: URL) -> String? {
        guard url.scheme == "hippocampus", url.host == "resume",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil,
              let items = components.queryItems, items.count == 1,
              items[0].name == "item", let item = items[0].value, isWorkItemId(item)
        else { return nil }
        return item
    }
}

/// A window as a command finds it.
public struct RecallWindowState: Equatable, Sendable {
    public let isVisible: Bool
    public let isMiniaturized: Bool

    public init(isVisible: Bool, isMiniaturized: Bool) {
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
    }
}

/// How the window's process answers a command from the app.
public enum RecallCommandAnswer: Equatable, Sendable {
    /// It shows its window, minimized or not, and says so: the app opens
    /// nothing else.
    case show
    /// It is quitting, or has no window to show (its last one just closed,
    /// and it quits with it): no answer, so the app waits for it to end and
    /// opens a fresh window on the place asked for.
    case none

    public static func decide(terminating: Bool, windows: [RecallWindowState]) -> RecallCommandAnswer {
        guard !terminating, windows.contains(where: { $0.isVisible || $0.isMiniaturized }) else { return .none }
        return .show
    }
}

/// Identifies a focused-event navigation, including repeated requests for the
/// same event. SwiftUI uses the sequence as a task identity.
public struct RecallFocusRequest: Equatable, Hashable, Sendable {
    public let eventId: UInt64
    public let sequence: UInt64

    public init(eventId: UInt64, sequence: UInt64) {
        self.eventId = eventId
        self.sequence = sequence
    }
}
