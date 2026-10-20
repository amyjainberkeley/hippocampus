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
}
