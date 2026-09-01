import Darwin
import Foundation

@main
struct KeyCustodyCommandRunnerBehavior {
    static func main() async throws {
        if CommandLine.arguments.count >= 3,
           CommandLine.arguments[1] == "resistant-child" {
            signal(SIGTERM, SIG_IGN)
            try "\(getpid())".write(
                toFile: CommandLine.arguments[2],
                atomically: true,
                encoding: .utf8
            )
            while true { try await Task.sleep(for: .seconds(1)) }
        }
        if CommandLine.arguments.count >= 3,
           CommandLine.arguments[1] == "short-child" {
            try "\(getpid())".write(
                toFile: CommandLine.arguments[2],
                atomically: true,
                encoding: .utf8
            )
            return
        }

        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        precondition(KeyCustodyCommandRunner.terminationGraceSeconds <= 0.5)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hippocampus-key-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let resistantPIDFile = directory.appendingPathComponent("resistant.pid")
        let resistant = Task {
            try await KeyCustodyCommandRunner.run(
                executableURL: executable,
                arguments: ["resistant-child", resistantPIDFile.path],
                environment: ProcessInfo.processInfo.environment
            )
        }
        let resistantPID = try await waitForPID(at: resistantPIDFile)
        let cancellationStart = ContinuousClock.now
        resistant.cancel()
        do {
            _ = try await resistant.value
            throw FixtureFailure("SIGTERM-resistant cancellation returned a result")
        } catch is CancellationError {
            // Expected.
        }
        precondition(
            cancellationStart.duration(to: .now) < .seconds(2),
            "TERM-to-KILL escalation exceeded its bound"
        )
        try assertNotRunning(resistantPID)

        let beforeInstallPIDFile = directory.appendingPathComponent("before-install.pid")
        let beforeInstall = Task {
            try await KeyCustodyCommandRunner.run(
                executableURL: executable,
                arguments: ["resistant-child", beforeInstallPIDFile.path],
                environment: ProcessInfo.processInfo.environment
            )
        }
        beforeInstall.cancel()
        do {
            _ = try await beforeInstall.value
            throw FixtureFailure("cancel-before-install returned a result")
        } catch is CancellationError {
            // Expected.
        }
        if FileManager.default.fileExists(atPath: beforeInstallPIDFile.path) {
            try assertNotRunning(try readPID(at: beforeInstallPIDFile))
        }

        let failedLaunch = Task {
            try await KeyCustodyCommandRunner.run(
                executableURL: directory.appendingPathComponent("missing-executable"),
                arguments: [],
                environment: ProcessInfo.processInfo.environment
            )
        }
        failedLaunch.cancel()
        do {
            _ = try await failedLaunch.value
            throw FixtureFailure("cancelled launch failure returned a result")
        } catch is CancellationError {
            // Cancellation wins the launch-failure race.
        }

        let shortPIDFile = directory.appendingPathComponent("short.pid")
        let completed = Task {
            try await KeyCustodyCommandRunner.run(
                executableURL: executable,
                arguments: ["short-child", shortPIDFile.path],
                environment: ProcessInfo.processInfo.environment
            )
        }
        let result = try await completed.value
        precondition(result.terminationStatus == 0)
        completed.cancel()
        try assertNotRunning(try readPID(at: shortPIDFile))
    }

    private static func waitForPID(at url: URL) async throws -> pid_t {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: url.path) {
                return try readPID(at: url)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureFailure("child never published its PID")
    }

    private static func readPID(at url: URL) throws -> pid_t {
        guard let pid = pid_t(try String(contentsOf: url, encoding: .utf8)) else {
            throw FixtureFailure("invalid child PID")
        }
        return pid
    }

    private static func assertNotRunning(_ pid: pid_t) throws {
        errno = 0
        guard kill(pid, 0) == -1, errno == ESRCH else {
            throw FixtureFailure("child PID \(pid) survived cancellation")
        }
    }
}

private struct FixtureFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
