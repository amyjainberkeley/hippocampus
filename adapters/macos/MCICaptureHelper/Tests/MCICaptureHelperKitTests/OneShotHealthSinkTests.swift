import Darwin
import Foundation
import XCTest
@testable import MCICaptureHelperKit

final class OneShotHealthSinkTests: XCTestCase {
    func testCollectorRetainsOneHealthFrameAndCannotBeReused() async throws {
        let sink = OneShotHealthSink()
        do { _ = try await sink.takeFrame(); XCTFail("An empty collector has no frame") }
        catch { XCTAssertEqual(error as? OneShotHealthSinkError, .missingFrame) }
        let frame = healthFrame()
        try await sink.write(frame)
        let collected = try await sink.takeFrame()
        XCTAssertEqual(collected, frame)
        do { try await sink.write(frame); XCTFail("Taking a frame must not rearm the collector") }
        catch { XCTAssertEqual(error as? OneShotHealthSinkError, .alreadyWritten) }
        do { _ = try await sink.takeFrame(); XCTFail("The same frame cannot be taken twice") }
        catch { XCTAssertEqual(error as? OneShotHealthSinkError, .missingFrame) }
    }

    func testCollectorRejectsWrongKindVersionLengthAndAppIdentity() async throws {
        let frame = healthFrame()
        var candidates = [Data(), frame + frame, Data(repeating: 0, count: 1 << 20)]
        for (offset, byte): (Int, UInt8) in [(0, 0), (1, 8), (2, 0x40), (3, 1), (12, 92), (88, 1)] {
            var invalid = frame
            invalid[offset] = byte
            candidates.append(invalid)
        }
        candidates.append(encodeHelperHealth(
            seq: 1, uptimeMs: 0, framesDelivered: 0, framesSuppressed: 0,
            framesRedactedByFailsafe: 0, cascadeForcedCount: 0, framesDroppedBackpressure: 0,
            framesDroppedLateAck: 0, framesEncodeFailed: 0, framesFocusRaceDropped: 0,
            failsafeByApp: [FailsafeAppCounter(bundleId: "com.example.Synthetic", counter: 1)]
        ))
        for invalid in candidates {
            let sink = OneShotHealthSink()
            do { try await sink.write(invalid); XCTFail("Only one counter-only health frame is admissible") }
            catch { XCTAssertEqual(error as? OneShotHealthSinkError, .invalidHealthFrame) }
            try await sink.write(frame)
        }
    }

    private func healthFrame() -> Data {
        encodeHelperHealth(seq: 1, uptimeMs: 0, framesDelivered: 0, framesSuppressed: 0,
                           framesRedactedByFailsafe: 0, cascadeForcedCount: 0, framesDroppedBackpressure: 0,
                           framesDroppedLateAck: 0, framesEncodeFailed: 0, framesFocusRaceDropped: 0)
    }

    func testExplicitRegularOnceWritesOneHealthFrameAndTruncatesOldTail() throws {
        let fixture = try OneShotCLIFixture()
        try Data(repeating: 0x41, count: 1024).write(to: fixture.output)
        let result = try fixture.run(arguments: ["--once", "--output", fixture.output.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        assertCounterOnlyHealth(try Data(contentsOf: fixture.output))
    }

    func testRegularStdoutOnceWritesOneHealthFrame() throws {
        let fixture = try OneShotCLIFixture()
        let result = try fixture.run(arguments: ["--once"], regularStdout: true)
        XCTAssertEqual(result.status, 0, result.stderr)
        assertCounterOnlyHealth(try Data(contentsOf: fixture.output))
    }

    func testPipeOnceKeepsBoundedIPCPath() throws {
        let fixture = try OneShotCLIFixture()
        let result = try fixture.run(arguments: ["--once"])
        XCTAssertEqual(result.status, 0, result.stderr)
        assertCounterOnlyHealth(result.stdout)
    }

    func testRegularStreamingAndCaptureRejectBeforeSourceLoading() throws {
        for redirected in [false, true] {
            for options in [[], ["--capture"], ["--once", "--capture"]] {
                let fixture = try OneShotCLIFixture()
                let original = Data("untouched synthetic fixture".utf8)
                try original.write(to: fixture.output)
                // Even a regressed early guard cannot reach live capture: the
                // existing source parser must fail on this synthetic input first.
                try Data("not valid denylist TOML".utf8).write(to: fixture.denylist)
                let arguments = options + (redirected ? [] : ["--output", fixture.output.path])
                let result = try fixture.run(arguments: arguments, regularStdout: redirected)
                XCTAssertEqual(result.status, 64, result.stderr)
                XCTAssertTrue(result.stderr.contains("pipe"), result.stderr)
                XCTAssertEqual(try Data(contentsOf: fixture.output), original)
            }
        }
    }

    private func assertCounterOnlyHealth(_ frame: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(frame.count, minFrameHeaderBytes + 93, file: file, line: line)
        guard frame.count == minFrameHeaderBytes + 93 else { return }
        XCTAssertEqual(Array(frame.prefix(4)), [frameMagic, frameVersion, 0x30, 0], file: file, line: line)
        XCTAssertEqual(Array(frame[12..<16]), [93, 0, 0, 0], file: file, line: line)
        XCTAssertEqual(frame[minFrameHeaderBytes + 72], 0, "No app identities in a one-shot fixture", file: file, line: line)
    }
}

private final class OneShotCLIFixture {
    let directory: URL
    var output: URL { directory.appendingPathComponent("health.bin") }
    var denylist: URL { directory.appendingPathComponent("denylist.toml") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("one-shot-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: output)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func run(arguments: [String], regularStdout: Bool = false) throws -> (status: Int32, stdout: Data, stderr: String) {
        let executable = Bundle(for: OneShotHealthSinkTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("mci-capture-helper")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NSError(domain: "one-shot-fixture-missing-helper", code: 1)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments + ["--denylist", denylist.path]
        process.currentDirectoryURL = directory
        process.environment = [
            "HOME": directory.path, "CFFIXED_USER_HOME": directory.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": directory.path,
        ]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        let regularHandle = regularStdout ? try FileHandle(forWritingTo: output) : nil
        defer { try? regularHandle?.close() }
        process.standardOutput = regularHandle ?? stdout.fileHandleForWriting
        process.standardError = stderr
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        guard ended.wait(timeout: .now() + 5) == .success else {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw NSError(domain: "one-shot-fixture-timeout", code: 1)
        }
        process.waitUntilExit()
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()
        return (process.terminationStatus, stdout.fileHandleForReading.readDataToEndOfFile(),
                String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
