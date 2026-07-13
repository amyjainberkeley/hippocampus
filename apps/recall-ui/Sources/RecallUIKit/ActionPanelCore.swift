// ActionPanelCore.swift — pure logic for the ⌘K Action Panel. Split
// from the SwiftUI view (`RecallUI/ActionPanel/ActionPanel.swift`) so
// `RecallUIKitTests` can exercise it without linking the executable.
// See peer study §4 (P1).

import Foundation

public struct ActionPanelCommand: Identifiable {
    public enum Category: String, Sendable, CaseIterable {
        case search = "Search"
        case hit = "Hit"
        case app = "App"
        case debug = "Debug"
    }

    public let id: String
    public let title: String
    public let shortcut: String
    public let category: Category
    /// One-line description surfaced in the ⌘/ help sheet. Optional so
    /// existing call sites keep compiling; empty renders as "—" in the
    /// help sheet's description column.
    public let description: String
    public let isEnabled: () -> Bool
    public let action: () -> Void

    public init(
        id: String,
        title: String,
        shortcut: String,
        category: Category,
        description: String = "",
        isEnabled: @escaping () -> Bool = { true },
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.category = category
        self.description = description
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// Decentralized command registry. Views register on `.onAppear` and
/// unregister on `.onDisappear` — that pattern is how contextual
/// gating (per-hit, per-view) works.
@MainActor
public final class ActionPanelRegistry: ObservableObject {
    public static let shared = ActionPanelRegistry()
    @Published public private(set) var commands: [ActionPanelCommand] = []
    @Published public var isVisible: Bool = false
    /// Whether the ⌘/ Keyboard Shortcuts help sheet is currently
    /// presented. Kept on the registry (Single Source of Truth) so any
    /// view can toggle it and the RootView's `.sheet` binding auto-fires.
    @Published public var isHelpVisible: Bool = false
    /// True while a ⌘R "refresh brain" pass is in-flight. Rendered as a
    /// spinner in the SearchView's search field. Reset by
    /// `endRefresh()`.
    @Published public var isRefreshing: Bool = false

    public init() {}

    public func register(_ command: ActionPanelCommand) {
        if let idx = commands.firstIndex(where: { $0.id == command.id }) {
            commands[idx] = command
        } else {
            commands.append(command)
        }
    }

    public func unregister(id: String) { commands.removeAll { $0.id == id } }
    public func show() { isVisible = true }
    public func hide() { isVisible = false }
    public func toggle() { isVisible.toggle() }

    public func showHelp() { isHelpVisible = true }
    public func hideHelp() { isHelpVisible = false }

    public func beginRefresh() { isRefreshing = true }
    public func endRefresh() { isRefreshing = false }

    /// Group the currently-registered commands by category, in the
    /// canonical presentation order (Search → Hit → App → Debug) with
    /// each group's commands sorted by title. Powers the ⌘/ help sheet
    /// — kept here so the sheet's rendering is a pure function of the
    /// registry (no hardcoded lists) and headless tests can pin the
    /// grouping without spinning up SwiftUI.
    public func groupedByCategory() -> [(category: ActionPanelCommand.Category, commands: [ActionPanelCommand])] {
        let byCategory = Dictionary(grouping: commands) { $0.category }
        return ActionPanelCommand.Category.allCases.compactMap { cat in
            guard let cmds = byCategory[cat], !cmds.isEmpty else { return nil }
            return (cat, cmds.sorted { $0.title < $1.title })
        }
    }
}

/// Substring-with-gaps fuzzy scorer. Every char of `query` must
/// appear in `candidate` in order (case-insensitive); score rewards
/// consecutive matches and word-start matches. No external dep.
public enum FuzzyMatcher {
    public static func score(query: String, candidate: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        var qi = 0, score = 0, lastMatched = -2
        var prevIsSep = true
        for ci in 0..<c.count {
            let ch = c[ci]
            if qi < q.count && ch == q[qi] {
                var bonus = 1
                if ci == lastMatched + 1 { bonus += 3 }
                if prevIsSep { bonus += 2 }
                score += bonus
                lastMatched = ci
                qi += 1
            }
            prevIsSep = (ch == " " || ch == "-" || ch == "_" || ch == "/")
        }
        return qi == q.count ? score : nil
    }
}

@MainActor
public final class ActionPanelViewModel: ObservableObject {
    @Published public var query: String = ""
    @Published public var selectedIndex: Int = 0
    private let registry: ActionPanelRegistry

    public init(registry: ActionPanelRegistry = .shared) { self.registry = registry }

    /// Filtered + fuzzy-ranked commands. Disabled commands are
    /// dropped so the palette only shows what can be invoked now.
    public func filtered(from commands: [ActionPanelCommand]) -> [ActionPanelCommand] {
        let enabled = commands.filter { $0.isEnabled() }
        guard !query.isEmpty else { return enabled }
        return enabled.compactMap { cmd -> (ActionPanelCommand, Int)? in
            guard let s = FuzzyMatcher.score(query: query, candidate: cmd.title) else { return nil }
            return (cmd, s)
        }.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    public func selectNext(in list: [ActionPanelCommand]) {
        guard !list.isEmpty else { return }
        selectedIndex = min(selectedIndex + 1, list.count - 1)
    }

    public func selectPrev() { selectedIndex = max(selectedIndex - 1, 0) }

    public func invoke(from list: [ActionPanelCommand]) {
        guard list.indices.contains(selectedIndex) else { return }
        let cmd = list[selectedIndex]
        registry.hide()
        cmd.action()
    }

    public func reset() { query = ""; selectedIndex = 0 }
}
