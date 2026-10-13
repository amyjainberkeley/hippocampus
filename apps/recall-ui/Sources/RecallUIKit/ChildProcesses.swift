import Darwin
import Foundation
import os

/// Every child process the window starts, so none outlives it (RULINGS G7,
/// critique-recall-engineering finding 3). The agent commands and the warm
/// answer session start their children here; quitting stops them all. A
/// child another package starts out of the window's reach (the OCR worker
/// behind "Read Again", inside the capture kit) is stopped through the stop
/// its owner registers for as long as it runs.
public final class ChildProcesses: Sendable {
    public static let shared = ChildProcesses()

    private let pids = OSAllocatedUnfairLock(initialState: Set<pid_t>())
    private let stops = OSAllocatedUnfairLock(initialState: [UUID: @Sendable () -> Void]())

    public init() {}

    /// Have `terminateAll` call `stop`, which must end the work's process at
    /// once, from any thread. Pass the key to `unregister` when the work ends.
    public func register(stop: @escaping @Sendable () -> Void) -> UUID {
        let key = UUID()
        stops.withLock { $0[key] = stop }
        return key
    }

    public func unregister(_ key: UUID) {
        stops.withLock { _ = $0.removeValue(forKey: key) }
    }

    /// Start `process` and list it until it exits.
    public func run(_ process: Process) throws {
        let earlier = process.terminationHandler
        process.terminationHandler = { [pids] finished in
            let pid = finished.processIdentifier
            pids.withLock { _ = $0.remove(pid) }
            earlier?(finished)
        }
        try process.run()
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        pids.withLock { _ = $0.insert(pid) }
        // A child can exit, and be reaped, before it is listed.
        if !process.isRunning {
            pids.withLock { _ = $0.remove(pid) }
        }
    }

    /// The children running now.
    public var running: Set<pid_t> {
        pids.withLock { $0 }
    }

    /// Stop every child now: each registered stop, then SIGTERM, then SIGKILL
    /// for any still running after `grace`. Synchronous, for
    /// `applicationWillTerminate` and the termination signal, where nothing
    /// waits for a task.
    public func terminateAll(grace: TimeInterval = 0.5) {
        for stop in stops.withLock({ Array($0.values) }) {
            stop()
        }
        let targets = running
        guard !targets.isEmpty else { return }
        for pid in targets where pid > 0 {
            _ = kill(pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, !running.isDisjoint(with: targets) {
            usleep(10_000)
        }
        for pid in running.intersection(targets) where pid > 0 {
            _ = kill(pid, SIGKILL)
        }
    }
}

/// Ends the window with the app that opened it (RULINGS G7a): a process
/// source on the parent's pid, and the termination signal (SIGTERM, which the
/// app sends when a quit request is not answered). `onEnd` runs once.
public final class ProcessLifetime: @unchecked Sendable {
    public enum Reason: Equatable, Sendable {
        case parentExited
        case signal(Int32)
    }

    private let sources: [any DispatchSourceProtocol]
    private let signals: [Int32]

    /// Watch `parent` and `signals`. Each signal is ignored by default from
    /// now on and handled by `onEnd` instead, which must then end the process.
    ///
    /// A parent of 1 is launchd. Either the window was opened by hand (Finder,
    /// `open`) and nothing is watched, or the app that opened it exited before
    /// this ran and launchd took the window in. The app always passes the
    /// memory's path (`MCI_DB_PATH`), so with that path the window ends at once.
    public init(
        parent: pid_t = getppid(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        signals: [Int32] = [SIGTERM],
        queue: DispatchQueue = .main,
        onEnd: @escaping @Sendable (Reason) -> Void
    ) {
        let fired = OSAllocatedUnfairLock(initialState: false)
        let once: @Sendable (Reason) -> Void = { reason in
            let first = fired.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            if first { onEnd(reason) }
        }
        var sources: [any DispatchSourceProtocol] = []
        for number in signals {
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { once(.signal(number)) }
            source.resume()
            sources.append(source)
        }
        if parent > 1 {
            let watchesOwnParent = parent == getppid()
            let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: queue)
            source.setEventHandler { once(.parentExited) }
            source.resume()
            sources.append(source)
            // The parent can be gone before the source was armed.
            let gone = (kill(parent, 0) == -1 && errno == ESRCH) || (watchesOwnParent && getppid() != parent)
            if gone {
                queue.async { once(.parentExited) }
            }
        } else if ProcessLifetime.openedByTheApp(environment) {
            queue.async { once(.parentExited) }
        }
        self.sources = sources
        self.signals = signals
    }

    /// The menu-bar app starts the window with the memory's path; a window
    /// opened by hand has none.
    static func openedByTheApp(_ environment: [String: String]) -> Bool {
        !(environment["MCI_DB_PATH"] ?? "").isEmpty
    }

    /// Stop watching, and give the signals their default action back.
    public func cancel() {
        for source in sources {
            source.cancel()
        }
        for number in signals {
            Darwin.signal(number, SIG_DFL)
        }
    }
}
