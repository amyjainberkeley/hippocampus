import AppKit

/// A moment's blocks as one attributed string, for the reading view's single
/// selectable text view (SPEC 4.6). Built off the main thread; every color is
/// a design token resolved when it is drawn, so light and dark need no
/// rebuild.
///
/// What the string says beyond its text is in attributes the view draws
/// from: a code or terminal line's place in its box (`readingBox`), a table
/// row's hairline (`readingRule`), a quote's rule (`readingQuote`), a
/// heading's level for VoiceOver's rotor (`readingHeading`), a block's group
/// for the rotors (`readingGroup`), and what a character copies as when it is
/// drawn differently (`readingCopyAs`).
public enum ReadingAttributedText {
    /// A built reading: the string, and the blocks it was built from.
    public final class Built: @unchecked Sendable {
        public let string: NSAttributedString
        public let blocks: [ReadingBlock]
        public let expandedQuotes: Set<Int>
        /// Space above the first line: a box's padding when the text opens
        /// with one (a text view lays its first paragraph out at its top,
        /// whatever space it asks for above it).
        public let topInset: CGFloat

        init(string: NSAttributedString, blocks: [ReadingBlock], expandedQuotes: Set<Int>, topInset: CGFloat) {
            self.string = string
            self.blocks = blocks
            self.expandedQuotes = expandedQuotes
            self.topInset = topInset
        }
    }

    /// The link a closed quote's line carries: clicking it opens the quote.
    public static let quoteLinkScheme = "hippocampus-reading"

    /// The quote at `index` opens from this link.
    public static func quoteLink(_ index: Int) -> URL {
        URL(string: "\(quoteLinkScheme)://quote/\(index)")!
    }

    /// The quote a link opens, if it is one of ours.
    public static func quoteIndex(of link: Any) -> Int? {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, url.scheme == quoteLinkScheme, url.host == "quote" else { return nil }
        return Int(url.lastPathComponent)
    }

    /// The most lines a quote shows before it is closed (SPEC 4.2).
    public static let quoteLinesShown = 6

    /// What VoiceOver's rotors move through in a built reading.
    public enum Rotor: Sendable {
        case headings, code, lists
    }

