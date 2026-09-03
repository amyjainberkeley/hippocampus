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
    case now = 0
    case search = 1
    case timeline = 2
    case episodes = 3
    case brief = 4
    case privacy = 5
    /// Cycle 8.42 — minimal Settings surface hosting the user-dictionary
    /// editor. Future settings can grow into the same scene.
    case settings = 6
    /// Cycle 8.46 — Privacy Dashboard (⌘7). Enterprise-grade trust
    /// artifact: shows what MCI has captured + gives the user delete /
    /// export controls over their brain. Amy's directive 2026-07-13:
    /// "show the full control, no collection."
    case privacyDashboard = 7
    /// **V2-P13 (Phase D scaffold)** — Rewind-style visual timeline
    /// strip (⌘8). Horizontally-scrolling row of capture cards with
    /// thumbnails + time markers. Distinct from `.timeline` (the flat
    /// chronological list); the two coexist during Phase D scaffold and
    /// may collapse into one tab in Phase D full impl (cycle 8.55+).
    case timelineStrip = 8
    /// Map a deep-link `?tab=…` query value (case-insensitive) to a
    /// `RecallTab`. Returns `nil` for unknown values so callers can
    /// ignore junk without crashing.
    ///
    /// Pinned by `BriefDeepLinkRoutingTests`.
    public static func from(deepLinkValue: String) -> RecallTab? {
        switch deepLinkValue.lowercased() {
        case "now":      return .now
        case "search":   return .search
        case "timeline": return .timeline
        case "episodes": return .episodes
        case "privacy":  return .privacy
        case "brief":    return .brief
        case "settings": return .settings
        case "dashboard", "privacy-dashboard": return .privacyDashboard
        case "timeline-strip", "strip": return .timelineStrip
        default:         return nil
        }
    }

    /// The env-var the recall-ui executable reads at launch to pick
    /// its initial tab. Hippocampus.app sets this when it handles a
    /// `hippocampus://recall?tab=…` URL.
    public static let initialTabEnvVar = "MCI_INITIAL_TAB"
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
