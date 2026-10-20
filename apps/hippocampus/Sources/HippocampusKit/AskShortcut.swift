// SPDX-License-Identifier: Apache-2.0
//
// AskShortcut.swift — what opens Ask right now, and the one place that names
// it (spec-shell S3 and S8, RULINGS X2).
//
// Three facts decide it: the key the person chose, whether that key's monitor
// is running (it needs Accessibility), and whether ⌃⇧Space registered. The
// menu, Preferences, the window and onboarding show only what this file says.
//
// Fn (Globe) adds one more (SPEC-DELTA 7): before Fn listens, its checks run
// (`FnKeyCheck`). With no Fn key, or while another app or macOS uses Fn and
// the person hasn't clicked Use Fn, Shift twice listens instead, and every
// place names Shift twice, because that is what works.

import Combine
import Foundation

public enum AskShortcut {
    /// ⌃⇧Space stays registered whatever key is chosen.
    public static let fallbackLabel = HotkeySpec.spotlightLikeDefault.displayLabel
    public static let fallbackPhrase = "Press \(HotkeySpec.spotlightLikeDefault.displayLabel)"

    /// What works right now, published in the app's own defaults for the
    /// window and onboarding, which run in the same bundle (RULINGS X2).
    /// Empty means nothing opens Ask.
    public static let effectiveLabelKey = "ai.hippocampus.ask.effectiveLabel"
    public static let effectivePhraseKey = "ai.hippocampus.ask.effectivePhrase"

    /// The chosen key while its monitor runs; else ⌃⇧Space when it
    /// registered; else nothing.
    public static func label(key: SoloKey, soloActive: Bool, fallbackRegistered: Bool) -> String? {
        if soloActive, let label = key.shortcutLabel { return label }
        return fallbackRegistered ? fallbackLabel : nil
    }

    /// The instruction that goes with `label`.
    public static func phrase(key: SoloKey, soloActive: Bool, fallbackRegistered: Bool) -> String? {
        if soloActive, let phrase = key.phrase { return phrase }
        return fallbackRegistered ? fallbackPhrase : nil
    }
}

/// The lines under "Open Ask with" in Preferences, General (spec-shell S8,
/// with the product critique's finding 12).
public struct AskKeyCaption: Equatable, Sendable {
    public let text: String
    /// "⌃⇧Space also works." when it does.
    public let secondLine: String?
    /// The key waits for Accessibility: show "Open System Settings…".
    public let needsAccessibility: Bool
    /// Fn is chosen and something else uses it: what, before Fn is taken.
    public let fnWarnings: [FnKeyNote]
    /// Show "Use Fn": Fn waits for the person's own click.
    public let offersUseFn: Bool

    /// - Parameters:
    ///   - fnCheck: Fn's checks, when Fn is the key.
    ///   - fnAccepted: what else using Fn the person accepted with Use Fn.
    public init(
        key: SoloKey, accessibilityGranted: Bool, fallbackRegistered: Bool,
        fnCheck: FnKeyCheck? = nil, fnAccepted: Set<String> = []
    ) {
        let fallback = AskShortcut.fallbackLabel
        let check = key == .fn ? fnCheck : nil
        let waitsForUseFn = check.map { $0.hasFnKey && $0.needsConfirmation(accepted: fnAccepted) } ?? false
        fnWarnings = waitsForUseFn ? (check?.warnings ?? []) : []
        offersUseFn = waitsForUseFn
        if key == .off {
            text = fallbackRegistered ? "Only \(fallback) opens Ask." : "Ask opens from the menu bar."
            secondLine = nil
            needsAccessibility = false
        } else if !accessibilityGranted {
            let meanwhile = fallbackRegistered ? "Until then, use \(fallback)." : "Until then, Ask opens from the menu bar."
            text = "macOS asks before an app can notice a key tap. "
                + "Hippocampus sees that \(Self.tapped(key)) was tapped, never what you type. "
                + meanwhile
            secondLine = nil
            needsAccessibility = true
        } else {
            if let check, !check.hasFnKey {
                text = AskKeyCopy.noFnKey
            } else if waitsForUseFn {
                text = AskKeyCopy.untilUseFn
            } else {
                text = Self.howTo(key)
            }
            secondLine = fallbackRegistered ? "\(fallback) also works." : nil
            needsAccessibility = false
        }
    }

