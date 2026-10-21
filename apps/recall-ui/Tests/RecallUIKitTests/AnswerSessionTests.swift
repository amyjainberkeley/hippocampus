import XCTest
@testable import RecallUIKit

final class AnswerSessionTests: XCTestCase {
    private let question = "When did I fix the tax rounding?"

    private func session(_ folder: URL, children: ChildProcesses, idleAfter: Duration = .seconds(60),
                         environment: [String: String] = ["MCI_DB_PATH": "/tmp/fixture/mci.sqlite"]) -> AnswerSession {
        AnswerSession(session: MemorySession(children: children), idleAfter: idleAfter) {
            try FakeAgent.launch(folder, environment: environment)
        }
    }

    private static func lines(_ folder: URL, _ name: String) -> [String] {
        let text = (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func testTheQuestionTravelsOnStandardInputNeverOnTheCommandLine() async throws {
        let folder = try FakeAgent.install()
        defer { try? FileManager.default.removeItem(at: folder) }
        let children = ChildProcesses()
        let answers = session(folder, children: children)
        let answer = try await answers.ask(question, app: "com.apple.Notes", title: "Pricing page draft", now: "Using Notes")
        await answers.stop()

        XCTAssertEqual(answer.answer, "Tuesday.")
        XCTAssertEqual(Self.lines(folder, "argv.txt"), ["mcp-serve", "--assist", "--db-path", "/tmp/fixture/mci.sqlite"])
        let sent = Self.lines(folder, "stdin.txt")
        XCTAssertEqual(sent.count, 1)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sent[0].utf8)) as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "tools/call")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["name"] as? String, "mci_ask")
        let arguments = try XCTUnwrap(params["arguments"] as? [String: String])
        XCTAssertEqual(arguments, ["question": question, "app": "com.apple.Notes",
                                   "title": "Pricing page draft", "now": "Using Notes"])
    }

    func testTheAnswerChildGetsOnlyTheWindowsOwnEnvironment() throws {
        let folder = try FakeAgent.install()
        defer { try? FileManager.default.removeItem(at: folder) }
        let launch = try FakeAgent.launch(folder, environment: [
            "HOME": "/Users/fixture", "MCI_DB_PATH": "/tmp/fixture/mci.sqlite",
            "MCI_DB_KEYCHAIN_SERVICE": "ai.hippocampus.brain", "ANTHROPIC_API_KEY": "fixture-secret",
            "MCI_DB_KEY_HEX": "00",
        ])
        XCTAssertEqual(launch.executable.lastPathComponent, "mci-agent")
        XCTAssertEqual(launch.arguments, ["mcp-serve", "--assist", "--db-path", "/tmp/fixture/mci.sqlite"])
        XCTAssertEqual(launch.environment["MCI_DB_KEYCHAIN_SERVICE"], "ai.hippocampus.brain")
        XCTAssertEqual(launch.environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertNil(launch.environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(launch.environment["MCI_DB_KEY_HEX"], "key bytes pass only with the development key")
    }

    /// The agent writes U+2028 and U+0085 unescaped inside a reply. Replies
    /// are cut at the 0x0A byte only, so such a reply arrives whole instead
    /// of timing out (RULINGS W2).
    func testARepliesHoldingLineSeparatorsArriveWhole() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("framing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = folder.appendingPathComponent("mci-agent")
        try #"""
        #!/bin/sh
        read line; printf '{"jsonrpc":"2.0","id":1,"result":{"text":"one\342\200\250two\302\205three"}}\n'
        read line; echo '{"jsonrpc":"2.0","id":2,"result":{"text":"next"}}'
        cat >/dev/null
        """#.write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)
        let launch = MemorySessionLaunch(executable: agent, arguments: [], environment: ["PATH": "/usr/bin:/bin"])
        let session = MemorySession(children: ChildProcesses())
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
        XCTAssertEqual(bytes.compactMap { framer.append($0) }.map { String(decoding: $0, as: UTF8.self) },
                       ["{\"a\":\"one\u{2028}two\u{0085}three\"}", "{\"b\":1}"])
    }

    func testCancellingAnAskStopsItsRequest() async throws {
        let folder = try FakeAgent.install(hang: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let children = ChildProcesses()
        let answers = session(folder, children: children)
        let question = self.question
        let ask = Task { try await answers.ask(question) }
        // A Mac busy with other builds can take seconds to start the fake
        // agent; the wait ends as soon as it has read the question.
        await assertEventually(timeout: 30) { Self.lines(folder, "stdin.txt").count == 1 }
        let pid = try XCTUnwrap(children.running.first)
        let cancelledAt = Date()
        ask.cancel()
        do {
            _ = try await ask.value
            XCTFail("a cancelled question was answered")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2)
        await assertEventually("the request is stopped with its child") { !isAlive(pid) && children.running.isEmpty }
        let running = await answers.isRunning
        XCTAssertFalse(running)
    }

    func testTheWarmChildStopsAfterItsIdleTimeAndStartsAgainWhenAsked() async throws {
        let folder = try FakeAgent.install()
        defer { try? FileManager.default.removeItem(at: folder) }
        let children = ChildProcesses()
        let answers = session(folder, children: children, idleAfter: .milliseconds(300))
        _ = try await answers.ask(question)
        let first = try XCTUnwrap(children.running.first)
        await assertEventually { await !answers.isRunning }
        await assertEventually { !isAlive(first) && children.running.isEmpty }
        let again = try await answers.ask(question)
        XCTAssertEqual(again.answer, "Tuesday.")
        XCTAssertNotEqual(children.running.first, first)
        await answers.stop()
        await assertEventually { children.running.isEmpty }
    }

    func testTheWarmChildStaysBetweenQuestionsWithinItsIdleTime() async throws {
        let folder = try FakeAgent.install()
        defer { try? FileManager.default.removeItem(at: folder) }
        let children = ChildProcesses()
        let answers = session(folder, children: children)
        _ = try await answers.ask(question)
        let first = children.running
        _ = try await answers.ask(question)
        XCTAssertEqual(children.running, first, "one warm child answers both")
        XCTAssertEqual(Self.lines(folder, "stdin.txt").count, 2)
        await answers.stop()
    }

    func testWithoutAnAgentAnswersAreUnavailable() async {
        let answers = AnswerSession { throw ContextHandoffError.agentUnavailable }
        do {
            _ = try await answers.ask(question)
            XCTFail("no agent, no answer")
        } catch {
            XCTAssertEqual(error as? UnderstandingError, .unavailable)
        }
    }

    func testAnEmptyQuestionIsNeverSent() async throws {
        let folder = try FakeAgent.install()
        defer { try? FileManager.default.removeItem(at: folder) }
        let children = ChildProcesses()
        let answers = session(folder, children: children)
        do {
            _ = try await answers.ask("  \n ")
            XCTFail("an empty question was asked")
        } catch {
            XCTAssertEqual(error as? UnderstandingError, .malformed)
        }
        XCTAssertTrue(children.running.isEmpty)
    }
}
