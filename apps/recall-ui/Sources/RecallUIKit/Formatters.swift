// Formatters.swift — pure-function presentation helpers.
//
// Kept in the testable library target (not the SwiftUI executable) so
// unit tests can pin the strings byte-exact without spinning a
// SwiftUI scene. All inputs are post-cascade `events` rows; no
// suppressed content can reach these helpers by construction
// (ADR-0016 §4.3 + ADR-0017 §5).

import Foundation

public enum Formatters {
    /// Render a stable, human-readable application name while keeping the
    /// original bundle identifier on the underlying event for provenance.
    public static func appDisplayName(_ bundleId: String?) -> String {
        guard let bundleId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleId.isEmpty,
              let component = bundleId.split(separator: ".").last,
              !component.isEmpty
        else {
            return "Unknown app"
        }

        let exactNames = [
            "com.apple.finder": "Finder",
            "com.apple.safari": "Safari",
            "com.apple.terminal": "Terminal",
            "com.github.githubclient": "GitHub",
            "com.microsoft.vscode": "VS Code",
            "com.tinyspeck.slackmacgap": "Slack",
        ]
        if let name = exactNames[bundleId.lowercased()] {
            return name
        }

        let componentNames = [
            "chrome": "Chrome",
            "github": "GitHub",
            "linear": "Linear",
            "notion": "Notion",
            "safari": "Safari",
            "slack": "Slack",
            "terminal": "Terminal",
            "vscode": "VS Code",
            "xcode": "Xcode",
        ]
        if let name = componentNames[component.lowercased()] {
            return name
        }

        let words = component
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return "Unknown app" }
        return words.map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    /// Snippet truncation — keeps the recall-list cell from rendering
    /// megabytes of OCR text if a runaway event slipped past the FFI
    /// cap (the FFI itself caps at 280 chars; this is defense-in-depth).
    public static func snippet(_ s: String, maxLen: Int = 280) -> String {
        guard maxLen >= 4 else { return String(s.prefix(maxLen)) }
        if s.count <= maxLen { return s }
        let head = s.prefix(maxLen - 1)
        return "\(head)…"
    }

    /// Convert microseconds-since-epoch to a stable Y-M-D HH:MM:SS string
    /// in UTC. The recall-ui v1 displays UTC; per-user time-zone
    /// presentation is Phase 4 (ADR-0017) onboarding-UX scope.
    public static func tsString(usSinceEpoch: UInt64) -> String {
        let secs = Double(usSinceEpoch) / 1_000_000.0
        let d = Date(timeIntervalSince1970: secs)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        return df.string(from: d) + " UTC"
    }

    /// One-line label used in the recall list cell. Compact and content-
    /// minimal — human-readable app name, then the title or URL when
    /// present. Never includes the OCR text.
    public static func contextLine(_ hit: Hit) -> String {
        let app = appDisplayName(hit.appBundleId)
        if let t = hit.windowTitle, !t.isEmpty {
            return "\(app) — \(t)"
        }
        if let u = hit.url, !u.isEmpty {
            return "\(app) — \(u)"
        }
        return app
    }

    /// Compact source-derived body shown under visual evidence previews.
    /// Context headers and OCR whitespace churn are presentation-only noise;
    /// the canonical stored event remains unchanged.
    public static func evidenceSummary(_ hit: Hit, maxLen: Int = 120) -> String {
        let body = stripContextHeader(hit.ocrTextSnippet)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard !body.isEmpty else { return "Visual evidence" }
        return snippet(body, maxLen: maxLen)
    }

    /// Render the source tag the row was retrieved with into a short
    /// display label. Keep the strings stable — tests assert on them.
    ///
    /// **Legacy — kept for tests / debug UIs.** The user-facing recall list
    /// now renders `matchReason(_:)` instead so users see plain English
    /// ("Matched: meaning") rather than engineer jargon ("hyb"). Cycle
    /// 8.36 PR-2 (`docs/research/2026-07-12-recall-ui-audit.md` §5, G6).
    public static func sourceTag(_ s: String) -> String {
        switch s {
        case "lexical": return "lex"
        case "hybrid": return "hyb"
        case "hybrid-related", "semantic-related": return "related"
        case "hybrid-conflict": return "conflict"
        case "timeline": return "time"
        default: return s
        }
    }

