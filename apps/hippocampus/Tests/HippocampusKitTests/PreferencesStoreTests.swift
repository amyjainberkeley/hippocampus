// SPDX-License-Identifier: TBD-private
//
// Tests for `PreferencesStore` — the persisted model behind
// the comprehensive Preferences window (⌘,).
//
// The SwiftUI window itself lives in the `Hippocampus` executable
// target which is not testable under SwiftPM, so we exercise the model
// layer here: default values, round-trip persistence, and enum coercion
// on corrupted stored values.
//
// Every test uses an ephemeral `UserDefaults(suiteName:)` — never the
// standard defaults — so the test suite is deterministic, parallel-
// safe, and does not touch the developer's actual Hippocampus prefs.

import XCTest
@testable import HippocampusKit

@MainActor
final class PreferencesStoreTests: XCTestCase {

    /// Fresh ephemeral suite per test — the suite name is a UUID so
    /// concurrent test cases can't collide, and we `removePersistentDomain`
    /// in tearDown to keep the disk cache clean between runs.
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var retentionURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "prefs-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        retentionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-prefs-\(UUID().uuidString)")
            .appendingPathComponent("retention.json")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try? FileManager.default.removeItem(at: retentionURL.deletingLastPathComponent())
        retentionURL = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Defaults

    /// Every preference must default to the value the app already
    /// ships with today. A first-run user who never opens Preferences
    /// sees zero behavior change — this test is the pin.
    func testDefaults_matchCurrentBehavior() {
        let store = PreferencesStore(defaults: defaults, retentionURL: retentionURL)

        XCTAssertTrue(store.showMenuBarIcon,
                      "menu-bar icon defaults ON (current behavior)")
        XCTAssertEqual(store.defaultRecallTab, .search,
                       "recall UI defaults to Search tab")
        XCTAssertEqual(store.retentionPolicy, .forever,
                       "retention defaults to forever (pruner idle)")
        XCTAssertEqual(store.customDatabasePath, "",
                       "DB path defaults empty (canonical location)")

    }

    // MARK: - Round-trip

    /// Change every preference, drop and re-hydrate the store from
    /// the same UserDefaults, and verify every value round-trips.
    /// Guards against a `didSet` observer being forgotten on a future
    /// property addition.
    func testRoundTrip_allPreferencesPersist() {
        do {
            let store = PreferencesStore(defaults: defaults, retentionURL: retentionURL)
            store.showMenuBarIcon = false
            store.defaultRecallTab = .brief
            XCTAssertTrue(store.setRetentionPolicy(.thirtyDays))
            store.customDatabasePath = "/tmp/custom.sqlite"
        }
        // New instance, same defaults — should re-read the persisted values.
        let reloaded = PreferencesStore(defaults: defaults, retentionURL: retentionURL)
        XCTAssertFalse(reloaded.showMenuBarIcon)
        XCTAssertEqual(reloaded.defaultRecallTab, .brief)
        XCTAssertEqual(reloaded.retentionPolicy, .thirtyDays)
        XCTAssertEqual(reloaded.customDatabasePath, "/tmp/custom.sqlite")
    }

    // MARK: - Defensive enum coercion

    /// A corrupted stored enum rawValue (from a downgrade or manual
    /// `defaults write`) must not crash — the store falls back to the
    /// shipped default.
    func testCorruptedRawValues_fallBackToDefaults() {
        defaults.set("not-a-tab", forKey: PreferencesStore.Keys.defaultRecallTab)
        defaults.set("not-a-policy", forKey: PreferencesStore.Keys.retentionPolicy)

        let store = PreferencesStore(defaults: defaults, retentionURL: retentionURL)
        XCTAssertEqual(store.defaultRecallTab, .search)
        XCTAssertEqual(store.retentionPolicy, .forever)
    }

    // MARK: - Enum display metadata

    /// `displayLabel` is the human-facing string for menu Pickers.
    /// If a rename accidentally leaks into the Rust brief-worker's
    /// tab-tag parser (`ProcessSupervisor.openRecallUI` reads
    /// `tab.rawValue`), this test catches it — labels are separate
    /// from `rawValue` by design.
    func testPreferredRecallTab_labelsDistinct() {
        let labels = Set(PreferredRecallTab.allCases.map(\.displayLabel))
        XCTAssertEqual(labels.count, PreferredRecallTab.allCases.count)
    }

    func testRetentionPolicy_labelsDistinct() {
        let labels = Set(RetentionPolicy.allCases.map(\.displayLabel))
        XCTAssertEqual(labels.count, RetentionPolicy.allCases.count)
    }

    /// The maxAgeSeconds derived value is used by a downstream
    /// pruner; pin the arithmetic so a `days30 → days60` typo is
    /// caught before it hits the brain.
    func testRetentionPolicy_maxAgeSecondsMatches() {
        XCTAssertEqual(RetentionPolicy.thirtyDays.maxAgeSeconds, 30 * 24 * 3600)
        XCTAssertEqual(RetentionPolicy.sevenDays.maxAgeSeconds, 7 * 24 * 3600)
        XCTAssertNil(RetentionPolicy.forever.maxAgeSeconds)
        XCTAssertNil(RetentionPolicy.custom.maxAgeSeconds)
    }

    func testRetentionPickerWritesWorkerCompatibleJsonAndReloadsIt() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_788_220_800)
        let store = PreferencesStore(
            defaults: defaults,
            retentionURL: retentionURL,
            now: { fixedDate }
        )

        XCTAssertTrue(store.setRetentionPolicy(.custom, customDays: 90))

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: retentionURL))
        let json = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(json["mode"] as? String, "custom")
        XCTAssertEqual(json["days"] as? Int, 90)
        XCTAssertEqual(json["updated_at"] as? String, "2026-09-01T00:00:00Z")
        XCTAssertNil(defaults.string(forKey: PreferencesStore.Keys.retentionPolicy))
        let reloaded = PreferencesStore(defaults: defaults, retentionURL: retentionURL)
        XCTAssertEqual(reloaded.retentionPolicy, .custom)
        XCTAssertEqual(reloaded.retentionCustomDays, 90)
    }

    func testLegacyUserDefaultsRetentionMigratesOnceToCanonicalFile() throws {
        defaults.set("days90", forKey: PreferencesStore.Keys.retentionPolicy)

        let store = PreferencesStore(defaults: defaults, retentionURL: retentionURL)

        XCTAssertEqual(store.retentionPolicy, .custom)
        XCTAssertEqual(store.retentionCustomDays, 90)
        XCTAssertNil(defaults.string(forKey: PreferencesStore.Keys.retentionPolicy))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: retentionURL))
        let json = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(json["mode"] as? String, "custom")
        XCTAssertEqual(json["days"] as? Int, 90)
    }

    // MARK: - Namespacing

    /// Every persisted key must live under the `ai.hippocampus.prefs.`
    /// namespace so a future `defaults delete` cleanup is a one-liner
    /// grep, and so a stray key in a different namespace can't collide
    /// with an existing MCI flag (e.g. `MCIBriefsEnabled`).
    func testAllKeys_areNamespaced() {
        let allKeys = [
            PreferencesStore.Keys.showMenuBarIcon,
            PreferencesStore.Keys.defaultRecallTab,
            PreferencesStore.Keys.retentionPolicy,
            PreferencesStore.Keys.customDatabasePath,
        ]
        for key in allKeys {
            XCTAssertTrue(
                key.hasPrefix("ai.hippocampus.prefs."),
                "key \(key) must be under the ai.hippocampus.prefs. namespace"
            )
        }
        // Uniqueness — no two properties share a key.
        XCTAssertEqual(Set(allKeys).count, allKeys.count)
    }

}
