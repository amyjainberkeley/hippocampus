// SPDX-License-Identifier: Apache-2.0

/// What opening Hippocampus shows (spec-shell S7). Opening it never does
/// nothing (Oct 18): while setup is unfinished, setup comes up; once it is
/// done, the person's own launch and every reopen show the window, in any
/// state of remembering, and the window lets them turn remembering on. A
/// login, a quiet relaunch, a link or a Preferences request at launch keeps
/// Hippocampus in the menu bar (07fedaf).
public enum AppOpening: Equatable, Sendable {
    /// Stay in the menu bar.
    case nothing
    /// Setup, which is unfinished.
    case setup
    /// The window, on Overview.
    case window

    /// At launch. `hasSetup` is false for a build without the setup program,
    /// which starts as if setup were done.
    public static func atLaunch(_ reason: LaunchReason, setupFinished: Bool, hasSetup: Bool) -> AppOpening {
        if !setupFinished && hasSetup { return .setup }
        return reason.opensWindow ? .window : .nothing
    }

    /// Opening Hippocampus again while it runs, which only the person does.
    /// (A copy leaving for Applications answers nothing before asking.)
    public static func atReopen(setupFinished: Bool, hasSetup: Bool) -> AppOpening {
        if !setupFinished && hasSetup { return .setup }
        return .window
    }
}
