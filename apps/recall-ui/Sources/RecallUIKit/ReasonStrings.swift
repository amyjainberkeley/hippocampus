// ReasonStrings.swift — privacy-moment reason code → friendly string.
//
// Locked by ADR-0017 §5.2 table. The mapping is the recall-ui's single
// source of truth; Localizable.strings (Phase 4 polish) overrides at
// runtime if present, but the fallback in this map is the binding copy.
//
// Carrying any user content in a reason string is an ADR-0017 §5.1 +
// ADR-0016 §4.5 invariant regression. These strings are static English
// only — no formatting of bundle ids, window titles, URLs, or OCR text.

import Foundation

public enum PrivacyReason: UInt8, Sendable, CaseIterable, Equatable {
    /// 1: source-level denylist (ADR-0013 §1).
    case denylist = 1
    /// 2: DRM / blacked region (Apple TV, Netflix, etc.).
    case drm = 2
    /// 3: secure event input — password being typed.
    case secureEventInput = 3
    /// 4: AX secure text-field subrole — password field detected.
    case axSecureSubrole = 4
    /// 5: denylist drift — app left allowlist mid-capture.
    case denylistDrift = 5
    /// 6: OCR-time secret/PII regex hit (ADR-0013 §6).
    case ocrSecretRegex = 6
    /// 7: fail-closed catchall — app unknown, MCI refused by default.
    case failsafeUnknown = 7
    /// 8: user denylist (new Phase 4).
    case userDenylist = 8
    /// 9: incognito / private-window exclusion (new Phase 4).
    case incognitoExclusion = 9

    public init?(rawCode: UInt8) {
        self.init(rawValue: rawCode)
    }
}

public enum ReasonStrings {
    /// The ADR-0017 §5.2 friendly-string table, verbatim. Each entry
    /// is content-free: it talks about the cascade decision, never the
    /// data the cascade saw. COO copy review is eligible; until that
    /// PR lands these strings ARE the v1 copy.
    public static let table: [UInt8: String] = [
        1: "App was on the denylist.",
        2: "DRM-protected video (Apple TV, Netflix, etc.).",
        3: "Password being typed.",
        4: "Password field detected.",
        5: "App was being captured but moved to denylist.",
        6: "Text matched a secret/PII pattern.",
        7: "App was unknown — MCI refused by default.",
        8: "You asked MCI to ignore this.",
        9: "Incognito/private browser window.",
    ]
    /// Fallback for an unknown reason code (forward-compat: a future
    /// cascade reason 10 reaches a v1 binary the user hasn't updated
    /// yet). Still content-free.
    public static let unknown = "MCI redacted this. (reason unknown to this build)"

    public static func string(for code: UInt8) -> String {
        table[code] ?? unknown
    }

    public static func string(for reason: PrivacyReason) -> String {
        string(for: reason.rawValue)
    }

    /// A short tag string used in the card heading (e.g. "§4" badge).
    /// Matches the ADR-0013 / ADR-0017 §-numbering. Pure layout, no
    /// content, but lets the user cross-reference the privacy ladder
    /// without us having to print the full cascade rule on every card.
    public static func sectionTag(for code: UInt8) -> String {
        switch code {
        case 1: return "§1"
        case 2: return "§2"
        case 3: return "§3"
        case 4: return "§4"
        case 5: return "§5"
        case 6: return "§6"
        case 7: return "§7"
        case 8: return "§8 (user)"
        case 9: return "§9 (incognito)"
        default: return "§?"
        }
    }
}