    /// The ranges a rotor moves through, in order, each with what it is
    /// called: a heading's own words, "Code", "List, 4 items".
    public static func rotorItems(_ rotor: Rotor, in string: NSAttributedString) -> [(range: NSRange, label: String)] {
        let all = NSRange(location: 0, length: string.length)
        let text = string.string as NSString
        var items: [(range: NSRange, label: String)] = []
        switch rotor {
        case .headings:
            string.enumerateAttribute(.readingHeading, in: all) { value, range, _ in
                guard value != nil else { return }
                items.append((range, text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        case .code, .lists:
            string.enumerateAttribute(.readingGroup, in: all) { value, range, _ in
                guard let group = value as? String else { return }
                let parts = group.split(separator: ":")
                if rotor == .lists, parts.first == "list" {
                    items.append((range, ReadingCopy.list(items: Int(parts.last ?? "") ?? 0)))
                } else if rotor == .code, parts.first == "code" || parts.first == "terminal" {
                    items.append((range, ReadingCopy.code))
                }
            }
        }
        return items
    }

    /// What copying `range` of a built reading gives (⌘C): plain text as it
    /// was read. A drawn checkbox or terminal marker copies as the marker
    /// that was read, a quote's line with its ">", an item's own lines on
    /// lines of their own; a quote's "Earlier in this thread" copies as
    /// nothing.
    public static func copiedText(of string: NSAttributedString, in range: NSRange) -> String {
        guard range.length > 0, NSMaxRange(range) <= string.length else { return "" }
        var out = ""
        let text = string.string as NSString
        string.enumerateAttributes(in: range) { attributes, run, _ in
            if let prefix = attributes[.readingCopyPrefix] as? String {
                let lineStart = text.lineRange(for: NSRange(location: run.location, length: 0)).location
                if lineStart == run.location { out += prefix }
            }
            if let copyAs = attributes[.readingCopyAs] as? String {
                out += copyAs
            } else {
                out += text.substring(with: run).replacingOccurrences(of: "\u{2028}", with: "\n")
            }
        }
        return out
    }

    /// `text`'s lines, split at every "\n" as `components(separatedBy:)`
    /// splits them, in a fraction of its time.
    static func lines(of text: String) -> [String] {
        var lines: [String] = []
        let bytes = text.utf8
        var start = bytes.startIndex
        var index = start
        while index != bytes.endIndex {
            if bytes[index] == UInt8(ascii: "\n") {
                lines.append(String(text[start..<index]))
                start = bytes.index(after: index)
            }
            index = bytes.index(after: index)
        }
        lines.append(String(text[start..<bytes.endIndex]))
        return lines
    }

    /// The blocks as one string. `expandedQuotes` are the quotes (by block
    /// index) that were opened.
    public static func make(_ blocks: [ReadingBlock], expandedQuotes: Set<Int> = []) -> Built {
        let builder = Builder()
        var previous: ReadingBlock?
        var subtitle = false
        for (index, block) in blocks.enumerated() {
            var gap = previous.map { gapBetween($0, block) } ?? 0
            // The line under a page's title stays close to its byline.
            if subtitle, isByline(block) { gap = 4 }
            builder.add(block, index: index, gap: gap, expanded: expandedQuotes.contains(index))
            if case .paragraph = block, let previous { subtitle = isH1(previous) } else { subtitle = false }
            previous = block
        }
        let topInset = builder.finish()
        return Built(string: builder.out, blocks: blocks, expandedQuotes: expandedQuotes, topInset: topInset)
    }

    // MARK: - Spacing (SPEC 4.6, the prototype's margins, collapsed)

    private static func isH1(_ block: ReadingBlock) -> Bool {
        if case .heading(1, _) = block { return true }
        return false
    }

    private static func isByline(_ block: ReadingBlock) -> Bool {
        switch block {
        case .byline, .meta: true
        default: false
        }
    }

    /// Space above a block, from its own margin and the one below the block
    /// before it: the larger of the two, as margins meet.
    static func gapBetween(_ previous: ReadingBlock, _ block: ReadingBlock) -> CGFloat {
        let below: CGFloat
        switch previous {
        case .label: below = 2
        case .heading(1, _): below = 4
        case .heading: below = 2
        case .byline, .meta:
            switch block {
            case .byline, .meta: return 2
            default: below = 10
            }
        default: below = 10
        }
        let above: CGFloat
        switch block {
        case .heading(let level, _):
            // A label sits right over its heading.
            if case .label = previous { return 2 }
            above = level == 1 ? 12 : 10
        case .paragraph, .byline, .meta:
            // The line under the page's title and its byline stay close.
            if case .heading(1, _) = previous { return 4 }
            above = 0
        case .turn:
            if case .turn = previous { return 12 }
            above = 0
        default: above = 0
        }
        return max(below, above)
    }

    // MARK: - Builder

    /// How a run of text looks: everything its attributes say. Runs that
    /// look alike share one template, so a long reading makes each set of
    /// attributes once and copies it after (SPEC 4.11's budget).
    private struct Look: Hashable {
        enum Font: Hashable {
            case body, bodyStrong, title, heading, caption, label, mono

            var font: NSFont {
                switch self {
                case .body: Style.body
                case .bodyStrong: Style.bodyStrong
                case .title: Style.title
                case .heading: Style.heading
                case .caption: Style.caption
                case .label: Style.label
                case .mono: Style.mono
                }
            }
        }

        enum Color: Hashable {
            case foreground, secondary, muted, accent, accentDim

            var color: NSColor {
                switch self {
                case .foreground: Style.foreground
                case .secondary: Style.secondary
                case .muted: Style.muted
                case .accent: Style.accent
                case .accentDim: Style.accentDim
                }
            }

            /// A code token's color.
            init(_ token: SyntaxTokenType) {
                switch token {
                case .keyword: self = .accent
                case .number: self = .accentDim
                case .comment: self = .muted
                case .string: self = .secondary
                case .plain: self = .foreground
                }
            }
        }

        /// A tab stop: right-aligned for a column of numbers, else left.
        struct Tab: Hashable {
            var right: Bool
            var location: CGFloat
        }

        var font: Font
        var color: Color
        var lineHeight: CGFloat
        var before: CGFloat = 0
        var after: CGFloat = 0
        var head: CGFloat = 0
        var firstHead: CGFloat?
        var tail: CGFloat = 0
        var tabs: [Tab] = []
        var box: String?
        var quote: String?
        var rule = false
        var heading: Int?
        var copyAs: String?
        var link: URL?
        var kern: CGFloat?

        var attributes: [NSAttributedString.Key: Any] {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            style.headIndent = head
            style.firstLineHeadIndent = firstHead ?? head
            style.tailIndent = tail
            style.lineBreakMode = .byWordWrapping
            if !tabs.isEmpty {
                style.tabStops = tabs.map { NSTextTab(textAlignment: $0.right ? .right : .left, location: $0.location) }
                style.defaultTabInterval = 18
            }
            let font = font.font
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color.color, .paragraphStyle: style,
                .baselineOffset: Builder.baseline(font, height: lineHeight),
            ]
            if let box { attributes[.readingBox] = box }
            if let quote { attributes[.readingQuote] = quote }
            if rule { attributes[.readingRule] = true }
            if let heading { attributes[.readingHeading] = heading }
            if let copyAs { attributes[.readingCopyAs] = copyAs }
            if let link { attributes[.link] = link }
            if let kern { attributes[.kern] = kern }
            return attributes
        }
    }

    private final class Builder {
        let out = NSMutableAttributedString()
        /// One string of one character per look, made the first time it is
        /// needed.
        private var templates: [Look: NSAttributedString] = [:]

        func add(_ block: ReadingBlock, index: Int, gap: CGFloat, expanded: Bool) {
            switch block {
            case let .label(text):
                emit(text + "\n", Look(font: .label, color: .muted, lineHeight: 19, before: gap))
            case let .heading(level, text):
                emit(text + "\n", Look(font: level == 1 ? .title : .heading, color: .foreground,
                                       lineHeight: level == 1 ? 21 : 18, before: gap, heading: level))
            case let .byline(text), let .meta(text):
                lines(ReadingAttributedText.lines(of: text), font: .caption, color: .secondary, gap: gap, between: 2, lineHeight: 16)
            case let .paragraph(text), let .other(_, text):
                lines(ReadingAttributedText.lines(of: text), font: .body, color: .foreground, gap: gap, between: 2, lineHeight: 19,
                      links: true)
            case let .lines(lines, table):
                if table {
                    rows(lines.map { [$0] }, numeric: [], gap: gap)
                } else {
                    self.lines(lines, font: .body, color: .foreground, gap: gap, between: 2, lineHeight: 19,
                               links: true)
                }
            case let .list(items):
                list(items, index: index, gap: gap)
            case let .code(text):
                code(ReadingAttributedText.lines(of: text), language: SyntaxHighlighter.detectLanguage(text), index: index, gap: gap)
            case let .terminal(text, prompts):
                terminal(ReadingAttributedText.lines(of: text), prompts: Set(prompts), index: index, gap: gap)
            case let .table(rows, numeric):
                self.rows(rows, numeric: numeric, gap: gap)
            case let .turn(speaker, time, text):
                turn(speaker: speaker, time: time, text: text, gap: gap)
            case let .quote(text):
                quote(text, index: index, gap: gap, expanded: expanded)
            }
        }

        /// `text` drawn as `look`: the look's template appended and its one
        /// character replaced by the text, which takes its attributes. Far
        /// cheaper than a new attributed string for every run.
        func emit(_ text: String, _ look: Look) {
            guard !text.isEmpty else { return }
            let template: NSAttributedString
            if let made = templates[look] {
                template = made
            } else {
                template = NSAttributedString(string: " ", attributes: look.attributes)
                templates[look] = template
            }
            out.append(template)
            out.replaceCharacters(in: NSRange(location: out.length - 1, length: 1), with: text)
        }

        /// The string ends without a line break after its last paragraph,
        /// and its first paragraph asks for no space above it: that space is
        /// the inset the view puts above the text.
        func finish() -> CGFloat {
            // The mutable string itself: `out.string` would copy all of it.
            let text = out.mutableString
            if text.hasSuffix("\n") {
                out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
            }
            guard out.length > 0,
                  let style = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
                  style.paragraphSpacingBefore > 0,
                  let first = style.mutableCopy() as? NSMutableParagraphStyle
            else { return 0 }
            first.paragraphSpacingBefore = 0
            let paragraph = text.paragraphRange(for: NSRange(location: 0, length: 0))
            out.addAttribute(.paragraphStyle, value: first, range: paragraph)
            return style.paragraphSpacingBefore
        }

        /// How far to raise text so it sits in the middle of a line `height`
        /// high, as the prototype's line heights place it.
        static func baseline(_ font: NSFont, height: CGFloat) -> CGFloat {
            let natural = font.ascender - font.descender
            return max(0, (height - natural) / 2)
        }

        func lines(_ lines: [String], font: Look.Font, color: Look.Color, gap: CGFloat, between: CGFloat,
                   lineHeight: CGFloat, links: Bool = false) {
            for (number, line) in lines.enumerated() {
                let shown = line.trimmingCharacters(in: .whitespaces)
                let start = out.length
                emit(shown + "\n", Look(font: font, color: color, lineHeight: lineHeight,
                                        before: number == 0 ? gap : between))
                if links, Self.mayHoldAddress(shown) { link(from: start) }
            }
        }

        /// Addresses in the text just added are links, drawn in the accent.
        func link(from start: Int) {
            let range = NSRange(location: start, length: out.length - start)
            let text = out.mutableString.substring(with: range)
            for found in LinkDetector.detect(in: text) {
                guard let url = URL(string: found.url) else { continue }
                let local = NSRange(found.range, in: text)
                out.addAttributes([.link: url, .foregroundColor: Style.accent],
                                  range: NSRange(location: start + local.location, length: local.length))
            }
        }

        /// Whether `text` can hold an address at all: the cheap test before
        /// the link detector's.
        static func mayHoldAddress(_ text: String) -> Bool {
            text.containsBytes("://")
        }

        // MARK: Lists

        func list(_ items: [ReadingListItem], index: Int, gap: CGFloat) {
            let start = out.length
            for (number, item) in items.enumerated() {
                let indent: CGFloat = item.depth > 0 ? 18 : 0
                let look = Look(font: .body, color: .foreground, lineHeight: 19, before: number == 0 ? gap : 4,
                                head: indent + 18, firstHead: indent, tabs: [Look.Tab(right: false, location: indent + 18)])
                let lineStart = out.length
                if let checked = item.checked {
                    out.append(Self.checkbox(checked, copyAs: item.marker, attributes: look.attributes))
                } else {
                    var marker = look
                    marker.color = .secondary
                    emit(item.marker, marker)
                }
                // The marker's tab copies as the space Copy Text puts there;
                // the item's own lines under it break within it.
                var tab = look
                tab.copyAs = " "
                emit("\t", tab)
                emit(item.text.replacingOccurrences(of: "\n", with: "\u{2028}") + "\n", look)
                if Self.mayHoldAddress(item.text) { link(from: lineStart) }
            }
            out.addAttribute(.readingGroup, value: "list:\(index):\(items.count)",
                             range: NSRange(location: start, length: out.length - start))
        }

        /// A checkbox drawn read-only: a square, ticked or not, that copies
        /// as the marker that was read.
        static func checkbox(_ checked: Bool, copyAs marker: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
            var drawn = attributes
            drawn[.readingCopyAs] = marker
            let name = checked ? "checkmark.square.fill" : "square"
            let words = checked ? ReadingCopy.checked : ReadingCopy.unchecked
            // A tick in the card's color on a filled square; an empty square.
            let colors = checked ? [Style.card, Style.secondary] : [Style.secondary]
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: colors))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: words)?
                .withSymbolConfiguration(configuration)
            else {
                drawn[.foregroundColor] = Style.secondary
                return NSAttributedString(string: checked ? "\u{2611}" : "\u{2610}", attributes: drawn)
            }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
            let box = NSMutableAttributedString(attachment: attachment)
            box.addAttributes(drawn, range: NSRange(location: 0, length: box.length))
            return box
        }

