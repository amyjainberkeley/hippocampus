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

    /// The blocks as one string. `expandedQuotes` are the quotes (by block
    /// index) that were opened.
    public static func make(_ blocks: [ReadingBlock], expandedQuotes: Set<Int> = []) -> Built {
        var builder = Builder()
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

    private struct Builder {
        let out = NSMutableAttributedString()

        mutating func add(_ block: ReadingBlock, index: Int, gap: CGFloat, expanded: Bool) {
            switch block {
            case let .label(text):
                paragraph(text, font: Style.label, color: Style.muted, gap: gap)
            case let .heading(level, text):
                let font = level == 1 ? Style.title : Style.heading
                let start = out.length
                paragraph(text, font: font, color: Style.foreground, gap: gap, lineHeight: level == 1 ? 21 : 18)
                out.addAttribute(.readingHeading, value: level, range: NSRange(location: start, length: out.length - start))
            case let .byline(text), let .meta(text):
                lines(text.components(separatedBy: "\n"), font: Style.caption, color: Style.secondary, gap: gap,
                      between: 2, lineHeight: 16)
            case let .paragraph(text):
                lines(text.components(separatedBy: "\n"), font: Style.body, color: Style.foreground, gap: gap,
                      between: 2, lineHeight: 19, links: true)
            case let .other(_, text):
                lines(text.components(separatedBy: "\n"), font: Style.body, color: Style.foreground, gap: gap,
                      between: 2, lineHeight: 19, links: true)
            case let .lines(lines, table):
                if table {
                    rows(lines.map { [$0] }, numeric: [], gap: gap)
                } else {
                    self.lines(lines, font: Style.body, color: Style.foreground, gap: gap, between: 2, lineHeight: 19,
                               links: true)
                }
            case let .list(items):
                list(items, index: index, gap: gap)
            case let .code(text):
                let language = SyntaxHighlighter.detectLanguage(text)
                box(text.components(separatedBy: "\n"), kind: "code", index: index, gap: gap) { line in
                    Self.codeLine(line, language: language)
                }
            case let .terminal(text, prompts):
                let prompted = Set(prompts)
                var number = 0
                box(text.components(separatedBy: "\n"), kind: "terminal", index: index, gap: gap) { line in
                    defer { number += 1 }
                    return Self.terminalLine(line, prompt: prompted.contains(number))
                }
            case let .table(rows, numeric):
                self.rows(rows, numeric: numeric, gap: gap)
            case let .turn(speaker, time, text):
                turn(speaker: speaker, time: time, text: text, gap: gap)
            case let .quote(text):
                quote(text, index: index, gap: gap, expanded: expanded)
            }
        }

        /// The string ends without a line break after its last paragraph,
        /// and its first paragraph asks for no space above it: that space is
        /// the inset the view puts above the text.
        func finish() -> CGFloat {
            if out.string.hasSuffix("\n") {
                out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
            }
            guard out.length > 0,
                  let style = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
                  style.paragraphSpacingBefore > 0,
                  let first = style.mutableCopy() as? NSMutableParagraphStyle
            else { return 0 }
            first.paragraphSpacingBefore = 0
            let paragraph = (out.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            out.addAttribute(.paragraphStyle, value: first, range: paragraph)
            return style.paragraphSpacingBefore
        }

        // MARK: Paragraph styles

        static func style(lineHeight: CGFloat, before: CGFloat, after: CGFloat = 0, head: CGFloat = 0,
                          firstHead: CGFloat? = nil, tail: CGFloat = 0, tabs: [NSTextTab] = []) -> NSParagraphStyle {
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
                style.tabStops = tabs
                style.defaultTabInterval = 18
            }
            return style
        }

        /// How far to raise text so it sits in the middle of a line `height`
        /// high, as the prototype's line heights place it.
        static func baseline(_ font: NSFont, height: CGFloat) -> CGFloat {
            let natural = font.ascender - font.descender
            return max(0, (height - natural) / 2)
        }

        func attributes(_ font: NSFont, _ color: NSColor, style: NSParagraphStyle, height: CGFloat) -> [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: color, .paragraphStyle: style,
             .baselineOffset: Self.baseline(font, height: height)]
        }

        func paragraph(_ text: String, font: NSFont, color: NSColor, gap: CGFloat, lineHeight: CGFloat = 19) {
            let style = Self.style(lineHeight: lineHeight, before: gap)
            out.append(NSAttributedString(string: text + "\n", attributes: attributes(font, color, style: style, height: lineHeight)))
        }

        func lines(_ lines: [String], font: NSFont, color: NSColor, gap: CGFloat, between: CGFloat,
                   lineHeight: CGFloat, links: Bool = false) {
            for (number, line) in lines.enumerated() {
                let style = Self.style(lineHeight: lineHeight, before: number == 0 ? gap : between)
                let start = out.length
                out.append(NSAttributedString(string: line.trimmingCharacters(in: .whitespaces) + "\n",
                                              attributes: attributes(font, color, style: style, height: lineHeight)))
                if links { link(from: start) }
            }
        }

        /// Addresses in the text just added are links, drawn in the accent.
        func link(from start: Int) {
            let range = NSRange(location: start, length: out.length - start)
            let text = (out.string as NSString).substring(with: range)
            for found in LinkDetector.detect(in: text) {
                guard let url = URL(string: found.url) else { continue }
                let local = NSRange(found.range, in: text)
                out.addAttributes([.link: url, .foregroundColor: Style.accent],
                                  range: NSRange(location: start + local.location, length: local.length))
            }
        }

        // MARK: Lists

        func list(_ items: [ReadingListItem], index: Int, gap: CGFloat) {
            let start = out.length
            for (number, item) in items.enumerated() {
                let indent: CGFloat = item.depth > 0 ? 18 : 0
                let style = Self.style(lineHeight: 19, before: number == 0 ? gap : 4, head: indent + 18, firstHead: indent,
                                       tabs: [NSTextTab(textAlignment: .left, location: indent + 18)])
                let base = attributes(Style.body, Style.foreground, style: style, height: 19)
                let line = NSMutableAttributedString()
                if let checked = item.checked {
                    line.append(Self.checkbox(checked, copyAs: item.marker, attributes: base))
                } else {
                    var marker = base
                    marker[.foregroundColor] = Style.secondary
                    line.append(NSAttributedString(string: item.marker, attributes: marker))
                }
                // The marker's tab copies as the space Copy Text puts there;
                // the item's own lines under it break within it.
                var tab = base
                tab[.readingCopyAs] = " "
                line.append(NSAttributedString(string: "\t", attributes: tab))
                let text = item.text.replacingOccurrences(of: "\n", with: "\u{2028}")
                line.append(NSAttributedString(string: text + "\n", attributes: base))
                let lineStart = out.length
                out.append(line)
                link(from: lineStart)
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

        /// Lines in an inset box: each line a paragraph, so a long line wraps
        /// under itself with a two-space hanging indent.
        func box(_ lines: [String], kind: String, index: Int, gap: CGFloat,
                 line make: (String) -> NSAttributedString) {
            let start = out.length
            let padding: CGFloat = 10
            let hang = Style.mono.advancement(forGlyph: Style.mono.glyph(withName: "space")).width * 2
            for (number, text) in lines.enumerated() {
                let first = number == 0
                let last = number == lines.count - 1
                let style = Self.style(lineHeight: 18, before: first ? gap + padding : 0,
                                       after: last ? padding : 0, head: padding + hang, firstHead: padding,
                                       tail: -padding)
                let place = first && last ? "only" : first ? "first" : last ? "last" : "middle"
                let line = NSMutableAttributedString(attributedString: make(text))
                line.append(NSAttributedString(string: "\n"))
                let range = NSRange(location: 0, length: line.length)
                line.addAttributes([.paragraphStyle: style, .readingBox: place, .font: Style.mono,
                                    .baselineOffset: Self.baseline(Style.mono, height: 18)], range: range)
                out.append(line)
            }
            out.addAttribute(.readingGroup, value: "\(kind):\(index)", range: NSRange(location: start, length: out.length - start))
        }

        static func codeLine(_ line: String, language: DetectedLanguage) -> NSAttributedString {
            let out = NSMutableAttributedString()
            for token in SyntaxHighlighter.codeTokens(line, language: language) {
                let color: NSColor = switch token.type {
                case .keyword: Style.accent
                case .number: Style.accentDim
                case .comment: Style.muted
                case .string: Style.secondary
                case .plain: Style.foreground
                }
                out.append(NSAttributedString(string: token.text, attributes: [.font: Style.mono, .foregroundColor: color]))
            }
            if out.length == 0 {
                out.append(NSAttributedString(string: "", attributes: [.font: Style.mono]))
            }
            return out
        }

        /// A terminal's line: a prompt line in the primary color, output in
        /// the secondary; a coding assistant's markers drawn as plain bullets
        /// and copied as read.
        static func terminalLine(_ line: String, prompt: Bool) -> NSAttributedString {
            let shown = SyntaxHighlighter.plainBullets(line)
            let out = NSMutableAttributedString(string: shown, attributes: [
                .font: Style.mono, .foregroundColor: prompt ? Style.foreground : Style.secondary,
            ])
            let drawn = Array(shown.utf16)
            let read = Array(line.utf16)
            if drawn != read, drawn.count == read.count {
                // One unit for one: each changed marker copies as read.
                for offset in drawn.indices where drawn[offset] != read[offset] {
                    let original = String(utf16CodeUnits: [read[offset]], count: 1)
                    out.addAttribute(.readingCopyAs, value: original, range: NSRange(location: offset, length: 1))
                }
            }
            return out
        }

        // MARK: Tables

        /// Rows on tab stops: each column as wide as its widest cell and
        /// 14 points apart, numbers right-aligned, a hairline under each
        /// row but the last.
        func rows(_ rows: [[String]], numeric: [Bool], gap: CGFloat) {
            let columns = rows.map(\.count).max() ?? 0
            var widths = [CGFloat](repeating: 0, count: columns)
            for row in rows {
                for (column, cell) in row.enumerated() {
                    let size = (cell as NSString).size(withAttributes: [.font: Style.body])
                    widths[column] = max(widths[column], ceil(size.width))
                }
            }
            var tabs: [NSTextTab] = []
            var x: CGFloat = 0
            for column in 0..<columns {
                if column > 0 {
                    let right = numeric.indices.contains(column) && numeric[column]
                    tabs.append(right ? NSTextTab(textAlignment: .right, location: x + widths[column])
                                      : NSTextTab(textAlignment: .left, location: x))
                }
                x += widths[column] + 14
            }
            for (number, row) in rows.enumerated() {
                let last = number == rows.count - 1
                let style = Self.style(lineHeight: 19, before: (number == 0 ? gap : 0) + 5, after: last ? 0 : 5,
                                       tabs: tabs)
                var line = row.joined(separator: "\t")
                if row.count == 1 { line = row[0] }
                let text = NSMutableAttributedString(string: line + "\n",
                                                     attributes: attributes(Style.body, Style.foreground, style: style, height: 19))
                if !last {
                    text.addAttribute(.readingRule, value: true, range: NSRange(location: 0, length: text.length))
                }
                out.append(text)
            }
        }

        // MARK: Turns and quotes

        func turn(speaker: String, time: String, text: String, gap: CGFloat) {
            let style = Self.style(lineHeight: 19, before: gap)
            let head = NSMutableAttributedString(string: speaker,
                                                 attributes: attributes(Style.bodyStrong, Style.foreground, style: style, height: 19))
            var timeAttributes = attributes(Style.caption, Style.muted, style: style, height: 19)
            timeAttributes[.kern] = 0
            head.append(NSAttributedString(string: "  " + time + "\n", attributes: timeAttributes))
            out.append(head)
            if !text.isEmpty {
                lines(text.components(separatedBy: "\n"), font: Style.body, color: Style.foreground, gap: 2,
                      between: 2, lineHeight: 19, links: true)
            }
        }

        /// Quoted mail: a rule at its left, the secondary color; closed as
        /// "Earlier in this thread" when it is longer than six lines.
        func quote(_ text: String, index: Int, gap: CGFloat, expanded: Bool) {
            let quoted = text.components(separatedBy: "\n")
            let long = quoted.count > ReadingAttributedText.quoteLinesShown
            if long {
                let style = Self.style(lineHeight: 19, before: gap)
                var toggle = attributes(Style.label, Style.foreground, style: style, height: 19)
                toggle[.link] = ReadingAttributedText.quoteLink(index)
                toggle[.readingCopyAs] = ""
                let mark = expanded ? "\u{2304} " : "\u{203A} "
                out.append(NSAttributedString(string: mark + ReadingCopy.earlierInThread + "\n", attributes: toggle))
                guard expanded else { return }
            }
            for (number, line) in quoted.enumerated() {
                let shown = line.hasPrefix(">") ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line
                let style = Self.style(lineHeight: 19, before: number == 0 ? (long ? 6 : gap) : 0, head: 12)
                var quoteAttributes = attributes(Style.body, Style.secondary, style: style, height: 19)
                quoteAttributes[.readingQuote] = number == 0 ? "first" : number == quoted.count - 1 ? "last" : "middle"
                let start = out.length
                out.append(NSAttributedString(string: shown + "\n", attributes: quoteAttributes))
                if line.hasPrefix(">") {
                    // The ">" it was read with copies with it.
                    out.addAttribute(.readingCopyPrefix, value: String(line.prefix(while: { $0 == ">" || $0 == " " })),
                                     range: NSRange(location: start, length: 1))
                }
                link(from: start)
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
