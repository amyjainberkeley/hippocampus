// SPDX-License-Identifier: Apache-2.0
//
// HelperExit — what must happen before the capture process ends by itself,
// and the deadline that ends it once its parent is gone.

import Darwin
import Foundation

/// Work that must not outlive the capture process.
///
/// `main.swift` registers stopping the OCR worker here. Stop Sharing, a lost
/// stream and an orphaned drain end the process without unwinding, and the
/// worker, a child of this process, would otherwise run on until it finished
/// its current frame or its model load. The registered work runs at most once,
/// from whichever thread gets here first; a caller on another thread returns
/// only after it has finished, and a call from inside the work returns at once.
/// The work must be quick and must never wait on the capture path.
public enum HelperExit {
    private final class Registry: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var work: [@Sendable () -> Void] = []
        var ran = false
    }

    private static let registry = Registry()

    /// Adds work to run before the process ends.
    public static func registerBeforeExit(_ work: @escaping @Sendable () -> Void) {
        registry.lock.withLock { registry.work.append(work) }
    }

    /// Runs the registered work once. Safe from any thread.
    public static func runBeforeExit() {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        guard !registry.ran else { return }
        registry.ran = true
        for work in registry.work { work() }
    }

    /// Test seam: forgets the registered work and whether it ran.
    internal static func resetForTesting() {
        registry.lock.withLock {
            registry.work = []
            registry.ran = false
        }
    }
}

/// Ends the capture process once its parent is gone, drained or not.
///
/// When lease input ends, the helper drains: it stops its streams and waits
/// for OCR in flight, up to 30 seconds a frame. A live parent bounds that
/// itself, with SIGTERM a second after it closes the lease. A parent that
/// crashed or was force quit cannot, and a stream that never finishes stopping
/// would keep this process, and the screen-recording indicator, alive.
///
/// So once lease input ends, a watcher checks every 100 ms whether the parent
/// is gone (`getppid() == 1`; the kernel closes a dead parent's pipes a moment
/// before it hands its children to launchd, so one check at end of input can
/// miss it). When it is gone, the registered before-exit work runs first, which
/// stops the OCR worker so the drain no longer waits on it, and the process
/// ends with status 85 ten seconds later. A live parent is never raced: the
/// watcher does nothing while the parent lives.
public final class ParentGoneDeadline: @unchecked Sendable {
    public static let exitStatus: Int32 = 85
    public static let seconds: TimeInterval = 10
    static let pollInterval: TimeInterval = 0.1

    private let seconds: TimeInterval
    private let pollInterval: TimeInterval
    private let parentIsGone: @Sendable () -> Bool
    private let beforeExit: @Sendable () -> Void
    private let exitProcess: @Sendable (Int32) -> Void
    private let lock = NSLock()
    private var armed = false

    public convenience init() {
        self.init(
            seconds: Self.seconds,
            pollInterval: Self.pollInterval,
            parentIsGone: { getppid() == 1 },
            beforeExit: { HelperExit.runBeforeExit() },
            exitProcess: { status in
                FileHandle.standardError.write(Data(
                    "mci-capture-helper: helper_health capture_stopped=deadline\n".utf8
                ))
                _exit(status)
            }
        )
    }

    /// Test seam: production uses the convenience initializer.
    init(
        seconds: TimeInterval,
        pollInterval: TimeInterval,
        parentIsGone: @escaping @Sendable () -> Bool,
        beforeExit: @escaping @Sendable () -> Void,
        exitProcess: @escaping @Sendable (Int32) -> Void
    ) {
        self.seconds = seconds
        self.pollInterval = pollInterval
        self.parentIsGone = parentIsGone
        self.beforeExit = beforeExit
        self.exitProcess = exitProcess
    }

    /// Starts the watcher and returns at once. Later calls do nothing.
    public func arm() {
        let first: Bool = lock.withLock {
            defer { armed = true }
            return !armed
        }
        guard first else { return }
        // A thread of its own, so a busy dispatch pool cannot delay it.
        let watcher = Thread { [self] in self.watch() }
        watcher.name = "mci-capture-helper.parent-gone-deadline"
        watcher.start()
    }

    private func watch() {
        while !parentIsGone() {
            Thread.sleep(forTimeInterval: pollInterval)
        }
        beforeExit()
        Thread.sleep(forTimeInterval: seconds)
        exitProcess(Self.exitStatus)
    }
}
