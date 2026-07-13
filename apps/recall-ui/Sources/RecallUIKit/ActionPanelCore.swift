// ActionPanelCore.swift — pure logic for the ⌘K Action Panel. Split
// from the SwiftUI view (`RecallUI/ActionPanel/ActionPanel.swift`) so
// `RecallUIKitTests` can exercise it without linking the executable.
// See peer study §4 (P1).

import Foundation

public struct ActionPanelCommand: Identifiable {
    public enum Category: String, Sendable {
        case search = "Search"
        case hit = "Hit"
        case app = "App"
        case debug = "Debug"
    }

    public let id: String
    public let title: String
    public let shortcut: String
    public let category: Category
    public let isEnabled: () -> Bool
    public let action: () -> Void

    public init(
        id: String,
        title: String,
        shortcut: String,
        category: Category,
        isEnabled: @escaping () -> Bool = { true },
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.category = category
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
