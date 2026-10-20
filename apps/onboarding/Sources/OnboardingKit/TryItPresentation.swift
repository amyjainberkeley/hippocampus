// SPDX-License-Identifier: Apache-2.0
//
// What Try it shows for each card. The screen draws this and decides
// nothing itself, so the tests and the preview renderer see what a person
// sees.
//
// Once something was read, the screen's title says where from ("Here’s what
// I just read from Safari") and the card shows it. Only a proof carries the lines
// under it: what to try now (a question when answers work on this Mac, a
// word from that window when they do not), "Open it for me", where macOS's
// recording icon is and what Stop Sharing does, and at most one line about
// what answers need.

import Foundation

/// The app's routes Try it opens (contract section 3b).
public enum AppLink {
    /// Shows Ask: "Open it for me".
    public static let ask = URL(string: "hippocampus://ask")!
    /// Restarts remembering in place: "Try Again" on a stalled card.
    public static let restart = URL(string: "hippocampus://restart")!
}

/// Asks the app to read the window in front once, now, past the reader's
/// rest, as opening Ask does (`ProcessSupervisor.requestFreshRead`). Try it
/// posts it when the person brings a window forward. The app acts on it only
/// while setup is open, after consent and while remembering, and the read
/// follows the rules every read does: a never-read app, an excluded app, a
/// private window or a password field is skipped. It carries nothing.
public enum SetupReadRequest {
    public static let notification = Notification.Name("ai.hippocampus.setup.readFrontWindow")
    /// The helper notices a newly focused window within a fifth of a
    /// second; the request waits for it, so it names that window.
    public static let delay: Duration = .milliseconds(500)

    @MainActor public static func post() {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            DistributedNotificationCenter.default().postNotificationName(
                notification, object: nil, userInfo: nil, deliverImmediately: true
            )
        }
    }
}

public struct TryItPresentation: Equatable, Sendable {
    /// A card's one button.
    public enum Action: Equatable, Sendable {
        /// "Try Again": the app restarts remembering in place.
        case tryAgain
        /// "Open System Settings", at the permission that is off.
        case openSettings(PermissionSurface)
    }

    /// What stands beside a status: the app it is about, or a symbol.
    public enum Icon: Equatable, Sendable {
        /// The app's own icon, crossed out when the window is skipped.
        case app(bundleId: String, skipped: Bool)
        /// An SF Symbol.
        case symbol(String)
    }

    /// The screen's title: "Try it", or where the proof was read.
    public let title: String
    /// The status card's first line when it holds no proof.
    public let heading: String?
    /// The status card's second line: the window's title, or what to do.
    public let detail: String?
    public let icon: Icon?
    /// What was read, when something was.
    public let proof: ReadProof?
    public let action: Action?
    /// Reading, or turning on: the card shows it is working.
    public let isWorking: Bool
    /// Ask opened: the screen's last line.
    public let finished: String?
    /// Under a proof: what to try now. Nil when no key opens Ask now.
    public let next: String?
    /// Under a proof: the key that opens Ask now, one keycap per entry.
    public let keycaps: [String]
    /// How many times those keycaps press, now and then, to show the key:
    /// twice for Shift twice, once for any other, none with no keycaps.
    public let keyPresses: Int
    /// Under a proof: "Open it for me".
    public let offersOpenItForMe: Bool
    /// Under a proof: macOS's recording icon and Stop Sharing.
    public let stopSharingNote: String?
    /// Under a proof, when answers do not work: why, in one line.
    public let answersNote: String?
    /// Under a status while it waits for a first read: Low Power Mode makes
    /// reading slower (SPEC 7.7).
    public let lowPowerNote: String?

