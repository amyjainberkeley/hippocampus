// SPDX-License-Identifier: Apache-2.0
//
// Storage-security review S9: the files the app writes beside the memory
// (consent, a development key file, settings) are mode 0600 from the moment
// they exist, whatever the process's umask. Throwaway folders only.

import Darwin
import XCTest
@testable import HippocampusKit

final class PrivateFilesTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testTheWriterIsPrivateEvenWithAnOpenUmaskAndLeavesNoTemporaryFile() throws {
        let previous = umask(0)
        defer { umask(previous) }
        let url = dir.appendingPathComponent("settings.toml")
        try PrivateFileWriter.write("a = 1\n", to: url)
        XCTAssertEqual(try mode(url), 0o600)
        try PrivateFileWriter.write("a = 2\n", to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a = 2\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["settings.toml"])
    }

    func testCaptureConsentIsPrivate() throws {
        let stateURL = dir.appendingPathComponent("capture-consent.json")
        let authority = CaptureConsentAuthority(stateURL: stateURL, ownerProcessID: 7, ownerStartTimeUs: 1)
        try authority.enable(generationID: "generation-1")
        XCTAssertEqual(try mode(stateURL), 0o600)
    }

    func testADevelopmentKeyFileIsPrivate() throws {
        let path = dir.appendingPathComponent("dev.key")
        try FileKeyStore(path: path).writeKey(String(repeating: "ab", count: 32))
        XCTAssertEqual(try mode(path), 0o600)
    }
}
