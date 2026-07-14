// SPDX-License-Identifier: TBD-private
//
// PreferencesStore — the UserDefaults-backed model behind the
// comprehensive Preferences window (Mac-native surface, ⌘,).
//
// Split from the SwiftUI window (which lives in the `Hippocampus`
// executable target and is not testable under SwiftPM) so we can
// round-trip every preference under XCTest and pin defaults against
// merge-conflict drift. The window binds directly to the `@Published`
// properties here.
//
// Design principles:
//   - **Non-sensitive only**: preferences are cosmetic + workflow
//     knobs (launch-at-login, menu-bar-visibility, default recall
//     tab, retention window, Ollama endpoint). They live in
//     `UserDefaults.standard`, not in the SQLCipher brain. Anything
//     that touches capture policy or crypto stays where it is
//     (denylist / allowlist / key store).
//   - **Default = current behavior**: every preference defaults to
//     the value the app already ships with today. Flipping a
//     preference is a deliberate opt-in / opt-out; a first-run user
//     who never opens Preferences sees zero behavior change.
//   - **Testable in isolation**: the store accepts an injected
//     `UserDefaults` so `PreferencesStoreTests` can use an ephemeral
//     suite and never touch the process-wide standard defaults.
//   - **Stable keys**: every key is prefixed `ai.hippocampus.prefs.`
//     so a future migration can grep the namespace and future
//     `UserDefaults` cleanups are safe.
//
// This file is deliberately small (≤ ~250 LOC) and dependency-free
// beyond Foundation + Combine — no AppKit, no SwiftUI — so the
// HippocampusKitTests target can `@testable import HippocampusKit`
// and exercise every path headlessly.

import Foundation
import Combine

// MARK: - Enum types persisted as strings

/// Which tab the Recall UI opens on when the user hits ⌘R / opens the
/// menu-bar "Show Recall Window" verb. Matches the `MCI_INITIAL_TAB`
/// env var the executable already honors (see `ProcessSupervisor.openRecallUI`).
public enum PreferredRecallTab: String, CaseIterable, Sendable, Codable {
    case search
    case timeline
    case episodes
    case brief

    public var displayLabel: String {
        switch self {
        case .search: return "Search"
        case .timeline: return "Timeline"
        case .episodes: return "Episodes"
        case .brief: return "Brief"
        }
    }
}

/// How long the brain keeps captured events before the retention
/// sweeper prunes them. `.forever` is the current default — the sweeper
/// is a no-op unless the user explicitly narrows the window.
public enum RetentionPolicy: String, CaseIterable, Sendable, Codable {
    case days30
    case days90
    case forever

    public var displayLabel: String {
        switch self {
        case .days30: return "30 days"
        case .days90: return "90 days"
        case .forever: return "Forever"
        }
    }

    /// TimeInterval a downstream sweeper can use. `nil` means no
    /// pruning. Kept off the caller so the sweeper never has to
    /// re-parse the enum.
    public var maxAgeSeconds: TimeInterval? {
        switch self {
        case .days30: return 30 * 24 * 3600
        case .days90: return 90 * 24 * 3600
        case .forever: return nil
        }
    }
}

// MARK: - Store

/// UserDefaults-backed preferences store. Every property is
/// `@Published` so SwiftUI Toggles / Pickers bind directly.
///
/// A single instance is created by the app at launch and passed into
/// the Preferences window; tests construct their own with an ephemeral
/// `UserDefaults`.
@MainActor
public final class PreferencesStore: ObservableObject {
    // MARK: General

