// SPDX-License-Identifier: TBD-private
//
// Onboarding exits with the app that started it. If the app crashes or is
// force-quit, a window left behind would hold a memory reader open and
// offer buttons that no longer reach anything (RULINGS O9).

import Foundation
import Darwin

public final class ParentProcessWatch: @unchecked Sendable {
    private let source: DispatchSourceProcess

    /// Call `onExit` once, on `queue`, when process `pid` exits. Nil when
    /// there is no parent to watch: pid 1 or lower means launchd started
    /// this process (or adopted it, its parent already gone).
    public init?(
        pid: pid_t = getppid(),
        queue: DispatchQueue = .main,
        onExit: @escaping @Sendable () -> Void
    ) {
        guard pid > 1 else { return nil }
        let fired = FiredOnce()
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler {
            if fired.claim() { onExit() }
        }
        source.resume()
        // A process that exited before the source was armed raises no event.
        if kill(pid, 0) != 0, errno == ESRCH {
            queue.async {
                if fired.claim() { onExit() }
            }
        }
    }

    public func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}

private final class FiredOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func claim() -> Bool {
        lock.withLock {
            defer { fired = true }
            return !fired
        }
    }
}
