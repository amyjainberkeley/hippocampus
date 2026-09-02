// SPDX-License-Identifier: TBD-private
//
// PreferencesStore — the persisted model behind the
// comprehensive Preferences window (Mac-native surface, ⌘,).
//
// Split from the SwiftUI window (which lives in the `Hippocampus`
// executable target and is not testable under SwiftPM) so we can
// round-trip every preference under XCTest and pin defaults against
// merge-conflict drift. The window binds directly to the `@Published`
// properties here.
//
// Design principles:
//   - **One retention authority**: cosmetic and workflow preferences
//     live in UserDefaults, while retention is written atomically to
//     the same `retention.json` the agent reads.
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
// This file is dependency-free beyond Foundation + Combine — no
// AppKit, no SwiftUI — so the
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
    case forever
    case thirtyDays
    case sevenDays
    case custom

    public var displayLabel: String {
        switch self {
        case .forever: return "Forever"
        case .thirtyDays: return "30 days"
        case .sevenDays: return "7 days"
        case .custom: return "Custom"
        }
    }

    /// TimeInterval a downstream sweeper can use. `nil` means no
    /// pruning. Kept off the caller so the sweeper never has to
    /// re-parse the enum.
    public var maxAgeSeconds: TimeInterval? {
        switch self {
        case .forever: return nil
        case .thirtyDays: return 30 * 24 * 3600
        case .sevenDays: return 7 * 24 * 3600
        case .custom: return nil
        }
    }
}

// MARK: - Store

/// Preferences store. Cosmetic properties bind directly through
/// UserDefaults; retention changes use `setRetentionPolicy` so the
/// worker-compatible file is committed before the UI changes.
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

    // MARK: Privacy

    /// Retention window applied by the brain-pruner. Defaults to
    /// `.forever` to match current behavior — the pruner is idle
    /// unless the user opts in.
    @Published public private(set) var retentionPolicy: RetentionPolicy
    @Published public private(set) var retentionCustomDays: Int?
    @Published public private(set) var retentionWriteError: String?

    // MARK: Advanced

    /// Custom SQLCipher database path. Empty string = default
    /// (`~/Library/Application Support/Hippocampus/mci.sqlite`).
    /// Changing this requires a restart — the supervisor caches its
    /// dbPath at boot.
    @Published public var customDatabasePath: String {
        didSet { defaults.set(customDatabasePath, forKey: Keys.customDatabasePath) }
    }

    // MARK: - Storage

    private let defaults: UserDefaults
    private let retentionURL: URL
    private let now: () -> Date

    private struct PersistedRetention: Codable {
        let mode: String
        let days: Int?
        let updated_at: String

        enum CodingKeys: String, CodingKey {
            case mode
            case days
            case updated_at
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(mode, forKey: .mode)
            if let days {
                try container.encode(days, forKey: .days)
            } else {
                try container.encodeNil(forKey: .days)
            }
            try container.encode(updated_at, forKey: .updated_at)
        }
    }

    public init(
        defaults: UserDefaults = .standard,
        retentionURL: URL = PreferencesStore.defaultRetentionURL,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.retentionURL = retentionURL
        self.now = now

        // Read + coerce every property from the injected UserDefaults.
        // First-launch users see the default value; existing users see
        // whatever they last set. Every read is defensive — an
        // out-of-range enum falls back to the shipped default rather
        // than crashing.
        self.showMenuBarIcon = defaults.object(forKey: Keys.showMenuBarIcon) as? Bool ?? true

        let rawTab = defaults.string(forKey: Keys.defaultRecallTab) ?? PreferredRecallTab.search.rawValue
        self.defaultRecallTab = PreferredRecallTab(rawValue: rawTab) ?? .search

        self.retentionPolicy = .forever
        self.retentionCustomDays = nil
        self.retentionWriteError = nil

        self.customDatabasePath = defaults.string(forKey: Keys.customDatabasePath) ?? ""

        if FileManager.default.fileExists(atPath: retentionURL.path) {
            do {
                let loaded = try Self.loadRetention(from: retentionURL)
                self.retentionPolicy = loaded.policy
                self.retentionCustomDays = loaded.days
            } catch {
                self.retentionWriteError = "Retention policy could not be read; keeping events forever."
            }
        } else if let migrated = Self.legacyRetention(
            defaults.string(forKey: Keys.retentionPolicy)
        ) {
            _ = setRetentionPolicy(migrated.policy, customDays: migrated.days)
        }
    }

    public static var defaultRetentionURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MCI")
            .appendingPathComponent("retention.json")
    }

    /// Atomically commits the worker's canonical retention payload.
    /// Published state changes only after the durable replacement succeeds.
    @discardableResult
    public func setRetentionPolicy(
        _ policy: RetentionPolicy,
        customDays: Int? = nil
    ) -> Bool {
        let normalizedDays: Int?
        switch policy {
        case .custom:
            guard let customDays, (1...365).contains(customDays) else {
                retentionWriteError = "Custom retention must be between 1 and 365 days."
                return false
            }
            normalizedDays = customDays
        case .forever, .thirtyDays, .sevenDays:
            normalizedDays = nil
        }

        do {
            try writeRetention(policy: policy, days: normalizedDays)
            retentionPolicy = policy
            retentionCustomDays = normalizedDays
            retentionWriteError = nil
            defaults.removeObject(forKey: Keys.retentionPolicy)
            return true
        } catch {
            retentionWriteError = "Retention policy was not saved: \(error.localizedDescription)"
            return false
        }
    }

    private static func loadRetention(
        from url: URL
    ) throws -> (policy: RetentionPolicy, days: Int?) {
        let persisted = try JSONDecoder().decode(
            PersistedRetention.self,
            from: Data(contentsOf: url)
        )
        guard let policy = RetentionPolicy(rawValue: persisted.mode) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if policy == .custom {
            guard let days = persisted.days, (1...365).contains(days) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (policy, days)
        }
        return (policy, nil)
    }

    private static func legacyRetention(
        _ rawValue: String?
    ) -> (policy: RetentionPolicy, days: Int?)? {
        switch rawValue {
        case "days30": return (.thirtyDays, nil)
        case "days90": return (.custom, 90)
        case "forever": return (.forever, nil)
        default: return nil
        }
    }

    private func writeRetention(policy: RetentionPolicy, days: Int?) throws {
        let directory = retentionURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload = PersistedRetention(
            mode: policy.rawValue,
            days: days,
            updated_at: formatter.string(from: now())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        let temporaryURL = directory.appendingPathComponent(
            ".retention.json.\(UUID().uuidString).tmp"
        )

        do {
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            if FileManager.default.fileExists(atPath: retentionURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    retentionURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: retentionURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    // MARK: - Keys

    /// Every UserDefaults key the store owns. The `ai.hippocampus.prefs.`
    /// prefix is the only namespace this store writes to — a future
    /// `defaults delete` cleanup is a one-liner.
    enum Keys {
        static let showMenuBarIcon = "ai.hippocampus.prefs.showMenuBarIcon"
        static let defaultRecallTab = "ai.hippocampus.prefs.defaultRecallTab"
        static let retentionPolicy = "ai.hippocampus.prefs.retentionPolicy"
        static let customDatabasePath = "ai.hippocampus.prefs.customDatabasePath"
    }
}
