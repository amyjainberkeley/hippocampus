import Darwin
import Foundation

@main
struct SupervisorProcessShutdownBehavior {
    @MainActor
    static func main() async throws {
        try await proveNormalQuitWaitsForDeath()
        try await proveResistantChildIsKilledBeforeRestartBoundary()
    }

    @MainActor
    private static func proveNormalQuitWaitsForDeath() async throws {
        let helper = try launchShell("trap 'exit 0' TERM; while :; do sleep 1; done")
        let agent = try launchShell("trap 'exit 0' TERM; while :; do sleep 1; done")
        let pids = [helper.processIdentifier, agent.processIdentifier]
        try await Task.sleep(for: .milliseconds(75))

        try await SupervisorProcessShutdown.stop(
            processes: [helper, agent],
            termTimeout: 1
        )

        precondition(pids.allSatisfy { !SupervisorProcessShutdown.pidIsAlive($0) })
    }

    @MainActor
    private static func proveResistantChildIsKilledBeforeRestartBoundary() async throws {
        let helper = try launchShell("trap '' TERM; while :; do sleep 1; done")
        let agent = try launchShell("trap '' TERM; while :; do sleep 1; done")
        let pids = [helper.processIdentifier, agent.processIdentifier]
        try await Task.sleep(for: .milliseconds(75))
        let start = ContinuousClock.now

        try await SupervisorProcessShutdown.stop(
            processes: [helper, agent],
            termTimeout: 0.1
        )

        precondition(!helper.isRunning && !agent.isRunning)
        precondition(pids.allSatisfy { !SupervisorProcessShutdown.pidIsAlive($0) })
        precondition(
            start.duration(to: .now) >= .milliseconds(100),
            "resistant children exited before the TERM grace boundary"
        )
    }

    private static func launchShell(_ script: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        return process
    }
}
