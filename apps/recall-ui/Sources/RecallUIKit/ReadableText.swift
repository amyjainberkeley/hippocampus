import Foundation

/// The last check on text a person reads (RULINGS T14): no header line and no
/// U+001E ever reaches the screen or the clipboard.
///
/// Cleaning is the Rust reader's job (`core/brain/src/reading.rs`, RULINGS
/// T2). This file only cuts what the store adds around the text: the header
/// line, the separator between a window's content and its chrome, and the
/// `[VISIBLE-OCR]` marker. Nothing else is removed, so a window whose reading
/// has not reached the FFI yet still shows every word it stored.
public enum ReadableText {
    /// Between a classified window's content and its chrome, in stored text.
    public static let chromeSeparator = "\n\n\u{1E}\n"
    /// Between a browser page's own text and the text read off the screen.
    public static let visibleTextSeparator = "\n\n[VISIBLE-OCR]\n"
    private static let mcpRevisionPrefix = "[MCP_RESOURCE revision_sha256="
    /// A header whose title holds a line break is looked for this far; text
    /// that only starts like a header is left alone.
    private static let maxWrappedHeaderCharacters = 8_192

    /// The stored text without its header, as the contract's `body()`
    /// (reading.md 2.1 step 1): an MCP resource's revision line goes first;
    /// then a first line `[app=… | title=… | url=…]`, as captures and
    /// transcript imports write it. A title holding a line break makes the
    /// header two lines: it then runs to the first `]` that ends a line after
    /// ` | url=`, and it still goes. Text without a header comes back unchanged.
    public static func body(_ stored: String) -> String {
        var text = Substring(stored)
        if text.hasPrefix(mcpRevisionPrefix), let close = text.range(of: "]\n") {
            let digest = text[text.index(text.startIndex, offsetBy: mcpRevisionPrefix.count)..<close.lowerBound]
            if digest.utf8.count == 64, digest.utf8.allSatisfy(Self.isASCIIHexDigit) {
                text = text[close.upperBound...]
            }
        }
        guard text.hasPrefix("[app=") else { return stored }
        let firstLineEnd = text.firstIndex(of: "\n") ?? text.endIndex
        let firstLine = text[..<firstLineEnd]
        guard let title = firstLine.range(of: " | title=") else { return stored }
        if firstLine.hasSuffix("]"),
           firstLine.range(of: " | url=", range: title.upperBound..<firstLine.endIndex) != nil {
            return firstLineEnd == text.endIndex ? "" : String(text[text.index(after: firstLineEnd)...])
        }
        let window = text.prefix(maxWrappedHeaderCharacters)
        guard let url = window.range(of: " | url=", range: title.upperBound..<window.endIndex) else {
            return stored
        }
        var search = url.upperBound
        while let close = window[search...].firstIndex(of: "]") {
            let next = window.index(after: close)
            if next == text.endIndex { return "" }
            guard next < window.endIndex else { break }
            if window[next] == "\n" { return String(text[window.index(after: next)...]) }
            search = next
        }
        return stored
    }

    private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    /// `body`, with the chrome separator as a paragraph break and any other
    /// U+001E as a space. For snippets and any other short text.
    public static func guarded(_ text: String) -> String {
        let stripped = body(text)
        guard stripped.contains("\u{1E}") else { return stripped }
        return stripped
            .replacingOccurrences(of: chromeSeparator, with: "\n\n")
            .replacingOccurrences(of: "\u{1E}", with: " ")
    }

    /// The parts of stored text without any cleaning: what was read, and the
    /// rest of the window (contract reading.md 2.1 steps 1, 2 and 5). Screen
    /// text is cut at the chrome separator; a browser page read both ways is
    /// cut at `[VISIBLE-OCR]`, the page being `main`. The FFI's
    /// `event_reading` replaces this once it ships, adding the cleaning.
    public static func parts(stored: String, sourceKind: String?) -> (main: String, rest: String) {
        let text = body(stored)
        if sourceKind == "browser_page_with_ocr",
           let marker = text.range(of: visibleTextSeparator) {
            let screen = split(String(text[marker.upperBound...]))
            let rest = [screen.main, screen.rest].filter { !$0.isEmpty }.joined(separator: "\n\n")
            return (trimmed(spaced(String(text[..<marker.lowerBound]))), rest)
        }
        return split(text)
    }

    private static func split(_ text: String) -> (main: String, rest: String) {
        guard let separator = text.range(of: chromeSeparator) else {
            return (trimmed(spaced(text)), "")
        }
        return (trimmed(spaced(String(text[..<separator.lowerBound]))),
                trimmed(spaced(String(text[separator.upperBound...]))))
    }

