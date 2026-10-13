// SPDX-License-Identifier: TBD-private
//
// ReadProof — the first thing setup shows of what Hippocampus read: the
// app's name, the window title, and up to three lines from the window.
//
// The card never shows a bundle id, the stored `[app=…]` header, or a row
// of interface labels. A line is shown only when it has four or more words,
// is mostly letters and reads like a sentence; the longest go first. A long
// line is shortened to fit, and what is shown must pass on its own. When no
// line passes, the card shows the app and title alone. It is text only,
// never a screenshot. Rows from the app the person last brought forward
// come first, so the card never shows a window they did not click.

import Foundation

/// One row of an `mci_events_since` reply.
public struct ReadRow: Sendable, Equatable {
    public let tsUs: UInt64
    public let appBundleId: String?
    public let windowTitle: String?
    public let text: String
    public let sourceKind: String

    public init(tsUs: UInt64, appBundleId: String?, windowTitle: String?, text: String, sourceKind: String) {
        self.tsUs = tsUs
        self.appBundleId = appBundleId
        self.windowTitle = windowTitle
        self.text = text
        self.sourceKind = sourceKind
    }
}

public struct ReadProof: Sendable, Equatable {
    public let appBundleId: String
    public let appName: String
    public let windowTitle: String?
    public let lines: [String]
    public let at: Date
    public let tsUs: UInt64

    /// Rows from screen reading and browser pages.
    public static let sourceKinds: Set<String> = [
        "screen_ocr", "screen_context", "browser_page", "browser_page_with_ocr",
    ]
    /// A window the person was not in (whole-screen reading).
    static let backgroundKind = "screen_context"
    /// Hippocampus's own windows are never read; listed for safety.
    public static let ownBundleIds: Set<String> = ["ai.hippocampus", "recall-ui", "onboarding"]
    public static let maximumLines = 3
    public static let maximumLineLength = 90
    public static let minimumWords = 4

    /// The rows in a tool reply: `result.events`, or nil when the reply is
    /// not a successful `mci_events_since` answer.
    public static func rows(fromReply json: Data) -> [ReadRow]? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              object["error"] == nil,
              let result = object["result"] as? [String: Any],
              let events = result["events"] as? [[String: Any]] else { return nil }
        return events.compactMap { event in
            guard let ts = (event["ts_us"] as? NSNumber)?.uint64Value else { return nil }
            return ReadRow(
                tsUs: ts,
                appBundleId: event["app_bundle_id"] as? String,
                windowTitle: event["window_title"] as? String,
                text: event["text_snippet"] as? String ?? "",
                sourceKind: event["source_kind"] as? String ?? "unknown"
            )
        }
    }

    /// The proof to show from `rows`: the newest row from the app last
    /// brought forward when there is one; otherwise the newest row from a
    /// window someone was in. Nil when nothing qualifies.
    public static func choose(
        from rows: [ReadRow],
        lastActivatedApp: String?,
        nameFor: (String) -> String = BundleDisplayNameResolver.displayName(for:)
    ) -> ReadProof? {
        let candidates: [(row: ReadRow, app: String)] = rows.compactMap { row in
            guard sourceKinds.contains(row.sourceKind),
                  let app = appId(of: row),
                  !ownBundleIds.contains(app.lowercased()) else { return nil }
            return (row, app)
        }
        let fromFrontApp = lastActivatedApp.map { front in candidates.filter { $0.app == front } } ?? []
        let pool = fromFrontApp.isEmpty
            ? candidates.filter { $0.row.sourceKind != backgroundKind }
            : fromFrontApp
        guard let chosen = pool.max(by: { $0.row.tsUs < $1.row.tsUs }) else { return nil }
        let title = windowTitle(of: chosen.row)
        return ReadProof(
            appBundleId: chosen.app,
            appName: nameFor(chosen.app),
            windowTitle: title,
            lines: lines(from: chosen.row.text, windowTitle: title),
            at: Date(timeIntervalSince1970: TimeInterval(chosen.row.tsUs) / 1_000_000),
            tsUs: chosen.row.tsUs
        )
    }

    /// The lines worth showing from one row's text, longest first.
    public static func lines(from text: String, windowTitle: String?) -> [String] {
        // Text after a record separator is the window's interface (tabs,
        // sidebars, toolbars); only what comes before it is content.
        let content = text.split(separator: "\u{1E}", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        var seen = Set<String>()
        var kept: [(length: Int, shown: String)] = []
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard qualifies(line), line != windowTitle, seen.insert(line).inserted else { continue }
            // Shortening cuts at a space, which can leave fewer than four
            // words ("Read more at…") or one piece of a long word.
            let shown = shortened(line)
            guard shown == line || qualifies(shown) else { continue }
            kept.append((line.count, shown))
        }
        return kept.enumerated()
            .sorted { $0.element.length != $1.element.length ? $0.element.length > $1.element.length : $0.offset < $1.offset }
            .prefix(maximumLines)
            .map { $0.element.shown }
    }

    /// A sentence-like line: four or more words, mostly letters, at least one
    /// word in lowercase (a row of labels is all capitals), and no header,
    /// bundle id or dotted name in it.
    public static func qualifies(_ line: String) -> Bool {
        guard !line.contains("[app="), !line.contains("\u{1E}"), !containsDottedName(line) else { return false }
        let tokens = line.split(whereSeparator: \.isWhitespace)
        let words = tokens.filter { $0.contains(where: \.isLetter) }
        guard words.count >= minimumWords else { return false }
        let visible = line.filter { !$0.isWhitespace }
        let letters = visible.filter(\.isLetter)
        guard letters.count * 2 > visible.count else { return false }
        return words.contains { $0.first(where: \.isLetter)?.isLowercase == true }
    }

    /// `com.apple.Safari`, `www.example.com`, `1.2.3`: three or more parts
    /// joined by dots, anywhere in the line, whatever punctuation or text
    /// sits around them ("com.apple.Safari,", "(app:com.apple.Notes)").
    static func containsDottedName(_ line: String) -> Bool {
        line.range(of: #"[\p{L}\p{N}_-]+(\.[\p{L}\p{N}_-]+){2,}"#, options: .regularExpression) != nil
    }

    static func shortened(_ line: String) -> String {
        guard line.count > maximumLineLength else { return line }
        var cut = String(line.prefix(maximumLineLength - 1))
        if let space = cut.lastIndex(of: " ") {
            cut = String(cut[..<space])
        }
        return cut + "…"
    }

    /// The row's app: its bundle id, or the one in an old stored header.
    static func appId(of row: ReadRow) -> String? {
        if let app = row.appBundleId?.trimmingCharacters(in: .whitespaces), !app.isEmpty, app != "?" {
            return app
        }
        return headerField("app", in: row.text)
    }

    static func windowTitle(of row: ReadRow) -> String? {
        if let title = row.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty, title != "?" {
            return title
        }
        return headerField("title", in: row.text)
    }

    /// A field of `[app=<bundle> | title=<title> | url=<url> | ts=<iso>]`.
    static func headerField(_ name: String, in text: String) -> String? {
        guard let first = text.split(separator: "\n", maxSplits: 1).first,
              first.hasPrefix("[app="), first.hasSuffix("]") else { return nil }
        let inner = first.dropFirst().dropLast()
        for field in inner.components(separatedBy: " | ") {
            let prefix = name + "="
            guard field.hasPrefix(prefix) else { continue }
            let value = String(field.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty || value == "?" ? nil : value
        }
        return nil
    }
}
