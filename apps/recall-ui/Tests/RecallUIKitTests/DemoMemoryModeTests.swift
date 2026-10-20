import XCTest
@testable import RecallUIKit

/// The window shows its Demo tag only when the app opened it on Demo Memory
/// (SPEC-DELTA 6), and its words pass the copy rules.
final class DemoMemoryModeTests: XCTestCase {
    func testOnlyTheAppsOwnFlagTurnsItOn() {
        XCTAssertTrue(DemoMemoryMode.isOn(environment: ["MCI_DEMO_MEMORY": "1"]))
        for environment in [[:], ["MCI_DEMO_MEMORY": "0"], ["MCI_DEMO_MEMORY": "true"], ["MCI_DEMO_MEMORY": ""],
                            ["MCI_DB_PATH": "/tmp/demo/mci.sqlite"]] {
            XCTAssertFalse(DemoMemoryMode.isOn(environment: environment), "\(environment)")
        }
        XCTAssertEqual(DemoMemoryMode.environmentKey, "MCI_DEMO_MEMORY",
                       "the app's DemoMemory sets this exact name")
    }

    /// Privacy on Demo Memory reads the week's own files, never the
    /// person's: its activity from the week's log, and how long moments are
    /// kept and what side pictures use from beside the week's store.
    func testPrivacyOnDemoMemoryReadsOnlyTheWeeksFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("demo-mode-\(UUID().uuidString)")
        let week = root.appendingPathComponent("Demo Memory", isDirectory: true)
        try FileManager.default.createDirectory(at: week, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["MCI_DEMO_MEMORY": "1", "MCI_DEVELOPMENT_FILE_KEY": "1",
                           "MCI_DB_PATH": week.appendingPathComponent("mci.sqlite").path]

        XCTAssertEqual(DemoMemoryMode.folder(environment: environment)?.standardizedFileURL,
                       week.standardizedFileURL)
        XCTAssertEqual(AuditLog.forWindow(environment: environment).baseURL.standardizedFileURL,
                       week.standardizedFileURL, "the activity")
        XCTAssertEqual(MemoryFolder.url(environment: environment).standardizedFileURL, week.standardizedFileURL,
                       "retention.json and pictures-usage.json")
        let usage = #"{"schema_version":1,"side_bytes":4000,"side_count":2,"side_budget_bytes":2000000000,"#
            + #""side_pictures_on":true}"#
        try usage.write(to: week.appendingPathComponent("pictures-usage.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(PicturesUsage.read(environment: environment)?.sideBytes, 4_000)
    }

    func testTheTagsWordsAreCalm() {
        for word in [DemoCopy.tag, DemoCopy.tagLabel] {
            XCTAssertNil(CopyStyleValidator.containsMarketingSpeak(word), word)
            XCTAssertNil(CopyStyleValidator.containsJargon(word), word)
            XCTAssertFalse(CopyStyleValidator.containsExclamation(word), word)
        }
    }
}
