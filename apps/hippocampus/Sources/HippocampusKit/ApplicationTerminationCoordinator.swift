// SPDX-License-Identifier: TBD-private
import CoreServices
import Foundation

package enum ApplicationTerminationIntent: Equatable {
    case quit
    case restart
}

/// Distinguishes a deliberate product quit/restart from AppKit lifecycle
/// noise. In particular, SwiftUI's menu-bar visibility action can ask the
/// application to terminate even though the user never chose Quit.
@MainActor
package final class ApplicationTerminationRequestGate {
    private var requestedIntent: ApplicationTerminationIntent?

    package init() {}

    package func request(_ intent: ApplicationTerminationIntent) {
        requestedIntent = intent
    }

    package func requestQuitIfAppleEvent(_ event: NSAppleEventDescriptor?) {
        guard requestedIntent == nil,
              let event,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication)
        else { return }
        requestedIntent = .quit
    }

    package func takeRequestedIntent() -> ApplicationTerminationIntent? {
        defer { requestedIntent = nil }
        return requestedIntent
    }
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

    /// Owns the awaited AppKit termination boundary. Restart scheduling is
    /// downstream of a verified `.stopped`: relaunching beside a surviving
    /// writer is never allowed. A quit always completes. When the verified
    /// stop hangs or fails within its bound, the supervisor is forced to a
    /// stop that can never relaunch and the app exits; its children follow
    /// the parent lease. On 2026-09-26 and 2026-10-08 a quit during capture
    /// recovery waited forever instead.
    @discardableResult
    package func terminate(
        intent: ApplicationTerminationIntent,
        reply: @escaping @MainActor (Bool) -> Void
    ) async -> Bool {
        if hasVerifiedShutdown {
            reply(true)
            return true
        }

        let outcome = await boundedShutdown()
        do {
            var verified = false
            if case .stopped = outcome { verified = supervisor.state == .stopped }
            if !verified {
                guard intent == .quit else {
                    if case .failed(let error) = outcome { throw error }
                    throw ApplicationTerminationError.supervisorDidNotStop
                }
                await supervisor.forceStopForQuit(timeout: shutdownTimeout)
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

    private enum ShutdownOutcome {
        case stopped
        case failed(Error)
        case timedOut
    }

    /// The verified stop, bounded. Its own steps are bounded too, but a quit
    /// must not depend on every one of them keeping that promise.
    private func boundedShutdown() async -> ShutdownOutcome {
        let supervisor = supervisor
        let limit = shutdownTimeout * 2 + 1
        return await withCheckedContinuation { continuation in
            var resumed = false
            func finish(_ outcome: ShutdownOutcome) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: outcome)
            }
            Task { @MainActor in
                do {
                    try await supervisor.shutdownAndWait(timeout: self.shutdownTimeout)
                    finish(.stopped)
                } catch {
                    finish(.failed(error))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(limit))
                finish(.timedOut)
            }
        }
    }
}

private enum ApplicationTerminationError: LocalizedError {
    case supervisorDidNotStop

    var errorDescription: String? {
        "The capture supervisor did not reach its verified stopped state."
    }
}
