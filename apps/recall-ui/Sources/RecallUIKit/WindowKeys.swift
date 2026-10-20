import Foundation

/// One line of the Keyboard Shortcuts sheet: the keys, and what they do.
public struct WindowKey: Equatable, Sendable, Identifiable {
    /// Each key or chord as a chip, in order ("⌘[", "⌘]").
    public let keys: [String]
    /// Whether the chips are the two ends of a run ("⌘1 – ⌘9").
    public let isRange: Bool
    public let does: String
    public let group: ActionPanelCommand.Category

    public var id: String { keys.joined(separator: " ") }

    public init(_ keys: [String], range: Bool = false, _ does: String, in group: ActionPanelCommand.Category) {
        self.keys = keys
        self.isRange = range
        self.does = does
        self.group = group
    }
}

/// Every key the window knows (SPEC 2.10 with SPEC-DELTA 1), for the
/// Keyboard Shortcuts sheet (⌘/), whose headings are the ⌘K groups. The
/// menus carry the same keys; tests pin that the two agree.
public enum WindowKeys {
    public static let all: [WindowKey] = [
        WindowKey(["\u{2318}1", "\u{2318}9"], range: true,
                  "Today, History, Web Pages, Documents, Code, Conversations, Looked Up, About You, AI Tools",
                  in: .goTo),
        WindowKey(["\u{2318}[", "\u{2318}]"], "Back and Forward", in: .goTo),
        WindowKey(["\u{2318}\u{2190}", "\u{2318}\u{2192}"], "Previous and next day, on Today and History", in: .goTo),
        WindowKey(["\u{2318}T"], "Go to today, on Today and History; elsewhere, open Today", in: .goTo),
        WindowKey(["\u{2303}\u{2318}S"], "Show or hide the sidebar", in: .goTo),
        WindowKey(["\u{2318}K"], "The command bar", in: .goTo),
        WindowKey(["\u{2318}F"], "Find in this page", in: .moments),
        WindowKey(["\u{2318}N"], "New Question", in: .moments),
        WindowKey(["\u{2191}", "\u{2193}", "\u{2190}", "\u{2192}"],
                  "Move in lists, menus and the sidebar; \u{2190} \u{2192} move along the day strip", in: .moments),
        WindowKey(["Space"], "The selected moment\u{2019}s screenshot, full size", in: .moments),
        WindowKey(["\u{2318}C", "\u{21E7}\u{2318}C"], "Copy Text, Copy for Your AI", in: .moments),
        WindowKey(["\u{2318}O", "\u{21E7}\u{2318}R"], "Open Link, Show Related", in: .moments),
        WindowKey(["Esc"], "Close, then clear the selection, then empty the field", in: .moments),
        WindowKey(["\u{2318}\u{21A9}"], "Ask your AI tool, with the selection or the typed question", in: .actions),
        WindowKey(["\u{2325}\u{21A9}"], "Ask on this Mac", in: .actions),
        WindowKey(["\u{2318}\u{232B}", "\u{2318}Z"], "Forget the selection, and undo it", in: .actions),
        WindowKey(["\u{21E7}\u{2318}\u{232B}", "\u{2318}J"], "Forget Recent, Context for This Folder", in: .actions),
        WindowKey(["\u{2318}R"], "Refresh", in: .actions),
        WindowKey(["\u{2318}/"], "Keyboard Shortcuts", in: .help),
        WindowKey(["\u{21E7}\u{2318}N"], "What\u{2019}s New", in: .help),
        WindowKey(["\u{2318},"], "Preferences", in: .help),
    ]

    /// The sheet's sections, in the ⌘K groups' order.
    public static var grouped: [(group: ActionPanelCommand.Category, keys: [WindowKey])] {
        ActionPanelCommand.Category.allCases.compactMap { group in
            let keys = all.filter { $0.group == group }
            return keys.isEmpty ? nil : (group, keys)
        }
    }
}