    private static func howTo(_ key: SoloKey) -> String {
        switch key {
        case .shiftTwice: "Press either Shift twice. Capitals and shortcuts don’t count."
        case .fn: AskKeyCopy.fnHowTo
        case .rightShift: "Tap right Shift by itself. Capitals and shortcuts don’t count."
        case .rightCommand: "Tap right ⌘ by itself. Shortcuts like ⌘C never open Ask."
        case .rightOption: "Tap right ⌥ by itself. Symbols and shortcuts don’t count."
        case .off: ""
        }
    }

    private static func tapped(_ key: SoloKey) -> String {
        switch key {
        case .shiftTwice: "Shift"
        case .fn: "Fn"
        case .rightShift: "right Shift"
        case .rightCommand: "right ⌘"
        case .rightOption: "right ⌥"
        case .off: ""
        }
    }
}

/// Keeps the Ask key listening once Accessibility is allowed (spec-shell S3,
/// D12; critique-shell-engineering 13).
///
/// A key monitor needs Accessibility. Without it the choice is kept, not
/// dropped, and the grant is noticed by `recheck()`: the app calls it when
/// macOS says the Accessibility list changed and when Ask or Preferences
/// opens, and a poll calls it every 2 s for ten minutes, then every 30 s,
/// until the key listens. Losing access turns the key off again, because a
/// global monitor then stops hearing taps without saying so.
///
/// Fn listens only after its checks (SPEC-DELTA 7): with no Fn key, or while
/// something else uses Fn that the person hasn't accepted with Use Fn,
/// Shift twice listens instead (`listeningKey`). Each recheck reads the
/// checks again, so a new Fn app, or Keyboard settings changed, counts.
@MainActor
public final class AskKeyWatch: ObservableObject {
    /// How the app hears the key. Injected, so tests never install a monitor.
    public struct Hooks {
        public var isTrusted: @MainActor () -> Bool
        /// Install the monitors for a key; false when they could not be.
        public var install: @MainActor (SoloKey) -> Bool
        public var uninstall: @MainActor () -> Void
        /// Run an action once after a delay, unless cancelled first.
        public var after: @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> AnyCancellable
        /// Fn's checks on this Mac, read when Fn is the key.
        public var fnCheck: @MainActor () -> FnKeyCheck

        public init(
            isTrusted: @escaping @MainActor () -> Bool,
            install: @escaping @MainActor (SoloKey) -> Bool,
            uninstall: @escaping @MainActor () -> Void,
            after: @escaping @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> AnyCancellable,
            fnCheck: @escaping @MainActor () -> FnKeyCheck = { .clear }
        ) {
            self.isTrusted = isTrusted
            self.install = install
            self.uninstall = uninstall
            self.after = after
            self.fnCheck = fnCheck
        }
    }

    public static let quickPoll: TimeInterval = 2
    public static let quickPollFor: TimeInterval = 10 * 60
    public static let slowPoll: TimeInterval = 30

    /// The key the person chose.
    @Published public private(set) var key: SoloKey = .off
    /// The key the monitor listens for: the chosen one, or Shift twice
    /// while Fn can't be taken yet.
    @Published public private(set) var listeningKey: SoloKey = .off
    /// The key's monitor is installed and hearing taps.
    @Published public private(set) var isActive = false
    @Published public private(set) var accessibilityGranted = false
    @Published public private(set) var fallbackRegistered = false
    /// Fn's checks, while Fn is the key.
    @Published public private(set) var fnCheck: FnKeyCheck?
    /// What else using Fn the person accepted with Use Fn.
    @Published public private(set) var fnAccepted: Set<String> = []
    /// A key setup chose since Preferences last looked, for Preferences to
    /// take as its own (`AskKeyPicker`).
    @Published public private(set) var chosenInSetup: SoloKey?

    private let hooks: Hooks
    private let defaults: UserDefaults?
    private var poll: AnyCancellable?
    private var waited: TimeInterval = 0
    private var published: (label: String, phrase: String)?

    /// `defaults` receives the effective label and phrase (RULINGS X2), and
    /// keeps the person's Use Fn.
    public init(hooks: Hooks, defaults: UserDefaults? = nil) {
        self.hooks = hooks
        self.defaults = defaults
        fnAccepted = FnKeyMonitor.accepted(from: defaults?.string(forKey: FnKeyMonitor.acceptedKey))
        publish()
    }

