import XCTest
@testable import RecallUIKit

/// The window's reads from the bundled agent, through a fake runner: the
/// arguments each read sends, two minutes of memory that a delete clears,
/// a Resume plan read fresh every time, and failures in the window's words.
/// No agent runs.
final class AgentWorkReaderTests: XCTestCase {
    private final class Runner: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [ContextHandoffCommand] = []
        private var answer: String
        private var fails = false

        init(_ answer: String) {
            self.answer = answer
        }

        var ran: [[String]] { lock.withLock { commands.map(\.arguments) } }
        var executables: [URL] { lock.withLock { commands.map(\.executableURL) } }

        func answer(_ text: String) {
            lock.withLock { answer = text }
        }

        func fail() {
            lock.withLock { fails = true }
        }

        func run(_ command: ContextHandoffCommand) throws -> String {
            try lock.withLock {
                commands.append(command)
                if fails { throw ContextHandoffError.agentUnavailable }
                return answer
            }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = WorkClock.now
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) {
            lock.withLock { date = date.addingTimeInterval(seconds) }
        }
    }

    private let workJSON = #"""
        {"generated_us": 1, "items": [
          {"id": "w_5c1e8a0d2f9b47e3a6d1", "kind": "code", "name": "trailhead-shop", "last_us": 5}
        ], "pages": [], "moment_items": {"4812": "w_5c1e8a0d2f9b47e3a6d1"}}
        """#

    private func reader(_ runner: Runner, clock: Clock = Clock(), environment: [String: String] = [:],
                        deletions: MemoryDeletionSignal = MemoryDeletionSignal()) -> AgentWorkReader {
        AgentWorkReader(
            environment: environment,
            recallExecutableURL: URL(fileURLWithPath: "/Applications/Hippocampus.app/Contents/MacOS/recall-ui"),
            isExecutable: { $0.lastPathComponent == "mci-agent" },
            run: { command, _ in try runner.run(command) },
            now: { clock.now },
            timeZone: TimeZone(secondsFromGMT: -7 * 3_600) ?? .gmt,
            deletions: deletions
        )
    }

    func testEachReadSendsItsArgumentsWithJSONAndTheTimeZone() async throws {
        let runner = Runner(workJSON)
        let agent = reader(runner, environment: ["MCI_DB_PATH": "/tmp/fixture-brain.db"])
        let work = try await agent.work(days: 90)
        XCTAssertEqual(work.items.map(\.name), ["trailhead-shop"])
        let found = try await agent.item(id: "w_5c1e8a0d2f9b47e3a6d1", before: 1_791_000_000_000_000)
        XCTAssertEqual(found?.name, "trailhead-shop")
        let lookups = try await agent.items(forMoments: [4812, 17])
        XCTAssertEqual(lookups, [4812: "w_5c1e8a0d2f9b47e3a6d1"])
        let tail = ["--json", "--tz-offset-secs", "-25200", "--db-path", "/tmp/fixture-brain.db"]
        XCTAssertEqual(runner.ran, [
            ["work", "--days", "90"] + tail,
            ["work", "--item", "w_5c1e8a0d2f9b47e3a6d1", "--before", "1791000000000000"] + tail,
            ["work", "--moments", "17,4812"] + tail,
        ])
        XCTAssertEqual(runner.executables.map(\.path),
                       Array(repeating: "/Applications/Hippocampus.app/Contents/MacOS/mci-agent", count: 3),
                       "only the agent beside the window")
    }

    func testWhatIsNeverAskedOfTheAgent() async throws {
        let runner = Runner(workJSON)
        let agent = reader(runner)
        let notAnId = try await agent.item(id: "trailhead shop", before: nil)
        XCTAssertNil(notAnId, "what can't be an id is never sent")
        let flag = try await agent.item(id: "--db-path", before: nil)
        XCTAssertNil(flag, "nor anything the agent could read as a flag")
        let none = try await agent.items(forMoments: [])
        XCTAssertEqual(none, [:])
        let plan = try await agent.plan(item: "../etc")
        XCTAssertEqual(plan, .empty)
        XCTAssertEqual(runner.ran, [])
    }

    func testReadsAreKeptTwoMinutesAndNeverAcrossADelete() async throws {
        let runner = Runner(workJSON)
        let clock = Clock()
        let deletions = MemoryDeletionSignal()
        let agent = reader(runner, clock: clock, deletions: deletions)
        _ = try await agent.work(days: 90)
        _ = try await agent.work(days: 90)
        XCTAssertEqual(runner.ran.count, 1, "the second read is the kept one")
        clock.advance(AgentWorkReader.lifetime + 1)
        _ = try await agent.work(days: 90)
        XCTAssertEqual(runner.ran.count, 2, "two minutes on, it reads again")
        await MainActor.run { deletions.post() }
        _ = try await agent.work(days: 90)
        XCTAssertEqual(runner.ran.count, 3, "a delete forgets what was kept")
        await agent.invalidate()
        _ = try await agent.work(days: 90)
        XCTAssertEqual(runner.ran.count, 4)
    }

    func testSearchesAreBoundedAndAPlanIsReadFreshEachTime() async throws {
        let runner = Runner(#"{"searches": [{"query": "per seat vs tiered pricing", "engine": "google", "ts_us": 9, "time": "14:06", "app": "Chrome", "url": "https://www.google.com/search?q=per+seat+vs+tiered+pricing", "event_id": 81206}]}"#)
        let agent = reader(runner)
        let searches = try await agent.searches(hours: 10_000, limit: 9_999)
        XCTAssertEqual(searches.map(\.query), ["per seat vs tiered pricing"])
        XCTAssertEqual(searches.first?.eventId, 81_206)
        XCTAssertEqual(runner.ran.first?.prefix(5).map { $0 }, ["searches", "--hours", "744", "--limit", "500"])

        runner.answer(#"{"items": [{"kind": "app", "title": "Slack", "app": "com.tinyspeck.slackmacgap"}]}"#)
        _ = try await agent.plan(item: "w_5c1e8a0d2f9b47e3a6d1")
        let plan = try await agent.plan(item: "w_5c1e8a0d2f9b47e3a6d1")
        XCTAssertEqual(plan.items.map(\.title), ["Slack"])
        XCTAssertEqual(runner.ran.filter { $0.first == "resume-plan" }.count, 2, "a plan is never kept")
        XCTAssertEqual(Array(runner.ran.last?.prefix(3) ?? []), ["resume-plan", "--item", "w_5c1e8a0d2f9b47e3a6d1"])
    }

    func testFailuresAreTheWindowsOwn() async {
        let runner = Runner("not json")
        let agent = reader(runner)
        do {
            _ = try await agent.work(days: 90)
            XCTFail("a malformed answer is an error")
        } catch {
            XCTAssertEqual(error as? UnderstandingError, .malformed)
        }
        runner.fail()
        do {
            _ = try await agent.work(days: 14)
            XCTFail("a failed run is an error")
        } catch {
            XCTAssertEqual(error as? UnderstandingError, .unavailable)
        }
        let missing = AgentWorkReader(environment: [:], recallExecutableURL: nil, isExecutable: { _ in false },
                                      run: { command, _ in try runner.run(command) })
        do {
            _ = try await missing.work(days: 90)
            XCTFail("no agent, no read")
        } catch {
            XCTAssertEqual(error as? UnderstandingError, .unavailable)
        }
    }
}
