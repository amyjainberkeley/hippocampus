// Formatters.swift — pure-function presentation helpers.
//
// Kept in the testable library target (not the SwiftUI executable) so
// unit tests can pin the strings byte-exact without spinning a
// SwiftUI scene. All inputs are post-cascade `events` rows; no
// suppressed content can reach these helpers by construction
// (ADR-0016 §4.3 + ADR-0017 §5).

import CMciBrainFFI
import Foundation

public enum Formatters {
    /// Render a stable, human-readable application name while keeping the
    /// original bundle identifier on the underlying event for provenance.
    ///
    /// The names come from the reader's one table (`mci_brain::apps::name`,
    /// through `mci_brain_ffi_app_name`), the one captions use too, so the
    /// app named under a row and in its caption always agree.
    public static func appDisplayName(_ bundleId: String?) -> String {
        guard let bundleId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleId.isEmpty,
              let raw = bundleId.withCString({ mci_brain_ffi_app_name($0) })
        else {
            return "Unknown app"
        }
        defer { mci_brain_ffi_string_free(raw) }
        let name = String(cString: raw)
        return name.isEmpty ? "Unknown app" : name
    }

    /// Whether `scalar` is a mark an app puts before a window's title: a
    /// status or progress glyph (✳, a braille spinner, ●, ⏺), as the reader
    /// leaves them out (`chrome::is_title_mark`).
    public static func isTitleMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2A, 0xB7, 0x2022, 0x2027, 0x2219, 0x22C5, 0x23E9...0x23FA, 0x25A0...0x25FF,
             0x2600...0x27BF, 0x2800...0x28FF, 0x2B50...0x2B55, 0x1F300...0x1FAFF:
            return true
        default:
            return scalar.properties.isWhitespace
        }
    }

    /// A window title without the status marks an app puts before it: "✳ Fix
    /// rounding" and "⠐ Fix rounding" are one title.
    public static func titleWithoutMarks(_ title: String) -> String {
        let scalars = title.unicodeScalars.drop(while: isTitleMark)
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line of what a window said, for a list row: the first line of
    /// its text with any stored header removed, skipping a first line that
    /// only repeats the window's title ("Pricing page draft" under the title
    /// "Pricing page draft") when another line follows.
    public static func rowLine(_ text: String, title: String?, maxLen: Int = 160) -> String {
        let lines = stripContextHeader(text)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return "" }
        let heading = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lines.count > 1, !heading.isEmpty, heading.hasPrefix(first.lowercased()) {
            return snippet(lines[1], maxLen: maxLen)
        }
        return snippet(first, maxLen: maxLen)
    }

    /// Up to two lines' worth of what the window said, for a row: its lines
    /// (`previewLines`: no stored header, and no leading line that only
    /// repeats the title, names a time or labels a heading) run together, at
    /// most `maxLen` characters. The row shows it in at most two lines.
    ///
    /// A search's passage (`isPassage`) keeps its leading lines but a first
    /// one the title starts with: the words it was found by may be in them.
    ///
    /// A line that ends a sentence, one the next line goes on from (it
    /// starts in lower case), or one a list's item follows ("• Monthly
    /// revenue …", "2. Ship it") is followed by a space; any other line
    /// break reads as " · ", so a heading or a name never runs into what
    /// follows it ("Maya Chen 10:42 AM · Pushed the new onboarding flow"),
    /// and a list's own mark never gets a second one.
    ///
    /// A preview longer than `maxLen` stops at its last whole word that
    /// fits, with "…". The start of a moment's text that the FFI cut at
    /// `rowTextCap` ends mid-word too: a preview that runs to that end stops
    /// at its last whole word, with "…". (A search's passage is cut by
    /// bytes, and for a chat or a terminal at its start, so its end is left
    /// as it came.)
    public static func rowPreview(_ text: String, title: String?, maxLen: Int = 220,
                                  isPassage: Bool = false) -> String {
        let lines = isPassage ? passageLines(text, title: title) : previewLines(text, title: title)
        var joined = ""
        var previous = ""
        var toTheEnd = true
        for line in lines {
            if joined.count >= maxLen {
                toTheEnd = false
                break
            }
            if joined.isEmpty {
                joined = line
                previous = line
                continue
            }
            let ended = joined.last.map { ".?!:;,".contains($0) } ?? false
            let goesOn = line.first?.isLowercase ?? false
            // A name and a time over a message never run into it, nor the
            // message before into them: "Sam Lee 2:02 PM · can you look at
            // the tax test? · Priya Shah 2:05 PM · on it".
            let speaker = endsWithClockTime(previous) || endsWithClockTime(line)
            let joins = !speaker && (ended || goesOn || startsAListItem(line))
            joined += (joins ? " " : " \u{00B7} ") + line
            previous = line
        }
        if !toTheEnd || joined.count > maxLen {
            return cutAtAWholeWord(joined, maxLen: maxLen)
        }
        // Counted as the FFI counts its cap: in Unicode scalars, Rust's
        // `char`s. A rating's "⭐️" or a flag is two of them in one Character.
        if !isPassage, text.unicodeScalars.count >= rowTextCap {
            return endingAtAWholeWord(joined)
        }
        return joined
    }

    /// `text` cut to fit `maxLen`, "…" included: up to its last whole word
    /// that fits, or at the limit when its first word alone is longer.
    static func cutAtAWholeWord(_ text: String, maxLen: Int) -> String {
        guard maxLen >= 4 else { return String(text.prefix(maxLen)) }
        let head = String(text.prefix(maxLen - 1))
        let next = text.dropFirst(head.count).first
        if head.last?.isWhitespace ?? false || next?.isWhitespace ?? true {
            // The cut fell between two words.
            return head.trimmingCharacters(in: looseEnd) + "\u{2026}"
        }
        return endingAtAWholeWord(head)
    }

    /// The most characters of a moment's text the FFI gives a row:
    /// `SNIPPET_CHAR_CAP` in adapters/macos/mci-brain-ffi/src/lib.rs, counted
    /// in Unicode scalars (Rust's `char`s). A text this long was cut there,
    /// wherever that fell, mid-word too.
    public static let rowTextCap = 280

    /// `text` up to its last whole word, then "…": what a row shows of a
    /// text cut short. A text of one word keeps it.
    static func endingAtAWholeWord(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.lastIndex(where: \.isWhitespace) else { return trimmed + "\u{2026}" }
        let kept = trimmed[..<space].trimmingCharacters(in: looseEnd)
        return (kept.isEmpty ? trimmed : kept) + "\u{2026}"
    }

    /// What a cut never leaves hanging before its "…": spaces, a separator
    /// or a comma.
    private static let looseEnd = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{00B7},;:"))

    /// A line a list's mark starts: "•", "◦", "▪", "‣", "-", "–" or "*" and
    /// a space, or a number and "." or ")" and a space ("2. Ship it").
    static func startsAListItem(_ line: String) -> Bool {
        if let mark = line.first, "\u{2022}\u{25E6}\u{25AA}\u{2023}-\u{2013}*".contains(mark) {
            return line.dropFirst().first == " "
        }
        let digits = line.prefix(while: \.isASCII).prefix(while: \.isNumber)
        guard (1...3).contains(digits.count) else { return false }
        let rest = line.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    /// Whether a line ends in a clock time, as a chat's name over a message
    /// does ("Sam Lee 2:02 PM", "Priya Shah 14:05").
    public static func endsWithClockTime(_ line: String) -> Bool {
        let tokens = line.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let last = tokens.last else { return false }
        if ["am", "pm"].contains(last), tokens.count >= 2 {
            return isClockTime(tokens[tokens.count - 2])
        }
        return isClockTime(last)
    }

    /// A search result's address line, as a search page shows it under a
    /// result's title: "pricingnotes.example › team-plans".
    public static func isCitation(_ line: String) -> Bool {
        let parts = line.components(separatedBy: " \u{203A} ")
        guard parts.count >= 2, let host = parts.first?.trimmingCharacters(in: .whitespaces) else { return false }
        let hostLike = !host.contains(" ") && host.contains(".") && host.contains(where: \.isLetter)
            || host.hasPrefix("https://") || host.hasPrefix("http://")
        return hostLike && parts.dropFirst().allSatisfy { $0.split(whereSeparator: \.isWhitespace).count <= 4 }
    }

    /// The lines a row's preview is made from: the stored header left out,
    /// runs of spaces as one, and while another line follows, the lines that
    /// lead it without saying more than the row already does (at most
    /// three): the window's own name read off the screen, a day or a time
    /// alone on its line, and, unless `keepingLabels` (a terminal's or code's
    /// own lines), a short label in capitals over a page's heading ("MONEY &
    /// ROUNDING").
    public static func previewLines(_ text: String, title: String?, keepingLabels: Bool = false) -> [String] {
        var lines = stripContextHeader(text)
            .split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty && !isCitation($0) }
        var dropped = 0
        while dropped < 3, lines.count > 1, let first = lines.first,
              repeatsTitle(first, title: title) || isDayOrTime(first) || (!keepingLabels && isLabel(first)) {
            lines.removeFirst()
            dropped += 1
        }
        return lines
    }

    /// A search passage's lines: no stored header, runs of spaces as one, and
    /// a first line the title starts with left out while another follows.
    private static func passageLines(_ text: String, title: String?) -> [String] {
        var lines = stripContextHeader(text)
            .split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty && !isCitation($0) }
        let heading = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lines.count > 1, let first = lines.first, !heading.isEmpty, heading.hasPrefix(first.lowercased()) {
            lines.removeFirst()
        }
        return lines
    }

    /// A short label in capitals: letters, none of them lower case, in at
    /// most five words ("MONEY & ROUNDING", "OPINION").
    public static func isLabel(_ line: String) -> Bool {
        let words = line.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) }
        return (1...5).contains(words.count)
            && line.contains(where: \.isLetter)
            && !line.contains(where: \.isLowercase)
    }

    /// Whether `line` only repeats the window's title: the title starts with
    /// it, or each of its words is a word of the title, leaving out the icons
    /// and single letters a toolbar is read as ("Q4 planning \u{2606}" under
    /// "Q4 planning - Google Docs", a search box under its results page).
    public static func repeatsTitle(_ line: String, title: String?) -> Bool {
        let heading = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !heading.isEmpty else { return false }
        if heading.hasPrefix(line.lowercased()) { return true }
        let said = words(line)
        return !said.isEmpty && said.isSubset(of: words(heading))
    }

    /// The words of a line as `repeatsTitle` compares them: lower case,
    /// without the punctuation and symbols around them, two characters or
    /// more, each with a letter or a digit.
    private static func words(_ text: String) -> Set<String> {
        let edges = CharacterSet.punctuationCharacters.union(.symbols)
        return Set(text.lowercased().split(whereSeparator: \.isWhitespace).compactMap { token -> String? in
            let word = token.trimmingCharacters(in: edges)
            guard word.count > 1, word.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return word
        })
    }

    private static let dayWords: Set<String> = [
        "today", "yesterday", "tomorrow", "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday", "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
    ]

    private static let monthWords: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september",
        "october", "november", "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep",
        "sept", "oct", "nov", "dec",
    ]

    /// A day or a time alone on its line, as a chat shows one over its
    /// messages: "Today 2:21 PM", "Yesterday", "Mon, Oct 12 at 2:21 PM". It
    /// names a day or a clock time; a month and a year alone ("May 2026")
    /// are a heading, not a time.
    public static func isDayOrTime(_ line: String) -> Bool {
        let tokens = line.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.")) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty, tokens.count <= 8 else { return false }
        var namesATime = false
        for token in tokens {
            if dayWords.contains(token) || isClockTime(token) {
                namesATime = true
            } else if !(monthWords.contains(token) || ["at", "am", "pm", "a.m", "p.m", "\u{00B7}"].contains(token)
                        || token.allSatisfy(\.isNumber)) {
                return false
            }
        }
        return namesATime
    }

    /// "2:21", "14:05", "2:21pm".
    private static func isClockTime(_ token: String) -> Bool {
        var clock = Substring(token)
        for suffix in ["am", "pm"] where clock.hasSuffix(suffix) {
            clock = clock.dropLast(suffix.count)
        }
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        return (2...3).contains(parts.count)
            && (1...2).contains(parts[0].count)
            && parts.dropFirst().allSatisfy { $0.count == 2 }
            && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// "Oct 12, 2:36 PM" in the person's locale: when a moment was, for
    /// rows and details that can come from any day.
    public static func dayAndTime(
        us: UInt64,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        style.locale = locale
        style.timeZone = timeZone
        return Date(timeIntervalSince1970: Double(us) / 1_000_000).formatted(style)
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
    /// - `"lexical"` → `"Exact words"` (BM25 / FTS5 keyword match)
    /// - `"hybrid"` → `"Similar meaning"` after evidence verification
    /// - `"hybrid-related"` / `"semantic-related"` → `"Related"`
    /// - `"hybrid-conflict"` → `"Says something different"`
    /// - `"timeline"` → `nil`
    /// - unknown → `nil`
    ///
    /// Cycle 8.36 PR-2 per `docs/research/2026-07-12-recall-ui-audit.md`
    /// §5 / G6 / §7 WOW moment.
    public static func matchReason(_ s: String) -> String? {
        switch s {
        case "lexical": return "Exact words"
        case "hybrid": return "Similar meaning"
        case "hybrid-related", "semantic-related": return "Related"
        case "hybrid-conflict": return "Says something different"
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

    /// A clock time in the person's own format ("2:09 PM", "14:09"). The agent
    /// never writes one into text; it sends microseconds (RULINGS I4).
    public static func clockTime(
        us: Int64,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                     calendar: calendar, timeZone: timeZone)
        return Date(timeIntervalSince1970: Double(us) / 1_000_000).formatted(style)
    }

    /// An hour in the person's own format ("3 PM", "15"): History's heading
    /// over moments in no session, and the day strip's ticks.
    public static func clockHour(
        us: Int64,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone).hour()
        return Date(timeIntervalSince1970: Double(us) / 1_000_000).formatted(style)
    }

    /// A length of time through the system formatter, abbreviated, in hours
    /// and minutes, rounded to the nearest minute and never under one
    /// ("5h 30m", "12m") (RULINGS V).
    public static func duration(us: Int64, locale: Locale = .autoupdatingCurrent) -> String {
        let minutes = max(1, Int((Double(max(0, us)) / 60_000_000).rounded()))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes)m"
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
