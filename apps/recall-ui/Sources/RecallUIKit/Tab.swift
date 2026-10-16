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

/// The three places in the window (RULINGS G5).
public enum RecallPlace: String, CaseIterable, Sendable {
    case overview, ask, you
}

public extension RecallTab {
    /// The place every name opens (RULINGS X9). Names are an outside
    /// contract: the app, links and old menus still send each of them.
    var place: RecallPlace {
        switch self {
        case .now, .brief: .overview
        case .search, .timeline, .timelineStrip, .episodes: .ask
        case .you, .privacy, .privacyDashboard, .settings: .you
        }
    }

    /// History, inside Ask: the field is emptied so it shows.
    var opensHistory: Bool {
        [.timeline, .timelineStrip, .episodes].contains(self)
    }

    /// Inside You, what is remembered and the controls that delete it.
    var opensPrivacy: Bool {
        [.privacy, .privacyDashboard].contains(self)
    }
}

/// A page pushed inside You.
public enum RecallYouPage: String, Hashable, Sendable {
    /// What is remembered, and deleting it.
    case privacy
    /// The names you use.
    case names
}

/// Where the window goes, and what it shows there.
///
/// One value for every way a request arrives: at launch (`MCI_INITIAL_TAB`
/// and the other launch variables), from the app while the window is open
/// (its command notification or a link), and from inside the window ("Show in
/// History", a session on You). The window applies a route the same way in
/// each case (critique-recall-engineering finding 5).
public struct RecallRoute: Equatable, Sendable {
    /// The place to show. Nil keeps the place on screen; a window that is
    /// only opening shows Overview.
    public var place: RecallPlace?
    /// Pages pushed inside You, in order. Empty shows You itself.
    public var youPath: [RecallYouPage]
    /// Empty Ask's field, so History shows.
    public var clearsField: Bool
    /// Put the cursor in Ask's field.
    public var focusesField: Bool
    /// A memory to show. With no `timeRange` Ask shows it with its detail;
    /// with one, History selects it inside that range.
    public var focusEventId: UInt64?
    /// A moment in the day to show: Overview's day, or History's.
    public var day: Date?
    /// A session's own time, in microseconds since the epoch. Overview
    /// selects the session overlapping it; History loads it (RULINGS W8).
    public var timeRange: ClosedRange<Int64>?
    /// Open Ask from the menu bar rather than anything in the window: the
    /// window has no popup of its own (RULINGS W3).
    public var opensAskPanel: Bool

    public init(
        place: RecallPlace? = nil,
        youPath: [RecallYouPage] = [],
        clearsField: Bool = false,
        focusesField: Bool = false,
        focusEventId: UInt64? = nil,
        day: Date? = nil,
        timeRange: ClosedRange<Int64>? = nil,
        opensAskPanel: Bool = false
    ) {
        self.place = place
        self.youPath = youPath
        self.clearsField = clearsField
        self.focusesField = focusesField
        self.focusEventId = focusEventId.flatMap { $0 == 0 ? nil : $0 }
        self.day = day
        self.timeRange = timeRange
        self.opensAskPanel = opensAskPanel
    }

    /// Ask, opened from the menu bar: where a request for the window's old
    /// popup goes (RULINGS W3).
    public static let askPanelURL = URL(string: "hippocampus://ask")!

    /// The place this route shows when `current` is on screen. A window that
    /// is only opening passes `.overview`.
    public func place(keeping current: RecallPlace) -> RecallPlace {
        place ?? current
    }

    /// The route for one of the window's names (RULINGS X9).
    public init(tab: RecallTab) {
        self.init(place: tab.place, youPath: tab.opensPrivacy ? [.privacy] : [],
                  clearsField: tab.opensHistory)
    }

