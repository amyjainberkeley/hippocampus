import Darwin
import XCTest
@testable import RecallUIKit

/// Storage-security review S9: the files the window writes beside the memory
/// are mode 0600 from the moment they exist. The user dictionary holds
/// people's names and aliases; a verdict names something About You says.
final class PrivateSettingsFilesTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-private-settings-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testTheUserDictionaryIsPrivate() throws {
        let url = dir.appendingPathComponent("Hippocampus/user_dictionary.toml")
        try saveUserDictionary(.empty, to: url)
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try mode(url.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try loadUserDictionary(from: url), .empty)
    }

    func testAVerdictFileIsPrivate() throws {
        let file = try VerdictInbox.write(id: 7, verdict: .confirm, directory: dir,
                                          now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(file.pathExtension, "json")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, [file.lastPathComponent], "no temporary file is left for the agent to see")
    }

    func testThePrivateWriterIgnoresAnOpenUmask() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = umask(0)
        defer { umask(previous) }
        let url = dir.appendingPathComponent("probe.json")
        try PrivateFileWriter.write(Data("{}".utf8), to: url)
        XCTAssertEqual(try mode(url), 0o600)
    }
}