        // MARK: Code and terminal

        /// Room for a box's wrapped line under its first: two spaces of the
        /// code font.
        static let hang = Style.mono.advancement(forGlyph: Style.mono.glyph(withName: "space")).width * 2

        /// A line in an inset box: its own paragraph, so a long line wraps
        /// under itself with a two-space hanging indent, and its place in
        /// the box.
        func boxLook(_ number: Int, of count: Int, gap: CGFloat, color: Look.Color) -> Look {
            let padding: CGFloat = 10
            let first = number == 0
            let last = number == count - 1
            return Look(font: .mono, color: color, lineHeight: 18, before: first ? gap + padding : 0,
                        after: last ? padding : 0, head: padding + Self.hang, firstHead: padding, tail: -padding,
                        box: first && last ? "only" : first ? "first" : last ? "last" : "middle")
        }

        /// Code, colored by its tokens: tokens of one color in a row are one
        /// run.
        func code(_ lines: [String], language: DetectedLanguage, index: Int, gap: CGFloat) {
            let start = out.length
            for (number, line) in lines.enumerated() {
                var runs: [(text: String, color: Look.Color)] = []
                for token in SyntaxHighlighter.codeTokens(line, language: language) {
                    let color = Look.Color(token.type)
                    if let last = runs.last, last.color == color {
                        runs[runs.count - 1].text += token.text
                    } else {
                        runs.append((token.text, color))
                    }
                }
                if runs.isEmpty { runs.append(("", .foreground)) }
                runs[runs.count - 1].text += "\n"
                for run in runs {
                    emit(run.text, boxLook(number, of: lines.count, gap: gap, color: run.color))
                }
            }
            out.addAttribute(.readingGroup, value: "code:\(index)", range: NSRange(location: start, length: out.length - start))
        }

