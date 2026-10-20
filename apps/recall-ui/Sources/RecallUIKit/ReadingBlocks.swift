import Foundation

/// One block of a moment's text, as the FFI's reading carries it (`blocks`,
/// `core/brain/src/reading_blocks.rs`, SPEC 4.2). Every block holds only text
/// that was read; its kind changes only how it is drawn.
public enum ReadingBlock: Equatable, Sendable {
    /// A short line in capitals before a heading ("MONEY & ROUNDING").
    case label(String)
    /// A title line: level 1 names the window, level 2 a section.
    case heading(level: Int, text: String)
    /// A short line with a date or "min read" near the top.
    case byline(String)
    /// Prose.
    case paragraph(String)
    /// Items with the markers that were read.
    case list([ReadingListItem])
    /// Lines that read like code, byte for byte.
    case code(String)
    /// A terminal's lines, byte for byte; `prompts` are the lines (from 0)
    /// that start with a shell prompt.
    case terminal(text: String, prompts: [Int])
    /// Rows whose cells are known; `numeric` says which columns hold numbers.
    case table(rows: [[String]], numeric: [Bool])
    /// Short lines that stay apart; `table` when they are a table's rows.
    case lines([String], table: Bool)
    /// A chat message: the speaker and time as read, then what was said.
    case turn(speaker: String, time: String, text: String)
    /// Quoted mail.
    case quote(String)
    /// Mail's header lines and signature, a chat's day divider.
    case meta(String)
    /// A kind this window does not know yet, drawn as its text.
    case other(kind: String, text: String)

    /// The block as plain text, its lines as read: what Copy Text copies of
    /// it (`Block::plain` in Rust). An item reads as its marker, a space and
    /// its text; a table row as its cells with a tab between them; a turn as
    /// the speaker and the time, then the message.
    public var plain: String {
        switch self {
        case let .label(text), let .heading(_, text), let .byline(text), let .paragraph(text),
             let .code(text), let .terminal(text, _), let .quote(text), let .meta(text),
             let .other(_, text):
            return text
        case let .list(items):
            return items.map { String(repeating: "  ", count: $0.depth) + $0.marker + " " + $0.text }
                .joined(separator: "\n")
        case let .table(rows, _):
            return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        case let .lines(lines, _):
            return lines.joined(separator: "\n")
        case let .turn(speaker, time, text):
            return text.isEmpty ? "\(speaker) \(time)" : "\(speaker) \(time)\n\(text)"
        }
    }

    /// The text the block holds, as read (its plain text).
    public var text: String { plain }
}

/// One list item: its marker as read ("•", "1.", "☐", "[x]"), what follows
/// it, 1 for an item under another, and for a checkbox whether it is ticked.
public struct ReadingListItem: Equatable, Sendable, Decodable {
    public let marker: String
    public let text: String
    public let depth: Int
    public let checked: Bool?

    public init(marker: String, text: String, depth: Int = 0, checked: Bool? = nil) {
        self.marker = marker
        self.text = text
        self.depth = depth
        self.checked = checked
    }

    private enum CodingKeys: String, CodingKey {
        case marker, text, depth, checked
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        marker = (try? values.decodeIfPresent(String.self, forKey: .marker)) ?? ""
        text = (try? values.decodeIfPresent(String.self, forKey: .text)) ?? ""
        depth = min(max((try? values.decodeIfPresent(Int.self, forKey: .depth)) ?? 0, 0), 1)
        checked = try? values.decodeIfPresent(Bool.self, forKey: .checked)
    }
}

