import XCTest
@testable import OnboardingKit

/// A child that either exited at once with `exitStatus`, or answers each
/// request from `pages`.
private final class FakeChild: ReaderChild, @unchecked Sendable {
    private let lock = NSLock()
    private var running: Bool
    private let status: Int32?
    private var pages: [[ReadRow]]
    private(set) var requests: [[String: Any]] = []
    private(set) var stopped = false

    init(exitedWith status: Int32) {
        running = false
        self.status = status
        pages = []
    }

    init(pages: [[ReadRow]]) {
        running = true
        status = nil
        self.pages = pages
    }

    var isRunning: Bool { lock.withLock { running } }
    var exitStatus: Int32? { lock.withLock { running ? nil : (status ?? 15) } }

    func call(_ line: Data, id: Int, timeout: Duration) async -> Data? {
        lock.withLock { () -> Data? in
            guard running else { return nil }
            requests.append((try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:])
            guard !pages.isEmpty else { return nil }
            let page = pages.removeFirst()
            let events: [[String: Any]] = page.map { row in
                ["ts_us": NSNumber(value: row.tsUs), "app_bundle_id": row.appBundleId ?? NSNull(),
                 "window_title": row.windowTitle ?? NSNull(), "text_snippet": row.text, "source_kind": row.sourceKind]
            }
            return try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": ["events": events]])
        }
    }

    func stop() {
        lock.withLock {
            running = false
            stopped = true
        }
    }
}

private final class FakeLauncher: ReaderLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var children: [FakeChild]
    private let clock: TestClock
    private(set) var launchTimes: [Date] = []

    init(children: [FakeChild], clock: TestClock) {
        self.children = children
        self.clock = clock
    }

    func launch() -> (any ReaderChild)? {
        lock.withLock {
            launchTimes.append(clock.now)
            return children.isEmpty ? nil : children.removeFirst()
        }
    }
}

final class AgentLastReadProbeTests: XCTestCase {
    private func rows(_ range: ClosedRange<UInt64>) -> [ReadRow] {
        range.map { ReadRow(tsUs: $0, appBundleId: "com.apple.Notes", windowTitle: "Plan", text: "row \($0)", sourceKind: "screen_ocr") }
    }

    func testExitsTenAndTwelveMeanNotReadyAndTheAgentIsStartedNoFasterThanEveryTwoSeconds() async {
        let clock = TestClock()
        let launcher = FakeLauncher(
            children: [FakeChild(exitedWith: 12), FakeChild(exitedWith: 10), FakeChild(exitedWith: 12)],
            clock: clock
        )
        let probe = AgentLastReadProbe(launcher: launcher, now: { clock.now })

        for _ in 0..<12 {
            let batch = await probe.rows(after: 0)
            XCTAssertEqual(batch, .notReady)
            clock.advance(0.5)
        }
        let launches = await probe.launchCount
        XCTAssertEqual(launches, 3, "six seconds of reads start the agent three times")
        let gaps = zip(launcher.launchTimes.dropFirst(), launcher.launchTimes).map { $0.timeIntervalSince($1) }
        XCTAssertTrue(gaps.allSatisfy { $0 >= AgentLastReadProbe.minimumRespawnInterval }, "\(gaps)")
        let last = await probe.lastExitStatus
        XCTAssertTrue(AgentLastReadProbe.notReadyExitCodes.contains(last ?? 0))
    }

    func testItPagesToTheNewestRows() async throws {
        let clock = TestClock()
        let child = FakeChild(pages: [rows(1...50), rows(51...100), rows(101...107)])
        let probe = AgentLastReadProbe(launcher: FakeLauncher(children: [child], clock: clock), now: { clock.now })
        let batch = await probe.rows(after: 0)
        guard case .rows(let found, let newest) = batch else { return XCTFail("\(batch)") }
        XCTAssertEqual(newest, 107)
        XCTAssertEqual(found.map(\.tsUs), Array(8...107), "the newest two pages are kept")
        let cursors = child.requests.map { request -> UInt64 in
            let arguments = (request["params"] as? [String: Any])?["arguments"] as? [String: Any]
            return (arguments?["ts_us"] as? NSNumber)?.uint64Value ?? .max
        }
        XCTAssertEqual(cursors, [0, 50, 100])
        let tool = (child.requests.first?["params"] as? [String: Any])?["name"] as? String
        XCTAssertEqual(tool, "mci_events_since")
    }

