// SPDX-License-Identifier: TBD-private
//
// What opens Ask, and how it is named: one decision for the menu,
// Preferences, the window and onboarding (spec-shell S3, S8; RULINGS X2).

import Combine
import XCTest
@testable import HippocampusKit

final class AskShortcutTests: XCTestCase {

    func testAListeningKeyIsNamedByItself() {
        let expected: [(SoloKey, String, String)] = [
            (.shiftTwice, "⇧⇧", "Press Shift twice"),
            (.rightShift, "right ⇧", "Tap right Shift"),
            (.rightCommand, "right ⌘", "Tap right ⌘"),
            (.rightOption, "right ⌥", "Tap right ⌥"),
        ]
        for (key, label, phrase) in expected {
            XCTAssertEqual(AskShortcut.label(key: key, soloActive: true, fallbackRegistered: true), label)
            XCTAssertEqual(AskShortcut.phrase(key: key, soloActive: true, fallbackRegistered: true), phrase)
            XCTAssertEqual(AskShortcut.label(key: key, soloActive: true, fallbackRegistered: false), label)
        }
    }

    func testWithTheKeyOffOnlyTheChordIsNamed() {
        XCTAssertEqual(AskShortcut.label(key: .off, soloActive: false, fallbackRegistered: true), "⌃⇧Space")
        XCTAssertEqual(AskShortcut.phrase(key: .off, soloActive: false, fallbackRegistered: true), "Press ⌃⇧Space")
    }

    func testAKeyWhoseMonitorIsNotListeningIsNeverNamed() {
        for key in SoloKey.allCases {
            XCTAssertEqual(AskShortcut.label(key: key, soloActive: false, fallbackRegistered: true), "⌃⇧Space", "\(key)")
            XCTAssertEqual(AskShortcut.phrase(key: key, soloActive: false, fallbackRegistered: true), "Press ⌃⇧Space")
        }
    }

    func testNothingIsNamedWhenNothingOpensAsk() {
        for key in SoloKey.allCases {
            XCTAssertNil(AskShortcut.label(key: key, soloActive: false, fallbackRegistered: false), "\(key)")
            XCTAssertNil(AskShortcut.phrase(key: key, soloActive: false, fallbackRegistered: false), "\(key)")
        }
    }

    func testTheChordIsTheRegisteredHotkey() {
        XCTAssertEqual(AskShortcut.fallbackLabel, HotkeySpec.spotlightLikeDefault.displayLabel)
        XCTAssertEqual(AskShortcut.effectiveLabelKey, "ai.hippocampus.ask.effectiveLabel")
        XCTAssertEqual(AskShortcut.effectivePhraseKey, "ai.hippocampus.ask.effectivePhrase")
    }

    // MARK: Preferences, General

    func testEachKeysCaptionSaysHowToPressIt() {
        let expected: [(SoloKey, String)] = [
            (.shiftTwice, "Press either Shift twice. Capitals and shortcuts don’t count."),
            (.rightShift, "Tap right Shift by itself. Capitals and shortcuts don’t count."),
            (.rightCommand, "Tap right ⌘ by itself. Shortcuts like ⌘C never open Ask."),
            // Option types symbols, not capitals.
            (.rightOption, "Tap right ⌥ by itself. Symbols and shortcuts don’t count."),
        ]
        for (key, text) in expected {
            let caption = AskKeyCaption(key: key, accessibilityGranted: true, fallbackRegistered: true)
            XCTAssertEqual(caption.text, text)
            XCTAssertEqual(caption.secondLine, "⌃⇧Space also works.")
            XCTAssertFalse(caption.needsAccessibility)
            XCTAssertNil(AskKeyCaption(key: key, accessibilityGranted: true, fallbackRegistered: false).secondLine)
        }
    }