        /// A terminal's lines: a prompt line in the primary color, output in
        /// the secondary; a coding assistant's markers drawn as plain bullets
        /// and copied as read.
        func terminal(_ lines: [String], prompts: Set<Int>, index: Int, gap: CGFloat) {
            let start = out.length
            for (number, line) in lines.enumerated() {
                let shown = SyntaxHighlighter.plainBullets(line)
                let lineStart = out.length
                emit(shown + "\n", boxLook(number, of: lines.count, gap: gap,
                                           color: prompts.contains(number) ? .foreground : .secondary))
                guard shown != line else { continue }
                let drawn = Array(shown.utf16)
                let read = Array(line.utf16)
                guard drawn.count == read.count else { continue }
                // One unit for one: each changed marker copies as read.
                for offset in drawn.indices where drawn[offset] != read[offset] {
                    let original = String(utf16CodeUnits: [read[offset]], count: 1)
                    out.addAttribute(.readingCopyAs, value: original,
                                     range: NSRange(location: lineStart + offset, length: 1))
                }
            }
            out.addAttribute(.readingGroup, value: "terminal:\(index)",
                             range: NSRange(location: start, length: out.length - start))
        }

        // MARK: Tables

        /// Rows on tab stops: each column as wide as its widest cell and
        /// 14 points apart, numbers right-aligned, a hairline under each
        /// row but the last.
        func rows(_ rows: [[String]], numeric: [Bool], gap: CGFloat) {
            let columns = rows.map(\.count).max() ?? 0
            var widths = [CGFloat](repeating: 0, count: columns)
            let measured: [NSAttributedString.Key: Any] = [.font: Style.body]
            for row in rows {
                for (column, cell) in row.enumerated() {
                    let size = (cell as NSString).size(withAttributes: measured)
                    widths[column] = max(widths[column], ceil(size.width))
                }
            }
            var tabs: [Look.Tab] = []
            var x: CGFloat = 0
            for column in 0..<columns {
                if column > 0 {
                    let right = numeric.indices.contains(column) && numeric[column]
                    tabs.append(Look.Tab(right: right, location: right ? x + widths[column] : x))
                }
                x += widths[column] + 14
            }
            for (number, row) in rows.enumerated() {
                let last = number == rows.count - 1
                let line = row.count == 1 ? row[0] : row.joined(separator: "\t")
                emit(line + "\n", Look(font: .body, color: .foreground, lineHeight: 19,
                                       before: (number == 0 ? gap : 0) + 5, after: last ? 0 : 5, tabs: tabs,
                                       rule: !last))
            }
        }

