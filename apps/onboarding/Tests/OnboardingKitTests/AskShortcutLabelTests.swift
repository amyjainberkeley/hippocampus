import XCTest
@testable import OnboardingKit

final class AskShortcutLabelTests: XCTestCase {
    func testEveryStoredKeyHasItsLabelPhraseAndKeycaps() {
        let expected: [(stored: String, hint: AskKeyHint, label: String, phrase: String, noun: String?, caps: [String])] = [
            ("shiftTwice", .shiftTwice, "⇧⇧", "Press Shift twice", "Shift twice", ["⇧", "⇧"]),
            ("rightShift", .rightShift, "right ⇧", "Tap right Shift", "right Shift", ["right ⇧"]),
            ("rightCommand", .rightCommand, "right ⌘", "Tap right Command", "right Command", ["right ⌘"]),
            ("rightOption", .rightOption, "right ⌥", "Tap right Option", "right Option", ["right ⌥"]),
            ("off", .chord, "⌃⇧Space", "Press Control-Shift-Space", nil, ["⌃", "⇧", "Space"]),
        ]
        for row in expected {
            let hint = AskKeyHint(stored: row.stored)
            XCTAssertEqual(hint, row.hint, row.stored)
            XCTAssertEqual(AskShortcutLabel.label(forStored: row.stored), row.label, row.stored)
            XCTAssertEqual(hint.phrase, row.phrase, row.stored)
            XCTAssertEqual(hint.noun, row.noun, row.stored)
            XCTAssertEqual(hint.keycaps, row.caps, row.stored)
        }
    }

    func testNothingStoredMeansShiftTwice() {
        XCTAssertEqual(AskKeyHint(stored: nil), .shiftTwice)
        XCTAssertEqual(AskShortcutLabel.label(forStored: nil), "⇧⇧")
    }

    func testAnUnknownValueMeansShiftTwiceAsTheAppTreatsIt() {
        XCTAssertEqual(AskKeyHint(stored: "capsLock"), .shiftTwice)
        XCTAssertEqual(AskKeyHint(stored: ""), .shiftTwice)
    }

    func testShiftTwicePulsesTwiceAndEveryOtherKeyOnce() {
        XCTAssertEqual(AskKeyHint.allCases.map(\.pulses), [2, 1, 1, 1, 1])
    }

    // MARK: - What opens Ask right now (RULINGS X2)

    func testWhatTheAppPublishesWinsOverTheChosenKey() {
        // Shift twice is chosen, but Accessibility is not on yet: only the
        // chord works, and Try it must say so.
        let now = AskKeyNow(effectiveLabel: "⌃⇧Space", effectivePhrase: "Press ⌃⇧Space", stored: "shiftTwice")
        XCTAssertEqual(now, AskKeyNow(phrase: "Press ⌃⇧Space", keycaps: ["⌃", "⇧", "Space"]))
        XCTAssertEqual(now.name, "⌃⇧Space")
    }

    func testEveryPublishedLabelHasItsKeycaps() {
        let published: [(label: String, phrase: String, caps: [String], name: String)] = [
            ("⇧⇧", "Press Shift twice", ["⇧", "⇧"], "Shift twice"),
            ("right ⇧", "Tap right Shift", ["right ⇧"], "right Shift"),
            ("right ⌘", "Tap right ⌘", ["right ⌘"], "right ⌘"),
            ("right ⌥", "Tap right ⌥", ["right ⌥"], "right ⌥"),
            ("⌃⇧Space", "Press ⌃⇧Space", ["⌃", "⇧", "Space"], "⌃⇧Space"),
        ]
        for row in published {
            let now = AskKeyNow(effectiveLabel: row.label, effectivePhrase: row.phrase, stored: "off")
            XCTAssertEqual(now.phrase, row.phrase, row.label)
            XCTAssertEqual(now.keycaps, row.caps, row.label)
            XCTAssertEqual(now.name, row.name, row.label)
        }
    }

