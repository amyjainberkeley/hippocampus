// SPDX-License-Identifier: TBD-private
//
// Tests for `PreferencesStore` — the UserDefaults-backed model behind
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

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "prefs-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Defaults

    /// Every preference must default to the value the app already
    /// ships with today. A first-run user who never opens Preferences
    /// sees zero behavior change — this test is the pin.
    func testDefaults_matchCurrentBehavior() {
        let store = PreferencesStore(defaults: defaults)

        XCTAssertTrue(store.showMenuBarIcon,
                      "menu-bar icon defaults ON (current behavior)")
        XCTAssertEqual(store.defaultRecallTab, .search,
                       "recall UI defaults to Search tab")
        XCTAssertEqual(store.retentionPolicy, .forever,
                       "retention defaults to forever (pruner idle)")
        XCTAssertEqual(store.ollamaEndpoint, "",
                       "Ollama endpoint defaults empty (bundled Qwen3)")
        XCTAssertEqual(store.customDatabasePath, "",
                       "DB path defaults empty (canonical location)")

        // Shipping plugins on by default; future plugins off.
        XCTAssertEqual(store.deepHookPlugins["Messages"], true)
        XCTAssertEqual(store.deepHookPlugins["Mail"], true)
        XCTAssertEqual(store.deepHookPlugins["Calendar"], false)
        XCTAssertEqual(store.deepHookPlugins["Notes"], false)
        XCTAssertEqual(store.deepHookPlugins["Reminders"], false)
    }

    // MARK: - Round-trip

    /// Change every preference, drop and re-hydrate the store from
    /// the same UserDefaults, and verify every value round-trips.
    /// Guards against a `didSet` observer being forgotten on a future
    /// property addition.
    func testRoundTrip_allPreferencesPersist() {
        do {
            let store = PreferencesStore(defaults: defaults)
            store.showMenuBarIcon = false
            store.defaultRecallTab = .brief
            store.retentionPolicy = .days30
            store.ollamaEndpoint = "http://localhost:11434"
            store.customDatabasePath = "/tmp/custom.sqlite"
            store.deepHookPlugins["Messages"] = false
            store.deepHookPlugins["Calendar"] = true
        }
        // New instance, same defaults — should re-read the persisted values.
        let reloaded = PreferencesStore(defaults: defaults)
        XCTAssertFalse(reloaded.showMenuBarIcon)
        XCTAssertEqual(reloaded.defaultRecallTab, .brief)
        XCTAssertEqual(reloaded.retentionPolicy, .days30)
        XCTAssertEqual(reloaded.ollamaEndpoint, "http://localhost:11434")
        XCTAssertEqual(reloaded.customDatabasePath, "/tmp/custom.sqlite")
        XCTAssertEqual(reloaded.deepHookPlugins["Messages"], false)
        XCTAssertEqual(reloaded.deepHookPlugins["Calendar"], true)
    }

    // MARK: - Defensive enum coercion

    /// A corrupted stored enum rawValue (from a downgrade or manual
    /// `defaults write`) must not crash — the store falls back to the
    /// shipped default.
    func testCorruptedRawValues_fallBackToDefaults() {
        defaults.set("not-a-tab", forKey: PreferencesStore.Keys.defaultRecallTab)
        defaults.set("not-a-policy", forKey: PreferencesStore.Keys.retentionPolicy)

        let store = PreferencesStore(defaults: defaults)
        XCTAssertEqual(store.defaultRecallTab, .search)
        XCTAssertEqual(store.retentionPolicy, .forever)
    }

    /// Corrupted deep-hook plugin blob must not crash — the store
    /// falls back to the shipped `defaultDeepHookPlugins` catalog.
    func testCorruptedDeepHookBlob_fallsBackToDefaults() {
        defaults.set(Data([0xFF, 0x00, 0x42]),
                     forKey: PreferencesStore.Keys.deepHookPlugins)

        let store = PreferencesStore(defaults: defaults)
        XCTAssertEqual(store.deepHookPlugins,
                       PreferencesStore.defaultDeepHookPlugins)
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
        XCTAssertEqual(RetentionPolicy.days30.maxAgeSeconds, 30 * 24 * 3600)
        XCTAssertEqual(RetentionPolicy.days90.maxAgeSeconds, 90 * 24 * 3600)
        XCTAssertNil(RetentionPolicy.forever.maxAgeSeconds)
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
            PreferencesStore.Keys.deepHookPlugins,
            PreferencesStore.Keys.retentionPolicy,
            PreferencesStore.Keys.ollamaEndpoint,
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

    // MARK: - Plugin ordering

    /// The order array must include every default plugin exactly once
    /// so the UI never silently drops a row (e.g. when a new plugin is
    /// added to `defaultDeepHookPlugins` but the developer forgets the
    /// order array).
    func testDeepHookPluginOrder_coversDefaults() {
        let ordered = Set(PreferencesStore.deepHookPluginOrder)
        let defaults = Set(PreferencesStore.defaultDeepHookPlugins.keys)
        XCTAssertEqual(ordered, defaults,
                       "deepHookPluginOrder must match defaultDeepHookPlugins keys")
        XCTAssertEqual(PreferencesStore.deepHookPluginOrder.count,
                       ordered.count,
                       "no duplicates in deepHookPluginOrder")
    }
}
