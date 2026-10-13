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
    @MainActor
    func testStartAtLoginIsTurnedOnOnceAndAChoiceSticks() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "login-default-\(UUID().uuidString)"))
        let service = RecordingLoginItems()
        let model = LoginItemViewModel(service: service)
        model.enableByDefaultOnce(defaults: defaults)
        XCTAssertEqual(service.registered, 1)
        XCTAssertTrue(model.isEnabled)
        model.toggle() // the person turns it off
        model.enableByDefaultOnce(defaults: defaults)
        XCTAssertEqual(service.registered, 1, "never re-enabled after the default was applied")
        XCTAssertFalse(model.isEnabled)
    }
}
