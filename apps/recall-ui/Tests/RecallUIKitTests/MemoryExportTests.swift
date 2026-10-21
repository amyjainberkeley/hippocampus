import Foundation
import XCTest

@testable import RecallUIKit

/// Storage-security review S8: Export Everything asks where to save, says
/// the file isn't encrypted and where it may sync, and has the bundled
/// agent write every moment into a file only this user can read.
final class MemoryExportTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    func testFoldersThatSyncToICloudAreNamed() {
        XCTAssertEqual(
            ExportDestination.warning(for: home.appendingPathComponent("Desktop/export.jsonl"), home: home),
            "Desktop and Documents may sync to iCloud."
        )
        XCTAssertNotNil(ExportDestination.warning(
            for: home.appendingPathComponent("Documents/Notes/export.jsonl"), home: home))
        XCTAssertEqual(
            ExportDestination.warning(
                for: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/export.jsonl"),
                home: home),
            "It\u{2019}s in iCloud Drive, so a copy leaves this Mac."
        )
        XCTAssertNil(ExportDestination.warning(for: home.appendingPathComponent("Downloads/export.jsonl"), home: home))
        XCTAssertNil(ExportDestination.warning(for: home.appendingPathComponent("DesktopArchive/x.jsonl"), home: home),
                     "a folder that only starts with the same letters isn't Desktop")
    }

    func testThePanelSaysTheFileIsNotEncryptedAndMaySync() {
        XCTAssertTrue(ExportDestination.panelMessage.contains("isn\u{2019}t encrypted"))
        XCTAssertTrue(ExportDestination.panelMessage.contains("iCloud"))
        XCTAssertTrue(ExportDestination.panelMessage.contains("Spotlight"))
        XCTAssertTrue(ExportDestination.suggestedName(now: Date(timeIntervalSince1970: 0)).hasSuffix(".jsonl"))
        XCTAssertFalse(ExportDestination.suggestedName(now: Date()).contains(":"))
    }

    func testEveryMomentIsWrittenByTheBundledAgent() throws {
        let recall = URL(fileURLWithPath: "/Applications/Hippocampus.app/Contents/MacOS/recall-ui")
        let out = URL(fileURLWithPath: "/Users/someone/Downloads/export.jsonl")
        let command = try MemoryExport.command(
            to: out,
            environment: ["MCI_DB_PATH": "/Users/someone/Library/Application Support/MCI/mci.sqlite"],
            recallExecutableURL: recall,
            isExecutable: { _ in true }
        )
        XCTAssertEqual(command.executableURL.lastPathComponent, "mci-agent")
        XCTAssertEqual(command.arguments, [
            "export", "--out", out.path,
            "--db-path", "/Users/someone/Library/Application Support/MCI/mci.sqlite",
        ])
        XCTAssertGreaterThanOrEqual(MemoryExport.timeoutSeconds, 600, "a large memory takes a while")
    }
}
