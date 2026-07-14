// ChangelogParser.swift — pure parser for the auto-generated
// CHANGELOG.md that ships in the .app bundle at
// Contents/Resources/CHANGELOG.md (baked by scripts/build-app.sh).
//
// # Why in RecallUIKit
//
// The "What's new" release-notes modal lives in `RecallUI/WhatsNew/`.
// This parser is the pure-logic split (mirrors `ActionPanelCore.swift`
// vs `ActionPanel/ActionPanel.swift`) so `RecallUIKitTests` can pin
// well-formed + malformed CHANGELOG inputs without linking the
// executable or importing SwiftUI. No network, no filesystem in this
// file — callers pass in the Markdown source as a `String`.
//
// # CHANGELOG shape (from scripts/gen-changelog.sh — PR #96)
//
//     ## [Unreleased] — 2026-07-13
//
//     _Range: main~100..HEAD · 97 commit(s) categorized._
//
//     ### ✨ Features
//
//     - **recall-ui:** … (`hash` · [#N](../../pull/N))
//     - …
//
//     ### 🐛 Bug fixes
//
//     - …
//
// # Degradation contract
//
// Malformed input degrades to an empty release rather than crashing.
// The modal is a "nice to have" surface — a garbled entry must never
// take down the recall-ui launch path. Individual bullet lines that
// don't fit the pattern are kept as-is so the user still sees them.

import Foundation

/// One parsed CHANGELOG entry, keyed by version.
public struct ChangelogRelease: Equatable, Sendable {
    /// Version string as it appears in the header, e.g. `"1.0.0"` or
    /// `"Unreleased"`. Kept as a plain `String` — semantic-version
    /// comparison happens outside the parser.
    public let version: String
    /// Release date (`YYYY-MM-DD`) if present in the header; nil for
    /// headers without a date.
    public let date: String?
    /// Sections in the order they appear in the source (Features →
    /// Fixes → Docs → …). Preserves author ordering — the modal
    /// renders them top-to-bottom.
    public let sections: [Section]

    public struct Section: Equatable, Sendable {
        public let title: String
        public let items: [String]

        public init(title: String, items: [String]) {
            self.title = title
            self.items = items
        }
    }

    public init(version: String, date: String?, sections: [Section]) {
        self.version = version
        self.date = date
        self.sections = sections
    }

    /// True when there is nothing to render — used by the modal to
    /// choose between the normal layout and the "no notes available"
    /// fallback copy.
    public var isEmpty: Bool {
        sections.allSatisfy { $0.items.isEmpty }
    }
}

/// Stateless parser. All entry points are static — no instance state.
public enum ChangelogParser {
    /// Parse the entire CHANGELOG.md source into an ordered list of
    /// releases (newest → oldest, matching the source ordering).
    /// Returns `[]` on completely malformed input.
    public static func parseAll(_ source: String) -> [ChangelogRelease] {
        var releases: [ChangelogRelease] = []
        var currentVersion: String?
        var currentDate: String?
        var currentSections: [ChangelogRelease.Section] = []
        var currentSectionTitle: String?
        var currentItems: [String] = []

        func flushSection() {
            if let title = currentSectionTitle, !currentItems.isEmpty {
                currentSections.append(.init(title: title, items: currentItems))
            }
            currentSectionTitle = nil
            currentItems = []
        }

        func flushRelease() {
            flushSection()
            if let v = currentVersion {
                releases.append(.init(
                    version: v,
                    date: currentDate,
                    sections: currentSections
                ))
            }
            currentVersion = nil
            currentDate = nil
            currentSections = []
        }

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("## "), let (version, date) = parseVersionHeader(line) {
                flushRelease()
                currentVersion = version
                currentDate = date
                continue
            }

            // Skip until we've seen a version header. This drops the
            // top-of-file "# Changelog" title + prose introduction.
            guard currentVersion != nil else { continue }

            if line.hasPrefix("### ") {
                flushSection()
                currentSectionTitle = stripSectionTitle(line)
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let item = String(line.dropFirst(2))
                currentItems.append(item)
                continue
            }
        }

        flushRelease()
        return releases
    }

    /// Convenience: look up a specific version in the parsed output.
    /// Matches on the exact `version` string first, and falls back to
    /// a case-insensitive equality (so `"unreleased"` finds
    /// `"Unreleased"`).
    public static func release(
        forVersion version: String,
        in source: String
    ) -> ChangelogRelease? {
        let all = parseAll(source)
        if let exact = all.first(where: { $0.version == version }) {
            return exact
        }
        return all.first { $0.version.caseInsensitiveCompare(version) == .orderedSame }
    }

    // MARK: - Line-level helpers

    /// Parse `## [X.Y.Z] — YYYY-MM-DD` (or `## [Unreleased]`, or
    /// variations with `-`/`—`/space). Returns nil if the shape
    /// doesn't look like a version header, so the caller can treat
    /// that line as prose.
    ///
    /// The bracketed form is required — plain `## Foo` headers are
    /// intentionally ignored so we don't accidentally treat a section
    /// title from CONTRIBUTING.md-style prose as a release.
    static func parseVersionHeader(_ line: String) -> (version: String, date: String?)? {
        // Strip the leading "## ".
        var rest = line
        rest.removeFirst(3)
        rest = rest.trimmingCharacters(in: .whitespaces)

        guard rest.hasPrefix("[") else { return nil }
        guard let closeIdx = rest.firstIndex(of: "]") else { return nil }
        let version = String(rest[rest.index(after: rest.startIndex)..<closeIdx])
            .trimmingCharacters(in: .whitespaces)
        guard !version.isEmpty else { return nil }

        // Everything after the "]" — could be " — 2026-07-13", " -
        // 2026-07-13", " (2026-07-13)", or empty.
        let after = rest[rest.index(after: closeIdx)...]
        let date = extractDate(from: String(after))
        return (version, date)
    }

    /// Extract a `YYYY-MM-DD` date from a trailing header fragment.
    /// Uses a plain regex-free scan so we don't take a dependency on
    /// `NSRegularExpression` for a 10-char shape.
    static func extractDate(from fragment: String) -> String? {
        let chars = Array(fragment)
        // Look for the first 4-digit year.
        var i = 0
        while i + 9 < chars.count {
            if chars[i].isASCIIDigit,
               chars[i + 1].isASCIIDigit,
               chars[i + 2].isASCIIDigit,
               chars[i + 3].isASCIIDigit,
               chars[i + 4] == "-",
               chars[i + 5].isASCIIDigit,
               chars[i + 6].isASCIIDigit,
               chars[i + 7] == "-",
               chars[i + 8].isASCIIDigit,
               chars[i + 9].isASCIIDigit
            {
                return String(chars[i...(i + 9)])
            }
            i += 1
        }
        return nil
    }

    /// Strip the leading `### ` and any lone emoji so the section
    /// title in the modal reads as plain text (e.g. `"Features"`
    /// instead of `"✨ Features"`). Emoji-free titles pass through
    /// unchanged.
    static func stripSectionTitle(_ line: String) -> String {
        var title = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        // If the first "word" is a single non-alphanumeric grapheme
        // (i.e. an emoji), drop it plus the following space.
        if let firstSpace = title.firstIndex(of: " ") {
            let head = title[..<firstSpace]
            let isEmojiLike = head.unicodeScalars.allSatisfy { scalar in
                !scalar.properties.isAlphabetic && !("0"..."9").contains(Character(scalar))
            } && !head.isEmpty
            if isEmojiLike {
                title = String(title[title.index(after: firstSpace)...])
            }
        }
        return title
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