    func testEmptyMemoryIsReadyWithNothingYet() async {
        let clock = TestClock()
        let probe = AgentLastReadProbe(
            launcher: FakeLauncher(children: [FakeChild(pages: [[]])], clock: clock), now: { clock.now }
        )
        let batch = await probe.rows(after: 42)
        XCTAssertEqual(batch, .rows([], newestTsUs: nil))
    }

    func testAChildThatStopsAnsweringIsReplacedLater() async {
        let clock = TestClock()
        let silent = FakeChild(pages: [])
        let launcher = FakeLauncher(children: [silent, FakeChild(pages: [rows(1...2)])], clock: clock)
        let probe = AgentLastReadProbe(launcher: launcher, now: { clock.now })
        let first = await probe.rows(after: 0)
        XCTAssertEqual(first, .notReady)
        XCTAssertTrue(silent.stopped)
        clock.advance(2)
        let second = await probe.rows(after: 0)
        XCTAssertEqual(second, .rows(rows(1...2), newestTsUs: 2))
    }

    func testStopEndsReadingUntilResumed() async {
        let clock = TestClock()
        let child = FakeChild(pages: [rows(1...1), rows(2...2)])
        let launcher = FakeLauncher(children: [child, FakeChild(pages: [rows(3...3)])], clock: clock)
        let probe = AgentLastReadProbe(launcher: launcher, now: { clock.now })
        _ = await probe.rows(after: 0)
        await probe.stop()
        XCTAssertTrue(child.stopped)
        clock.advance(10)
        let after = await probe.rows(after: 1)
        XCTAssertEqual(after, .notReady)
        XCTAssertEqual(launcher.launchTimes.count, 1, "nothing starts the agent after stop")

        // Try Again: reading resumes with a new agent.
        await probe.resume()
        let resumed = await probe.rows(after: 2)
        XCTAssertEqual(resumed, .rows(rows(3...3), newestTsUs: 3))
        XCTAssertEqual(launcher.launchTimes.count, 2)
    }

    func testResumingStillStartsTheAgentNoFasterThanEveryTwoSeconds() async {
        let clock = TestClock()
        let launcher = FakeLauncher(children: [FakeChild(exitedWith: 12), FakeChild(exitedWith: 12)], clock: clock)
        let probe = AgentLastReadProbe(launcher: launcher, now: { clock.now })
        _ = await probe.rows(after: 0)
        await probe.stop()
        await probe.resume()
        let soon = await probe.rows(after: 0)
        XCTAssertEqual(soon, .notReady)
        XCTAssertEqual(launcher.launchTimes.count, 1)
        clock.advance(AgentLastReadProbe.minimumRespawnInterval)
        _ = await probe.rows(after: 0)
        XCTAssertEqual(launcher.launchTimes.count, 2)
    }

    // MARK: - The environment

    func testTheReaderGetsTheKeyReferenceItInheritedAndNothingElse() throws {
        let inherited = [
            "HOME": "/Users/someone", "PATH": "/usr/bin:/bin", "TMPDIR": "/tmp/x",
            "MCI_DB_PATH": "/Users/someone/Library/Application Support/MCI/mci.sqlite",
            "MCI_DB_KEYCHAIN_SERVICE": "ai.hippocampus.brain", "MCI_DB_KEYCHAIN_ACCOUNT": "database-key-v1",
            "MCI_DB_KEYCHAIN_STORAGE_MODEL": "file-keychain-acl-v1",
            "MCI_DB_KEY_HEX": String(repeating: "ab", count: 32),
            "SOME_PROVIDER_API_KEY": "secret", "MCI_ONBOARDING_STEP": "try-it",
        ]
        let environment = try XCTUnwrap(ReaderEnvironment.make(inherited: inherited))
        XCTAssertEqual(environment, [
            "HOME": "/Users/someone", "PATH": "/usr/bin:/bin", "TMPDIR": "/tmp/x",
            "MCI_DB_PATH": "/Users/someone/Library/Application Support/MCI/mci.sqlite",
            "MCI_DB_KEYCHAIN_SERVICE": "ai.hippocampus.brain", "MCI_DB_KEYCHAIN_ACCOUNT": "database-key-v1",
            "MCI_DB_KEYCHAIN_STORAGE_MODEL": "file-keychain-acl-v1",
            "MCI_EMBEDDER_DISABLED": "1",
        ])
    }

