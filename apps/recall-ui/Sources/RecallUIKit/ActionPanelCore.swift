// ActionPanelCore.swift — pure logic for the ⌘K Action Panel. Split
// from the SwiftUI view (`RecallUI/ActionPanel/ActionPanel.swift`) so
// `RecallUIKitTests` can exercise it without linking the executable.
// See peer study §4 (P1).

import Foundation

public struct ActionPanelCommand: Identifiable {
    /// The ⌘K groups, in order (SPEC 2.9): Go To (the places and every
    /// Working On item), Moments (matches for what is typed), Actions and
    /// Help. The shortcuts sheet's headings are the same.
    public enum Category: String, Sendable, CaseIterable {
        case goTo = "Go To"
        case moments = "Moments"
        case actions = "Actions"
        case help = "Help"

        /// The names the groups had before (SPEC 2.9: "Hit" and "Debug"
        /// go). Kept so a command registered by an older name lands in the
        /// group that holds it now.
        public static let search = Category.moments
        public static let hit = Category.actions
        public static let app = Category.actions
        public static let debug = Category.help
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

    /// The ids each view's list registered, by the view's group.
    private var groups: [String: [String]] = [:]

    /// Registers a view's whole list as one group, and again whenever the
    /// list changes: ids the group had that are gone are unregistered, new
    /// ones registered, the rest replaced. So ⌘K's Go To lists the Working On
    /// items that load after the window appears, and drops one that leaves.
    public func register(group: String, _ commands: [ActionPanelCommand]) {
        let ids = commands.map(\.id)
        for id in groups[group] ?? [] where !ids.contains(id) {
            unregister(id: id)
        }
        for command in commands {
            register(command)
        }
        groups[group] = ids
    }

    /// Every command a group registered goes: its view went.
    public func unregister(group: String) {
        for id in groups.removeValue(forKey: group) ?? [] {
            unregister(id: id)
        }
    }
    public func show() { isVisible = true }
    public func hide() { isVisible = false }
    public func toggle() { isVisible.toggle() }

    public func showHelp() { isHelpVisible = true }
    public func hideHelp() { isHelpVisible = false }

    public func beginRefresh() { isRefreshing = true }
    public func endRefresh() { isRefreshing = false }

    /// Group the currently-registered commands by category, in the
    /// canonical presentation order (Go To → Moments → Actions → Help) with
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

public extension [ActionPanelCommand] {
    /// What a list shows in ⌘K, to tell when it changed: each command's id,
    /// title and shortcut, in order.
    var panelSignature: [String] {
        map { "\($0.id)\u{1F}\($0.title)\u{1F}\($0.shortcut)" }
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
    /// dropped so the palette only shows what can be invoked now. With
    /// nothing typed they come in ⌘K's groups (SPEC 2.9): Go To, with the
    /// places and every Working On item, then Moments, Actions and Help,
    /// each group in the order its commands were registered.
    public func filtered(from commands: [ActionPanelCommand]) -> [ActionPanelCommand] {
        let enabled = commands.filter { $0.isEnabled() }
        guard !query.isEmpty else { return Self.inGroups(enabled) }
        return enabled.compactMap { cmd -> (ActionPanelCommand, Int)? in
            guard let s = FuzzyMatcher.score(query: query, candidate: cmd.title) else { return nil }
            return (cmd, s)
        }.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    /// `commands` in ⌘K's groups' order, keeping their order within each.
    static func inGroups(_ commands: [ActionPanelCommand]) -> [ActionPanelCommand] {
        let order = ActionPanelCommand.Category.allCases
        return commands.enumerated().sorted { first, second in
            let a = order.firstIndex(of: first.element.category) ?? order.count
            let b = order.firstIndex(of: second.element.category) ?? order.count
            return a == b ? first.offset < second.offset : a < b
        }.map(\.element)
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
