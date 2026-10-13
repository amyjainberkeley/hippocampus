import Foundation

/// What opens Ask right now, as the menu-bar app publishes it (RULINGS X2).
///
/// The window runs inside the app's bundle (`ai.hippocampus`), so it reads
/// the app's own defaults through `UserDefaults.standard` when it draws:
/// `ai.hippocampus.ask.effectiveLabel` and `.effectivePhrase`, which the app
/// writes whenever what works changes. An empty label means nothing opens
/// Ask. When the app has not written them, the key the person chose
/// (`ai.hippocampus.prefs.askKey`) stands in, named as the app names it.
public struct AskShortcutLabel: Equatable, Sendable {
    public static let effectiveLabelKey = "ai.hippocampus.ask.effectiveLabel"
    public static let effectivePhraseKey = "ai.hippocampus.ask.effectivePhrase"
    public static let askKeyKey = "ai.hippocampus.prefs.askKey"

    /// The key as a shortcut is shown ("⇧⇧", "right ⇧", "⌃⇧Space"); empty
    /// when nothing opens Ask.
    public let label: String
    /// The instruction ("Press Shift twice"); empty when nothing opens Ask.
    public let phrase: String

    public init(label: String, phrase: String) {
        self.label = label
        self.phrase = phrase
    }

    public var opensAsk: Bool { !label.isEmpty }

    /// Read at render time; nothing is cached.
    public static func current(defaults: UserDefaults = .standard) -> AskShortcutLabel {
        if let label = defaults.object(forKey: effectiveLabelKey) as? String {
            guard !label.isEmpty else { return AskShortcutLabel(label: "", phrase: "") }
            let phrase = defaults.string(forKey: effectivePhraseKey) ?? ""
            return AskShortcutLabel(label: label, phrase: phrase.isEmpty ? UserFacingCopy.askKeyPhrase(label) : phrase)
        }
        let chosen = defaults.string(forKey: askKeyKey) ?? ""
        let names = UserFacingCopy.askKeyNames[chosen] ?? UserFacingCopy.askKeyNames["shiftTwice"]!
        return AskShortcutLabel(label: names.label, phrase: names.phrase)
    }
}
