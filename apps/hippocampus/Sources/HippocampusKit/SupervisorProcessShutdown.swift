// SPDX-License-Identifier: TBD-private
import Darwin
import Foundation

enum SupervisorProcessShutdownError: LocalizedError, Equatable {
    case survivingProcesses([pid_t])

    var errorDescription: String? {
        switch self {
        case .survivingProcesses(let pids):
            "Child processes did not stop: \(pids.map(String.init).joined(separator: ", "))"
        }
    }
}

/// The single production TERM-to-KILL boundary for the capture topology.
/// Completion means each tracked Foundation process has exited and its PID no
/// longer resolves in the process table.
@MainActor
enum SupervisorProcessShutdown {
    static func stop(
        processes: [Process],
        termTimeout: TimeInterval,
        killTimeout: TimeInterval = 1
    ) async throws {
        let tracked = processes.filter { $0.processIdentifier > 0 }

        for process in tracked where process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGCONT)
            process.terminate()
        }

        await waitForDeath(processes: tracked, timeout: termTimeout)

        for process in tracked where process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }

        await waitForDeath(processes: tracked, timeout: killTimeout)

        let survivors = tracked.compactMap { process -> pid_t? in
            let pid = process.processIdentifier
            return process.isRunning || pidIsAlive(pid) ? pid : nil
        }
        guard survivors.isEmpty else {
            throw SupervisorProcessShutdownError.survivingProcesses(survivors)
        }
    }

    static func pidIsAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func waitForDeath(
        processes: [Process],
        timeout: TimeInterval
    ) async {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while SupervisorStopPolicy.shouldWait(
            now: Date(),
            deadline: deadline,
            helperRunning: processIsAlive(processes.first),
            agentRunning: processes.dropFirst().contains(where: processIsAlive)
        ) {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func processIsAlive(_ process: Process?) -> Bool {
        guard let process else { return false }
        return process.isRunning || pidIsAlive(process.processIdentifier)
    }
}