    /// Whether the menu-bar icon renders. If off, only ⇧⌘Space
    /// remains as an entry point. Currently informational — the
    /// MenuBarExtra scene reads this at launch (a future PR wires
    /// the live hide/show; today the value is persisted and the
    /// scene reads it on next relaunch).
    @Published public var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon) }
    }

    /// Recall UI's initial tab. Read by `ProcessSupervisor.openRecallUI`
    /// when no explicit `initialTab:` is passed (menu-bar "Show Recall
    /// Window" uses the default; "Show Timeline" passes `"timeline"`
    /// explicitly and is unaffected).
    @Published public var defaultRecallTab: PreferredRecallTab {
        didSet { defaults.set(defaultRecallTab.rawValue, forKey: Keys.defaultRecallTab) }
    }

    // MARK: Capture

    /// Deep-hook plugin toggles. Each plugin is a named boolean; the
    /// values default to whatever the plugin ships with (`Messages`
    /// and `Mail` are on by default; future `Calendar`, `Notes`,
    /// `Reminders` default off until they ship).
    ///
    /// Stored as a small `[String: Bool]` dict under a single key so
    /// adding a new plugin doesn't require a new key + migration.
    @Published public var deepHookPlugins: [String: Bool] {
        didSet {
            if let data = try? JSONEncoder().encode(deepHookPlugins) {
                defaults.set(data, forKey: Keys.deepHookPlugins)
            }
        }
    }

    // MARK: Privacy

    /// Retention window applied by the brain-pruner. Defaults to
    /// `.forever` to match current behavior — the pruner is idle
    /// unless the user opts in.
    @Published public var retentionPolicy: RetentionPolicy {
        didSet { defaults.set(retentionPolicy.rawValue, forKey: Keys.retentionPolicy) }
    }

    // MARK: Advanced

    /// Optional Ollama endpoint for BYOK local-LLM users who want to
    /// route brief-authoring through their own local model instead of
    /// bundled Qwen3. Empty string = disabled (default).
    @Published public var ollamaEndpoint: String {
        didSet { defaults.set(ollamaEndpoint, forKey: Keys.ollamaEndpoint) }
    }

    /// Custom SQLCipher database path. Empty string = default
    /// (`~/Library/Application Support/Hippocampus/mci.sqlite`).
    /// Changing this requires a restart — the supervisor caches its
    /// dbPath at boot.
    @Published public var customDatabasePath: String {
        didSet { defaults.set(customDatabasePath, forKey: Keys.customDatabasePath) }
    }

    // MARK: - Storage

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Read + coerce every property from the injected UserDefaults.
        // First-launch users see the default value; existing users see
        // whatever they last set. Every read is defensive — an
        // out-of-range enum falls back to the shipped default rather
        // than crashing.
        self.showMenuBarIcon = defaults.object(forKey: Keys.showMenuBarIcon) as? Bool ?? true

        let rawTab = defaults.string(forKey: Keys.defaultRecallTab) ?? PreferredRecallTab.search.rawValue
        self.defaultRecallTab = PreferredRecallTab(rawValue: rawTab) ?? .search

        if let data = defaults.data(forKey: Keys.deepHookPlugins),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) {
            self.deepHookPlugins = decoded
        } else {
            self.deepHookPlugins = PreferencesStore.defaultDeepHookPlugins
        }

        let rawRetention = defaults.string(forKey: Keys.retentionPolicy) ?? RetentionPolicy.forever.rawValue
        self.retentionPolicy = RetentionPolicy(rawValue: rawRetention) ?? .forever

        self.ollamaEndpoint = defaults.string(forKey: Keys.ollamaEndpoint) ?? ""
        self.customDatabasePath = defaults.string(forKey: Keys.customDatabasePath) ?? ""
    }

    // MARK: - Known plugin catalog

    /// The set of deep-hook plugins the app knows about. Shipping
    /// plugins default to enabled; future ones default off so a new
    /// row appearing in the list is a deliberate opt-in. Extending
    /// this dict is a single-line change; no migration required
    /// because the store rehydrates any missing key on next read.
    public static let defaultDeepHookPlugins: [String: Bool] = [
        "Messages": true,
        "Mail": true,
        "Calendar": false,
        "Notes": false,
        "Reminders": false,
    ]

    /// Stable display ordering for UI. Alphabetical + shipping-first
    /// keeps the list scannable regardless of dict iteration order.
    public static let deepHookPluginOrder: [String] = [
        "Messages", "Mail", "Calendar", "Notes", "Reminders",
    ]

    // MARK: - Keys

    /// Every UserDefaults key the store owns. The `ai.hippocampus.prefs.`
    /// prefix is the only namespace this store writes to — a future
    /// `defaults delete` cleanup is a one-liner.
    enum Keys {
        static let showMenuBarIcon = "ai.hippocampus.prefs.showMenuBarIcon"
        static let defaultRecallTab = "ai.hippocampus.prefs.defaultRecallTab"
        static let deepHookPlugins = "ai.hippocampus.prefs.deepHookPlugins"
        static let retentionPolicy = "ai.hippocampus.prefs.retentionPolicy"
        static let ollamaEndpoint = "ai.hippocampus.prefs.ollamaEndpoint"
        static let customDatabasePath = "ai.hippocampus.prefs.customDatabasePath"
    }
}
