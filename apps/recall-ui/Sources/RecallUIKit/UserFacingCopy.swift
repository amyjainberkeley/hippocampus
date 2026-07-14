// UserFacingCopy.swift — canonical plain-English copy for user-facing
// error and status strings.
//
// Cycle 8.54 product-readiness audit polish gap #2 fix — "Cryptic
// engineer-jargon in user-facing error strings" (see
// `docs/research/2026-07-13-copy-audit.md` +
// `docs/design/copy-style-guide.md`). Every string here replaces a
// prior string that either exposed a raw `\(error)`, leaked an
// internal identifier ("brain", "helper", "mci-agent", "SCStream"),
// or apologized without naming a next action.
//
// The internal thrown `BrainReaderError` values are unchanged — they
// remain engineer-facing (log + crash reports). Only the strings a
// user actually reads are rewritten.

import Foundation

/// Canonical user-facing copy strings. Every entry is enumerated in
/// `CopyStyleTests` and grep-linted against the copy style guide:
/// (1) no raw error codes, (2) no engineer jargon, (3) failures name
/// a next action.
public enum UserFacingCopy {

    // Memory (brain) unreachable — used by SearchView, EpisodesView,
    // TimelineView, PrivacyMomentsView. Prior copy was
    // "Couldn't open your brain".
    public static let memoryUnreachableTitle =
        "Hippocampus can\u{2019}t reach your local memory right now"
    public static let memoryUnreachableBody =
        "Try relaunching Hippocampus, or open the Privacy Dashboard "
        + "to check its status."
    public static let openHippocampusAction = "Open Hippocampus"

    // Brief / timeline / event-detail load failures. Reassuring body
    // ("Your captures are safe") replaces the prior raw `\(error)`.
    public static let briefLoadFailedTitle = "This brief didn\u{2019}t load"
    public static let timelineLoadFailedTitle = "Your timeline didn\u{2019}t load"
    public static let loadFailedBody =
        "Your captures are safe — this was a display hiccup. "
        + "Try again in a moment."
    public static let eventDetailFailedTitle =
        "This event\u{2019}s details didn\u{2019}t load"

    /// Stale-event body — replaces "Event no longer in brain (may
    /// have been suppressed)." Uses "marked private" as the
    /// user-visible synonym for our internal redaction/denylist path.
    public static let eventNoLongerAvailable =
        "This event isn\u{2019}t available anymore — it may have "
        + "been deleted or marked private."

    // Privacy Dashboard mutations — reassuring copy + next action.
    public static let deleteFailedBanner =
        "Delete didn\u{2019}t go through. Nothing was removed — "
        + "your captures are unchanged. Try again in a moment."
    public static let dashboardLoadFailedBanner =
        "The Privacy Dashboard couldn\u{2019}t load right now. "
        + "Try relaunching Hippocampus."
    public static let exportFailedBanner =
        "Export didn\u{2019}t finish. Check that your Downloads "
        + "folder has free space, then try again."
    public static let auditExportFailedBanner =
        "Activity-log export didn\u{2019}t finish. Check that your "
        + "Downloads folder has free space, then try again."

    // Custom-names editor.
    public static func customNamesValidationFailed(_ detail: String) -> String {
        "Couldn\u{2019}t save your custom names — \(detail)"
    }
    public static func customNamesParseFailed(_ detail: String) -> String {
        "Couldn\u{2019}t read the custom-names file — \(detail)"
    }
    public static let customNamesWriteFailed =
        "Couldn\u{2019}t save to disk. Check that Hippocampus has "
        + "permission to write to your Application Support folder."
    public static let unexpectedErrorGeneric =
        "Something went wrong. Try again — if it keeps happening, "
        + "use \u{201C}Send Feedback\u{201D} from the menu bar."

    // Menu-bar & MCP registration.
    public static let tccRevokedNotificationTitle =
        "Hippocampus paused capture"
    public static let mcpAgentMissing =
        "Hippocampus can\u{2019}t find its Claude Code connector. "
        + "Try reinstalling Hippocampus."
    public static let mcpRegisterFailed =
        "Couldn\u{2019}t connect to Claude Code. Try again — if it "
        + "keeps happening, use \u{201C}Send Feedback\u{201D}."

    /// PrivacyDashboard fresh-brain empty-state title. "brain" →
    /// "memory" (see MCIEmptyState.noPrivacyEvents).
    public static let emptyPrivacyEventsFreshTitle = "Your memory is empty"
}

// MARK: - Copy-style validators (referenced by CopyStyleTests)

public enum CopyStyleValidator {
    /// Matches `-3815`-style codes, `errno=NNN`, `code=NNN`, and
    /// hex ids like `0x2A`. See copy-style-guide §2.
    public static func containsRawErrorCode(_ text: String) -> Bool {
        let patterns = [
            #"\B-\d{3,}\b"#,
            #"\berrno\s*[=:]\s*-?\d+"#,
            #"\bcode\s*[=:]\s*-?\d+"#,
            #"\b0x[0-9A-Fa-f]{2,}\b"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Jargon banned from user-facing copy. See copy-style-guide §3.
    public static let bannedJargon: [String] = [
        "SCStream", "TCC", "MCP", "FFI", "denylist",
        "cascade", "helper", "SQLCipher", "sentinel",
    ]

    public static func containsJargon(_ text: String) -> String? {
        let lower = text.lowercased()
        return bannedJargon.first { lower.contains($0.lowercased()) }
    }
}
