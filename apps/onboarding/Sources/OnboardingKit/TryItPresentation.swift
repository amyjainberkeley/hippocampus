// SPDX-License-Identifier: TBD-private
//
// What Try it shows for each card. The screen draws this and decides
// nothing itself, so the tests and the preview renderer see what a person
// sees.
//
// Only a proof carries the lines under it: what to try now (a question
// when answers work on this Mac, a word from that window when they do
// not), "Open it for me", where macOS's recording icon is and what Stop
// Sharing does, and at most one line about Apple Intelligence.

import Foundation

/// The app's routes Try it opens (contract section 3b).
public enum AppLink {
    /// Shows Ask: "Open it for me".
    public static let ask = URL(string: "hippocampus://ask")!
    /// Restarts remembering in place: "Try Again" on a stalled card.
    public static let restart = URL(string: "hippocampus://restart")!
}

public struct TryItPresentation: Equatable, Sendable {
    /// A card's one button.
    public enum Action: Equatable, Sendable {
        /// "Try Again": the app restarts remembering in place.
        case tryAgain
        /// "Add Extension": the browser extension panel.
        case addExtension
        /// "Open System Settings", at the permission that is off.
        case openSettings(PermissionSurface)
    }

    /// The card's sentence when it holds no proof.
    public let message: String?
    /// What was read, when something was.
    public let proof: ReadProof?
    public let action: Action?
    /// "Turning on…": the card shows it is working.
    public let isWorking: Bool
    /// Ask opened: the screen's last line.
    public let finished: String?
    /// Under a proof: what to try now. Nil when no key opens Ask now.
    public let next: String?
    /// Under a proof: the key that opens Ask now, one keycap per entry.
    public let keycaps: [String]
    /// Under a proof: "Open it for me".
    public let offersOpenItForMe: Bool
    /// Under a proof: macOS's recording icon and Stop Sharing.
    public let stopSharingNote: String?
    /// Under a proof, when answers do not work: why, in one line.
    public let answersNote: String?

    public init(card: TryItViewModel.Card, keyNow: AskKeyNow, understanding: UnderstandingAvailability?) {
        var message: String?
        var proof: ReadProof?
        var action: Action?
        var finished: String?
        switch card {
        case .starting:
            message = OnboardingCopy.tryItStarting
        case .waiting(let note):
            message = OnboardingCopy.waitingText(note)
            action = Self.action(for: note)
        case .stalled(let cause):
            message = OnboardingCopy.stalledText(cause)
            switch cause {
            case .unknown: action = .tryAgain
            case .permissionOff(let surface): action = .openSettings(surface)
            case .frontApp(let note): action = Self.action(for: note)
            }
        case .proof(let shown):
            proof = shown
        case .notRemembering(let state):
            message = state == .paused ? OnboardingCopy.tryItPaused : OnboardingCopy.tryItOff
        case .finished(let openedForThem):
            finished = OnboardingCopy.tryItFinished(keyNow, openedForThem: openedForThem)
        }
        self.message = message
        self.proof = proof
        self.action = action
        self.isWorking = card == .starting
        self.finished = finished
        let underProof = proof != nil
        self.next = underProof
            ? OnboardingCopy.tryItNext(keyNow, answersAvailable: understanding == .available) : nil
        self.keycaps = underProof && keyNow.phrase != nil ? keyNow.keycaps : []
        self.offersOpenItForMe = underProof
        self.stopSharingNote = underProof ? OnboardingCopy.stopSharingNote : nil
        self.answersNote = underProof ? Self.answersNote(understanding) : nil
    }

    /// The message as drawn: its first sentence as the heading, the rest
    /// under it. Nothing is dropped; a one-sentence message has no rest.
    public var messageParts: (heading: String, detail: String?)? {
        guard let message else { return nil }
        guard let stop = message.range(of: ". ") else { return (message, nil) }
        let heading = String(message[..<stop.lowerBound]) + "."
        let detail = message[stop.upperBound...].trimmingCharacters(in: .whitespaces)
        return (heading, detail.isEmpty ? nil : detail)
    }

    private static func action(for note: FrontAppNote) -> Action? {
        if case .needsExtension = note { return .addExtension }
        return nil
    }

    /// One line, only when the check has answered and answers do not work.
    static func answersNote(_ understanding: UnderstandingAvailability?) -> String? {
        switch understanding {
        case nil, .available: nil
        case .turnedOff: OnboardingCopy.answersNeedAppleIntelligence
        case .preparing: OnboardingCopy.appleIntelligencePreparing
        case .unsupported: OnboardingCopy.answersUnsupported
        }
    }
}
