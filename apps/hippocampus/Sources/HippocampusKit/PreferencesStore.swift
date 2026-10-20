// SPDX-License-Identifier: Apache-2.0
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
//   - **Preserve choices**: fresh retention defaults to 90 days;
//     explicit existing selections are preserved, with review before
//     finite legacy selections authorize deletion.
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

/// Retention uses the agent's canonical policy names. New installations
/// default to 90 days; existing explicit choices remain selected.
public enum RetentionPolicy: String, CaseIterable, Sendable, Codable {
    case forever
    case ninetyDays
    case thirtyDays
    case sevenDays
    case custom

    public var displayLabel: String {
        switch self {
        case .forever: return "Forever"
        case .ninetyDays: return "90 days"
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
        case .ninetyDays: return 90 * 24 * 3600
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

    /// Persisted but read by nothing; Preferences no longer shows it
    /// (spec-shell S8, D16).
    @Published public var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon) }
    }

    /// Persisted but read by nothing; Preferences no longer shows it
    /// (spec-shell S8, D16).
    @Published public var defaultRecallTab: PreferredRecallTab {
        didSet { defaults.set(defaultRecallTab.rawValue, forKey: Keys.defaultRecallTab) }
    }

    /// The key that opens Ask when tapped by itself. ⌃⇧Space stays
    /// registered whatever this is.
    @Published public var askKey: SoloKey {
        didSet { defaults.set(askKey.rawValue, forKey: Keys.askKey) }
    }

    // MARK: Privacy

    /// Finite legacy selections require review before the agent deletes data.
    @Published public private(set) var retentionPolicy: RetentionPolicy
    @Published public private(set) var retentionCustomDays: Int?
    @Published public private(set) var retentionWriteError: String?
    @Published public private(set) var retentionNeedsReview: Bool = false

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
        var schema_version: Int?
        let mode: String
        let days: Int?
        let updated_at: String?

        enum CodingKeys: String, CodingKey {
            case schema_version
            case mode
            case days
            case updated_at
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(schema_version, forKey: .schema_version)
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
        // Never written here: a stored choice stays, and anyone who never
        // chose gets Shift twice (spec-shell S3).
        self.askKey = defaults.string(forKey: Keys.askKey).flatMap(SoloKey.init(rawValue:)) ?? .shiftTwice

        self.retentionPolicy = .forever
        self.retentionCustomDays = nil
        self.retentionWriteError = nil

        self.customDatabasePath = defaults.string(forKey: Keys.customDatabasePath) ?? ""

        if FileManager.default.fileExists(atPath: retentionURL.path) {
            do {
                let loaded = try Self.loadRetention(from: retentionURL)
                self.retentionPolicy = loaded.policy
                self.retentionCustomDays = loaded.days
                self.retentionNeedsReview = loaded.needsReview
            } catch {
                self.retentionWriteError = "Couldn’t read this setting, so nothing is being deleted. Choose again."
            }
        } else if let migrated = Self.legacyRetention(
            defaults.string(forKey: Keys.retentionPolicy)
        ) {
            self.retentionPolicy = migrated.policy
            self.retentionCustomDays = migrated.days
            self.retentionNeedsReview = migrated.policy != .forever
            // Migrate the selection without silently authorizing finite deletion.
            do {
                try writeRetention(policy: migrated.policy, days: migrated.days, schemaVersion: nil)
                defaults.removeObject(forKey: Keys.retentionPolicy)
            } catch {
                self.retentionWriteError = "Couldn’t carry over your old setting. Choose again."
            }
        } else {
            self.retentionPolicy = .ninetyDays
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
                retentionWriteError = "Choose between 1 and 365 days."
                return false
            }
            normalizedDays = customDays
        case .forever, .ninetyDays, .thirtyDays, .sevenDays:
            normalizedDays = nil
        }

        do {
            try writeRetention(policy: policy, days: normalizedDays)
            retentionPolicy = policy
            retentionCustomDays = normalizedDays
            retentionWriteError = nil
            retentionNeedsReview = false
            defaults.removeObject(forKey: Keys.retentionPolicy)
            return true
        } catch {
            retentionWriteError = "Couldn’t save. Try again."
            return false
        }
    }

    private static func loadRetention(
        from url: URL
    ) throws -> (policy: RetentionPolicy, days: Int?, needsReview: Bool) {
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
            return (policy, days, persisted.schema_version != 2)
        }
        return (policy, nil, policy != .forever && persisted.schema_version != 2)
    }

    private static func legacyRetention(
        _ rawValue: String?
    ) -> (policy: RetentionPolicy, days: Int?)? {
        switch rawValue {
        case "days30": return (.thirtyDays, nil)
        case "days90": return (.custom, 90)
        case "forever": return (.forever, nil)
        case "sevenDays": return (.sevenDays, nil)
        case "thirtyDays": return (.thirtyDays, nil)
        case "ninetyDays": return (.ninetyDays, nil)
        default: return nil
        }
    }

    private func writeRetention(policy: RetentionPolicy, days: Int?, schemaVersion: Int? = 2) throws {
        let directory = retentionURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload = PersistedRetention(
            schema_version: schemaVersion,
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
        static let askKey = "ai.hippocampus.prefs.askKey"
        static let retentionPolicy = "ai.hippocampus.prefs.retentionPolicy"
        static let customDatabasePath = "ai.hippocampus.prefs.customDatabasePath"
    }
}

