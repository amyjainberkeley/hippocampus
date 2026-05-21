// SPDX-License-Identifier: TBD-private
import XCTest

final class BuildAppScriptTests: XCTestCase {

    private var scriptPath: String? {
        let testFile = URL(fileURLWithPath: #filePath)
        // Tests/HippocampusKitTests/BuildAppScriptTests.swift
        //   → ../.. = package root → Resources/build-app.sh
        let pkgRoot = testFile
            .deletingLastPathComponent()  // HippocampusKitTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
        let candidate = pkgRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent("build-app.sh")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate.path
        }
        return nil
    }

    func test_help_flag_exits_zero() throws {
        guard let path = scriptPath else {
            throw XCTSkip("build-app.sh not found at expected source-tree location")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [path, "--help"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "build-app.sh --help should exit 0")

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("Assemble Hippocampus.app"), "Expected usage text in --help output")
        XCTAssertTrue(output.contains("--debug"), "Expected --debug option in help")
        XCTAssertTrue(output.contains("--dist"), "Expected --dist option in help")
    }

    func test_unknown_flag_exits_nonzero() throws {
        guard let path = scriptPath else {
            throw XCTSkip("build-app.sh not found at expected source-tree location")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [path, "--bogus"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0, "build-app.sh --bogus should exit nonzero")
    }
}
