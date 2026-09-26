import Foundation

/// Coalesces launch requests while key custody and topology become ready.
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
        guard pending, state == .running || state == .paused else { return false }
        pending = false
        return true
    }
}
