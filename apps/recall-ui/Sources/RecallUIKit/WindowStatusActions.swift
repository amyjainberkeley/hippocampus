import Foundation

/// What each of the status's controls asks of the app (SPEC 2.6.4): the
/// banner's button, the status menu's action and ⌘K's. Every change to
/// remembering goes over the private pipe as the one op the app carries out
/// for that click; the app decides whether it may.
public enum WindowStatusActions {
    /// What a control does.
    public enum Effect: Equatable, Sendable {
        /// Asks the app over the pipe.
        case send(WindowChannelProtocol.Op, permission: String? = nil)
        /// Opens setup where it stopped.
        case finishSetup
        /// Opens Hippocampus (a window opened by hand).
        case openHippocampus
    }

    /// The op for `action`. Turn Off is its own op, never a pause: while a
    /// turn-on is under way the app offers Turn Off, not Pause. Leave Demo
    /// Memory is its own too, never Resume: the app goes back to the
    /// person's own memory with remembering as it was before, a pause they
    /// made included, as the menu bar's Leave does.
    public static func effect(of action: WindowStatus.Action) -> Effect {
        switch action {
        case .pause: .send(.pause)
        case .resume, .resumeNow: .send(.resume)
        case .turnOn: .send(.turnOn)
        case .turnOff: .send(.turnOff)
        case let .openSystemSettings(permission): .send(.openSystemSettings, permission: permission.rawValue)
        case .tryAgain: .send(.tryAgain)
        case .quit: .send(.quit)
        case .finishSetup: .finishSetup
        case .openHippocampus: .openHippocampus
        case .leaveDemoMemory: .send(.leaveDemo)
        }
    }

    /// ⌘K's one status command: the action the status offers now (in Demo
    /// Memory, Leave Demo Memory), only when the window can ask the app for
    /// it. None in a window opened by hand, which has no pipe, and none while
    /// a forget holds remembering, which offers nothing.
    public static func command(for status: WindowStatus, hasPipe: Bool) -> WindowStatus.Action? {
        guard hasPipe, status.hasControls, let action = status.action else { return nil }
        switch effect(of: action) {
        case .send: return action
        case .finishSetup: return action
        case .openHippocampus: return nil
        }
    }
}