    func testWithoutAccessibilityTheCaptionSaysWhyAndOffersSystemSettings() {
        let caption = AskKeyCaption(key: .shiftTwice, accessibilityGranted: false, fallbackRegistered: true)
        XCTAssertEqual(caption.text, "macOS asks before an app can notice a key tap. "
            + "Hippocampus sees that Shift was tapped, never what you type. Until then, use ⌃⇧Space.")
        XCTAssertNil(caption.secondLine)
        XCTAssertTrue(caption.needsAccessibility)
        XCTAssertTrue(AskKeyCaption(key: .rightCommand, accessibilityGranted: false, fallbackRegistered: true)
            .text.contains("Hippocampus sees that right ⌘ was tapped, never what you type."))
        XCTAssertTrue(AskKeyCaption(key: .rightOption, accessibilityGranted: false, fallbackRegistered: false)
            .text.hasSuffix("Until then, Ask opens from the menu bar."))
    }

    func testWithTheKeyOffTheCaptionNamesWhatStillOpensAsk() {
        let chord = AskKeyCaption(key: .off, accessibilityGranted: false, fallbackRegistered: true)
        XCTAssertEqual(chord.text, "Only ⌃⇧Space opens Ask.")
        XCTAssertFalse(chord.needsAccessibility, "the key is off, so nothing waits for Accessibility")
        XCTAssertEqual(
            AskKeyCaption(key: .off, accessibilityGranted: true, fallbackRegistered: false).text,
            "Ask opens from the menu bar."
        )
    }

    func testNoCaptionUsesABannedOrSloppyWord() {
        var texts: [String] = []
        for key in SoloKey.allCases {
            for granted in [true, false] {
                for registered in [true, false] {
                    let caption = AskKeyCaption(key: key, accessibilityGranted: granted, fallbackRegistered: registered)
                    texts.append(caption.text)
                    texts += [caption.secondLine].compactMap { $0 }
                }
            }
        }
        for text in texts {
            XCTAssertFalse(text.isEmpty)
            for banned in ["Recall", "popup", "—", ";", "'", "never opens Ask.", "Typing never"] {
                XCTAssertFalse(text.contains(banned), "\(banned) in \(text)")
            }
        }
    }

    // MARK: The monitor keeps trying (D12)

    @MainActor
    private final class Rig {
        var trusted = false
        var installs: [SoloKey] = []
        var uninstalls = 0
        var installWorks = true
        var scheduled: [(seconds: TimeInterval, action: @MainActor @Sendable () -> Void, cancelled: () -> Bool)] = []

        lazy var hooks = AskKeyWatch.Hooks(
            isTrusted: { [unowned self] in self.trusted },
            install: { [unowned self] key in
                self.installs.append(key)
                return self.installWorks
            },
            uninstall: { [unowned self] in self.uninstalls += 1 },
            after: { [unowned self] seconds, action in
                final class Flag { var cancelled = false }
                let flag = Flag()
                self.scheduled.append((seconds, action, { flag.cancelled }))
                return AnyCancellable { flag.cancelled = true }
            }
        )

        /// Run the next poll that is still wanted.
        func firePoll() -> TimeInterval? {
            while !scheduled.isEmpty {
                let next = scheduled.removeFirst()
                if !next.cancelled() {
                    next.action()
                    return next.seconds
                }
            }
            return nil
        }

        var pendingPolls: Int { scheduled.filter { !$0.cancelled() }.count }
    }

    @MainActor
    func testTheKeyWaitsForAccessibilityThenListensWithoutARestart() {
        let rig = Rig()
        let watch = AskKeyWatch(hooks: rig.hooks)
        watch.start(key: .shiftTwice)
        XCTAssertFalse(watch.isActive)
        XCTAssertFalse(watch.accessibilityGranted)
        XCTAssertEqual(watch.key, .shiftTwice, "the choice is kept, not dropped")
        XCTAssertTrue(rig.installs.isEmpty)
        XCTAssertEqual(rig.firePoll(), AskKeyWatch.quickPoll)
        XCTAssertFalse(watch.isActive)
        rig.trusted = true
        XCTAssertEqual(rig.firePoll(), AskKeyWatch.quickPoll)
        XCTAssertTrue(watch.isActive)
        XCTAssertTrue(watch.accessibilityGranted)
        XCTAssertEqual(rig.installs, [.shiftTwice])
        XCTAssertEqual(rig.pendingPolls, 0, "the poll stops once the key listens")
    }

