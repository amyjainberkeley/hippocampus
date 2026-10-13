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