    /// Nil for a name the window does not know, so junk is ignored.
    public init?(tab: String) {
        guard let tab = RecallTab.from(
            deepLinkValue: tab.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else { return nil }
        self.init(tab: tab)
    }

    /// What a request from the app asks for, at launch or while the window is
    /// open. A memory to show lands in Ask, whatever the name says. A name
    /// opens its place. The old popup flag opens Ask from the menu bar and
    /// leaves the window where it is.
    public init(_ request: RecallLaunchRequest) {
        if let eventId = request.focusEventId {
            self.init(place: .ask, clearsField: true, focusEventId: eventId)
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

    /// "Ask": an empty field with the cursor in it.
    public static let newQuestion = RecallRoute(place: .ask, clearsField: true, focusesField: true)
    /// "Show History": Ask with an empty field, so History shows.
    public static let showHistory = RecallRoute(place: .ask, clearsField: true)
    /// ⌘F: the cursor in Ask's field, keeping what is typed.
    public static let findInAsk = RecallRoute(place: .ask, focusesField: true)
    /// "Names You Use", inside You.
    public static let names = RecallRoute(place: .you, youPath: [.names])

    /// "Show in History" for a session: History on the session's own time,
    /// with `eventId` (its newest moment) selected (RULINGS W8).
    public static func history(
        of timeRange: ClosedRange<Int64>,
        selecting eventId: Int64? = nil
    ) -> RecallRoute {
        RecallRoute(place: .ask, clearsField: true,
                    focusEventId: eventId.flatMap { UInt64(exactly: $0) },
                    day: Self.date(us: timeRange.lowerBound), timeRange: timeRange)
    }

    /// A session on Overview: its day, with the session overlapping
    /// `timeRange` selected (a session row on You).
    public static func overview(showing timeRange: ClosedRange<Int64>) -> RecallRoute {
        RecallRoute(place: .overview, day: Self.date(us: timeRange.lowerBound), timeRange: timeRange)
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

    public let tab: RecallTab?
    public let focusEventId: UInt64?
    public let openPopup: Bool

    /// Running workspaces change only for an explicit destination or focused event.
    public var navigationTab: RecallTab? {
        focusEventId == nil ? tab : .search
    }

    public var initialTab: RecallTab {
        if focusEventId != nil { return .search }
        return tab ?? (openPopup ? .search : RecallTab.defaultTab)
    }

    public init(tab: RecallTab?, focusEventId: UInt64?, openPopup: Bool) {
        self.tab = tab
        self.focusEventId = focusEventId.flatMap { $0 == 0 ? nil : $0 }
        self.openPopup = openPopup
    }

    public init(environment: [String: String]) {
        let tab = environment[RecallTab.initialTabEnvVar].flatMap(RecallTab.from)
        let focus = environment[Self.focusEventEnvVar]
            .flatMap(UInt64.init)
            .flatMap { $0 == 0 ? nil : $0 }
        self.init(
            tab: tab,
            focusEventId: focus,
            openPopup: environment[Self.openPopupEnvVar] == "1"
        )
    }

    public init?(url: URL) {
        guard url.scheme == "hippocampus", url.host == "recall" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let tab = items.first(where: { $0.name == "tab" })?.value.flatMap(RecallTab.from)
        let focus = items.first(where: { $0.name == "focus" })?.value
            .flatMap(UInt64.init)
            .flatMap { $0 == 0 ? nil : $0 }
        self.init(
            tab: tab,
            focusEventId: focus,
            openPopup: items.contains { $0.name == "popup" && $0.value == "1" }
        )
    }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo else { return nil }
        let tab = (userInfo["tab"] as? String).flatMap {
            RecallTab.from(deepLinkValue: $0)
        }
        let focusNumber = userInfo["focus_event_id"] as? NSNumber
        let numericFocus = focusNumber.map(\.uint64Value)
        let focusString = userInfo["focus_event_id"] as? String
        let stringFocus = focusString.flatMap(UInt64.init)
        let parsedFocus = numericFocus ?? stringFocus
        let focus = parsedFocus.flatMap { $0 == 0 ? nil : $0 }
        let openPopup = (userInfo["open_popup"] as? Bool) == true
            || (userInfo["open_popup"] as? NSNumber)?.boolValue == true
        self.init(tab: tab, focusEventId: focus, openPopup: openPopup)
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