    func testWhenTheAppPublishedNothingTheChosenKeyStandsIn() {
        for hint in AskKeyHint.allCases {
            let stored = hint == .chord ? "off" : hint.rawValue
            let now = AskKeyNow(effectiveLabel: nil, effectivePhrase: nil, stored: stored)
            XCTAssertEqual(now.phrase, hint.phrase, stored)
            XCTAssertEqual(now.keycaps, hint.keycaps, stored)
            XCTAssertEqual(now.name, hint.sentenceName, stored)
        }
        XCTAssertEqual(AskKeyNow(effectiveLabel: nil, effectivePhrase: nil, stored: nil).phrase, "Press Shift twice")
        // A phrase without a label is not a publication.
        XCTAssertEqual(AskKeyNow(effectiveLabel: nil, effectivePhrase: "Press ⌃⇧Space", stored: "shiftTwice").phrase,
                       "Press Shift twice")
    }

    func testAnEmptyLabelMeansNothingOpensAsk() {
        for label in ["", "  "] {
            let now = AskKeyNow(effectiveLabel: label, effectivePhrase: "Press Shift twice", stored: "shiftTwice")
            XCTAssertNil(now.phrase)
            XCTAssertNil(now.name)
            XCTAssertEqual(now.keycaps, [])
        }
    }

    func testALabelWithoutAPhraseOrUnknownToOnboardingStillReadsRight() {
        let knownLabel = AskKeyNow(effectiveLabel: "⇧⇧", effectivePhrase: nil, stored: "off")
        XCTAssertEqual(knownLabel, AskKeyNow(phrase: "Press Shift twice", keycaps: ["⇧", "⇧"]))
        let unknown = AskKeyNow(effectiveLabel: "F5", effectivePhrase: "", stored: "shiftTwice")
        XCTAssertEqual(unknown, AskKeyNow(phrase: "Press F5", keycaps: ["F5"]))
        XCTAssertEqual(unknown.name, "F5")
    }

    func testItReadsTheAppsThreeKeys() {
        let defaults = [
            "ai.hippocampus.ask.effectiveLabel": "right ⌥",
            "ai.hippocampus.ask.effectivePhrase": "Tap right ⌥",
            "ai.hippocampus.prefs.askKey": "rightOption",
        ]
        var asked: [String] = []
        let now = AskKeyNow.read { key in
            asked.append(key)
            return defaults[key]
        }
        XCTAssertEqual(now, AskKeyNow(phrase: "Tap right ⌥", keycaps: ["right ⌥"]))
        XCTAssertEqual(Set(asked), Set(defaults.keys))
        XCTAssertEqual(AskKeyNow.read { _ in nil }, AskKeyNow(phrase: "Press Shift twice", keycaps: ["⇧", "⇧"]))
    }

    func testThePreferenceIsTheAppsOwn() throws {
        XCTAssertEqual(AskShortcutLabel.preferenceKey, "ai.hippocampus.prefs.askKey")
        XCTAssertEqual(AskShortcutLabel.applicationID, "ai.hippocampus")
        let store = try String(
            contentsOf: repositoryRoot.appendingPathComponent("apps/hippocampus/Sources/HippocampusKit/PreferencesStore.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(store.contains("static let askKey = \"ai.hippocampus.prefs.askKey\""))
    }

    func testEveryKeyTheAppCanStoreIsKnownHere() throws {
        let trigger = try String(
            contentsOf: repositoryRoot.appendingPathComponent("apps/hippocampus/Sources/HippocampusKit/SoloKeyTrigger.swift"),
            encoding: .utf8
        )
        let body = try XCTUnwrap(trigger.components(separatedBy: "public enum SoloKey").dropFirst().first)
            .components(separatedBy: "public var id").first ?? ""
        let cases = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }
            .flatMap { line in
                (line.dropFirst(5).components(separatedBy: "//").first ?? "")
                    .split(separator: ",")
                    .map { $0.split(whereSeparator: { "=( ".contains($0) }).first.map(String.init) ?? "" }
            }
            .filter { !$0.isEmpty }
        XCTAssertFalse(cases.isEmpty)
        let known: Set<String> = ["shiftTwice", "rightShift", "rightCommand", "rightOption", "off"]
        for stored in cases {
            XCTAssertTrue(known.contains(stored), "the app can store \(stored); onboarding must name it")
        }
    }
}
