// SPDX-License-Identifier: Apache-2.0
//
// AskPanelStatus.swift — what Ask's footer says about remembering, and the
// one button that goes with it (spec-shell S1, product critique 11). It is the
// status row the menu and Preferences show (`StatusRow`), so the three never
// disagree; only "Remembering" reads "On this Mac" here, and Pause is left to
// the menu. Before setup no button turns remembering on: Start Remembering in
// onboarding is the only consent (product critique 4).

import Foundation

public struct AskPanelStatus: Equatable, Sendable {
    /// The footer's button: the status row's own.
    public typealias Action = CaptureStatusAction

    /// Where setup stands.
    public enum Setup: Equatable, Sendable {
        case complete
        /// Onboarding is open, so there is nothing to offer: it is on screen.
        case inProgress
        /// Onboarding closed before Start Remembering.
        case notFinished

        /// A build without the onboarding binary has no setup to finish.
        public init(sentinelPresent: Bool, hasOnboarding: Bool, onboardingOpen: Bool) {
            if sentinelPresent || !hasOnboarding {
                self = .complete
            } else {
                self = onboardingOpen ? .inProgress : .notFinished
            }
        }
    }

    public let text: String
    public let action: Action?
    /// The picture the menu bar shows, so Ask's mark matches it.
    public let mark: HiMark.State
    /// Nothing is read while paused, off, waiting for a permission, stopped,
    /// skipping or before setup, so "this" cannot mean the window in front.
    /// Otherwise a saved read of the window decides.
    public let readsThisWindow: Bool
    /// Remembering as it should: the footer can say something else.
    public let isRemembering: Bool

    public init(_ status: MenuBarStatus, setup: Setup = .complete) {
        self.init(status, row: StatusRow(StatusFacts(status: status, setup: setup), now: Date()), setup: setup)
    }

    public init(_ status: MenuBarStatus, row: StatusRow, setup: Setup) {
        let remembering = setup == .complete && status.isRemembering
        text = remembering ? "On this Mac" : row.title
        action = row.action == .pause ? nil : row.action
        readsThisWindow = setup == .complete && Self.mayReadThisWindow(status)
        mark = status.markState
        isRemembering = remembering
    }

    private static func mayReadThisWindow(_ status: MenuBarStatus) -> Bool {
        switch status {
        case .recording, .unchanged, .starting, .noMemory: return true
        // Remembering is running and may be reading other windows; a saved
        // read of this one decides.
        case .blocked, .stale: return true
        case .skipping, .paused, .idle, .needsPermission, .error, .stopFailed, .turnOnFailed: return false
        }
    }
}

extension ProcessSupervisor {
    /// Where setup stands, from the setup-complete file and onboarding.
    public func setup(finished: Bool) -> AskPanelStatus.Setup {
        AskPanelStatus.Setup(sentinelPresent: finished, hasOnboarding: hasOnboarding, onboardingOpen: onboardingIsRunning)
    }

    /// The one status row: the menu, Ask's footer and Preferences.
    public func statusRow(setupFinished: Bool = OnboardingSentinel.isComplete, now: Date = Date()) -> StatusRow {
        StatusRow(StatusFacts(
            status: menuBarStatus, setup: setup(finished: setupFinished),
            lastSavedAt: captureReceipt?.lastStoredFrameAt,
            pausedSince: pausedSince, stoppedSharingAt: stoppedSharingAt,
            turningOn: turningOn
        ), now: now)
    }

    /// What Ask's footer shows now.
    public func askPanelStatus(setupFinished: Bool = OnboardingSentinel.isComplete) -> AskPanelStatus {
        AskPanelStatus(menuBarStatus, row: statusRow(setupFinished: setupFinished), setup: setup(finished: setupFinished))
    }

    /// The status row's button, wherever it is pressed: the menu, Ask's
    /// footer or Preferences (spec-shell S2, Actions). Each is offered only
    /// in a state where it acts. Before setup only Finish Setup… acts,
    /// whatever asks: turning remembering on is onboarding's to do. Quit
    /// belongs to the app, which handles it before calling this.
    public func performAskStatusAction(
        _ action: AskPanelStatus.Action,
        setupFinished: Bool = OnboardingSentinel.isComplete,
        openURL: (URL) -> Void
    ) {
        if !setupFinished, hasOnboarding, action != .finishSetup { return }
        switch action {
        case .pause:
            setPaused(true)
        case .resume:
            setPaused(false)
        case .turnOn:
            // Turning remembering on also ends a pause (spec-shell S5). It
            // never fails silently: the status says why it didn't take.
            turnOn()
        case .openSystemSettings(let permission):
            // Coming back may mean it is allowed now: the next look tries
            // again, once (`retryIfPermissionMayBeBack`).
            notePermissionFixChosen()
            if let url = URL(string: permission.settingsPaneURLString) { openURL(url) }
        case .tryAgain:
            // Try Again tries what failed: a turn-on that didn't take, or
            // the run.
            if !captureEnabled, turnOnFailure != nil {
                turnOn()
            } else {
                retryNow()
            }
        case .quit:
            break
        case .finishSetup:
            _ = openOnboarding()
        }
    }
}

/// Tells onboarding's Try it screen that Ask opened (RULINGS X1). A
/// distributed notification reaches every process of this user, so it is
/// posted only while onboarding runs.
public enum AskPanelNotice {
    public static let didShow = Notification.Name("ai.hippocampus.ask.didShow")

    public static func announceShown(onboardingRunning: Bool, post: (Notification.Name) -> Void) {
        guard onboardingRunning else { return }
        post(didShow)
    }
}
