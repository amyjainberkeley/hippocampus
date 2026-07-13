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
