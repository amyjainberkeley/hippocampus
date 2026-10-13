// SPDX-License-Identifier: TBD-private
//
// AskPanelStatus.swift — what Ask's footer says about remembering, and the
// one button that goes with it (spec-shell S1, product critique 11), so an
// answer about "now" is never silently stale.

import Foundation

public struct AskPanelStatus: Equatable, Sendable {
    /// The footer's button.
    public enum Action: Equatable, Sendable {
        case resume
        case turnOn
        case openSystemSettings(TCCRevokedReason)
        case tryAgain

        public var title: String {
            switch self {
            case .resume: "Resume"
            case .turnOn: "Turn On"
            case .openSystemSettings: "Open System Settings…"
            case .tryAgain: "Try Again"
            }
        }
    }

    public let text: String
    public let action: Action?
    /// The picture the menu bar shows, so Ask's mark matches it.
    public let mark: HiMark.State
    /// Nothing is read while paused, off, waiting for a permission or
    /// stopped, so "this" cannot mean the window in front. Otherwise a saved
    /// read of the window decides.
    public let readsThisWindow: Bool
    /// Remembering as it should: the footer can say something else.
    public let isRemembering: Bool

    public init(_ status: MenuBarStatus) {
        let row = Self.row(for: status)
        text = row.text
        action = row.action
        readsThisWindow = row.reads
        mark = status.markState
        isRemembering = status == .recording || status == .unchanged
    }

    private static func row(for status: MenuBarStatus) -> (text: String, action: Action?, reads: Bool) {
        switch status {
        case .recording, .unchanged: ("On this Mac", nil, true)
        case .starting: ("Starting…", nil, true)
        case .noMemory: ("Nothing saved yet", nil, true)
        case .paused: ("Paused", .resume, false)
        case .idle: ("Off", .turnOn, false)
        case .needsPermission(let permission): ("Needs permission", .openSystemSettings(permission), false)
        case .error: ("Not saving", .tryAgain, false)
        // Other windows may still be read; a saved read of this one decides.
        case .blocked, .stale: ("Not saving", .tryAgain, true)
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
