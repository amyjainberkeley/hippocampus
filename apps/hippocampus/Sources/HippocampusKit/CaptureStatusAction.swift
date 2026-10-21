// SPDX-License-Identifier: Apache-2.0
//
// CaptureStatusAction.swift — the status row's one button and its words, the
// same in the menu, Ask's footer and Preferences. Display copy: the launch
// copy check reads this file (scripts/check-launch-copy.sh).

/// The one button that goes with a status, the same in the menu, Ask's
/// footer and Preferences (spec-shell S2, product critique 11).
public enum CaptureStatusAction: Equatable, Sendable {
    case pause
    /// Ends a pause. Its words are setup's own for turning remembering on,
    /// Start Remembering (launch playbook, decision 5): Resume is Working
    /// On's, and reopens a project.
    case resume
    case turnOn
    /// A turn-on under way, turned off before it lands: the newer word wins.
    case turnOff
    case openSystemSettings(TCCRevokedReason)
    /// Restart remembering now (`ProcessSupervisor.retryNow()`).
    case tryAgain
    /// After a failed stop, quitting is the one sure way to stop.
    case quit
    /// Before setup, the only way on is onboarding's Start Remembering.
    case finishSetup

    public var title: String {
        switch self {
        case .pause: return "Pause"
        case .resume: return "Start Remembering"
        case .turnOn: return "Turn On"
        case .turnOff: return "Turn Off"
        case .openSystemSettings: return "Open System Settings…"
        case .tryAgain: return "Try Again"
        case .quit: return "Quit Hippocampus"
        case .finishSetup: return "Finish Setup…"
        }
    }
}