    /// Plain-English "why did this match?" label for the recall list.
    /// Maps the internal source tag to a user-facing string; returns `nil`
    /// for `"timeline"` (chronological rows have no match reason worth
    /// showing — the timestamp already communicates provenance) and for
    /// unknown sources (forward-compat: a future retrieval mode shouldn't
    /// leak raw jargon into the UI).
    ///
    /// - `"lexical"` → `"Matched: text"` (BM25 / FTS5 keyword match)
    /// - `"hybrid"` → `"Matched: meaning"` after evidence verification
    /// - `"hybrid-related"` / `"semantic-related"` → unverified related context
    /// - `"hybrid-conflict"` → evidence the verifier marked contradictory
    /// - `"timeline"` → `nil`
    /// - unknown → `nil`
    ///
    /// Cycle 8.36 PR-2 per `docs/research/2026-07-12-recall-ui-audit.md`
    /// §5 / G6 / §7 WOW moment.
    public static func matchReason(_ s: String) -> String? {
        switch s {
        case "lexical": return "Matched: text"
        case "hybrid": return "Matched: meaning"
        case "hybrid-related", "semantic-related": return "Related by meaning"
        case "hybrid-conflict": return "Conflicting evidence"
        case "timeline": return nil
        default: return nil
        }
    }

    // MARK: - Entity chip overflow
    //
    // `HitRow` renders the hit's `entities` as pill chips. When the hit
    // has many mentions we cap the visible chips and show a `"+N more"`
    // affordance so a single row never grows past two lines and stays
    // keyboard-scannable. The math is a pure function so tests can pin it
    // without spinning a SwiftUI scene.

    /// Result of applying the visible-chip cap to a hit's entity list.
    /// - `visible` — the entity names to render as chips (in original order).
    /// - `overflow` — how many additional entities are hidden; `0` when
    ///   nothing was truncated. Render a `"+N more"` chip when > 0.
    public struct EntityChipDisplay: Equatable, Sendable {
        public let visible: [String]
        public let overflow: Int
        public init(visible: [String], overflow: Int) {
            self.visible = visible
            self.overflow = overflow
        }
    }

    /// Default cap: at most 5 chips render inline before the row falls
    /// back to the `"+N more"` affordance. Matches the audit-doc spec
    /// (§5 PR-2 mentions "cap ~5") and keeps the row layout stable at
    /// standard window widths.
    public static let entityChipCap: Int = 5

    /// Split `entities` into `visible` (first N) + `overflow` count.
    /// Preserves the original order; ignores duplicates on purpose (the
    /// upstream FFI already de-dupes — see `enrich_hit` in
    /// `adapters/macos/mci-brain-ffi/src/lib.rs`).
    public static func entityChipDisplay(
        _ entities: [String],
        cap: Int = entityChipCap
    ) -> EntityChipDisplay {
        guard cap > 0 else {
            return EntityChipDisplay(visible: [], overflow: entities.count)
        }
        if entities.count <= cap {
            return EntityChipDisplay(visible: entities, overflow: 0)
        }
        let visible = Array(entities.prefix(cap))
        return EntityChipDisplay(
            visible: visible,
            overflow: entities.count - cap
        )
    }

    /// Content-free "N related" label for the linked-event badge on
    /// `HitRow`. Returns `nil` for an empty list so the caller can skip
    /// rendering the badge entirely. Singular/plural aware.
    public static func linkedBadge(_ linkedEventIds: [UInt64]) -> String? {
        let n = linkedEventIds.count
        if n == 0 { return nil }
        if n == 1 { return "1 related" }
        return "\(n) related"
    }

