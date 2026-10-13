import Foundation
import os
import XCTest
@testable import RecallUIKit

/// The contract samples copied into `Tests/UnderstandingFixtures/`: made-up
/// data (persona Sam), never anything read from this Mac.
enum UnderstandingFixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("UnderstandingFixtures", isDirectory: true)

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func object(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data(name)) as? [String: Any] ?? [:]
    }

    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    static func overview() throws -> DayOverview {
        try JSONDecoder().decode(DayOverview.self, from: data("overview.sample.json"))
    }

    static func modelPage() throws -> ModelPage {
        try JSONDecoder().decode(ModelPage.self, from: data("model-page.sample.json"))
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }
}

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_791_841_025))

    var now: Date { lock.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Records every command a reader runs, with its time limit, and answers
/// with a fixed output.
final class RecordingRunner: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [(command: ContextHandoffCommand, timeout: TimeInterval)]())
    private let output: @Sendable (ContextHandoffCommand) throws -> String

    init(output: @escaping @Sendable (ContextHandoffCommand) throws -> String) {
        self.output = output
    }

    var commands: [ContextHandoffCommand] { lock.withLock { $0.map(\.command) } }
    var timeouts: [TimeInterval] { lock.withLock { $0.map(\.timeout) } }

    var run: AgentUnderstandingReader.Runner {
        { [self] command, timeout in
            lock.withLock { $0.append((command, timeout)) }
            return try output(command)
        }
    }
}

enum TestFolders {
    /// A new, empty folder for one test, under the temporary folder.
    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-understanding-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A stand-in for `mci-agent mcp-serve`: writes its arguments and every line
/// it reads beside itself, then answers each request, or hangs when a `hang`
/// file is there. It never reads a memory.
enum FakeAgent {
    static let script = """
    #!/bin/sh
    dir=$(cd "$(dirname "$0")" && pwd)
    printf '%s\\n' "$@" > "$dir/argv.txt"
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "$dir/stdin.txt"
      if [ -f "$dir/hang" ]; then exec sleep 30; fi
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      printf '{"jsonrpc":"2.0","id":%s,"result":{"result":{"answer":"Tuesday.","unavailable":null,"sources":[]}}}\\n' "$id"
    done
    """

    /// Install the stand-in as `mci-agent` in a new folder; returns the folder.
    static func install(hang: Bool = false) throws -> URL {
        let folder = try TestFolders.make()
        let agent = folder.appendingPathComponent("mci-agent")
        try Data(script.utf8).write(to: agent)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)
        if hang {
            try Data().write(to: folder.appendingPathComponent("hang"))
        }
        return folder
    }

    static func launch(_ folder: URL, environment: [String: String] = [:]) throws -> MemorySessionLaunch {
        try AgentUnderstandingReader.answerLaunch(
            environment: environment,
            recallExecutableURL: folder.appendingPathComponent("recall-ui"),
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
    }
}

/// Poll until `condition` holds or `timeout` passes.
func eventually(timeout: TimeInterval = 3, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Fail the test unless `condition` holds within `timeout`.
func assertEventually(
    _ message: @autoclosure () -> String = "",
    timeout: TimeInterval = 3,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @Sendable () async -> Bool
) async {
    if await !eventually(timeout: timeout, condition) {
        XCTFail(message(), file: file, line: line)
    }
}

func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}
