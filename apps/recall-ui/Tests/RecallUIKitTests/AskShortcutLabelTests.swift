import XCTest
@testable import RecallUIKit

final class AskShortcutLabelTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "recall-ask-key-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testWhatTheAppPublishesIsWhatTheWindowShows() {
        defaults.set("right ⌘", forKey: AskShortcutLabel.effectiveLabelKey)
        defaults.set("Tap right ⌘", forKey: AskShortcutLabel.effectivePhraseKey)
        defaults.set("shiftTwice", forKey: AskShortcutLabel.askKeyKey)
        XCTAssertEqual(AskShortcutLabel.current(defaults: defaults), AskShortcutLabel(label: "right ⌘", phrase: "Tap right ⌘"))
    }

    func testAnEmptyLabelMeansNothingOpensAsk() {
        defaults.set("", forKey: AskShortcutLabel.effectiveLabelKey)
        defaults.set("Press Shift twice", forKey: AskShortcutLabel.effectivePhraseKey)
        let label = AskShortcutLabel.current(defaults: defaults)
        XCTAssertFalse(label.opensAsk)
        XCTAssertEqual(label, AskShortcutLabel(label: "", phrase: ""))
    }

    func testWithoutWhatTheAppPublishesTheChosenKeyStandsIn() {
        let expected: [String: AskShortcutLabel] = [
            "shiftTwice": AskShortcutLabel(label: "⇧⇧", phrase: "Press Shift twice"),
            "rightShift": AskShortcutLabel(label: "right ⇧", phrase: "Tap right Shift"),
            "rightCommand": AskShortcutLabel(label: "right ⌘", phrase: "Tap right ⌘"),
            "rightOption": AskShortcutLabel(label: "right ⌥", phrase: "Tap right ⌥"),
            "off": AskShortcutLabel(label: "⌃⇧Space", phrase: "Press ⌃⇧Space"),
            "capsLock": AskShortcutLabel(label: "⇧⇧", phrase: "Press Shift twice"),
        ]
        for (key, label) in expected {
            defaults.set(key, forKey: AskShortcutLabel.askKeyKey)
            XCTAssertEqual(AskShortcutLabel.current(defaults: defaults), label, key)
        }
        defaults.removeObject(forKey: AskShortcutLabel.askKeyKey)
        XCTAssertEqual(AskShortcutLabel.current(defaults: defaults), AskShortcutLabel(label: "⇧⇧", phrase: "Press Shift twice"))
    }

    func testALabelWithoutAPhraseSaysPress() {
        defaults.set("⌃⌥Space", forKey: AskShortcutLabel.effectiveLabelKey)
        XCTAssertEqual(AskShortcutLabel.current(defaults: defaults), AskShortcutLabel(label: "⌃⌥Space", phrase: "Press ⌃⌥Space"))
    }

    func testTheKeysAreTheOnesTheAppWrites() {
        XCTAssertEqual(AskShortcutLabel.effectiveLabelKey, "ai.hippocampus.ask.effectiveLabel")
        XCTAssertEqual(AskShortcutLabel.effectivePhraseKey, "ai.hippocampus.ask.effectivePhrase")
        XCTAssertEqual(AskShortcutLabel.askKeyKey, "ai.hippocampus.prefs.askKey")
        XCTAssertEqual(Set(UserFacingCopy.askKeyNames.keys), ["shiftTwice", "rightShift", "rightCommand", "rightOption", "off"])
    }
}