    /// Relative time display: "just now", "3 min ago", "2 hours ago", etc.
    /// Falls back to absolute UTC string for dates older than 30 days.
    /// The `now` parameter exists for testability.
    public static func relativeTime(usSinceEpoch: UInt64, now: Date = Date()) -> String {
        let secs = Double(usSinceEpoch) / 1_000_000.0
        let date = Date(timeIntervalSince1970: secs)
        let diff = now.timeIntervalSince(date)
        guard diff >= 0 else { return tsString(usSinceEpoch: usSinceEpoch) }
        if diff < 60 { return "just now" }
        if diff < 3600 {
            let m = Int(diff / 60)
            return "\(m) min ago"
        }
        if diff < 86400 {
            let h = Int(diff / 3600)
            return h == 1 ? "1 hour ago" : "\(h) hours ago"
        }
        if diff < 172800 { return "yesterday" }
        let d = Int(diff / 86400)
        if d < 30 { return "\(d) days ago" }
        return tsString(usSinceEpoch: usSinceEpoch)
    }

    /// Score → percent string with one decimal, or empty for nil.
    public static func scoreString(_ s: Float?) -> String {
        guard let s else { return "" }
        // Clamp into [0,1]; the FFI is already in this range but a hostile
        // wire change shouldn't blow up the UI.
        let clamped = max(0.0, min(1.0, s))
        return String(format: "%.1f%%", clamped * 100.0)
    }

    // MARK: - Context-header strip + source label
    //
    // `brain_ingest::compose_context_header` (apps/agent/src/brain_ingest.rs)
    // prepends `[app=… | title=… | url=… | ts=…]\n` to every event's
    // `text_snippet` so the FTS5 index can match on the structured
    // metadata via lexical queries (`url=railway`, `app=Safari`, …). The
    // prefix is load-bearing for search and MUST stay in the stored
    // field — we strip it only at display time so the user sees the
    // body, not the redundant header that the URL chip + app row
    // already render above it.

    /// Regex matching the leading ADR-0010 §1.3 context header on
    /// `text_snippet`. Anchored at start, requires the four `|`-
    /// separated tokens in order (app/title/url/ts), and consumes the
    /// trailing `]\n`. Each value field forbids `\n` so a malformed or
    /// body-resembling line cannot eat into the actual content.
    private static let contextHeaderPattern =
        #"^\[app=[^\n]*? \| title=[^\n]*? \| url=[^\n]*? \| ts=[^\n]*?\]\n?"#

    private static let contextHeaderRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: contextHeaderPattern)

    /// Strip the leading `[app=… | title=… | url=… | ts=…]\n` header
    /// from a `text_snippet` for display. The stored field is unchanged
    /// (FTS5 still indexes the prefix). When the input does not start
    /// with a fully-formed header, returns the input verbatim.
    public static func stripContextHeader(_ s: String) -> String {
        guard let regex = contextHeaderRegex else { return s }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard
            let match = regex.firstMatch(in: s, range: range),
            match.range.location == 0
        else {
            return s
        }
        return ns.substring(from: match.range.length)
    }

    /// Source-aware label for the event-card body, classified from the
    /// `(url, text_snippet)` shape after the context header is
    /// stripped. PageContentEvents (from the Safari `.appex` /
    /// Chromium native host) carry both a URL and a body; OCREvents
    /// (from the SCStream Vision path) carry a body but no URL;
    /// browser-URL-change events carry a URL but no body.
    public static func sourceLabel(url: String?, textSnippet: String) -> String {
        let hasUrl = !(url?.isEmpty ?? true)
        let hasText = !stripContextHeader(textSnippet).isEmpty
        switch (hasUrl, hasText) {
        case (true, true): return "Page Content"
        case (false, true): return "OCR Text"
        case (true, false): return "Browser URL"
        case (false, false): return "Event"
        }
    }
}