        // MARK: Turns and quotes

        func turn(speaker: String, time: String, text: String, gap: CGFloat) {
            emit(speaker, Look(font: .bodyStrong, color: .foreground, lineHeight: 19, before: gap))
            emit("  " + time + "\n", Look(font: .caption, color: .muted, lineHeight: 19, before: gap, kern: 0))
            if !text.isEmpty {
                lines(ReadingAttributedText.lines(of: text), font: .body, color: .foreground, gap: 2, between: 2, lineHeight: 19,
                      links: true)
            }
        }

        /// Quoted mail: a rule at its left, the secondary color; closed as
        /// "Earlier in this thread" when it is longer than six lines.
        func quote(_ text: String, index: Int, gap: CGFloat, expanded: Bool) {
            let quoted = ReadingAttributedText.lines(of: text)
            let long = quoted.count > ReadingAttributedText.quoteLinesShown
            if long {
                let mark = expanded ? "\u{2304} " : "\u{203A} "
                emit(mark + ReadingCopy.earlierInThread + "\n",
                     Look(font: .label, color: .foreground, lineHeight: 19, before: gap, copyAs: "",
                          link: ReadingAttributedText.quoteLink(index)))
                guard expanded else { return }
            }
            for (number, line) in quoted.enumerated() {
                let marked = line.hasPrefix(">")
                let shown = marked ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line
                let start = out.length
                emit(shown + "\n", Look(font: .body, color: .secondary, lineHeight: 19,
                                        before: number == 0 ? (long ? 6 : gap) : 0, head: 12,
                                        quote: number == 0 ? "first" : number == quoted.count - 1 ? "last" : "middle"))
                if marked {
                    // The ">" it was read with copies with it.
                    out.addAttribute(.readingCopyPrefix, value: String(line.prefix(while: { $0 == ">" || $0 == " " })),
                                     range: NSRange(location: start, length: 1))
                }
                if Self.mayHoldAddress(shown) { link(from: start) }
            }
        }
    }
}

