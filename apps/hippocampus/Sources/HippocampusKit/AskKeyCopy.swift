// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The words for the key that opens Ask (SPEC-DELTA 7): Fn (Globe) beside
/// Shift twice in Preferences, what else uses Fn, and the note for a
/// keyboard without it. Every string passes the launch copy rules
/// (`AskKeyCopyTests`, `scripts/check-launch-copy.sh`); setup says the same
/// in `OnboardingCopy.AskKey`.
public enum AskKeyCopy {
    /// How Fn opens Ask, under the picker.
    public static let fnHowTo = "Tap Fn by itself. Fn with arrows and function keys keeps working."
    /// Fn is chosen, but no keyboard here has it.
    public static let noFnKey = "This keyboard has no Fn key, so Shift twice opens Ask."
    /// Fn is chosen and waits for Use Fn: what works meanwhile.
    public static let untilUseFn = "Until you click Use Fn, Shift twice opens Ask."
    /// Takes Fn over what else uses it: the person's own click.
    public static let useFn = "Use Fn"
    public static let openKeyboardSettings = "Open Keyboard Settings…"
    /// macOS's own setting, the exact step in Keyboard settings. The
    /// setting's label draws a globe; the words name the key instead.
    public static let globeStep = "In Keyboard settings, choose Do Nothing for the Globe key."

    /// A known Fn app is installed: say so by name, and the two ways on.
    public static func appsUseFn(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return "\(names[0]) uses Fn. Pick another key, or turn Fn off in \(names[0])."
        case 2: return "\(names[0]) and \(names[1]) use Fn. Pick another key, or turn Fn off in both."
        default:
            let list = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
            return "\(list) use Fn. Pick another key, or turn Fn off in each."
        }
    }

    /// What macOS does with the Globe key now.
    public static func globeUsesFn(_ action: GlobeKeyAction) -> String {
        switch action {
        case .changeInputSource: "macOS uses the Globe key to change the input source."
        case .showEmojiAndSymbols: "macOS uses the Globe key to show Emoji & Symbols."
        case .startDictation: "macOS uses the Globe key to start Dictation."
        case .macOSDefault, .doNothing: "macOS uses the Globe key for its own shortcut."
        }
    }
}