extension ReadingBlock: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, text, level, items, prompts, rows, numeric, lines, table, speaker, time
    }

    /// Never fails on a block's own fields: a block the window cannot read
    /// whole keeps whatever text it holds, so nothing that was read is lost
    /// and one odd block never costs the whole reading.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? values.decode(String.self, forKey: .kind)) ?? ""
        let text = (try? values.decodeIfPresent(String.self, forKey: .text)) ?? nil
        func string(_ key: CodingKeys) -> String? { (try? values.decodeIfPresent(String.self, forKey: key)) ?? nil }
        switch kind {
        case "label" where text != nil: self = .label(text!)
        case "heading" where text != nil:
            let level = (try? values.decodeIfPresent(Int.self, forKey: .level)) ?? nil
            self = .heading(level: level == 1 ? 1 : 2, text: text!)
        case "byline" where text != nil: self = .byline(text!)
        case "paragraph" where text != nil: self = .paragraph(text!)
        case "code" where text != nil: self = .code(text!)
        case "quote" where text != nil: self = .quote(text!)
        case "meta" where text != nil: self = .meta(text!)
        case "terminal" where text != nil:
            let prompts = ((try? values.decodeIfPresent([Int].self, forKey: .prompts)) ?? nil) ?? []
            self = .terminal(text: text!, prompts: prompts)
        case "list":
            if let items = (try? values.decodeIfPresent([ReadingListItem].self, forKey: .items)) ?? nil {
                self = .list(items)
            } else {
                self = .other(kind: kind, text: text ?? "")
            }
        case "table":
            if let rows = (try? values.decodeIfPresent([[String]].self, forKey: .rows)) ?? nil {
                let numeric = ((try? values.decodeIfPresent([Bool].self, forKey: .numeric)) ?? nil) ?? []
                self = .table(rows: rows, numeric: numeric)
            } else {
                self = .other(kind: kind, text: text ?? "")
            }
        case "lines":
            if let lines = (try? values.decodeIfPresent([String].self, forKey: .lines)) ?? nil {
                let table = ((try? values.decodeIfPresent(Bool.self, forKey: .table)) ?? nil) ?? false
                self = .lines(lines, table: table)
            } else {
                self = .other(kind: kind, text: text ?? "")
            }
        case "turn":
            if let speaker = string(.speaker), let time = string(.time) {
                self = .turn(speaker: speaker, time: time, text: text ?? "")
            } else {
                self = .other(kind: kind, text: text ?? "")
            }
        default:
            self = .other(kind: kind, text: text ?? "")
        }
    }
}

/// A moment's text as blocks.
public enum ReadingBlocks {
    /// The most blocks, items, rows, cells, lines and marked prompts the
    /// FFI splits one reading into (`MAX_ELEMENTS` in
    /// `core/brain/src/reading_blocks.rs`).
    public static let maxElements = 2_000
    /// The most bytes of JSON its blocks add around the text they hold
    /// (`MAX_STRUCTURE_BYTES`): no element costs more than 64.
    public static let maxStructureBytes = maxElements * 64 + 1024

    /// The blocks to draw for `main` when a reading carries none of its own
    /// (a reader without the FFI's blocks): one code block when it reads like
    /// code, as the detail always drew it, else one paragraph of all of it.
    /// None when it holds no text.
    public static func fallback(main: String) -> [ReadingBlock] {
        guard !main.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return SyntaxHighlighter.looksLikeCode(main) ? [.code(main)] : [.paragraph(main)]
    }

    /// The blocks as plain text, with the structure kept: what Copy Text
    /// copies (SPEC 4.7, `plain_text` in Rust). Blocks are set apart by a
    /// blank line, except a label over its heading and a level-1 heading
    /// with the line under it and its byline or header lines; list markers
    /// and code lines are as read, and no Markdown symbol is added.
    public static func plainText(_ blocks: [ReadingBlock]) -> String {
        var out = ""
        var previous: ReadingBlock?
        var group = false
        for block in blocks {
            let close = previous.map { staysClose($0, block, group: group) } ?? false
            if case .heading(1, _) = block {
                group = true
            } else if close, case .heading(1, _)? = previous {
                group = true
            } else {
                group = close && group
            }
            if !out.isEmpty { out += close ? "\n" : "\n\n" }
            out += block.plain
            previous = block
        }
        return out
    }

    /// Whether `block` stays on the line after `previous` (`stays_close`).
    static func staysClose(_ previous: ReadingBlock, _ block: ReadingBlock, group: Bool) -> Bool {
        switch (previous, block) {
        case (.label, .heading):
            return true
        case (.heading(1, _), .paragraph), (.heading(1, _), .byline), (.heading(1, _), .meta):
            return true
        case (.byline, .byline), (.byline, .meta), (.meta, .byline), (.meta, .meta):
            return true
        case (.paragraph, .byline), (.paragraph, .meta):
            return group
        default:
            return false
        }
    }
}
