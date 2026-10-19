import Foundation

/// What a History row shows of a moment: what it was about as the headline,
/// one or two lines of what the window said, and where it was.
///
/// The caption ("Looking up how to type accents") comes from the FFI: the
/// one stored for the moment, or one made from its title. Without one, the
/// row reads as it did before: the window's name, its text, the app.
public enum MomentRowText {
    /// The longest caption shown, in characters (the store keeps at most 200).
    public static let maxCaptionCharacters = 200

    /// A caption as it may be shown: its first line, trimmed, with no header
    /// and no U+001E (RULINGS T14), at most `maxCaptionCharacters`. Nil when
    /// there is none.
    public static func caption(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let line = ReadableText.guarded(raw)
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty, line.count <= maxCaptionCharacters else { return nil }
        return line
    }

    /// The window's name: its title, else its address, else the app's name.
    public static func windowName(_ hit: Hit) -> String {
        if let title = hit.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let url = hit.url, !url.isEmpty { return url }
        return Formatters.appDisplayName(hit.appBundleId)
    }

    /// The headline: what the moment was about, or the window's name.
    public static func headline(_ hit: Hit) -> String {
        hit.caption ?? windowName(hit)
    }

    /// One or two lines of what the window said, without the stored header
    /// or a first line that only repeats the title.
    public static func preview(_ hit: Hit) -> String {
        Formatters.rowPreview(hit.ocrTextSnippet, title: hit.windowTitle, isPassage: isPassage(hit))
    }

    /// A search's row: its text is the passage around the words searched
    /// for, not the start of the moment (History's, a moment opened by id).
    static func isPassage(_ hit: Hit) -> Bool {
        !["recent", "timeline", "linked"].contains(hit.source)
    }

