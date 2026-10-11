import Foundation
import XCTest
@testable import HippocampusKit

final class CommandBarTests: XCTestCase {
    func testQuestionsAreAskedAndPhrasesAreSearched() {
        for question in ["what did we decide on pricing?", "When is the beta", "who owns the launch plan", "summarize my day"] {
            XCTAssertTrue(CommandBarModel.looksLikeQuestion(question), question)
        }
        for phrase in ["stripe pricing", "launch plan", "Ravi"] {
            XCTAssertFalse(CommandBarModel.looksLikeQuestion(phrase), phrase)
        }
    }

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
}
