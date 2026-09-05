import AppKit
import ApplicationServices
import Foundation
import os

/// Reads focus from Accessibility on every call. NSWorkspace's frontmost cache
/// can remain stale when a command-line helper reads it on background queues.
public struct AXFocusedApplicationSource: FrontmostPidSource, FrontmostAppSource {
    private let focusedPID: @Sendable () -> pid_t?
    private let bundleID: @Sendable (pid_t) -> String?
    private static let query = BoundedFocusedPIDQuery(perform: readFocusedPID)

    public init() {
        self.init(
            focusedPID: { Self.query.read() },
            bundleID: { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        )
    }

    internal init(focusedPID: @escaping @Sendable () -> pid_t?,
                  bundleID: @escaping @Sendable (pid_t) -> String?) {
        self.focusedPID = focusedPID
        self.bundleID = bundleID
    }

    public func frontmostPidAndBundle() -> (pid_t, String)? {
        guard let pid = focusedPID(), pid > 0,
              let bundle = bundleID(pid),
              !bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              focusedPID() == pid
        else { return nil }
        return (pid, bundle)
    }

    public func currentBundleId() -> String? {
        frontmostPidAndBundle()?.1
    }

    private static func readFocusedPID() -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString,
                                           &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let application = value as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(application, &pid) == .success, pid > 0 else { return nil }
        return pid
    }
}

/// At most one AX request exists even if the OS fails to return. Late answers
/// are discarded; later callers fail closed instead of accumulating requests.
internal final class BoundedFocusedPIDQuery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mci.context.focused-application", qos: .userInitiated)
    private let occupied = OSAllocatedUnfairLock(initialState: false)
    private let perform: @Sendable () -> pid_t?

    init(perform: @escaping @Sendable () -> pid_t?) {
        self.perform = perform
    }

    func read(timeoutMs: Int = 50) -> pid_t? {
        guard occupied.withLock({ busy in
            guard !busy else { return false }
            busy = true
            return true
        }) else { return nil }

        let result = OSAllocatedUnfairLock<pid_t?>(initialState: nil)
        let completion = DispatchSemaphore(value: 0)
        queue.async { [self] in
            let pid = perform()
            result.withLock { $0 = pid }
            occupied.withLock { $0 = false }
            completion.signal()
        }
        guard completion.wait(timeout: .now() + .milliseconds(max(1, timeoutMs))) == .success
        else { return nil }
        return result.withLock { $0 }
    }
}