    private static func spaced(_ text: String) -> String {
        text.contains("\u{1E}") ? text.replacingOccurrences(of: "\u{1E}", with: " ") : text
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }
}

/// What one moment's window said, ready to read (contract reading.md, FFI):
/// `main` is what the person was reading, `rest` is the rest of the window
/// (tabs, sidebars, menus, status bars). Views and exports show this, never
/// the stored text, which keeps its header and is for audits only.
public struct EventReading: Sendable, Equatable {
    /// Where a search's words are: shown first, or only in the rest of the
    /// window, where "Also in this window" opens by itself (RULINGS T12).
    public enum Match: String, Sendable {
        case main, rest
    }

    /// Both parts come from the same bounded read as `EventText`.
    public static let maxUTF8Bytes = EventText.maxUTF8Bytes + 1024
    static let maxJSONBytes = (EventText.maxUTF8Bytes + 1024) * 6 + 512

    public let eventId: UInt64
    public let tsUs: UInt64
    public let appBundleId: String?
    /// Where the moment came from (`screen_ocr`, `browser_page`, …);
    /// `unknown` when the store has no source for it.
    public let sourceKind: String
    public let main: String
    public let rest: String
    /// Nil without a search, or when neither part holds its words.
    public let matchIn: Match?
    /// The stored text was longer than the read limit, so its end is missing.
    public let isTruncated: Bool

    public init(
        eventId: UInt64, tsUs: UInt64, appBundleId: String?, sourceKind: String?,
        main: String, rest: String, matchIn: Match? = nil, isTruncated: Bool
    ) throws {
        let main = ReadableText.guarded(main)
        let rest = ReadableText.guarded(rest)
        guard eventId > 0, eventId <= UInt64(Int64.max), tsUs <= UInt64(Int64.max),
              main.utf8.count + rest.utf8.count <= Self.maxUTF8Bytes,
              (appBundleId?.utf8.count ?? 0) <= EventText.maxAppUTF8Bytes else {
            throw BrainReaderError.decodeFailed("Invalid bounded event reading")
        }
        self.eventId = eventId
        self.tsUs = tsUs
        self.appBundleId = appBundleId
        self.sourceKind = sourceKind.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        self.main = main
        self.rest = rest
        self.matchIn = matchIn
        self.isTruncated = isTruncated
    }

    /// The reading of stored text from a reader without the FFI's reading:
    /// cut where the store marked it, with nothing cleaned.
    public init(stored text: EventText, sourceKind: String? = nil) {
        let parts = ReadableText.parts(stored: text.text, sourceKind: sourceKind)
        self.eventId = text.eventId
        self.tsUs = text.tsUs
        self.appBundleId = text.appBundleId
        self.sourceKind = sourceKind.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        self.main = parts.main
        self.rest = parts.rest
        self.matchIn = nil
        self.isTruncated = text.isTruncated
    }

    /// Ids can be reused after a delete: use a reading only for the moment it was read for.
    public func matches(_ hit: Hit) -> Bool {
        eventId == hit.id && tsUs == hit.tsUs && appBundleId == hit.appBundleId
    }

    /// What "Copy Text" copies: `main`, then `rest` when it is shown. Never a header.
    public func text(includingRest: Bool) -> String {
        guard includingRest, !rest.isEmpty else { return main }
        return main.isEmpty ? rest : main + "\n\n" + rest
    }

    /// The line count "Also in this window" shows: `rest`'s non-empty lines.
    public var restLineCount: Int {
        rest.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.count
    }
}

extension EventReading: Decodable {
    private enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case tsUs = "ts_us"
        case appBundleId = "app_bundle_id"
        case sourceKind = "source_kind"
        case main, rest
        case matchIn = "match_in"
        case isTruncated = "truncated"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            eventId: values.decode(UInt64.self, forKey: .eventId),
            tsUs: values.decode(UInt64.self, forKey: .tsUs),
            appBundleId: values.decodeIfPresent(String.self, forKey: .appBundleId),
            sourceKind: values.decodeIfPresent(String.self, forKey: .sourceKind),
            main: values.decode(String.self, forKey: .main),
            rest: values.decodeIfPresent(String.self, forKey: .rest) ?? "",
            matchIn: (try? values.decodeIfPresent(String.self, forKey: .matchIn)).flatMap(Match.init(rawValue:)),
            isTruncated: values.decodeIfPresent(Bool.self, forKey: .isTruncated) ?? false
        )
    }
}
