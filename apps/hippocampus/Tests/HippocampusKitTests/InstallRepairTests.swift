// SPDX-License-Identifier: Apache-2.0
import Darwin
@testable import HippocampusKit
import XCTest

/// What a launch puts right from an older install (reports/e2e, findings 1
/// and 5): the old OCR worker's two network folders go, and nothing else;
/// the product's folders and the files directly in them become owner-only.
/// Everything here happens in a throwaway home.
final class InstallRepairTests: XCTestCase {
    private var home: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-repair-\(UUID().uuidString)", isDirectory: true)
        home = scratch.appendingPathComponent("home", isDirectory: true)
        outside = scratch.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    }

    // MARK: The old OCR worker's network folders

    func testExactlyTheOldOCRWorkersNetworkFoldersAreDeleted() throws {
        let cache = try file("Library/Caches/hippocampus-ocr/Cache.db")
        _ = try file("Library/Caches/hippocampus-ocr/fsCachedData/0A1B")
        let storage = try file("Library/HTTPStorages/hippocampus-ocr/httpstorages.sqlite")
        let kept = [
            try file("Library/Caches/ai.hippocampus/com.apple.e5rt.e5bundlecache/x"),
            try file("Library/Caches/hippocampus-ocr-notes/x"),
            try file("Library/Caches/com.example.other/Cache.db"),
            try file("Library/HTTPStorages/ai.hippocampus/httpstorages.sqlite"),
            try file("Library/HTTPStorages/hippocampus-ocr.binarycookies"),
            // ONNX Runtime's own folder: every app that uses it shares it.
            try file("Library/Application Support/Microsoft/DeveloperTools/.onnxruntime/deviceid"),
            try file("Library/Application Support/MCI/mci.sqlite"),
        ]

        let removed = InstallRepair.removeOCRWorkerNetworkFolders(home: home)

        XCTAssertEqual(Set(removed.map(\.lastPathComponent)), ["hippocampus-ocr"])
        XCTAssertEqual(removed.count, 2)
        for gone in [cache.deletingLastPathComponent(), storage.deletingLastPathComponent()] {
            XCTAssertFalse(exists(gone), gone.path)
        }
        for still in kept {
            XCTAssertTrue(exists(still), still.path)
        }
        XCTAssertTrue(exists(home.appendingPathComponent("Library/Caches")))
        XCTAssertTrue(exists(home.appendingPathComponent("Library/HTTPStorages")))
        // The next launch finds nothing to do.
        XCTAssertEqual(InstallRepair.removeOCRWorkerNetworkFolders(home: home), [])
    }

    func testALinkInAFoldersPlaceIsRemovedAndNeverFollowed() throws {
        let target = outside.appendingPathComponent("someone-elses", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let theirs = target.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: theirs)
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let link = caches.appendingPathComponent("hippocampus-ocr")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertEqual(InstallRepair.removeOCRWorkerNetworkFolders(home: home).map(\.path), [link.path])

        XCTAssertFalse(exists(link))
        XCTAssertTrue(exists(theirs), "what the link pointed at is not ours")
    }

    func testAHomeWithoutThemIsLeftAsItWas() throws {
        XCTAssertEqual(InstallRepair.removeOCRWorkerNetworkFolders(home: home), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
    }

    // MARK: Owner-only modes

    func testAnOlderInstallsFoldersAndTheFilesInThemBecomeOwnerOnly() throws {
        // As 0.3.0 left them: folders 0755, files 0644.
        let folders = [
            "Library/Application Support/MCI", "Library/Logs/MCI", "Library/Application Support/Hippocampus",
            ".mci", ".config/hippocampus", "Library/Caches/ai.hippocampus",
        ]
        let files = [
            "Library/Application Support/MCI/mci.sqlite", "Library/Application Support/MCI/mci.sqlite-wal",
            "Library/Application Support/MCI/mci.sqlite-shm", "Library/Application Support/MCI/user-deny.toml",
            "Library/Logs/MCI/helper-stderr.log", "Library/Application Support/Hippocampus/.writer.lock",
            ".mci/device-id", ".config/hippocampus/runtime.toml",
        ]
        for path in files { try chmod(try file(path), 0o644) }
        for path in folders {
            let folder = home.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try chmod(folder, 0o755)
        }
        let script = try file(".config/hippocampus/hook.sh")
        try chmod(script, 0o755)
        let blobs = home.appendingPathComponent("Library/Application Support/MCI/blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try chmod(blobs, 0o700)
        // Not ours: another app's folder beside ours, and a file a link in
        // our folder points at.
        let theirs = try file("Library/Application Support/Another App/settings.json")
        try chmod(theirs, 0o644)
        try chmod(theirs.deletingLastPathComponent(), 0o755)
        let linked = outside.appendingPathComponent("linked.txt")
        try Data("x".utf8).write(to: linked)
        try chmod(linked, 0o644)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("Library/Logs/MCI/link.log"), withDestinationURL: linked
        )

        let changed = InstallRepair.makeOwnerOnly(home: home)

        for path in folders { XCTAssertEqual(try mode(home.appendingPathComponent(path)), 0o700, path) }
        for path in files { XCTAssertEqual(try mode(home.appendingPathComponent(path)), 0o600, path) }
        XCTAssertEqual(try mode(script), 0o700, "the owner keeps the right to run it")
        XCTAssertEqual(try mode(blobs), 0o700)
        XCTAssertEqual(try mode(theirs), 0o644, "another app's file is not ours to change")
        XCTAssertEqual(try mode(theirs.deletingLastPathComponent()), 0o755, "nor its folder")
        XCTAssertEqual(try mode(linked), 0o644, "a link is never followed")
        XCTAssertEqual(changed.count, folders.count + files.count + 1)
        XCTAssertEqual(InstallRepair.makeOwnerOnly(home: home), [], "the next launch finds nothing to do")
    }

    func testAFolderThatIsALinkIsLeftAlone() throws {
        let elsewhere = outside.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try chmod(elsewhere, 0o755)
        let logs = home.appendingPathComponent("Library/Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("MCI"), withDestinationURL: elsewhere)

        XCTAssertEqual(InstallRepair.makeOwnerOnly(home: home), [])
        XCTAssertEqual(try mode(elsewhere), 0o755)
    }

    // MARK: Wiring

    func testTheLaunchRepairsBeforeAnythingStartsAndOnlyInTheCopyThatStays() throws {
        let app = try source("Sources/Hippocampus/HippocampusApp.swift")
        let launch = try method("func applicationDidFinishLaunching(", in: app)
        let repair = try XCTUnwrap(launch.range(of: "InstallRepair.runOnLaunch()"))
        let offer = try XCTUnwrap(launch.range(of: "if MoveToApplicationsPrompt.run() {"))
        XCTAssertLessThan(offer.lowerBound, repair.lowerBound, "a copy leaving for Applications repairs nothing")
        for later in ["configurePreferencesController()", "installStatusItem()", "Task {"] {
            let start = try XCTUnwrap(launch.range(of: later), later)
            XCTAssertLessThan(repair.lowerBound, start.lowerBound, later)
        }
    }

    func testTheAppsFirstStatementMakesEveryNewFileOwnerOnly() throws {
        let entry = try source("Sources/Hippocampus/HippocampusEntryPoint.swift")
        let main = try method("static func main() {", in: entry)
        let statements = main.split(whereSeparator: \.isNewline).dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        XCTAssertEqual(statements.first, "umask(0o077)")
    }

    // MARK: Helpers

    @discardableResult
    private func file(_ path: String) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func chmod(_ url: URL, _ mode: mode_t) throws {
        guard Darwin.chmod(url.path, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM) }
    }

    private func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return info.st_mode & 0o7777
    }

    private func source(_ relative: String) throws -> String {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: package.appendingPathComponent(relative), encoding: .utf8)
    }

    private func method(_ declaration: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: declaration))
        let end = try XCTUnwrap(source.range(of: "\n    }", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.upperBound])
    }
}
