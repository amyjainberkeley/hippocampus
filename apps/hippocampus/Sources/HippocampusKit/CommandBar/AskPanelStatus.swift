// SPDX-License-Identifier: TBD-private
//
// AskPanelStatus.swift — what Ask's footer says about remembering, and the
// one button that goes with it (spec-shell S1, product critique 11), so an
// answer about "now" is never silently stale. A button is offered only in a
// state where it acts, and before setup none of them turns remembering on:
// Start Remembering in onboarding is the only consent (product critique 4).

import Foundation

public struct AskPanelStatus: Equatable, Sendable {
    /// The footer's button.
    public enum Action: Equatable, Sendable {
        case resume
        case turnOn
        case openSystemSettings(TCCRevokedReason)
        case tryAgain
        case finishSetup

        public var title: String {
            switch self {
            case .resume: "Resume"
            case .turnOn: "Turn On"
            case .openSystemSettings: "Open System Settings…"
            case .tryAgain: "Try Again"
            case .finishSetup: "Finish Setup…"
            }
        }
    }

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
    /// Nothing is read while paused, off, waiting for a permission, stopped
    /// or before setup, so "this" cannot mean the window in front. Otherwise
    /// a saved read of the window decides.
    public let readsThisWindow: Bool
    /// Remembering as it should: the footer can say something else.
    public let isRemembering: Bool

    public init(_ status: MenuBarStatus, setup: Setup = .complete) {
        let row = setup == .complete
            ? Self.row(for: status)
            : (text: "Not set up yet", action: setup == .notFinished ? .finishSetup : nil, reads: false)
        text = row.text
        action = row.action
        readsThisWindow = row.reads
        mark = status.markState
        isRemembering = setup == .complete && (status == .recording || status == .unchanged)
    }

    private static func row(for status: MenuBarStatus) -> (text: String, action: Action?, reads: Bool) {
        switch status {
        case .recording, .unchanged: ("On this Mac", nil, true)
        case .starting: ("Starting…", nil, true)
        case .noMemory: ("Nothing saved yet", nil, true)
        case .paused: ("Paused", .resume, false)
        case .idle: ("Off", .turnOn, false)
        case .needsPermission(let permission): ("Needs permission", .openSystemSettings(permission), false)
        // Remembering stopped, so a start tries again.
        case .error: ("Not saving", .tryAgain, false)
        // Remembering is running, where a start does nothing, so no button
        // until the supervisor can restart a running run (spec-shell S2,
        // `retryNow()`). Other windows may still be read; a saved read of
        // this one decides.
        case .blocked, .stale: ("Not saving", nil, true)
        }
    }
}

extension ProcessSupervisor {
    /// What Ask's footer shows now.
    public func askPanelStatus(setupFinished: Bool = OnboardingSentinel.isComplete) -> AskPanelStatus {
        AskPanelStatus(menuBarStatus, setup: AskPanelStatus.Setup(
            sentinelPresent: setupFinished, hasOnboarding: hasOnboarding, onboardingOpen: onboardingIsRunning
        ))
    }

    /// The footer's button, doing what the menu's status action does
    /// (spec-shell S2, Actions). `AskPanelStatus` offers each one only in a
    /// state where it acts. Before setup only Finish Setup… acts, whatever
    /// asks: turning remembering on is onboarding's to do.
    public func performAskStatusAction(
        _ action: AskPanelStatus.Action,
        setupFinished: Bool = OnboardingSentinel.isComplete,
        pauses: UserPauseController = .shared,
        openURL: (URL) -> Void
    ) {
        if !setupFinished, hasOnboarding, action != .finishSetup { return }
        switch action {
        case .resume:
            pauses.setPaused(false)
            setPaused(false)
        case .turnOn:
            pauses.setPaused(false)
            setPaused(false)
            if captureEnabled {
                start()
            } else {
                Task { [weak self] in try? await self?.applyCaptureEnabled(true) }
            }
        case .openSystemSettings(let permission):
            if let url = URL(string: permission.settingsPaneURLString) { openURL(url) }
        case .tryAgain:
            start()
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
