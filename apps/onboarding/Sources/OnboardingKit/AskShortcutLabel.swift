// SPDX-License-Identifier: Apache-2.0
//
// The key that opens Ask (RULINGS X2). Onboarding reads two things from the
// app's own defaults, at render time, so a change shows without a restart:
//
// - The key the person chose, `ai.hippocampus.prefs.askKey`: one of
//   `shiftTwice`, `rightShift`, `rightCommand`, `rightOption`, `off`.
//   Missing or unknown means `shiftTwice`, as the app treats it; `off`
//   leaves only Control-Shift-Space. Welcome and the Accessibility row
//   describe this key: they say what Hippocampus does once it is set up,
//   and before setup nothing opens Ask at all.
// - What opens Ask right now, which the app publishes:
//   `ai.hippocampus.ask.effectiveLabel` ("⇧⇧", "right ⇧", "⌃⇧Space", or
//   empty when nothing does) and `ai.hippocampus.ask.effectivePhrase`
//   ("Press Shift twice", "Press ⌃⇧Space"). Try it tells the person to
//   press a key now, so it names only what these say, and falls back to
//   the chosen key when the app has published nothing.
//
// Onboarding does not link HippocampusKit, so this is a small copy of the
// app's names.

import Foundation

public enum AskShortcutLabel {
    public static let preferenceKey = "ai.hippocampus.prefs.askKey"
    /// What opens Ask right now, as the menu shows it; empty when nothing does.
    public static let effectiveLabelKey = "ai.hippocampus.ask.effectiveLabel"
    /// The instruction for that key: "Press Shift twice".
    public static let effectivePhraseKey = "ai.hippocampus.ask.effectivePhrase"
    /// The app's defaults domain. Read by name, because inside the app
    /// bundle and under `swift run` this process's own domain differs.
    public static let applicationID = "ai.hippocampus"

    /// A string from the app's defaults, or nil when it is not set.
    public static func appValue(_ key: String) -> String? {
        CFPreferencesCopyAppValue(key as CFString, applicationID as CFString) as? String
    }

    /// The raw stored value, or nil when the person never chose.
    public static func storedValue() -> String? {
        appValue(preferenceKey)
    }

    /// The key as the menu shows it: "⇧⇧", "right ⇧", "right ⌘",
    /// "right ⌥", or "⌃⇧Space" when the key is off.
    public static func label(forStored stored: String?) -> String {
        AskKeyHint(stored: stored).label
    }

    public static func current() -> String {
        label(forStored: storedValue())
    }
}

/// How onboarding names the chosen Ask key in its sentences and keycaps.
public enum AskKeyHint: String, Sendable, Equatable, CaseIterable {
    case shiftTwice
    case rightShift
    case rightCommand
    case rightOption
    /// The key is off: Control-Shift-Space is the way in.
    case chord

    public init(stored: String?) {
        switch stored {
        case "rightShift": self = .rightShift
        case "rightCommand": self = .rightCommand
        case "rightOption": self = .rightOption
        case "off": self = .chord
        default: self = .shiftTwice
        }
    }

    /// The key whose menu label this is ("⇧⇧" is Shift twice), or nil.
    public init?(label: String) {
        guard let hint = Self.allCases.first(where: { $0.label == label }) else { return nil }
        self = hint
    }

    /// Read now, from the app's preference.
    public static func current() -> AskKeyHint {
        AskKeyHint(stored: AskShortcutLabel.storedValue())
    }

    /// "Press" for Shift twice and the chord, "Tap" for a single key.
    public var verb: String {
        switch self {
        case .shiftTwice, .chord: "Press"
        case .rightShift, .rightCommand, .rightOption: "Tap"
        }
    }

    /// What the keycaps show, one cap per entry.
    public var keycaps: [String] {
        switch self {
        case .shiftTwice: ["⇧", "⇧"]
        case .rightShift: ["right ⇧"]
        case .rightCommand: ["right ⌘"]
        case .rightOption: ["right ⌥"]
        case .chord: ["⌃", "⇧", "Space"]
        }
    }

