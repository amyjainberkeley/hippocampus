// SPDX-License-Identifier: TBD-private
//
// The key that opens Ask, as the person chose it in Preferences
// (RULINGS X2): `ai.hippocampus.prefs.askKey` in the app's own defaults,
// one of `shiftTwice`, `rightShift`, `rightCommand`, `rightOption`, `off`.
// Missing or unknown means `shiftTwice`, as the app treats it. `off` leaves
// only Control-Shift-Space. Onboarding does not link HippocampusKit, so
// this is a small copy of the app's names, read at render time so a change
// in Preferences shows without a restart.

import Foundation

public enum AskShortcutLabel {
    public static let preferenceKey = "ai.hippocampus.prefs.askKey"
    /// The app's defaults domain. Read by name, because inside the app
    /// bundle and under `swift run` this process's own domain differs.
    public static let applicationID = "ai.hippocampus"

    /// The raw stored value, or nil when the person never chose.
    public static func storedValue() -> String? {
        CFPreferencesCopyAppValue(preferenceKey as CFString, applicationID as CFString) as? String
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

/// How onboarding names the Ask key in its sentences and keycaps.
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
}
