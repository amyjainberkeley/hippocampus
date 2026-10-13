import Foundation

/// Coalesces requests to show the window while key custody and topology
/// become ready. Running, paused and stopped are all ready: opening the app
/// shows the window even when remembering is off (spec-shell S5, D9). A
/// failed start is not; the request ends there, so the app can show where
/// the fix is instead.
public struct RecallPresentationGate {
    private var initialLaunchRequested = false
    private var pending = false

    public init() {}

    public mutating func request(initialLaunch: Bool, state: SupervisorState) -> Bool {
        if initialLaunch {
            guard !initialLaunchRequested else { return false }
            initialLaunchRequested = true
        }
        pending = true
        return consumeIfReady(state: state)
    }

    public mutating func consumeIfReady(state: SupervisorState) -> Bool {
        guard pending, state == .running || state == .paused || state == .stopped else { return false }
        pending = false
        return true
    }

    /// True once for a pending request that a failed start ended.
    public mutating func consumeIfBlocked(state: SupervisorState) -> Bool {
        guard pending, case .crashed = state else { return false }
        pending = false
        return true
    }
}