    /// - Parameter macOSMajorVersion: picks the line for a Mac with no
    ///   model: macOS 26 can turn Apple Intelligence on.
    public init(
        card: TryItViewModel.Card,
        keyNow: AskKeyNow,
        understanding: UnderstandingAvailability?,
        lowPowerMode: Bool = false,
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) {
        var title = OnboardingCopy.tryItTitle
        var heading: String?
        var detail: String?
        var icon: Icon?
        var proof: ReadProof?
        var action: Action?
        var working = false
        var finished: String?
        switch card {
        case .starting:
            heading = OnboardingCopy.tryItStarting
            working = true
        case .reading(let window):
            heading = OnboardingCopy.tryItReading(window.appName)
            detail = window.title
            icon = .app(bundleId: window.bundleId, skipped: false)
            working = true
        case .noWindow:
            heading = OnboardingCopy.tryItNoWindow
            detail = OnboardingCopy.tryItOpenSomething
            icon = .symbol("macwindow")
        case .nothingToShow(let window):
            heading = OnboardingCopy.tryItNothingToShow(window.appName)
            detail = OnboardingCopy.tryItOpenSomething
            icon = .app(bundleId: window.bundleId, skipped: false)
        case .skipped(let reason, let window):
            heading = OnboardingCopy.skippedText(reason, app: window?.appName)
            detail = OnboardingCopy.tryItSwitchWindows
            if reason == .passwordField || window == nil {
                icon = .symbol("lock")
            } else if let window {
                icon = .app(bundleId: window.bundleId, skipped: true)
            }
        case .stalled(let cause):
            heading = OnboardingCopy.stalledText(cause)
            switch cause {
            case .unknown:
                action = .tryAgain
                icon = .symbol("text.viewfinder")
            case .permissionOff(let surface):
                action = .openSettings(surface)
                icon = .symbol(surface == .accessibility ? "accessibility" : "rectangle.dashed")
            }
        case .proof(let shown):
            proof = shown
            title = OnboardingCopy.tryItReadFrom(shown.appName)
        case .notRemembering(let state):
            heading = state == .paused ? OnboardingCopy.tryItPaused : OnboardingCopy.tryItOff
            icon = .symbol(state == .paused ? "pause.circle" : "power")
        case .finished(let openedForThem):
            finished = OnboardingCopy.tryItFinished(keyNow, openedForThem: openedForThem)
        }
        // A heading of two sentences shows its first as the heading and the
        // rest under it. Nothing is dropped.
        if detail == nil, let whole = heading, let stop = whole.range(of: ". ") {
            heading = String(whole[..<stop.lowerBound]) + "."
            let rest = whole[stop.upperBound...].trimmingCharacters(in: .whitespaces)
            detail = rest.isEmpty ? nil : rest
        }
        self.title = title
        self.heading = heading
        self.detail = detail
        self.icon = icon
        self.proof = proof
        self.action = action
        self.isWorking = working
        self.finished = finished
        let underProof = proof != nil
        self.next = underProof
            ? OnboardingCopy.tryItNext(keyNow, answersAvailable: understanding == .available) : nil
        self.keycaps = underProof && keyNow.phrase != nil ? keyNow.keycaps : []
        self.keyPresses = self.keycaps.isEmpty ? 0 : keyNow.presses
        self.offersOpenItForMe = underProof
        self.stopSharingNote = underProof ? OnboardingCopy.stopSharingNote : nil
        self.answersNote = underProof ? Self.answersNote(understanding, macOSMajorVersion: macOSMajorVersion) : nil
        self.lowPowerNote = lowPowerMode && Self.waitsForARead(card) ? OnboardingCopy.tryItLowPower : nil
    }

    /// The cards that wait for something to be read.
    static func waitsForARead(_ card: TryItViewModel.Card) -> Bool {
        switch card {
        case .starting, .reading: true
        case .noWindow, .nothingToShow, .skipped, .proof, .stalled, .notRemembering, .finished: false
        }
    }

    /// The status as one sentence, as VoiceOver reads it.
    public var spoken: String? {
        guard let heading else { return nil }
        return detail.map { "\(heading) \($0)" } ?? heading
    }

    /// One line, only when the check has answered and answers do not work.
    /// A model on this Mac that answers is `.available`: nothing is said.
    static func answersNote(_ understanding: UnderstandingAvailability?, macOSMajorVersion: Int) -> String? {
        switch understanding {
        case nil, .available: nil
        case .noModel: OnboardingCopy.noModelNote(macOSMajorVersion: macOSMajorVersion)
        case .preparing: OnboardingCopy.appleIntelligencePreparing
        case .turnedOff: OnboardingCopy.answersNeedAppleIntelligence
        case .unsupported: OnboardingCopy.answersUnsupported
        }
    }
}