    public var label: String? {
        AskShortcut.label(key: listeningKey, soloActive: isActive, fallbackRegistered: fallbackRegistered)
    }

    public var phrase: String? {
        AskShortcut.phrase(key: listeningKey, soloActive: isActive, fallbackRegistered: fallbackRegistered)
    }

    public var caption: AskKeyCaption {
        caption(for: key)
    }

    /// The caption for `key`: Preferences shows the picker's key before the
    /// app has started listening for it.
    public func caption(for key: SoloKey) -> AskKeyCaption {
        AskKeyCaption(
            key: key, accessibilityGranted: accessibilityGranted, fallbackRegistered: fallbackRegistered,
            fnCheck: key == .fn ? currentFnCheck() : nil, fnAccepted: fnAccepted
        )
    }

    /// Fn's checks: the last ones read, or read now.
    public func currentFnCheck() -> FnKeyCheck {
        fnCheck ?? hooks.fnCheck()
    }

    /// Listen for `key`, replacing any earlier choice.
    public func start(key: SoloKey) {
        removeMonitor()
        poll = nil
        waited = 0
        self.key = key
        recheck()
    }

    /// Stop listening, at quit.
    public func stop() {
        removeMonitor()
        poll = nil
        key = .off
        listeningKey = .off
        fnCheck = nil
        publish()
    }

    /// Whether ⌃⇧Space registered.
    public func setFallbackRegistered(_ registered: Bool) {
        fallbackRegistered = registered
        publish()
    }

    /// Use Fn: the person takes Fn over what else uses it now. Kept, so
    /// only a new conflict asks again.
    public func acceptFn() {
        let check = currentFnCheck()
        fnAccepted.formUnion(check.conflictTokens)
        defaults?.set(FnKeyMonitor.acceptedValue(fnAccepted), forKey: FnKeyMonitor.acceptedKey)
        recheck()
    }

    /// Setup wrote a choice: listen for it now. Preferences takes it as its
    /// own when it shows (`adoptSetupChoice`).
    public func setupChose(_ key: SoloKey) {
        fnAccepted = FnKeyMonitor.accepted(from: defaults?.string(forKey: FnKeyMonitor.acceptedKey))
        chosenInSetup = key
        start(key: key)
    }

    /// Preferences has taken setup's choice.
    public func adoptedSetupChoice() {
        chosenInSetup = nil
    }

    /// Look again whether Accessibility is allowed, and listen if it is.
    public func recheck() {
        let trusted = hooks.isTrusted()
        accessibilityGranted = trusted
        let listen = resolveListeningKey()
        if listen != listeningKey {
            removeMonitor()
            listeningKey = listen
        }
        if key == .off {
            removeMonitor()
            poll = nil
        } else if trusted {
            if !isActive { isActive = hooks.install(listeningKey) }
            if isActive {
                poll = nil
                waited = 0
            } else {
                schedulePoll()
            }
        } else {
            removeMonitor()
            schedulePoll()
        }
        publish()
    }

    /// Fn's checks, read now, decide what listens when Fn is the key.
    private func resolveListeningKey() -> SoloKey {
        guard key == .fn else {
            fnCheck = nil
            return key
        }
        let check = hooks.fnCheck()
        if check != fnCheck { fnCheck = check }
        return check.listeningKey(accepted: fnAccepted)
    }

    private func removeMonitor() {
        guard isActive else { return }
        hooks.uninstall()
        isActive = false
    }

    private func schedulePoll() {
        guard poll == nil else { return }
        let interval = waited < Self.quickPollFor ? Self.quickPoll : Self.slowPoll
        poll = hooks.after(interval) { [weak self] in
            guard let self else { return }
            self.poll = nil
            self.waited += interval
            self.recheck()
        }
    }

    /// Written only when it changes, so the poll does not write defaults
    /// every two seconds.
    private func publish() {
        guard let defaults else { return }
        let now = (label: label ?? "", phrase: phrase ?? "")
        guard published?.label != now.label || published?.phrase != now.phrase else { return }
        defaults.set(now.label, forKey: AskShortcut.effectiveLabelKey)
        defaults.set(now.phrase, forKey: AskShortcut.effectivePhraseKey)
        published = now
    }
}
