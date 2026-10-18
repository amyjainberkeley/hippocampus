import Foundation

/// Coalesces requests to show the window. The window reads memory itself, so
/// once there is memory it can read (`memoryReady`) it opens at once, in any
/// state of remembering: running, paused, stopped, starting, or after a start
/// that failed. Opening Hippocampus never does nothing (Oct 18).
///
/// Before then (a first run whose database the agent has not made yet, or a
/// launch whose key is not checked yet) a request waits, and opens once
/// remembering is running, paused or stopped (spec-shell S5, D9). A start
/// that failed before there was memory to read ends the request, so the app
/// can show where the fix is instead.
public struct RecallPresentationGate {
    private var initialLaunchRequested = false
    private var pending = false

    public init() {}

    public mutating func request(initialLaunch: Bool, state: SupervisorState, memoryReady: Bool = false) -> Bool {
        if initialLaunch {
            guard !initialLaunchRequested else { return false }
            initialLaunchRequested = true
        }
        pending = true
        return consumeIfReady(state: state, memoryReady: memoryReady)
    }

    public mutating func consumeIfReady(state: SupervisorState, memoryReady: Bool = false) -> Bool {
        guard pending, memoryReady || state == .running || state == .paused || state == .stopped else { return false }
        pending = false
        return true
    }

    /// True once for a pending request that a failed start ended before there
    /// was memory to show.
    public mutating func consumeIfBlocked(state: SupervisorState, memoryReady: Bool = false) -> Bool {
        guard pending, !memoryReady, case .crashed = state else { return false }
        pending = false
        return true
    }
}
