// CopyStyleValidator.swift — the lint engine behind the launch copy guard.
//
// Kept apart from `UserFacingCopy` on purpose: this file names the words a
// trustworthy app avoids, so it is the one place those words legitimately
// appear as string literals. `scripts/check-launch-copy.sh` carries the same
// lists as the cross-app outside judge and skips this file for that reason.
// `CopyStyleTests` (window), `MenuBarCopyStyleTests` (menu bar) and
// `OnboardingCopyTests` (onboarding) run these rules string-by-string. See
// `reports/launch-kit/copy.md` and the copy audit in
// `docs/research/2026-07-13-copy-audit.md`.

import Foundation

public enum CopyStyleValidator {
    /// Matches `-3815`-style codes, `errno=NNN`, `code=NNN`, and
    /// hex ids like `0x2A`. See the copy style guide §2.
    public static func containsRawErrorCode(_ text: String) -> Bool {
        let patterns = [
            #"\B-\d{3,}\b"#,
            #"\berrno\s*[=:]\s*-?\d+"#,
            #"\bcode\s*[=:]\s*-?\d+"#,
            #"\b0x[0-9A-Fa-f]{2,}\b"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Jargon banned from user-facing copy. See the copy style guide §3.
    public static let bannedJargon: [String] = [
        "SCStream", "TCC", "MCP", "FFI", "denylist",
        "cascade", "helper", "SQLCipher", "sentinel",
    ]

    public static func containsJargon(_ text: String) -> String? {
        let lower = text.lowercased()
        return bannedJargon.first { lower.contains($0.lowercased()) }
    }

    // MARK: - Launch copy guard (professional, trustworthy tone)
    //
    // The words a trustworthy, Apple-quality app never writes: marketing
    // superlatives and the tells of machine-written copy. Kept deliberately
    // conservative — only words no honest status, help or empty-state string
    // needs — so the guard can run over every user-facing string without a
    // false positive.

    /// Marketing / machine-written words, matched whole-word (case-insensitive).
    public static let bannedMarketingWords: [String] = [
        "seamless", "seamlessly", "effortless", "effortlessly", "unlock",
        "supercharge", "supercharged", "magic", "magical", "delve", "powerful",
        "smart", "simply", "leverage", "utilize", "robust", "elevate", "empower",
        "unleash", "harness", "turbocharge", "frictionless", "revolutionary",
        "transformative", "hiccup", "oops", "whoops", "gotcha",
    ]

    /// Marketing phrases, matched as substrings (case-insensitive). "AI" alone
    /// is fine ("your AI", "AI Tools"); only the hype compound is banned.
    public static let bannedMarketingPhrases: [String] = [
        "ai-powered", "ai powered", "game-changer", "game changer",
        "cutting-edge", "cutting edge", "state-of-the-art", "state of the art",
        "blazing fast", "lightning fast", "world-class", "best-in-class",
        "next-generation",
    ]

    /// The first marketing word or phrase in `text`, or nil when it is clean.
    public static func containsMarketingSpeak(_ text: String) -> String? {
        let lower = text.lowercased()
        if let phrase = bannedMarketingPhrases.first(where: { lower.contains($0) }) {
            return phrase
        }
        let words = Set(lower.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        return bannedMarketingWords.first { words.contains($0) }
    }

    /// True when `text` shouts with an exclamation mark.
    public static func containsExclamation(_ text: String) -> Bool {
        text.contains("!")
    }

    /// True when `text` stacks two or more em-dashes. One spaced em-dash is
    /// fine; a pileup reads as machine-written.
    public static func hasEmDashPileup(_ text: String) -> Bool {
        text.filter { $0 == "\u{2014}" }.count >= 2
    }
}