    func testADevelopmentKeyBuildForwardsItsKeyFile() throws {
        let environment = try XCTUnwrap(ReaderEnvironment.make(inherited: [
            "MCI_DB_PATH": "/tmp/dev/mci.sqlite", "MCI_DEVELOPMENT_FILE_KEY": "1", "MCI_DB_KEY_FILE": "/tmp/dev/key",
        ]))
        XCTAssertEqual(environment["MCI_DEVELOPMENT_FILE_KEY"], "1")
        XCTAssertEqual(environment["MCI_DB_KEY_FILE"], "/tmp/dev/key")
        XCTAssertNil(environment["MCI_DB_KEYCHAIN_SERVICE"])
    }

    func testWithoutAMemoryPathOrAWholeKeyReferenceNothingIsRead() {
        XCTAssertNil(ReaderEnvironment.make(inherited: ["MCI_DB_KEYCHAIN_SERVICE": "s", "MCI_DB_KEYCHAIN_ACCOUNT": "a",
                                                        "MCI_DB_KEYCHAIN_STORAGE_MODEL": "m"]))
        XCTAssertNil(ReaderEnvironment.make(inherited: ["MCI_DB_PATH": "/tmp/mci.sqlite", "MCI_DB_KEYCHAIN_SERVICE": "s"]))
        XCTAssertNil(ReaderEnvironment.make(inherited: ["MCI_DB_PATH": "/tmp/mci.sqlite", "MCI_DB_KEY_HEX": "ab"]))
        XCTAssertNil(AgentReaderLauncher(executable: URL(fileURLWithPath: "/bin/sh"), environment: nil).launch())
        XCTAssertNil(AgentReaderLauncher(executable: nil, environment: [:]).launch())
    }

    // MARK: - The pipe child

    func testThePipeChildReportsAnExitTwelveAsGone() async throws {
        let child = try XCTUnwrap(ProcessReaderChild(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 12"], environment: [:]
        ))
        let deadline = Date().addingTimeInterval(5)
        while child.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(child.exitStatus, 12)
        let reply = await child.call(Data("{}".utf8), id: 1, timeout: .seconds(1))
        XCTAssertNil(reply, "a write to a gone child fails without ending this process")
    }

    /// A reply as the agent writes it: one line, the snippet's characters
    /// as they are.
    private func reply(snippet: String) -> String {
        #"{"jsonrpc":"2.0","id":7,"result":{"events":[{"ts_us":5,"app_bundle_id":"com.apple.Notes","window_title":"Plan","text_snippet":""#
            + snippet + #"","source_kind":"screen_ocr"}]}}"#
    }

    /// Start a child that answers one request with `body` and a newline.
    private func answer(with body: String) async throws -> Data? {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("reply.json")
        try Data(body.utf8).write(to: file)
        let script = "read line; cat \"$0\"; printf '\\n'; read line"
        let child = try XCTUnwrap(ProcessReaderChild(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, file.path], environment: [:]
        ))
        defer { child.stop() }
        return await child.call(Data(#"{"id":7}"#.utf8), id: 7, timeout: .seconds(5))
    }

    func testRepliesWithLineSeparatorsInsideAStringStillArrive() async throws {
        // The agent's JSON writer leaves U+2028, U+2029 and U+0085 as they
        // are; only the newline byte ends a reply.
        for separator in ["\u{2028}", "\u{2029}", "\u{85}"] {
            let snippet = "first\(separator)second"
            let body = reply(snippet: snippet)
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(body.utf8)), "the reply is valid JSON")
            let delivered = try await answer(with: body)
            let reply = try XCTUnwrap(delivered, "U+\(String(separator.unicodeScalars.first!.value, radix: 16))")
            XCTAssertEqual(ReadProof.rows(fromReply: reply)?.first?.text, snippet)
        }
        let plain = try await answer(with: reply(snippet: "first second"))
        XCTAssertEqual(plain.flatMap(ReadProof.rows(fromReply:))?.count, 1)
    }

    func testThePipeChildMatchesRepliesToRequestsById() async throws {
        let script = #"read line; printf '%s\n' '{"jsonrpc":"2.0","id":7,"result":{"events":[]}}'; read line"#
        let child = try XCTUnwrap(ProcessReaderChild(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], environment: [:]
        ))
        defer { child.stop() }
        let answer = await child.call(Data(#"{"id":7}"#.utf8), id: 7, timeout: .seconds(5))
        let reply = try XCTUnwrap(answer)
        XCTAssertEqual(ReadProof.rows(fromReply: reply), [])
    }
}
