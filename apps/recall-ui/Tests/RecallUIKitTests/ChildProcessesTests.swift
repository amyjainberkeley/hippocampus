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

    func testTheTerminationSignalEndsTheWindowOnce() async throws {
        // SIGUSR2 stands in for SIGTERM so the test runner itself is never asked to stop.
        let ended = OSAllocatedUnfairLock(initialState: [ProcessLifetime.Reason]())
        let lifetime = ProcessLifetime(parent: 1, signals: [SIGUSR2],
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
