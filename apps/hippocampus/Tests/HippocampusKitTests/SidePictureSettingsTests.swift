// SPDX-License-Identifier: Apache-2.0
//
// Pictures of the windows beside the one in front (SPEC 6.1 and 6.7): where
// the person's choice is kept, who gets them on by default, and what
// Preferences shows. Every file here is a temporary one; the person's own
// settings are never read or written.

import TOMLKit
import XCTest
@testable import HippocampusKit

final class SidePictureSettingsTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("side-pictures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func config() throws -> RuntimeConfig {
        RuntimeConfig(path: try temporaryFolder().appendingPathComponent("runtime.toml"))
    }

    // MARK: Who gets them (SPEC 6.1)

    func testANewInstallsFirstYesTurnsThemOn() throws {
        let config = try config()
        XCTAssertFalse(config.sidePictures.enabled)
        try config.setCaptureEnabled(true)
        XCTAssertTrue(config.captureEnabled)
        XCTAssertTrue(config.sidePictures.enabled)
    }

    func testSomeoneWhoAlreadySaidYesKeepsThemOffUntilTheyTurnThemOn() throws {
        let config = try config()
        try FileManager.default.createDirectory(at: config.path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Remembering, from before side pictures existed.
        try "capture_enabled = true\n".write(to: config.path, atomically: true, encoding: .utf8)
        try config.setCaptureEnabled(false)
        try config.setCaptureEnabled(true)
        XCTAssertFalse(config.sidePictures.enabled)
        // Turned off before, then on again: still not on its own.
        let paused = try self.config()
        try FileManager.default.createDirectory(at: paused.path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "capture_enabled = false\n".write(to: paused.path, atomically: true, encoding: .utf8)
        try paused.setCaptureEnabled(true)
        XCTAssertFalse(paused.sidePictures.enabled)
    }

    func testTurningRememberingOffNeverTurnsThemOn() throws {
        let config = try config()
        try config.setCaptureEnabled(false)
        XCTAssertFalse(config.sidePictures.enabled)
        try config.setCaptureEnabled(true)
        XCTAssertFalse(config.sidePictures.enabled)
    }

    func testThePersonsChoiceIsNeverOverwrittenByAnotherYes() throws {
        let config = try config()
        try config.setSideWindowPictures(false)
        try config.setCaptureEnabled(true)
        XCTAssertFalse(config.sidePictures.enabled)
    }

    // MARK: The keys

    func testTheSwitchBudgetAndForgetRequestRoundTrip() throws {
        let config = try config()
        try config.setCaptureEnabled(true)
        try config.setSideWindowPictures(false)
        try config.setSidePicturesBudgetMB(5_000)
        let when = Date(timeIntervalSince1970: 1_792_444_800)
        try config.requestDeleteSidePictures(at: when)
        XCTAssertEqual(config.sidePictures,
                       SidePictureSettings(enabled: false, budgetMB: 5_000, deleteRequestedAt: when))
        // Other keys stay, and the file is what the helper and the agent read.
        XCTAssertTrue(config.captureEnabled)
        let text = try String(contentsOf: config.path, encoding: .utf8)
        XCTAssertTrue(text.contains("side_window_pictures = false"), text)
        XCTAssertTrue(text.contains("side_pictures_budget_mb = 5000"), text)
        XCTAssertTrue(text.contains("delete_side_pictures_requested_at = 1792444800"), text)
        let mode = try FileManager.default.attributesOfItem(atPath: config.path.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testOnlyTheThreeBudgetsCanBeChosen() throws {
        let config = try config()
        for megabytes in [0, 1_500, 10_000, -1] {
            XCTAssertThrowsError(try config.setSidePicturesBudgetMB(megabytes), "\(megabytes)")
        }
        for megabytes in SidePictureSettings.budgetChoicesMB {
            try config.setSidePicturesBudgetMB(megabytes)
            XCTAssertEqual(config.sidePictures.budgetMB, megabytes)
        }
    }

    func testADamagedFileReadsAsOff() throws {
        let config = try config()
        try FileManager.default.createDirectory(at: config.path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        for document in ["side_window_pictures = \"yes\"\n", "side_window_pictures = true\n[unterminated",
                         "side_window_pictures = true\nside_window_pictures = true\n"] {
            try document.write(to: config.path, atomically: true, encoding: .utf8)
            XCTAssertFalse(config.sidePictures.enabled, document)
        }
        // A key holding something else is not overwritten by the switch.
        try "side_window_pictures = 1\n".write(to: config.path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try config.setSideWindowPictures(true))
    }

    // MARK: Preferences

    @MainActor
    private func preferences(
        settings: String, usage: [String: Any]?, freeBytes: Int64? = 300_000_000_000
    ) throws -> (SidePicturesPreferences, RuntimeConfig) {
        let folder = try temporaryFolder()
        let config = RuntimeConfig(path: folder.appendingPathComponent("runtime.toml"))
        try settings.write(to: config.path, atomically: true, encoding: .utf8)
        let usageURL = folder.appendingPathComponent("pictures-usage.json")
        if let usage {
            try JSONSerialization.data(withJSONObject: usage).write(to: usageURL)
        }
        let model = SidePicturesPreferences(config: config, usageURL: usageURL, availableBytes: { freeBytes },
                                            now: { Date(timeIntervalSince1970: 1_792_444_800) })
        return (model, config)
    }

    private func usage(side: Int64, count: Int = 3, budget: Int64 = 2_000_000_000) -> [String: Any] {
        ["schema_version": 1, "updated_at": "2026-10-19T21:00:00.000Z", "front_bytes": 1_000,
         "side_bytes": side, "side_count": count, "side_budget_bytes": budget, "side_pictures_on": true]
    }

    @MainActor
    func testPreferencesSayWhatThePicturesUse() throws {
        let (model, _) = try preferences(settings: "side_window_pictures = true\n", usage: usage(side: 640_000_000))
        XCTAssertTrue(model.enabled)
        XCTAssertEqual(model.budgetMB, 2_000)
        XCTAssertEqual(model.usageLine, "Using 640 MB.")
    }

    @MainActor
    func testAFullBudgetSaysOlderPicturesAreThinnedFirst() throws {
        let (model, _) = try preferences(settings: "side_window_pictures = true\n",
                                         usage: usage(side: 2_000_000_000))
        XCTAssertEqual(model.usageLine, "Using 2 GB of 2 GB. Older pictures are thinned out first.")
    }

    @MainActor
    func testALowDiskSaysTheyArePaused() throws {
        let (model, _) = try preferences(settings: "side_window_pictures = true\n", usage: usage(side: 640_000_000),
                                         freeBytes: 9_000_000_000)
        XCTAssertEqual(model.usageLine, "Paused: the Mac is low on space.")
    }

    @MainActor
    func testWithoutAUsageRecordThereIsNoLineYet() throws {
        let (model, _) = try preferences(settings: "side_window_pictures = true\n", usage: nil)
        XCTAssertNil(model.usageLine)
        XCTAssertTrue(model.hasPictures)
        // A record from another version is not read.
        var future = usage(side: 1)
        future["schema_version"] = 2
        let (other, _) = try preferences(settings: "", usage: future)
        XCTAssertNil(other.usage)
    }

    @MainActor
    func testSwitchingBudgetAndForgettingWriteTheSettingsAtOnce() throws {
        let (model, config) = try preferences(settings: "side_window_pictures = true\n",
                                              usage: usage(side: 0, count: 0))
        model.setBudget(megabytes: 1_000)
        XCTAssertEqual(config.sidePictures.budgetMB, 1_000)
        model.setEnabled(false)
        XCTAssertFalse(config.sidePictures.enabled)
        XCTAssertFalse(model.enabled)
        XCTAssertFalse(model.hasPictures)
        model.forgetPictures()
        XCTAssertEqual(config.sidePictures.deleteRequestedAt, Date(timeIntervalSince1970: 1_792_444_800))
        XCTAssertNil(model.writeError)
    }

    @MainActor
    func testRefreshReadsChangesMadeElsewhere() throws {
        let (model, config) = try preferences(settings: "side_window_pictures = false\n", usage: nil)
        XCTAssertFalse(model.enabled)
        try config.setSideWindowPictures(true)
        try config.setSidePicturesBudgetMB(5_000)
        model.refresh()
        XCTAssertTrue(model.enabled)
        XCTAssertEqual(model.budgetMB, 5_000)
    }
}

/// The words for pictures of side windows meet the bar every menu-bar word
/// meets (`MenuBarCopyStyleTests`), and say exactly what SPEC 9 says.
final class SidePicturesCopyTests: XCTestCase {
    private static let marketingWords: Set<String> = [
        "seamless", "seamlessly", "effortless", "effortlessly", "unlock", "supercharge", "magic", "magical",
        "delve", "powerful", "smart", "simply", "leverage", "utilize", "robust", "elevate", "empower",
        "unleash", "harness", "frictionless", "revolutionary", "hiccup", "oops", "whoops", "gotcha",
    ]
    private static let jargon = ["scstream", "sqlcipher", "sentinel", "denylist", "mci-agent", "errno", "helper",
                                 "captured", "captures", "keyframe", "blob", "dhash", "toml"]

    func testTheWordsAreCalmAndPlain() {
        for text in SidePicturesCopy.allStrings {
            let lower = text.lowercased()
            let words = Set(lower.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
            for word in Self.marketingWords where words.contains(word) {
                XCTFail("marketing word \(word): \(text)")
            }
            for term in Self.jargon where lower.contains(term) {
                XCTFail("jargon \(term): \(text)")
            }
            XCTAssertFalse(text.contains("!"), text)
            XCTAssertLessThan(text.filter { $0 == "\u{2014}" }.count, 2, text)
            XCTAssertFalse(text.contains("'"), "typographer’s apostrophes only: \(text)")
        }
    }

    func testTheWordsAreSpecNines() {
        XCTAssertEqual(SidePicturesCopy.toggle, "Keep screenshots of windows beside the one you’re using")
        XCTAssertEqual(SidePicturesCopy.explanation,
                       "When their text changes, Hippocampus keeps a picture of other windows you can see, "
                           + "encrypted like the rest. Calls, video and private windows are never kept.")
        XCTAssertEqual(SidePicturesCopy.useAtMost, "Use at most:")
        XCTAssertEqual(SidePictureSettings.budgetChoicesMB.map { SidePicturesCopy.budget(megabytes: $0) },
                       ["1 GB", "2 GB", "5 GB"])
        XCTAssertEqual(SidePicturesCopy.using(bytes: 640_000_000), "Using 640 MB.")
        XCTAssertEqual(SidePicturesCopy.lowOnSpace, "Paused: the Mac is low on space.")
        XCTAssertEqual(SidePicturesCopy.forgetButton, "Forget Pictures of Other Windows…")
        XCTAssertEqual(SidePicturesCopy.forgetTitle, "Forget pictures of other windows?")
        XCTAssertEqual(SidePicturesCopy.forgetMessage,
                       "Their text stays. Only the pictures are deleted from this Mac for good.")
        XCTAssertEqual(SidePicturesCopy.whatsNew,
                       "Hippocampus can now keep pictures of the other windows you can see, not just the one "
                           + "you’re using. It’s off until you turn it on.")
        XCTAssertEqual(SidePicturesCopy.whatsNewButton, "Turn On…")
    }
}