// MARK: - Pictures of side windows (SPEC 6.7)

/// Preferences › Remembering's pictures of the windows beside the one in
/// front: the switch, the budget, what they use, and forgetting them.
///
/// The switch, budget and Forget request live in `runtime.toml`, where the
/// capture helper and the agent read them at their next read: turning the
/// switch off stops new pictures at once, with no restart. What they use
/// comes from the agent's content-free `pictures-usage.json`.
@MainActor
public final class SidePicturesPreferences: ObservableObject {
    /// What the pictures use, as the agent last measured it.
    public struct Usage: Equatable, Sendable {
        public let sideBytes: Int64
        public let sideCount: Int
        public let budgetBytes: Int64

        public init(sideBytes: Int64, sideCount: Int, budgetBytes: Int64) {
            self.sideBytes = sideBytes
            self.sideCount = sideCount
            self.budgetBytes = budgetBytes
        }
    }

    /// Below this much free space no new side picture is kept.
    public static let lowSpaceBytes: Int64 = 10_000_000_000

    @Published public private(set) var enabled: Bool
    @Published public private(set) var budgetMB: Int
    @Published public private(set) var usage: Usage?
    @Published public private(set) var lowOnSpace: Bool
    @Published public private(set) var writeError: String?

    private let config: RuntimeConfig
    private let usageURL: URL
    private let availableBytes: () -> Int64?
    private let now: () -> Date

    public init(
        config: RuntimeConfig,
        usageURL: URL,
        availableBytes: @escaping () -> Int64?,
        now: @escaping () -> Date = Date.init
    ) {
        self.config = config
        self.usageURL = usageURL
        self.availableBytes = availableBytes
        self.now = now
        let settings = config.sidePictures
        self.enabled = settings.enabled
        self.budgetMB = settings.budgetMB ?? SidePictureSettings.defaultBudgetMB
        self.usage = Self.readUsage(usageURL)
        self.lowOnSpace = (availableBytes() ?? Int64.max) < Self.lowSpaceBytes
    }

    /// The person's own: `~/.config/hippocampus/runtime.toml` and the usage
    /// record beside the memory.
    public static func live() -> SidePicturesPreferences {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MCI", isDirectory: true)
        return SidePicturesPreferences(
            config: RuntimeConfig(),
            usageURL: support.appendingPathComponent("pictures-usage.json"),
            availableBytes: {
                let values = try? support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                return values?.volumeAvailableCapacityForImportantUsage
            }
        )
    }

    /// Read the settings, the usage record and the free space again.
    public func refresh() {
        let settings = config.sidePictures
        enabled = settings.enabled
        budgetMB = settings.budgetMB ?? SidePictureSettings.defaultBudgetMB
        usage = Self.readUsage(usageURL)
        lowOnSpace = (availableBytes() ?? Int64.max) < Self.lowSpaceBytes
    }

    public func setEnabled(_ value: Bool) {
        do {
            try config.setSideWindowPictures(value)
            enabled = value
            writeError = nil
        } catch {
            writeError = "Couldn’t save. Try again."
        }
    }

    public func setBudget(megabytes: Int) {
        do {
            try config.setSidePicturesBudgetMB(megabytes)
            budgetMB = megabytes
            writeError = nil
        } catch {
            writeError = "Couldn’t save. Try again."
        }
    }

    /// Carries a confirmed forget out at once when no agent runs to read the
    /// request (remembering paused or off): the app's one short pass under
    /// the writer lease (`ProcessSupervisor.forgetSidePicturesNow`). Nil
    /// leaves it to the agent, which reads it within seconds while
    /// remembering runs.
    public var forgetNow: (@MainActor () async -> Void)?

    /// Forget Pictures of Other Windows…, confirmed: every picture of a side
    /// window kept until now goes; their text stays. The request is saved for
    /// the agent, `forgetNow` carries it out at once when none runs, and what
    /// the pictures use is read again after. The task is the carrying out.
    @discardableResult
    public func forgetPictures() -> Task<Void, Never>? {
        do {
            try config.requestDeleteSidePictures(at: now())
            writeError = nil
        } catch {
            writeError = "Couldn’t save. Try again."
            return nil
        }
        guard let forgetNow else { return nil }
        return Task { @MainActor [weak self] in
            await forgetNow()
            self?.refresh()
        }
    }

    /// The line beside the budget: low on space, full, or what they use.
    public var usageLine: String? {
        if lowOnSpace { return SidePicturesCopy.lowOnSpace }
        guard let usage else { return nil }
        if usage.budgetBytes > 0, usage.sideBytes >= usage.budgetBytes {
            return SidePicturesCopy.full(bytes: usage.sideBytes, budgetBytes: usage.budgetBytes)
        }
        return SidePicturesCopy.using(bytes: usage.sideBytes)
    }

    /// Whether there is anything to forget: unknown counts as yes.
    public var hasPictures: Bool {
        usage.map { $0.sideCount > 0 } ?? true
    }

    /// `pictures-usage.json`, version 1, or nil.
    static func readUsage(_ url: URL) -> Usage? {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (record["schema_version"] as? NSNumber)?.intValue == 1,
              let side = record["side_bytes"] as? NSNumber,
              let count = record["side_count"] as? NSNumber,
              let budget = record["side_budget_bytes"] as? NSNumber
        else { return nil }
        return Usage(sideBytes: side.int64Value, sideCount: count.intValue, budgetBytes: budget.int64Value)
    }
}