    @MainActor
    func testTheAccessibilityNoticeStartsTheKeyAtOnce() {
        let rig = Rig()
        let watch = AskKeyWatch(hooks: rig.hooks)
        watch.start(key: .rightShift)
        rig.trusted = true
        watch.recheck()
        XCTAssertTrue(watch.isActive)
        XCTAssertEqual(rig.installs, [.rightShift])
        XCTAssertEqual(rig.pendingPolls, 0)
    }

    @MainActor
    func testThePollSlowsDownAfterTenMinutes() {
        let rig = Rig()
        let watch = AskKeyWatch(hooks: rig.hooks)
        watch.start(key: .shiftTwice)
        var waited: TimeInterval = 0
        while waited < AskKeyWatch.quickPollFor {
            waited += rig.firePoll() ?? .infinity
        }
        XCTAssertEqual(rig.firePoll(), AskKeyWatch.slowPoll)
        XCTAssertEqual(rig.firePoll(), AskKeyWatch.slowPoll)
        XCTAssertFalse(watch.isActive)
    }

    @MainActor
    func testLosingAccessibilityStopsTheKeyAndWaitsAgain() {
        let rig = Rig()
        rig.trusted = true
        let watch = AskKeyWatch(hooks: rig.hooks)
        watch.start(key: .shiftTwice)
        XCTAssertTrue(watch.isActive)
        rig.trusted = false
        watch.recheck()
        XCTAssertFalse(watch.isActive, "a global monitor stops hearing taps without saying so")
        XCTAssertEqual(rig.uninstalls, 1)
        XCTAssertEqual(rig.pendingPolls, 1)
        rig.trusted = true
        _ = rig.firePoll()
        XCTAssertTrue(watch.isActive)
        XCTAssertEqual(rig.installs, [.shiftTwice, .shiftTwice])
    }

    @MainActor
    func testStopCancelsThePollAndOffNeverListens() {
        let rig = Rig()
        let watch = AskKeyWatch(hooks: rig.hooks)
        watch.start(key: .rightOption)
        XCTAssertEqual(rig.pendingPolls, 1)
        watch.stop()
        XCTAssertEqual(rig.pendingPolls, 0)
        rig.trusted = true
        watch.start(key: .off)
        XCTAssertFalse(watch.isActive)
        XCTAssertTrue(rig.installs.isEmpty)
        XCTAssertEqual(rig.pendingPolls, 0)
    }

    @MainActor
    func testChangingTheKeySwapsTheMonitor() {
        let rig = Rig()
        rig.trusted = true
        let watch = AskKeyWatch(hooks: rig.hooks)
        watch.start(key: .shiftTwice)
        watch.start(key: .rightCommand)
        XCTAssertEqual(rig.installs, [.shiftTwice, .rightCommand])
        XCTAssertEqual(rig.uninstalls, 1)
        XCTAssertTrue(watch.isActive)
    }

    @MainActor
    func testWhatWorksIsPublishedForTheWindowAndOnboarding() throws {
        let suite = "ask-shortcut-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rig = Rig()
        let watch = AskKeyWatch(hooks: rig.hooks, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: AskShortcut.effectiveLabelKey), "", "nothing opens Ask yet")
        watch.setFallbackRegistered(true)
        watch.start(key: .shiftTwice)
        XCTAssertEqual(defaults.string(forKey: AskShortcut.effectiveLabelKey), "⌃⇧Space")
        XCTAssertEqual(defaults.string(forKey: AskShortcut.effectivePhraseKey), "Press ⌃⇧Space")
        XCTAssertEqual(watch.caption.needsAccessibility, true)
        rig.trusted = true
        watch.recheck()
        XCTAssertEqual(defaults.string(forKey: AskShortcut.effectiveLabelKey), "⇧⇧")
        XCTAssertEqual(defaults.string(forKey: AskShortcut.effectivePhraseKey), "Press Shift twice")
        XCTAssertEqual(watch.label, "⇧⇧")
        XCTAssertEqual(watch.caption.secondLine, "⌃⇧Space also works.")
        watch.stop()
        XCTAssertEqual(defaults.string(forKey: AskShortcut.effectiveLabelKey), "⌃⇧Space")
    }
}
