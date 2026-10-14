import Foundation
import XCTest
@testable import HippocampusKit

final class CommandBarTests: XCTestCase {
    func testHitBodyDropsTheProvenanceHeader() throws {
        let json = #"{"event_id":3,"ts_us":5,"app_bundle_id":"com.apple.Notes","window_title":"Plan","url":null,"text_snippet":"[app=com.apple.Notes | title=Plan]\nBeta ships Oct 21.\nOwner: Maya"}"#
        let hit = try JSONDecoder().decode(BarHit.self, from: Data(json.utf8))
        XCTAssertEqual(hit.body, "Beta ships Oct 21. Owner: Maya")
    }

    private func fakeAgent(_ script: String) throws -> MemorySessionLaunch {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake-agent")
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return MemorySessionLaunch(executable: url, arguments: ["mcp-serve"], environment: ["PATH": "/usr/bin:/bin"])
    }

    func testSessionMatchesRepliesByIdAndUnwrapsResults() async throws {
        // Echo two replies: the understanding shape (result.result) and recall's (result).
        let launch = try fakeAgent(#"""
        read line; echo '{"jsonrpc":"2.0","id":1,"result":{"content":[],"result":{"day":{"x":1}},"isError":false}}'
        read line; echo '{"jsonrpc":"2.0","id":2,"result":{"hits":[],"outcome":"degraded"}}'
        read line; echo '{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"bad args"}}'
        cat >/dev/null
        """#)
        let session = MemorySession()
        let day = try await session.call("mci_day", arguments: Data("{}".utf8), launch: launch, timeout: .seconds(5))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: day) as? [String: Any])?["day"] as? [String: Int], ["x": 1])
        let recall = try await session.call("mci_recall", arguments: Data(#"{"query":"q"}"#.utf8), launch: launch, timeout: .seconds(5))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: recall) as? [String: Any])?["outcome"] as? String, "degraded")
        do {
            _ = try await session.call("mci_day", arguments: Data("{}".utf8), launch: launch, timeout: .seconds(5))
            XCTFail("an error reply must throw")
        } catch let error as MemorySessionError {
            XCTAssertEqual(error, .toolFailed("bad args"))
        }
        await session.stop()
    }

    /// The agent writes U+2028 and U+0085 unescaped inside a reply. Replies
    /// are cut at the 0x0A byte only, so such a reply arrives whole instead
    /// of timing out (RULINGS S11).
    func testARepliesHoldingLineSeparatorsArriveWhole() async throws {
        let launch = try fakeAgent(#"""
        read line; printf '{"jsonrpc":"2.0","id":1,"result":{"text":"one\342\200\250two\302\205three"}}\n'
        read line; echo '{"jsonrpc":"2.0","id":2,"result":{"text":"next"}}'
        cat >/dev/null
        """#)
        let session = MemorySession()
        let first = try await session.call("mci_ask", arguments: Data("{}".utf8), launch: launch, timeout: .seconds(5))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: first) as? [String: Any])?["text"] as? String,
                       "one\u{2028}two\u{0085}three")
        let second = try await session.call("mci_ask", arguments: Data("{}".utf8), launch: launch, timeout: .seconds(5))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: second) as? [String: Any])?["text"] as? String, "next")
        await session.stop()

        // Splitting at every line break, as `bytes.lines` does, would cut
        // the first reply in three.
        var framer = ReplyFramer()
        let bytes = Data("{\"a\":\"one\u{2028}two\u{0085}three\"}\n{\"b\":1}\n".utf8)
        let frames = bytes.compactMap { framer.append($0) }
        XCTAssertEqual(frames.map { String(decoding: $0, as: UTF8.self) },
                       ["{\"a\":\"one\u{2028}two\u{0085}three\"}", "{\"b\":1}"])
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HippocampusKit/CommandBar/MemorySession.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("in reader.bytes.lines"))
        XCTAssertTrue(source.contains("for try await byte in reader.bytes {"))
        XCTAssertTrue(source.contains("var framer = ReplyFramer()"))
    }

    func testSilentAgentTimesOutAndMissingAgentIsUnavailable() async throws {
        let silent = try fakeAgent("sleep 30")
        let session = MemorySession()
        do {
            _ = try await session.call("mci_day", arguments: Data("{}".utf8), launch: silent, timeout: .milliseconds(300))
            XCTFail("expected a timeout")
        } catch let error as MemorySessionError {
            XCTAssertEqual(error, .timedOut)
        }
        let missing = MemorySessionLaunch(executable: URL(fileURLWithPath: "/nonexistent/mci-agent"), arguments: [], environment: [:])
        do {
            _ = try await session.call("mci_day", arguments: Data("{}".utf8), launch: missing, timeout: .seconds(1))
            XCTFail("expected unavailable")
        } catch let error as MemorySessionError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    /// Quit ends Ask's session even when its child ignores SIGTERM in the
    /// middle of an answer (spec-shell S6.2).
    func testStopAndWaitEndsASilentChildWithinASecondAndAHalf() async throws {
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: ready) }
        let silent = try fakeAgent("trap '' TERM\ntouch '\(ready.path)'\nwhile :; do sleep 0.05; done")
        let session = MemorySession()
        let answer = Task {
            try await session.call("mci_ask", arguments: Data("{}".utf8), launch: silent, timeout: .seconds(30))
        }
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = await session.runningProcessIdentifier
        let child = try XCTUnwrap(pid, "the session started its child, which now ignores SIGTERM")

        let started = ContinuousClock.now
        await session.stopAndWait(timeout: .seconds(1))
        let took = started.duration(to: .now)

        XCTAssertGreaterThanOrEqual(took, .milliseconds(900), "SIGTERM was ignored, so SIGKILL ended it")
        XCTAssertLessThan(took, .milliseconds(1500))
        XCTAssertNotEqual(kill(child, 0), 0, "the child is gone, not just let go")
        let running = await session.isRunning
        XCTAssertFalse(running)
        do {
            _ = try await answer.value
            XCTFail("the answer in flight must fail")
        } catch let error as MemorySessionError {
            XCTAssertEqual(error, .exited)
        }
    }

    @MainActor
    func testActivatingAHitOpensItsPageOrTheEvent() throws {
        let model = CommandBarModel(launch: { _ in nil })
        XCTAssertEqual(model.rows, [], "no suggestions without a running agent")
        XCTAssertNil(model.activate())
        XCTAssertFalse(model.back(), "Esc on the home screen closes the bar")
    }

    @MainActor
    func testAsksWarmSessionsStopAfterTimeWithoutACall() async throws {
        let launch = try fakeAgent(#"""
        while read line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
          echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"hits\":[]}}"
        done
        """#)
        let sessions = WarmMemorySessions(launch: { _ in launch }, idleAfter: .milliseconds(300))
        _ = try await sessions.call(.reads, "mci_recall", arguments: Data(#"{"query":"q"}"#.utf8), timeout: .seconds(5))
        let runningAfterCall = await sessions.reads.isRunning
        XCTAssertTrue(runningAfterCall, "warm between calls")
        _ = try await sessions.call(.reads, "mci_recall", arguments: Data(#"{"query":"r"}"#.utf8), timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(150))
        let runningSoonAfter = await sessions.reads.isRunning
        XCTAssertTrue(runningSoonAfter, "each call starts the wait again")
        var stopped = false
        for _ in 0..<100 where !stopped {
            try await Task.sleep(for: .milliseconds(20))
            stopped = await !sessions.reads.isRunning
        }
        XCTAssertTrue(stopped, "stopped once idle")
        XCTAssertEqual(WarmMemorySessions.idleStop, .seconds(600), "about ten minutes in the app")
    }

    @MainActor
    func testWithoutTheAgentACallSaysUnavailable() async {
        let sessions = WarmMemorySessions(launch: { _ in nil })
        do {
            _ = try await sessions.call(.assistant, "mci_ask", arguments: Data("{}".utf8), timeout: .seconds(1))
            XCTFail("expected unavailable")
        } catch let error as MemorySessionError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("\(error)")
        }
    }
}

private final class RecordingLoginItems: LoginItemService, @unchecked Sendable {
    var registered = 0
    var enabled = false
    func status() -> LoginItemStatus { enabled ? .enabled : .notRegistered }
    func register() throws { registered += 1; enabled = true }
    func unregister() throws { enabled = false }
}

final class LoginItemDefaultTests: XCTestCase {
    /// Only setup's ticked "Open Hippocampus at login" adds the login item
    /// (RULINGS O8); unticked, or a sentinel from an older setup, leaves it
    /// as it is.
    @MainActor
    func testOpenAtLoginFollowsSetupsCheckboxAndNothingElse() throws {
        let service = RecordingLoginItems()
        let model = LoginItemViewModel(service: service)
        model.applySetupChoice(opensAtLogin: false)
        model.applySetupChoice(opensAtLogin: nil)
        XCTAssertEqual(service.registered, 0)
        XCTAssertFalse(model.isEnabled)
        model.applySetupChoice(opensAtLogin: true)
        XCTAssertEqual(service.registered, 1)
        XCTAssertTrue(model.isEnabled)

        let kept = RecordingLoginItems()
        kept.enabled = true
        let existing = LoginItemViewModel(service: kept)
        existing.applySetupChoice(opensAtLogin: false)
        XCTAssertTrue(existing.isEnabled, "an existing install keeps whatever it has")
    }

    func testTheSentinelCarriesTheOpenAtLoginChoice() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sentinel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(OnboardingSentinel.filename)
        XCTAssertNil(OnboardingSentinel.opensAtLogin(at: url), "no file")
        for (body, choice) in [
            ("onboarding-completed-at 2026-10-12T21:05:00Z\nopen-at-login yes\n", true as Bool?),
            ("onboarding-completed-at 2026-10-12T21:05:00Z\nopen-at-login no\n", false),
            ("onboarding-completed-at 2026-10-12T21:05:00Z\n", nil),
        ] {
            try body.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertEqual(OnboardingSentinel.opensAtLogin(at: url), choice, body)
        }
        let app = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Hippocampus/HippocampusApp.swift"), encoding: .utf8)
        XCTAssertFalse(app.contains("enableByDefaultOnce"), "no launch turns the login item on by itself")
        XCTAssertTrue(app.contains("loginItemVM.applySetupChoice(opensAtLogin: OnboardingSentinel.opensAtLogin())"))
    }
}
