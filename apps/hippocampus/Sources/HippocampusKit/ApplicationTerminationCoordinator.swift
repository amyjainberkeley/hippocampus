// SPDX-License-Identifier: TBD-private
import Foundation

package enum ApplicationTerminationIntent: Equatable {
    case quit
    case restart
}

@MainActor
package protocol ApplicationRestartLaunching: AnyObject {
    func scheduleRestart() throws
}

@MainActor
package final class DelayedApplicationRestartLauncher: ApplicationRestartLaunching {
    private let bundlePath: String

    package init(bundlePath: String) {
        self.bundlePath = bundlePath
    }

    package func scheduleRestart() throws {
        let task = ChildProcessEnvironment.makeProcess()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "sleep 1; exec /usr/bin/open \"$1\"",
            "hippocampus-restart",
            bundlePath,
        ]
        try task.run()
    }
}

@MainActor
package final class ApplicationTerminationCoordinator {
    private let supervisor: ProcessSupervisor
    private let restartLauncher: any ApplicationRestartLaunching
    private let shutdownTimeout: TimeInterval
    private let cleanup: @MainActor () -> Void
    private let onFailure: @MainActor (Error) -> Void

    package private(set) var hasVerifiedShutdown = false

    package init(
        supervisor: ProcessSupervisor,
        restartLauncher: any ApplicationRestartLaunching,
        shutdownTimeout: TimeInterval = 2,
        cleanup: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        self.supervisor = supervisor
        self.restartLauncher = restartLauncher
        self.shutdownTimeout = shutdownTimeout
        self.cleanup = cleanup
        self.onFailure = onFailure
    }

    /// Owns the awaited AppKit termination boundary. A positive reply is sent
    /// only after the supervisor publishes `.stopped`; restart scheduling is
    /// downstream of that same proof.
    @discardableResult
    package func terminate(
        intent: ApplicationTerminationIntent,
        reply: @escaping @MainActor (Bool) -> Void
    ) async -> Bool {
        if hasVerifiedShutdown {
            reply(true)
            return true
        }

        do {
            try await supervisor.shutdownAndWait(timeout: shutdownTimeout)
            guard supervisor.state == .stopped else {
                throw ApplicationTerminationError.supervisorDidNotStop
            }
            if intent == .restart {
                try restartLauncher.scheduleRestart()
            }
            cleanup()
            hasVerifiedShutdown = true
            reply(true)
            return true
        } catch {
            onFailure(error)
            reply(false)
            return false
        }
    }
}

private enum ApplicationTerminationError: LocalizedError {
    case supervisorDidNotStop

    var errorDescription: String? {
        "The capture supervisor did not reach its verified stopped state."
    }
}
