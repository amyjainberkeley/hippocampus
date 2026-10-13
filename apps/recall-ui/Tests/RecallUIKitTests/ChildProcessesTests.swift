import AppKit
import MCIKeyframeCodec
import XCTest
import os
@testable import RecallUIKit

final class ChildProcessesTests: XCTestCase {
    private func sleeper(_ seconds: String = "30") -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [seconds]
        return process
    }

    func testTerminatingStopsEveryChildStillRunning() async throws {
        let children = ChildProcesses()
        let first = sleeper()
        let second = sleeper()
        try children.run(first)
        try children.run(second)
        let pids = [first.processIdentifier, second.processIdentifier]
        XCTAssertEqual(children.running, Set(pids))
        let started = Date()
        children.terminateAll(grace: 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        await assertEventually { pids.allSatisfy { !isAlive($0) } && children.running.isEmpty }
        XCTAssertFalse(first.isRunning || second.isRunning)
    }

    func testAChildThatEndsIsNoLongerListed() async throws {
        let children = ChildProcesses()
        let quick = Process()
        quick.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try children.run(quick)
        await assertEventually { children.running.isEmpty }
        children.terminateAll()
    }

    func testTheRunnerListsItsChildUntilItEnds() async throws {
        let children = ChildProcesses()
        let command = ContextHandoffCommand(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        let run = Task { try await ContextHandoffExporter.run(command: command, timeoutSeconds: 60, children: children) }
        await assertEventually { children.running.count == 1 }
        let pid = try XCTUnwrap(children.running.first)
        children.terminateAll()
        do {
            _ = try await run.value
            XCTFail("a stopped child returned output")
        } catch {
            XCTAssertEqual(error as? ContextHandoffError, .commandFailed)
        }
        await assertEventually { children.running.isEmpty && !isAlive(pid) }
    }

    func testQuittingCallsEveryRegisteredStopUntilItIsUnregistered() {
        let children = ChildProcesses()
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        let reading = children.register { calls.withLock { $0.append("reading") } }
        let other = children.register { calls.withLock { $0.append("other") } }
        children.terminateAll()
        XCTAssertEqual(Set(calls.withLock { $0 }), ["reading", "other"])
        children.unregister(reading)
        children.unregister(other)
        children.terminateAll()
        XCTAssertEqual(calls.withLock { $0 }.count, 2, "work that ended is not stopped again")
    }

    func testQuittingStopsTheWorkerReadAgainStarted() async throws {
        let fixture = try RereadFixture()
        defer { fixture.remove() }
        let children = ChildProcesses()
        let service = LocalScreenshotRereader(provider: fixture.provider, executableURL: fixture.workerURL,
                                              children: children)
        let url = fixture.imageURL
        let read = Task { await service.read(url: url) }
        let pidFile = fixture.pidFile
        await assertEventually("the stand-in worker started", timeout: 10) {
            RereadFixture.pid(in: pidFile).map(isAlive) == true
        }
        let pid = try XCTUnwrap(RereadFixture.pid(in: pidFile))
        XCTAssertTrue(children.running.isEmpty, "the capture kit starts the worker itself")
        let stopped = Date()
        children.terminateAll()
        let outcome = await read.value
        XCTAssertLessThan(Date().timeIntervalSince(stopped), 5, "the read ends with its worker, not at its deadline")
        if case .text = outcome { XCTFail("a stopped worker gives no reading") }
        await assertEventually { !isAlive(pid) }
    }

    func testTheWindowEndsWhenTheAppThatOpenedItExits() async throws {
        let parent = sleeper("0.3")
        try parent.run()
        let ended = OSAllocatedUnfairLock(initialState: [ProcessLifetime.Reason]())
        let lifetime = ProcessLifetime(parent: parent.processIdentifier, signals: [],
                                       queue: DispatchQueue(label: "lifetime-test")) { reason in
            ended.withLock { $0.append(reason) }
        }
        defer { lifetime.cancel() }
        await assertEventually { ended.withLock { $0 } == [.parentExited] }
    }

    func testAParentAlreadyGoneEndsTheWindowAtOnce() async throws {
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try parent.run()
        parent.waitUntilExit()
        let ended = OSAllocatedUnfairLock(initialState: [ProcessLifetime.Reason]())
        let lifetime = ProcessLifetime(parent: parent.processIdentifier, signals: [],
                                       queue: DispatchQueue(label: "lifetime-test")) { reason in
            ended.withLock { $0.append(reason) }
        }
        defer { lifetime.cancel() }
        await assertEventually { ended.withLock { $0 } == [.parentExited] }
    }

    func testAWindowTheAppOpenedEndsAtOnceWhenTheAppIsAlreadyGone() async throws {
        // An orphan's parent is launchd (pid 1); the app always passes the memory's path.
        let ended = OSAllocatedUnfairLock(initialState: [ProcessLifetime.Reason]())
        let lifetime = ProcessLifetime(parent: 1, environment: ["MCI_DB_PATH": "/tmp/fixture/mci.sqlite"],
                                       signals: [], queue: DispatchQueue(label: "lifetime-test")) { reason in
            ended.withLock { $0.append(reason) }
        }
        defer { lifetime.cancel() }
        await assertEventually { ended.withLock { $0 } == [.parentExited] }
    }

    func testAWindowOpenedByHandHasNoAppToWatch() async throws {
        let ended = OSAllocatedUnfairLock(initialState: [ProcessLifetime.Reason]())
        let lifetime = ProcessLifetime(parent: 1, environment: ["MCI_DB_PATH": ""], signals: [],
                                       queue: DispatchQueue(label: "lifetime-test")) { reason in
            ended.withLock { $0.append(reason) }
        }
        defer { lifetime.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(ended.withLock { $0 }.isEmpty)
        XCTAssertFalse(ProcessLifetime.openedByTheApp([:]))
    }

    func testTheTerminationSignalEndsTheWindowOnce() async throws {
        // SIGUSR2 stands in for SIGTERM so the test runner itself is never asked to stop.
        let ended = OSAllocatedUnfairLock(initialState: [ProcessLifetime.Reason]())
        let lifetime = ProcessLifetime(parent: 1, environment: [:], signals: [SIGUSR2],
                                       queue: DispatchQueue(label: "lifetime-test")) { reason in
            ended.withLock { $0.append(reason) }
        }
        defer { lifetime.cancel() }
        kill(getpid(), SIGUSR2)
        await assertEventually { ended.withLock { $0 } == [.signal(SIGUSR2)] }
        kill(getpid(), SIGUSR2)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(ended.withLock { $0 }, [.signal(SIGUSR2)])
    }

    func testTheAppDelegateStopsChildrenOnQuitAndWithTheApp() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("Sources/RecallUI/MCIRecallApp.swift"),
                                encoding: .utf8)
        let launch = try XCTUnwrap(source.range(of: "func applicationDidFinishLaunching"))
        let terminate = try XCTUnwrap(source.range(of: "func applicationWillTerminate"))
        let launching = source[launch.upperBound..<terminate.lowerBound]
        XCTAssertTrue(launching.contains("lifetime = ProcessLifetime {"))
        XCTAssertTrue(launching.contains("ChildProcesses.shared.terminateAll()"))
        let quitting = source[terminate.upperBound...].prefix(400)
        XCTAssertTrue(quitting.contains("ChildProcesses.shared.terminateAll()"))
    }
}

/// A saved screenshot sealed with a made-up key, and a stand-in OCR worker
/// that writes its pid beside itself, takes the image, and then never answers.
private struct RereadFixture: Sendable {
    let root: URL
    let imageURL: URL
    let workerURL: URL
    let pidFile: URL
    let provider: ThumbnailDataProvider

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("reread-lifetime-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 20,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let key = Data(repeating: 13, count: 32)
        let sealed = try KeyframeBlobCodec.seal(plaintext: image, keyMaterial: key)
        imageURL = root.appendingPathComponent(sealed.lowercaseHexDigest + ".bin")
        try sealed.bytes.write(to: imageURL)
        provider = ThumbnailDataProvider(blobRoot: root) { key }
        workerURL = root.appendingPathComponent("synthetic-ocr-worker")
        pidFile = root.appendingPathComponent("worker.pid")
        let worker = """
        #!/bin/sh
        echo $$ > "$(dirname "$0")/worker.pid"
        /bin/cat > /dev/null
        exec /bin/sleep 30
        """
        try worker.write(to: workerURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workerURL.path)
    }

    static func pid(in file: URL) -> pid_t? {
        (try? String(contentsOf: file, encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