    /// Terminals, as the reader lists them (`TERMINAL_APPS` in
    /// core/brain/src/reading.rs): their text is kept as it was read.
    static let terminalApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty", "co.zeit.hyper",
    ]

    /// Code editors (`EDITOR_APPS` in core/brain/src/chrome.rs, and Xcode).
    static let codeEditors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "dev.zed.Zed", "com.sublimetext.4", "com.apple.dt.Xcode",
    ]

    /// A terminal's lines, or code's, one to a line as they were read: up to
    /// `limit` of them, each at most 160 characters. Run together they would
    /// read as one long sentence ("cargo test tax running 6 tests test …").
    /// Nil for every other moment, whose lines run together (`preview`), and
    /// for a search's row, whose passage holds the words it was found by.
    public static func codeLines(_ hit: Hit, limit: Int = 2) -> [String]? {
        guard !isPassage(hit), let app = hit.appBundleId else { return nil }
        let lines = Formatters.previewLines(hit.ocrTextSnippet, title: hit.windowTitle, keepingLabels: true)
        let isEditor = codeEditors.contains(app) || app.hasPrefix("com.jetbrains.")
        guard terminalApps.contains(app) || (isEditor && readsLikeCode(lines)) else { return nil }
        let shown = lines.prefix(max(1, limit))
            .map { Formatters.snippet(SyntaxHighlighter.plainBullets($0), maxLen: 160) }
        return shown.isEmpty ? nil : Array(shown)
    }

    /// Four in ten of the first lines read like code: they hold a bracket,
    /// a parenthesis, `;`, `=`, `<`, `>` or `::`, or end in `,` or `:`
    /// (the reader's own test for a preformatted block).
    private static func readsLikeCode(_ lines: [String]) -> Bool {
        let sample = lines.prefix(8)
        guard !sample.isEmpty else { return false }
        let code = sample.filter { line in
            line.contains(where: { "{}();=<>[]".contains($0) }) || line.contains("::")
                || line.hasSuffix(",") || line.hasSuffix(":")
        }.count
        return code * 10 >= sample.count * 4
    }

    /// The line under the text: the app, then what of the window's title
    /// the caption does not already say (else, without a caption, the kind
    /// of moment), then how many moments the row holds. "Slack · Northwind
    /// Studio, 3 moments" under "Chatting with Sam Lee".
    public static func origin(_ hit: Hit, count: Int = 1, caption: String? = nil) -> String {
        let parts = originParts(hit, count: count, caption: caption)
        return parts.count.map { "\(parts.place), \($0)" } ?? parts.place
    }

    /// The line under the text in two parts: where the moment was, and how
    /// many moments the row holds, if more than one. `caption` stands in for
    /// the row's own when the detail got one with the moment's text.
    public static func originParts(_ hit: Hit, count: Int = 1,
                                   caption: String? = nil) -> (place: String, count: String?) {
        let app = Formatters.appDisplayName(hit.appBundleId)
        var place = app
        if let caption = caption ?? hit.caption {
            let unsaid = titleParts(hit).filter { !caption.localizedCaseInsensitiveContains($0) }
            if !unsaid.isEmpty {
                place += " \u{00B7} " + unsaid.joined(separator: " \u{00B7} ")
            }
        } else {
            place += " \u{00B7} " + UserFacingCopy.momentSource(sourceKind: hit.sourceKind)
        }
        return (place, count > 1 ? UserFacingCopy.momentCount(count) : nil)
    }

    /// Site and product names a window's title ends with, said by the app's
    /// name or the caption already.
    private static let titleSuffixes: Set<String> = [
        "google chrome", "chrome", "safari", "arc", "mozilla firefox", "firefox", "microsoft edge", "brave",
        "google search", "google docs", "google sheets", "google slides", "google calendar", "google drive",
        "gmail", "youtube", "notion", "figma", "github", "wikipedia", "stack overflow", "medium", "reddit",
        "linkedin", "slack", "discord", "visual studio code", "cursor", "zed", "xcode", "claude", "chatgpt",
        "microsoft teams", "zoom",
    ]

    /// The parts of a window's title worth showing beside its app: without
    /// the status mark an app puts before it, an unread count, the app's or
    /// a site's name, "(Channel)" or "(DM)", or a terminal's size. "launch
    /// (Channel) - Northwind Studio - Slack" is "launch" and "Northwind
    /// Studio"; "Notes" in Notes is nothing.
    public static func titleParts(_ hit: Hit) -> [String] {
        var title = Formatters.titleWithoutMarks(hit.windowTitle ?? "")
        if title.hasPrefix("("), let close = title.firstIndex(of: ")") {
            let count = title[title.index(after: title.startIndex)..<close]
            if !count.isEmpty, count.allSatisfy({ $0.isNumber || $0 == "+" }) {
                title = String(title[title.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        let app = Formatters.appDisplayName(hit.appBundleId).lowercased()
        var parts = splitTitle(title)
            .map { part -> String in
                var part = withoutReplyMarks(part)
                for marker in [" (Channel)", " (DM)", " (Private)"] where part.hasSuffix(marker) {
                    part = String(part.dropLast(marker.count))
                }
                return part.trimmingCharacters(in: .whitespaces)
            }
            .filter { part in
                let lower = part.lowercased()
                return !part.isEmpty && lower != app && !titleSuffixes.contains(lower) && !isTerminalSize(part)
                    && part.contains(where: { $0.isLetter || $0.isNumber })
            }
        // "Activity Monitor (All Processes)" in Activity Monitor and "Zoom
        // Workplace" in Zoom say only the app.
        parts.removeAll { part in
            let lower = part.lowercased()
            return lower.hasPrefix(app + " (") || ["workplace", "home", "app"].map { "\(app) \($0)" }.contains(lower)
        }
        return parts
    }

    /// An email subject without its reply and forward marks: "Fwd: Re:
    /// Launch plan" is "Launch plan".
    static func withoutReplyMarks(_ subject: String) -> String {
        var rest = Substring(subject.trimmingCharacters(in: .whitespaces))
        while let mark = ["re:", "fwd:", "fw:"].first(where: { rest.lowercased().hasPrefix($0) }) {
            rest = rest.dropFirst(mark.count).drop(while: \.isWhitespace)
        }
        return String(rest)
    }

    /// A title split at " - ", " — ", " – ", " | " and " · ".
    private static func splitTitle(_ title: String) -> [String] {
        var parts = [title]
        for separator in [" - ", " \u{2014} ", " \u{2013} ", " | ", " \u{00B7} "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts
    }

    /// A terminal's size in its title: "160×40", "80x24".
    private static func isTerminalSize(_ part: String) -> Bool {
        let pieces = part.split(whereSeparator: { $0 == "\u{00D7}" || $0 == "x" })
        return pieces.count == 2 && pieces.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
