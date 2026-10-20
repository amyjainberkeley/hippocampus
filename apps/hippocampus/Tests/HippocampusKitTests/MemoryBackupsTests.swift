// SPDX-License-Identifier: Apache-2.0
//
// Storage-security review S5: by default the memory's folder carries the
// sticky "excluded from backup" mark, so Time Machine never holds the
// memory beside the keychain with its key; Preferences can include it.
// Every folder here is a throwaway one.

import XCTest
@testable import HippocampusKit

@MainActor
final class MemoryBackupsTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-backups-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheMemoryFolderIsMadePrivateAndLeftOutOfBackups() throws {
        let folder = root.appendingPathComponent("Library/Application Support/MCI", isDirectory: true)
        XCTAssertTrue(MemoryBackups.apply(include: false, folder: folder))
        XCTAssertEqual(MemoryBackups.isExcluded(folder), true)
        let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        // Including it clears the mark; leaving it out again sets it.
        XCTAssertTrue(MemoryBackups.apply(include: true, folder: folder))
        XCTAssertEqual(MemoryBackups.isExcluded(folder), false)
        XCTAssertTrue(MemoryBackups.apply(include: false, folder: folder))
        XCTAssertEqual(MemoryBackups.isExcluded(folder), true)
    }

    func testAFolderAnEarlierReleaseLeftOpenIsClosed() throws {
        let folder = root.appendingPathComponent("MCI", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertTrue(MemoryBackups.apply(include: false, folder: folder))
        let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    func testThePreferenceIsOffByDefaultAndAppliesWhenChanged() throws {
        let suite = "memory-backups-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = root.appendingPathComponent("MCI", isDirectory: true)
        let store = PreferencesStore(
            defaults: defaults,
            retentionURL: root.appendingPathComponent("retention.json"),
            memoryFolder: folder
        )
        XCTAssertFalse(store.memoryInTimeMachine, "left out of backups unless the person includes it")
        XCTAssertTrue(store.applyMemoryBackupChoice(), "what the app does at launch")
        XCTAssertEqual(MemoryBackups.isExcluded(folder), true)

        store.memoryInTimeMachine = true
        XCTAssertEqual(MemoryBackups.isExcluded(folder), false)
        XCTAssertEqual(defaults.object(forKey: "ai.hippocampus.prefs.memoryInTimeMachine") as? Bool, true)
        let reopened = PreferencesStore(
            defaults: defaults,
            retentionURL: root.appendingPathComponent("retention.json"),
            memoryFolder: folder
        )
        XCTAssertTrue(reopened.memoryInTimeMachine, "the choice is kept")
    }

    func testTheSwitchSaysWhatItCosts() {
        XCTAssertEqual(MemoryBackups.toggleTitle, "Include my memory in Time Machine backups")
        XCTAssertTrue(MemoryBackups.tradeoff.contains("keeps what you delete"))
        XCTAssertEqual(MemoryBackups.tradeoff.filter { $0 == "." }.count, 1, "one sentence")
    }
}