// MARK: - Attribute keys

public extension NSAttributedString.Key {
    /// A code or terminal line's place in its box: "first", "middle", "last"
    /// or "only".
    static let readingBox = NSAttributedString.Key("hippocampus.reading.box")
    /// A table row with a hairline under it.
    static let readingRule = NSAttributedString.Key("hippocampus.reading.rule")
    /// A quote's line: "first", "middle" or "last".
    static let readingQuote = NSAttributedString.Key("hippocampus.reading.quote")
    /// A heading's level, 1 or 2.
    static let readingHeading = NSAttributedString.Key("hippocampus.reading.heading")
    /// The group a block's text belongs to: "code:<index>",
    /// "terminal:<index>", "list:<index>:<items>".
    static let readingGroup = NSAttributedString.Key("hippocampus.reading.group")
    /// What a drawn character copies as (a checkbox, a terminal's marker); an
    /// empty string copies as nothing.
    static let readingCopyAs = NSAttributedString.Key("hippocampus.reading.copyAs")
    /// What a line copies with before it (a quote's ">").
    static let readingCopyPrefix = NSAttributedString.Key("hippocampus.reading.copyPrefix")
}

// MARK: - Style (design tokens only)

/// The reading view's fonts and colors: the window's tokens (`MCI.Font`,
/// `MCI.Color`), as AppKit draws them.
public enum ReadingStyle {
    /// A token's color, light or dark by the appearance it is drawn in, and
    /// with Increase Contrast `contrast` in its place.
    static func token(_ name: String, contrast: String? = nil) -> NSColor {
        let pick = { (name: String) in MCI.Color.allTokens.first { $0.name == name } }
        guard let normal = pick(name) else { return .labelColor }
        let strong = contrast.flatMap(pick) ?? normal
        return NSColor(name: NSColor.Name("hippocampus.reading.\(name)")) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                    .accessibilityHighContrastDarkAqua])
            let token = (match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua)
                ? strong : normal
            let dark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            return NSColor(hex: dark ? token.dark : token.light)
        }
    }

    public static let foreground = token("foreground")
    public static let secondary = token("foregroundSecondary")
    /// Muted text; with Increase Contrast, the secondary color.
    public static let muted = token("foregroundMuted", contrast: "foregroundSecondary")
    public static let accent = token("accent")
    /// The card the text sits on (`background`).
    public static let card = token("background")
    public static let accentDim = token("accentDim")
    /// Hairlines; with Increase Contrast, the strong border.
    public static let hairline = token("border", contrast: "borderStrong")
    public static let rule = token("borderStrong")
    /// A code or terminal box: the foreground, faint, over the card's
    /// background (the prototype's inset).
    public static let inset: NSColor = {
        guard let foreground = MCI.Color.allTokens.first(where: { $0.name == "foreground" }) else {
            return .quaternaryLabelColor
        }
        return NSColor(name: NSColor.Name("hippocampus.reading.inset")) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: foreground.dark, alpha: 0.07)
                : NSColor(hex: foreground.light, alpha: 0.055)
        }
    }()

    // Fonts never change once made; AppKit's fonts are safe to read from any
    // thread, which is where the string is built.
    nonisolated(unsafe) public static let body = NSFont.systemFont(ofSize: 14, weight: .regular)
    nonisolated(unsafe) public static let bodyStrong = NSFont.systemFont(ofSize: 14, weight: .semibold)
    nonisolated(unsafe) public static let title = NSFont.systemFont(ofSize: 17, weight: .semibold)
    nonisolated(unsafe) public static let heading = NSFont.systemFont(ofSize: 14, weight: .semibold)
    nonisolated(unsafe) public static let caption = NSFont.systemFont(ofSize: 12, weight: .regular)
    nonisolated(unsafe) public static let captionStrong = NSFont.systemFont(ofSize: 12, weight: .semibold)
    nonisolated(unsafe) public static let label = NSFont.systemFont(ofSize: 11, weight: .semibold)
    nonisolated(unsafe) public static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    nonisolated(unsafe) public static let checkbox = NSFont.systemFont(ofSize: 14, weight: .regular)
}

private typealias Style = ReadingStyle
