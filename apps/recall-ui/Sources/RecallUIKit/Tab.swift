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
        default:         return nil
        }
    }

    /// The env-var the recall-ui executable reads at launch to pick
    /// its initial tab. Hippocampus.app sets this when it handles a
    /// `hippocampus://recall?tab=…` URL.
    public static let initialTabEnvVar = "MCI_INITIAL_TAB"
}