    /// The instruction: "Press Shift twice", "Tap right Shift", …
    public var phrase: String {
        "\(verb) \(sentenceName)"
    }

    /// The key as a noun ("Shift twice", "right Shift"), nil for the chord.
    public var noun: String? {
        switch self {
        case .shiftTwice: "Shift twice"
        case .rightShift: "right Shift"
        case .rightCommand: "right Command"
        case .rightOption: "right Option"
        case .chord: nil
        }
    }

    /// The key's name inside a sentence, the chord included.
    public var sentenceName: String {
        noun ?? "Control-Shift-Space"
    }

    /// The compact label the menu shows.
    public var label: String {
        switch self {
        case .shiftTwice: "⇧⇧"
        case .rightShift: "right ⇧"
        case .rightCommand: "right ⌘"
        case .rightOption: "right ⌥"
        case .chord: "⌃⇧Space"
        }
    }

    /// How many times the keycaps pulse: twice for Shift twice, once for
    /// a single key and for the chord.
    public var pulses: Int {
        self == .shiftTwice ? 2 : 1
    }

    /// When Welcome's keycaps pulse, in seconds from the start of each
    /// cycle: 0.6 s in, and again 0.3 s later for Shift twice.
    public var pulseTimes: [TimeInterval] {
        Self.pulseTimes(presses: pulses)
    }

    /// The pulse times for a key pressed `presses` times, as Welcome's.
    public static func pulseTimes(presses: Int) -> [TimeInterval] {
        Array([0.6, 0.9].prefix(max(0, presses)))
    }

    /// Welcome shows the press again this often while it is on screen.
    public static let pulseCycle: TimeInterval = 6
}

/// What opens Ask right now, for the sentences on Try it that tell the
/// person to press it (RULINGS X2).
public struct AskKeyNow: Equatable, Sendable {
    /// The instruction: "Press Shift twice", "Press ⌃⇧Space". Nil when
    /// nothing opens Ask right now.
    public let phrase: String?
    /// The keycaps to draw, one per cap. Empty when nothing opens Ask.
    public let keycaps: [String]

    public init(phrase: String?, keycaps: [String]) {
        self.phrase = phrase
        self.keycaps = keycaps
    }

    /// From what the app published. No label at all means the app has not
    /// published one, and the chosen key stands in; an empty label means
    /// nothing opens Ask. A label onboarding does not know is drawn as one
    /// keycap.
    public init(effectiveLabel: String?, effectivePhrase: String?, stored: String?) {
        guard let rawLabel = effectiveLabel else {
            let chosen = AskKeyHint(stored: stored)
            self.init(phrase: chosen.phrase, keycaps: chosen.keycaps)
            return
        }
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            self.init(phrase: nil, keycaps: [])
            return
        }
        let known = AskKeyHint(label: label)
        let published = effectivePhrase?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            phrase: published.flatMap { $0.isEmpty ? nil : $0 } ?? known?.phrase ?? "Press \(label)",
            keycaps: known?.keycaps ?? [label]
        )
    }

    /// Read with `value`, which answers for a key of the app's defaults.
    public static func read(_ value: (String) -> String?) -> AskKeyNow {
        AskKeyNow(
            effectiveLabel: value(AskShortcutLabel.effectiveLabelKey),
            effectivePhrase: value(AskShortcutLabel.effectivePhraseKey),
            stored: value(AskShortcutLabel.preferenceKey)
        )
    }

    /// Read now, from the app's defaults.
    public static func current() -> AskKeyNow {
        read(AskShortcutLabel.appValue)
    }

    /// How many times the keycaps press when Try it shows the key: twice
    /// for Shift twice, once for a single key or the chord, never when
    /// nothing opens Ask.
    public var presses: Int {
        if keycaps.isEmpty { return 0 }
        return keycaps == AskKeyHint.shiftTwice.keycaps ? AskKeyHint.shiftTwice.pulses : 1
    }

    /// The key's name inside a sentence: the phrase without its verb
    /// ("Shift twice", "right ⌘", "⌃⇧Space").
    public var name: String? {
        guard let phrase else { return nil }
        let parts = phrase.split(separator: " ", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : phrase
    }
}
