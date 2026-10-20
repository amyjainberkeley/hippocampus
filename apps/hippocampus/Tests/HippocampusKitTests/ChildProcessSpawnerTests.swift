// SPDX-License-Identifier: Apache-2.0
//
// The window's process gets its private pipe on descriptors 3 and 4 and
// nothing else beyond standard input, output and error (SPEC 2.6.4); the
// app's ends are close-on-exec, so no other child inherits them. The child
// here is a shell script made for the test, never the real window.

import Darwin
import XCTest
@testable import HippocampusKit

final class ChildProcessSpawnerTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("spawner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func script(_ body: String) throws -> URL {
        let url = scratch.appendingPathComponent("window.sh")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func waitForExit(_ process: SpawnedWindowProcess, seconds: Double = 5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testTheWindowGetsItsTwoPipesAndNothingElse() async throws {
        let report = scratch.appendingPathComponent("report")
        let descriptors = scratch.appendingPathComponent("descriptors")
        // The last step replaces the shell with ls, so what ls finds open is
        // what the window was given (and ls's own one or two).
        let window = try script("""
            echo "channel=$MCI_WINDOW_CHANNEL" > "\(report.path)"
            echo "tab=$MCI_INITIAL_TAB" >> "\(report.path)"
            read line <&4
            echo "$line" >&3
            exec /bin/ls /dev/fd > "\(descriptors.path)"
            """)
        let process = try ChildProcessSpawner.spawnWindow(executable: window,
                                                          environment: ["MCI_INITIAL_TAB": "overview", "PATH": "/usr/bin:/bin"])
        // The app's ends never reach another child.
        XCTAssertNotEqual(fcntl(process.fromWindow.fileDescriptor, F_GETFD) & FD_CLOEXEC, 0)
        XCTAssertNotEqual(fcntl(process.toWindow.fileDescriptor, F_GETFD) & FD_CLOEXEC, 0)

        process.toWindow.write(Data("hello window\n".utf8))
        let echoed = try await Task.detached { () throws -> String in
            var bytes: [UInt8] = []
            var byte: UInt8 = 0
            while Darwin.read(process.fromWindow.fileDescriptor, &byte, 1) == 1, byte != 0x0A { bytes.append(byte) }
            return String(decoding: bytes, as: UTF8.self)
        }.value
        XCTAssertEqual(echoed, "hello window", "the window reads 4 and writes 3")

        await waitForExit(process)
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationStatus, 0)
        let lines = try String(contentsOf: report, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["channel=3,4", "tab=overview"])
        let open = Set(try String(contentsOf: descriptors, encoding: .utf8).split(separator: "\n").compactMap { Int($0) })
        XCTAssertTrue(open.isSuperset(of: [0, 1, 2, 3, 4]), "\(open.sorted())")
        // Beyond the pipe, only what ls opened itself (the folder it lists):
        // none of the app's descriptors, nor the pipe ends it moved high.
        XCTAssertLessThanOrEqual(open.count, 7, "\(open.sorted())")
        XCTAssertLessThanOrEqual(open.max() ?? 0, 6, "\(open.sorted())")
    }

    func testAWindowThatEndsIsReapedAndSaysHow() async throws {
        let window = try script("exit 3\n")
        let process = try ChildProcessSpawner.spawnWindow(executable: window, environment: [:])
        let ended = expectation(description: "ended")
        process.onExit { status in
            XCTAssertEqual(status, 3)
            ended.fulfill()
        }
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertFalse(process.isRunning)
        // Asked again later, it still says so.
        let late = expectation(description: "late")
        process.onExit { _ in late.fulfill() }
        await fulfillment(of: [late], timeout: 1)
        XCTAssertEqual(waitpid(process.processIdentifier, nil, WNOHANG), -1, "no zombie is left")
    }

    func testTerminateEndsIt() async throws {
        let window = try script("exec /bin/sleep 30\n")
        let process = try ChildProcessSpawner.spawnWindow(executable: window, environment: [:])
        XCTAssertTrue(process.isRunning)
        process.terminate()
        await waitForExit(process)
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationStatus, 128 + SIGTERM)
    }

    func testAMissingExecutableThrows() {
        XCTAssertThrowsError(try ChildProcessSpawner.spawnWindow(
            executable: scratch.appendingPathComponent("missing"), environment: [:]))
    }
}
