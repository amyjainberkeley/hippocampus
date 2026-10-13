// SPDX-License-Identifier: TBD-private
//
// OCRRegionRoles — sorts a window's reading into content and chrome
// (RULINGS T1, T3, T15). Reference: `tools/ocr/screens/layout.py`; the
// `OCRReadingOrder` parity fixtures pin both to the same blocks and the same
// stored string.
//
// Roles are opt-in: only a caller that passes an `OCRWindowGeometry` gets
// them. Without geometry the reading is unclassified, byte for byte what it
// was, and re-reads stay that way this round. Nothing is dropped: chrome is
// moved after U+001E, never deleted, and when unsure it is content.

import CoreGraphics
import Foundation

/// The window an OCR read belongs to. `rect` is the window in the frame,
/// normalized with a bottom-left origin (the boxes' convention); for the
/// focused window it is the whole frame. `pixelsPerPoint` turns frame pixels
/// into the window's points.
public struct OCRWindowGeometry: Sendable, Equatable {
    public let rect: CGRect
    public let pixelsPerPoint: CGFloat
    public let title: String?
    public let bundleId: String?

    public init(rect: CGRect, pixelsPerPoint: CGFloat, title: String?, bundleId: String?) {
        self.rect = rect
        self.pixelsPerPoint = pixelsPerPoint
        self.title = title
        self.bundleId = bundleId
    }

    /// A window given in global points with a top-left origin (the window
    /// server's), placed in a display frame given the same way, as the
    /// display frame's normalized bottom-left space. A window partly off the
    /// display keeps its true edges, so its hidden status bar is never
    /// mistaken for the visible bottom row.
    public static func normalizedRect(of window: CGRect, in display: CGRect) -> CGRect {
        guard display.width > 0, display.height > 0 else { return .null }
        return CGRect(x: (window.minX - display.minX) / display.width,
                      y: 1 - (window.maxY - display.minY) / display.height,
                      width: window.width / display.width,
                      height: window.height / display.height)
    }
}

extension OCRReadingOrder {
    static let minWindowWidth: CGFloat = 320
    static let minWindowHeight: CGFloat = 240
    /// Points, and share of height: where bars sit without separators.
    static let topBandPoints: CGFloat = 110
    static let topBandShare: CGFloat = 0.20
    static let bottomBandPoints: CGFloat = 24
    static let bottomBandShare: CGFloat = 0.05
    /// Of the window's width.
    static let navMaxWidth: CGFloat = 0.30
    /// A navigation column starts this close to the window's left edge.
    static let navEdge: CGFloat = 0.06
    static let navMinRows = 4
    /// Median words per row.
    static let navMaxWords = 3
    /// Share of rows that look like code.
    static let navMaxCode: Double = 0.2
    /// What sits beside navigation is at least this much wider.
    static let navWider: CGFloat = 1.5
    /// A pane with this share of its rows in navigation is navigation.
    static let navPaneShare: Double = 0.75
    static let placeholderMaxWords = 6
    /// A composer sits this close to its pane's bottom edge, in line heights.
    static let placeholderReach: CGFloat = 3.0
    /// A title bar's text starts this close to the window's top edge, in line heights.
    static let titleReach: CGFloat = 1.5
    /// Items of a bar stand this far apart, in line heights.
    static let spreadGap: CGFloat = 3.0
    /// A table's cells line up within this, in line heights.
    static let gridAlign: CGFloat = 0.5
    /// Lines cut short in a list of previews, and their share of its lines.
    static let previewMin = 2
    static let previewShare: Double = 0.2
    static let dateMaxWords = 6
    /// A date divider's centre is this close to its pane's, as a share of its width.
    static let dateCentre: CGFloat = 0.05
    static let dateWords: Set<String> = Set((
        "today yesterday tomorrow now at am pm a.m. p.m. "
            + "monday tuesday wednesday thursday friday saturday sunday mon tue tues wed thu thurs fri sat sun "
            + "january february march april may june july august september october november december "
            + "jan feb mar apr jun jul aug sep sept oct nov dec"
    ).split(separator: " ").map(String.init))
    /// Share of rows that look like code for a block to be code.
    static let codeShare: Double = 0.4
    /// Rows read from a pane's top row down to tell whether it sits above code.
    static let codeAhead = 6

    static let chromeSeparator = "\n\n\u{1E}\n"

    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty",
    ]
    /// The Rust reader's CHAT_APPS: apps whose windows are conversations,
    /// where a centred date divides messages.
    static let chatApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "com.hnc.Discord", "net.whatsapp.WhatsApp",
        "desktop.WhatsApp", "ru.keepcoder.Telegram", "org.telegram.desktop", "org.whispersystems.signal-desktop",
        "com.microsoft.teams2", "com.facebook.archon", "com.openai.chat", "com.anthropic.claudefordesktop",
    ]
    static let ellipses = ["\u{2026}", "..."]
    static let breadcrumb = [" > ", " \u{203A} ", " / ", " \u{3009} ", " \u{276F} "]
    static let codeMarks = Set("{}();=<>[]".unicodeScalars)
    static let codeEndings = Set("{}();,=[]<>:".unicodeScalars)
    static let prompts = ["$ ", "% ", "\u{276F} "]
    /// A composer's prompt is one of these as its whole text, or starts with
    /// one of the starts ("Message #general", "Message Maya Chen").
    static let composerWords: Set<String> = [
        "message", "imessage", "text message", "reply", "type a message", "write a message", "leave a comment",
        "add a comment", "write a comment",
    ]
    static let composerStarts = [
        "message ", "type a message", "write a message", "leave a comment", "add a comment", "write a comment",
    ]
    static let sentenceEnds = Set(".!?".unicodeScalars)

    // MARK: - The reading

    enum Role: String {
        case content
        case chrome
    }

    struct Block {
        let role: Role
        /// The rule that set the role: content, unplaced, navigation, bar,
        /// placeholder, status, date, gutter or glyph.
        let rule: String
        let boxes: [Box]
        let text: String
    }

    /// `blocks` in reading order, and the `stored` string built from them.
    struct Reading {
        let blocks: [Block]
        let stored: String
        let classified: Bool

        var contentBlocks: Int { blocks.filter { $0.role == .content }.count }
        var chromeBlocks: Int { blocks.filter { $0.role == .chrome }.count }
        var chromeLines: Int {
            blocks.filter { $0.role == .chrome }.reduce(0) { $0 + $1.text.split(separator: "\n").count }
        }
    }

    // MARK: - Role rules

    static func looksLikeCode(_ text: String) -> Bool {
        let text = trim(text)
        guard let last = text.unicodeScalars.last else { return false }
        if contains(text, "::") || contains(text, "->") || contains(text, "=>")
            || text.unicodeScalars.contains(where: { codeMarks.contains($0) }) {
            return true
        }
        return codeEndings.contains(last)
    }

    static func isCode(_ blockRows: [[Box]], terminal: Bool) -> Bool {
        if terminal { return true }
        let texts = blockRows.map { row in row.map(\.trimmed).joined(separator: " ") }
        if texts.contains(where: { text in prompts.contains { hasPrefix(text, $0) } }) { return true }
        return Double(texts.filter(looksLikeCode).count) >= codeShare * Double(texts.count)
    }

    static func normalized(_ text: String) -> String {
        words(text).joined(separator: " ").lowercased()
    }

    static func endsWithEllipsis(_ text: String) -> Bool {
        ellipses.contains { hasSuffix(text, $0) }
    }

    /// A web address or a domain, as a browser's address bar shows it. A
    /// padlock or a star read beside it is ignored.
    static func isAddress(_ text: String) -> Bool {
        let parts = words(text).filter { length($0) > glyphMaxChars }
        guard parts.count == 1 else { return false }
        let token = parts[0]
        let scalars = Array(token.unicodeScalars)
        let slash = scalars.firstIndex(of: "/")
        let host = scalars[..<(slash ?? scalars.count)]
        let brackets = Set("(){}<>".unicodeScalars)
        return host.contains(".") && host.last != "." && !scalars.contains(where: { brackets.contains($0) })
            && (slash != nil || hasPrefix(token, "http") || hasPrefix(token, "www."))
    }

    /// Text cut short with an ellipsis, as a tab or a list shows a long title.
    /// A close mark read after it does not hide the cut.
    static func truncated(_ text: String) -> Bool {
        var parts = words(text)
        while let last = parts.last, length(last) <= glyphMaxChars, !endsWithEllipsis(last) {
            parts.removeLast()
        }
        return parts.last.map(endsWithEllipsis) ?? false
    }

    /// A row of nothing but marks: every token one or two characters, at least
    /// one of them a symbol. Code punctuation is code, not a mark.
    static func iconRow(_ row: [Box]) -> Bool {
        let tokens = row.flatMap { words($0.text) }
        return !tokens.isEmpty && tokens.allSatisfy { length($0) <= glyphMaxChars } && tokens.contains { token in
            !token.unicodeScalars.contains(where: isLetterOrNumber)
                && !token.unicodeScalars.allSatisfy { codePunctuation.contains($0) }
        }
    }

    /// A row of buttons drawn as letters (a composer's B, I, S) beside icons.
    static func marksRow(_ row: [Box]) -> Bool {
        let tokens = row.flatMap { words($0.text) }
        return !tokens.isEmpty
            && tokens.allSatisfy { length($0) <= 3 && !$0.unicodeScalars.contains(where: isDigit) }
            && row.contains(where: glyphShaped)
    }

    /// A row of interface: tabs, a toolbar, a breadcrumb, an address bar or,
    /// for the window's first row, its title.
    static func stripShaped(_ row: [Box], title: String) -> Bool {
        let texts = row.map(\.trimmed)
        let joined = texts.joined(separator: " ")
        if row.count >= 3 && texts.allSatisfy({ words($0).count <= 4 }) { return true }
        if texts.contains(where: truncated) { return true }
        if breadcrumb.map({ occurrences(of: $0, in: joined) }).reduce(0, +) >= 2 { return true }
        if isAddress(joined) { return true }
        return !title.isEmpty && texts.contains { namesWindow($0, title: title) }
    }

    /// Whether a box's text is the window's title, or most of it, or holds it
    /// with little else.
    static func namesWindow(_ text: String, title: String) -> Bool {
        let line = normalized(text), name = normalized(title)
        let lineLength = Double(length(line)), nameLength = Double(length(name))
        if lineLength < 4 || nameLength < 4 { return false }
        return (contains(name, line) && lineLength >= 0.5 * nameLength)
            || (contains(line, name) && nameLength >= 0.5 * lineLength)
    }

    /// A field's text, short enough for a prompt, with icons read beside it
    /// left out; "" when the row is longer than a prompt.
    static func promptWords(_ row: [Box]) -> String {
        let joined = row.filter { $0.compactLength > glyphMaxChars }.map(\.trimmed).joined(separator: " ")
        return !joined.isEmpty && words(joined).count <= placeholderMaxWords ? joined : ""
    }

    /// A composer's prompt: worded like one, or trailing off. A sentence is not one.
    static func isPlaceholder(_ row: [Box]) -> Bool {
        let joined = promptWords(row)
        guard let last = joined.unicodeScalars.last else { return false }
        if endsWithEllipsis(joined) { return true }
        if sentenceEnds.contains(last) { return false }
        let lowered = normalized(joined)
        return composerWords.contains(lowered) || composerStarts.contains { hasPrefix(lowered, $0) }
    }

    /// A search field: "Search", or "Search" and what it searches.
    static func isSearch(_ row: [Box]) -> Bool {
        let joined = promptWords(row)
        guard let last = joined.unicodeScalars.last, !sentenceEnds.contains(last) else { return false }
        let lowered = normalized(joined)
        return lowered == "search" || hasPrefix(lowered, "search ")
    }

    /// A rectangle of the window between separators, and its regions.
    /// `ruled`: the pane is one row of a ruled table.
    final class Pane {
        let rect: Rect
        let regions: [Cut]
        let ruled: Bool

        init(rect: Rect, regions: [Cut], ruled: Bool) {
            self.rect = rect
            self.regions = regions
            self.ruled = ruled
        }
    }

    /// The window being read, in frame pixels with a top-left origin.
    struct Window {
        let title: String
        let terminal: Bool
        let chat: Bool
        let x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat
        let width: CGFloat, height: CGFloat
        let topBand: CGFloat, bottomBand: CGFloat
        let lineHeight: CGFloat

        init(_ geometry: OCRWindowGeometry, width frameWidth: CGFloat, height frameHeight: CGFloat,
             lineHeight: CGFloat) {
            title = geometry.title ?? ""
            terminal = geometry.bundleId.map { OCRReadingOrder.terminals.contains($0) } ?? false
            chat = geometry.bundleId.map { OCRReadingOrder.chatApps.contains($0) } ?? false
            let scale = OCRReadingOrder.scale(geometry)
            let rect = OCRReadingOrder.windowRect(geometry, width: frameWidth, height: frameHeight)
            x0 = rect.x0
            y0 = rect.y0
            x1 = rect.x1
            y1 = rect.y1
            width = x1 - x0
            height = y1 - y0
            topBand = y0 + min(OCRReadingOrder.topBandPoints * scale, OCRReadingOrder.topBandShare * height)
            bottomBand = y1 - min(OCRReadingOrder.bottomBandPoints * scale, OCRReadingOrder.bottomBandShare * height)
            self.lineHeight = lineHeight
        }
    }

    static func scale(_ geometry: OCRWindowGeometry) -> CGFloat {
        geometry.pixelsPerPoint > 0 && geometry.pixelsPerPoint.isFinite ? geometry.pixelsPerPoint : 1
    }

    static func windowRect(_ geometry: OCRWindowGeometry, width: CGFloat, height: CGFloat) -> Rect {
        let x = geometry.rect.origin.x, y = geometry.rect.origin.y
        let w = geometry.rect.size.width, h = geometry.rect.size.height
        return Rect(x0: x * width, y0: (1 - y - h) * height, x1: (x + w) * width, y1: (1 - y) * height)
    }

    /// A row whose items stand far apart: a title at one end of a bar and its
    /// controls at the other.
    static func spread(_ row: [Box], lineHeight: CGFloat) -> Bool {
        row.count >= 2 && zip(row, row.dropFirst()).allSatisfy { $1.x0 - $0.x1 >= spreadGap * lineHeight }
    }

    /// A region of a pane, with what the role rules ask of it worked out once.
    final class Region {
        let boxes: [Box]
        let rows: [[Box]]
        let x0: CGFloat, x1: CGFloat, top: CGFloat, bottom: CGFloat
        let table: Bool

        init(_ boxes: [Box], table: Bool = false) {
            self.boxes = boxes
            rows = OCRReadingOrder.rows(boxes)
            x0 = boxes.map(\.x0).min() ?? 0
            x1 = boxes.map(\.x1).max() ?? 0
            top = boxes.map(\.y0).min() ?? 0
            bottom = boxes.map(\.y1).max() ?? 0
            // A table worth protecting has two rows or more; one row of short
            // items is how a bar looks to the cut.
            self.table = table && rows.count >= 2
        }
    }

    /// Whether something at least `navWider` times as wide stands to the right
    /// of `region`, level with it.
    static func widerBeside(_ region: Region, _ everything: [Region], skip: Set<ObjectIdentifier>) -> Bool {
        everything.contains { other in
            !skip.contains(ObjectIdentifier(other)) && other.x0 >= region.x1
                && other.x1 - other.x0 >= navWider * (region.x1 - region.x0)
                && other.top < region.bottom && other.bottom > region.top
        }
    }

    /// A column of short items at the window's left edge, beside something
    /// wider. Never on the right, never code, never a table.
    static func isNavigation(_ region: Region, _ everything: [Region], skip: Set<ObjectIdentifier>,
                             win: Window) -> Bool {
        if region.table || region.rows.count < navMinRows { return false }
        if region.x0 - win.x0 > navEdge * win.width || region.x1 - region.x0 > navMaxWidth * win.width {
            return false
        }
        let counts = region.rows.map { row in Double(row.map(\.wordCount).reduce(0, +)) }
        if median(counts) > Double(navMaxWords) { return false }
        let texts = region.rows.map { row in row.map(\.trimmed).joined(separator: " ") }
        if Double(texts.filter(looksLikeCode).count) > navMaxCode * Double(texts.count) { return false }
        return widerBeside(region, everything, skip: skip)
    }

    /// How many items of `row` start or end within `gridAlign` line heights of
    /// where an item of `other` starts or ends.
    static func linedUp(_ row: [Box], _ other: [Box], lineHeight: CGFloat) -> Int {
        let reach = gridAlign * lineHeight
        return row.filter { box in
            other.contains { abs(box.x0 - $0.x0) <= reach || abs(box.x1 - $0.x1) <= reach }
        }.count
    }

    /// Whether `row` lines up with the row below it, item for item, as a
    /// table's rows do: two of its items at least.
    static func grid(_ row: [Box], _ below: [Box], lineHeight: CGFloat) -> Bool {
        row.count >= 2 && below.count >= 2 && linedUp(row, below, lineHeight: lineHeight) >= 2
    }

    /// Whether every item of the row with fewer items (the upper one when both
    /// have as many) lines up with an item of the other: a table's header over
    /// its row.
    static func inStep(_ row: [Box], _ below: [Box], lineHeight: CGFloat) -> Bool {
        let (fewer, more) = row.count <= below.count ? (row, below) : (below, row)
        return fewer.count >= 2 && linedUp(fewer, more, lineHeight: lineHeight) == fewer.count
    }

    /// A panel's title set in capitals (EXPLORER, CHAT), with icons beside it at most.
    static func capsLabel(_ row: [Box]) -> Bool {
        let labels = row.filter { hasLetter($0.text) }.map(\.trimmed)
        if labels.isEmpty || row.contains(where: { $0.compactLength > glyphMaxChars && !hasLetter($0.text) }) {
            return false
        }
        for text in labels {
            let letters = text.unicodeScalars.filter(isLetter)
            if letters.count < 2 || letters.contains(where: { $0.properties.generalCategory != .uppercaseLetter }) {
                return false
            }
            if words(text).count > navMaxWords { return false }
        }
        return true
    }

    /// Regions that make up a list of previews: a column of stacked regions
    /// where several lines are cut short, beside a wider column.
    static func previewLists(_ regions: [Region], _ everything: [Region]) -> Set<ObjectIdentifier> {
        var found = Set<ObjectIdentifier>()
        var i = 0
        while i < regions.count {
            var column = [regions[i]]
            var x0 = regions[i].x0, x1 = regions[i].x1
            var j = i + 1
            while j < regions.count {
                let other = regions[j]
                if min(x1, other.x1) - max(x0, other.x0) < 0.5 * min(x1 - x0, other.x1 - other.x0) { break }
                column.append(other)
                x0 = min(x0, other.x0)
                x1 = max(x1, other.x1)
                j += 1
            }
            let columnRows = column.flatMap(\.rows)
            let cutShort = columnRows.filter { row in truncated(row.map(\.trimmed).joined(separator: " ")) }.count
            if !column.contains(where: \.table) && columnRows.count >= navMinRows && cutShort >= previewMin
                && Double(cutShort) >= previewShare * Double(columnRows.count) {
                let members = Set(column.map { ObjectIdentifier($0) })
                if widerBeside(Region(column.flatMap(\.boxes)), everything, skip: members) {
                    found.formUnion(members)
                }
            }
            i = j
        }
        return found
    }

    /// A word of a date or a time: a weekday, a month, today, a clock time, a
    /// day of the month or a year.
    static func dateWord(_ token: String) -> Bool {
        var scalars = Array(token.unicodeScalars)
        while let first = scalars.first, first == "," || first == "." { scalars.removeFirst() }
        while let last = scalars.last, last == "," || last == "." { scalars.removeLast() }
        let word = String(String.UnicodeScalarView(scalars)).lowercased()
        if dateWords.contains(word) { return true }
        var digits = Array(word.unicodeScalars)
        for suffix in ["st", "nd", "rd", "th", "am", "pm"] where hasSuffix(word, suffix) && digits.count > 2 {
            digits.removeLast(2)
            break
        }
        let marks = Set(":/.-".unicodeScalars)
        return !digits.isEmpty && digits.allSatisfy { isDigit($0) || marks.contains($0) } && digits.contains(where: isDigit)
    }

    /// A divider that says when: a short line, alone on its row, centred in its
    /// pane, made only of date and time words.
    static func dateLine(_ row: [Box], pane: Pane) -> Bool {
        guard row.count == 1 else { return false }
        let box = row[0]
        let tokens = words(box.text)
        if tokens.isEmpty || tokens.count > dateMaxWords || !tokens.allSatisfy(dateWord) { return false }
        if !tokens.contains(where: hasLetter) && !tokens.contains(where: { contains($0, ":") }) {
            return false  // numbers alone are data
        }
        let px0 = pane.rect.x0, px1 = pane.rect.x1
        return abs(box.cx - (px0 + px1) / 2) <= dateCentre * (px1 - px0) && box.w <= 0.5 * (px1 - px0)
    }

    /// Whether a pane's top row is a bar: interface in a strip, marks only, a
    /// panel's title in capitals, or, for a pane of one row in the window's top
    /// band, a header with items at both ends or a search field. Above code
    /// only a strip comes off. A row that lines up with the row below it is a
    /// table's header, except in a pane wholly in the window's top band.
    static func isBar(_ row: [Box], below: [Box]?, win: Window, paneTop: Bool, panel: Bool, single: Bool,
                      code: Bool, bandPane: Bool) -> Bool {
        if let below, !bandPane, grid(row, below, lineHeight: win.lineHeight) { return false }
        let topBand = centreY(row) <= win.topBand
        if !(paneTop || topBand) { return false }
        // Only a row at the window's top edge can be its title bar.
        let title = rowSpan(row).top <= win.y0 + titleReach * win.lineHeight ? win.title : ""
        if code { return stripShaped(row, title: title) }
        let alone = below == nil && paneTop  // the only row of a pane between separators
        if stripShaped(row, title: title) || iconRow(row) || (panel && capsLabel(row)) || (alone && marksRow(row)) {
            return true
        }
        return single && topBand && (spread(row, lineHeight: win.lineHeight) || isSearch(row) || isPlaceholder(row))
    }

    struct Assigned {
        let role: Role
        let rule: String
        let boxes: [Box]
        let pane: Pane
    }

    /// Roles in reading order, for the regions of each pane.
    static func classify(_ windowPanes: [Pane], win: Window) -> [Assigned] {
        let regionsByPane = windowPanes.map { pane in pane.regions.map { Region($0.boxes, table: $0.table) } }
        let everything = regionsByPane.flatMap { $0 }
        var out: [Assigned] = []
        for (index, pane) in windowPanes.enumerated() {
            let mine = regionsByPane[index]
            if mine.isEmpty { continue }
            if win.terminal {
                out += mine.map { Assigned(role: .content, rule: "content", boxes: $0.boxes, pane: pane) }
                continue
            }
            let r = pane.rect
            let own = Set(mine.map { ObjectIdentifier($0) })
            // A pane of its own beside the rest is judged whole. Otherwise each
            // region is judged on its own.
            if r.x1 - r.x0 < win.width - 1 && !mine.contains(where: \.table)
                && isNavigation(Region(mine.flatMap(\.boxes)), everything, skip: own, win: win) {
                out += mine.map { Assigned(role: .chrome, rule: "navigation", boxes: $0.boxes, pane: pane) }
                continue
            }
            var navigation = previewLists(mine, everything)
            for region in mine where isNavigation(region, everything, skip: [ObjectIdentifier(region)], win: win) {
                navigation.insert(ObjectIdentifier(region))
            }
            // In a pane that is mostly navigation, a short line left over in the
            // navigation's column belongs with it.
            let navRegions = mine.filter { navigation.contains(ObjectIdentifier($0)) }
            let navRows = navRegions.map(\.rows.count).reduce(0, +)
            if !navigation.isEmpty && Double(navRows) >= navPaneShare * Double(mine.map(\.rows.count).reduce(0, +)) {
                let navX1 = navRegions.map(\.x1).max()!
                for region in mine where !region.table && region.rows.count <= 2 && region.x0 < navX1
                    && region.rows.allSatisfy({ row in words(row.map(\.text).joined(separator: " ")).count <= 4 }) {
                    navigation.insert(ObjectIdentifier(region))
                }
            }
            let rest = mine.filter { !navigation.contains(ObjectIdentifier($0)) }
            var home: [ObjectIdentifier: Region] = [:]
            for region in rest {
                for box in region.boxes { home[ObjectIdentifier(box)] = region }
            }
            let inTable: (Box) -> Bool = { home[ObjectIdentifier($0)]?.table ?? false }
            let lines = rows(rest.flatMap(\.boxes))
            let paneTop = r.y0 > win.y0 + 0.5 * win.lineHeight  // a separator above it
            // A panel: below the window's top and narrower than it, so its
            // title may be set in capitals.
            let panel = paneTop && r.x1 - r.x0 < win.width - 1
            // Bars come off the top of a pane, one row at a time, until a row
            // reads as something else. A table's rows are never bars, nor are
            // a ruled table's, except in a pane wholly in the top band.
            var top = 0
            let bandPane = r.y1 <= win.topBand
            while (!pane.ruled || bandPane) && top < lines.count
                && (bandPane || !lines[top].contains(where: inTable)) {
                let below = top + 1 < lines.count ? lines[top + 1] : nil
                let code = top + 1 < lines.count
                    && isCode(Array(lines[top..<min(lines.count, top + codeAhead)]), terminal: false)
                guard isBar(lines[top], below: below, win: win, paneTop: paneTop, panel: panel,
                            single: lines.count == 1, code: code, bandPane: bandPane) else { break }
                top += 1
            }
            // At the foot of a pane: a composer's placeholder, alone in its
            // region, or the window's status bar.
            var foot: Assigned?
            if !pane.ruled && top < lines.count && !lines[lines.count - 1].contains(where: inTable) {
                let last = lines[lines.count - 1]
                let alone = last.allSatisfy { home[ObjectIdentifier($0)]?.rows.count == 1 }
                let atFoot = r.y1 - rowSpan(last).bottom <= placeholderReach * win.lineHeight
                if atFoot && alone && isPlaceholder(last) {
                    foot = Assigned(role: .chrome, rule: "placeholder", boxes: last, pane: pane)
                } else if centreY(last) >= win.bottomBand && stripShaped(last, title: "") {
                    foot = Assigned(role: .chrome, rule: "status", boxes: last, pane: pane)
                }
            }
            var moved = Set<ObjectIdentifier>()
            for row in lines[..<top] {
                for box in row { moved.insert(ObjectIdentifier(box)) }
            }
            for box in foot?.boxes ?? [] { moved.insert(ObjectIdentifier(box)) }
            out += lines[..<top].map { Assigned(role: .chrome, rule: "bar", boxes: $0, pane: pane) }
            for region in mine {
                if navigation.contains(ObjectIdentifier(region)) {
                    out.append(Assigned(role: .chrome, rule: "navigation", boxes: region.boxes, pane: pane))
                    continue
                }
                // A date line between messages divides them; it is not said.
                var run: [[Box]] = []
                for full in region.rows {
                    let row = full.filter { !moved.contains(ObjectIdentifier($0)) }
                    if row.isEmpty { continue }
                    if win.chat && !region.table && dateLine(row, pane: pane) {
                        if !run.isEmpty {
                            out.append(Assigned(role: .content, rule: "content", boxes: run.flatMap { $0 }, pane: pane))
                            run = []
                        }
                        out.append(Assigned(role: .chrome, rule: "date", boxes: row, pane: pane))
                    } else {
                        run.append(row)
                    }
                }
                if !run.isEmpty {
                    out.append(Assigned(role: .content, rule: "content", boxes: run.flatMap { $0 }, pane: pane))
                }
            }
            if let foot { out.append(foot) }
        }
        return out
    }

    // MARK: - Assembly

    /// (placed boxes, unplaced texts). U+001E goes first, so no line can
    /// write the separator the stored text uses.
    static func prepare(_ lines: [OCRLine], minConfidence: Float, width: CGFloat,
                        height: CGFloat) -> (boxes: [Box], unplaced: [String]) {
        var boxes: [Box] = [], unplaced: [String] = []
        var positions: [Data: [Box]] = [:]
        for line in lines {
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: line.text.unicodeScalars.lazy.filter { $0.value != 0x1E })
            let text = String(scalars)
            let confidence = line.confidence
            guard confidence.isFinite, minConfidence <= confidence, confidence <= 1, !trim(text).isEmpty else {
                continue
            }
            let x = line.boundingBox.origin.x, y = line.boundingBox.origin.y
            let w = line.boundingBox.size.width, h = line.boundingBox.size.height
            guard x.isFinite, y.isFinite, w.isFinite, h.isFinite, w > 0, h > 0, x >= 0, y >= 0,
                  x + w <= 1, y + h <= 1 else {
                unplaced.append(text)
                continue
            }
            // To pixels with a top-left origin, so gaps compare in one unit.
            let box = Box(text, x * width, (1 - y - h) * height, (x + w) * width, (1 - y) * height)
            // Literal bytes: canonically equal readings stay apart.
            let literal = Data(text.utf8)
            let previous = positions[literal, default: []]
            if previous.contains(where: { iou($0, box) >= 0.7 }) { continue }
            boxes.append(box)
            // Bound comparison work on a screen with thousands of identical labels.
            if previous.count < duplicatePositions { positions[literal, default: []].append(box) }
        }
        return (boxes, unplaced)
    }

    static func classifiable(_ geometry: OCRWindowGeometry, width: CGFloat, height: CGFloat) -> Bool {
        let scale = scale(geometry)
        let rect = windowRect(geometry, width: width, height: height)
        return (rect.x1 - rect.x0) / scale >= minWindowWidth && (rect.y1 - rect.y0) / scale >= minWindowHeight
    }

    static func render(_ boxes: [Box], left: CGFloat? = nil, flat: Bool = false, stacked: Bool = false) -> String {
        renderRows(boxes, left: left ?? boxes.map(\.x0).min() ?? 0, flat: flat, stacked: stacked)
            .joined(separator: "\n")
    }

    /// The frame cut at its separators, each pane cut into regions; a ruled
    /// table's row stays whole.
    static func paneRegions(_ boxes: [Box], separators: [Separator], rect: Rect, lineHeight: CGFloat) -> [Pane] {
        let windowPanes = panes(boxes, separators: separators, rect: rect, lineHeight: lineHeight)
        let ruled = ruledRows(windowPanes, lineHeight: lineHeight)
        return windowPanes.enumerated().map { index, pane in
            if pane.boxes.isEmpty { return Pane(rect: pane.rect, regions: [], ruled: false) }
            if ruled.contains(index) {
                return Pane(rect: pane.rect, regions: [Cut(boxes: pane.boxes, table: false)], ruled: true)
            }
            return Pane(rect: pane.rect, regions: cut(pane.boxes, lineHeight: lineHeight), ruled: false)
        }
    }

    static func unclassified(_ boxes: [Box], unplaced: [String], separators: [Separator], width: CGFloat,
                             height: CGFloat, lineHeight: CGFloat) -> Reading {
        var blocks: [Block] = []
        let frame = Rect(x0: 0, y0: 0, x1: width, y1: height)
        for pane in paneRegions(boxes, separators: separators, rect: frame, lineHeight: lineHeight) {
            for region in pane.regions {
                blocks.append(Block(role: .content, rule: "content", boxes: region.boxes, text: render(region.boxes)))
            }
        }
        let page = blocks.map(\.text).joined(separator: "\n\n")
        let stored = ((page.isEmpty ? [] : [page]) + unplaced).joined(separator: "\n")
        if !unplaced.isEmpty {
            blocks.append(Block(role: .content, rule: "unplaced", boxes: [], text: unplaced.joined(separator: "\n")))
        }
        return Reading(blocks: blocks, stored: stored, classified: false)
    }

    /// Code regions stacked in one pane share their leftmost edge, so a blank
    /// line in code does not reset its indentation.
    static func codeLeftEdges(_ roles: [Assigned], win: Window) -> [Int: CGFloat] {
        let code = roles.enumerated().filter { entry in
            entry.element.role == .content && isCode(rows(entry.element.boxes), terminal: win.terminal)
        }.map { (index: $0.offset, pane: $0.element.pane, x0: $0.element.boxes.map(\.x0).min()!,
                 x1: $0.element.boxes.map(\.x1).max()!) }
        var edges: [Int: CGFloat] = [:]
        for entry in code {
            edges[entry.index] = code.filter { other in
                other.pane === entry.pane && other.x0 < entry.x1 && other.x1 > entry.x0
            }.map(\.x0).min()
        }
        return edges
    }

    /// The reading of engine `lines`. `separators` are the worker's pane
    /// separators (normalized, bottom-left, one of width and height zero).
    /// `window` turns on classification; without it the reading is
    /// unclassified, as it always was.
    static func read(_ lines: [OCRLine], pixelSize: CGSize, separators: [CGRect] = [],
                     window: OCRWindowGeometry? = nil, minConfidence: Float = 0.5) -> Reading {
        let width = pixelSize.width > 0 ? pixelSize.width : 1
        let height = pixelSize.height > 0 ? pixelSize.height : 1
        let (boxes, unplaced) = prepare(lines, minConfidence: minConfidence, width: width, height: height)
        if boxes.isEmpty {
            let text = unplaced.joined(separator: "\n")
            return Reading(blocks: text.isEmpty ? [] : [Block(role: .content, rule: "unplaced", boxes: [], text: text)],
                           stored: text, classified: false)
        }
        let lineHeight = CGFloat(median(boxes.map { Double($0.h) }))
        let seps = toSeparators(separators, width: width, height: height)
        guard let window, classifiable(window, width: width, height: height) else {
            return unclassified(boxes, unplaced: unplaced, separators: seps, width: width, height: height,
                                lineHeight: lineHeight)
        }
        let win = Window(window, width: width, height: height, lineHeight: lineHeight)
        var kept = boxes, numbers: [Box] = [], marks: [Box] = []
        if !win.terminal {
            // A terminal's text is its output: numbers counting down a column
            // and a lone "y" are what it printed.
            (kept, numbers) = withoutGutter(boxes, lineHeight: lineHeight)
            marks = glyphs(kept, lineHeight: lineHeight)
            let taken = Set(marks.map { ObjectIdentifier($0) })
            kept = kept.filter { !taken.contains(ObjectIdentifier($0)) }
        }
        let windowPanes = paneRegions(kept, separators: seps, rect: Rect(x0: win.x0, y0: win.y0, x1: win.x1, y1: win.y1),
                                      lineHeight: lineHeight)
        let roles = windowPanes.contains(where: { !$0.regions.isEmpty }) ? classify(windowPanes, win: win) : []
        let edges = codeLeftEdges(roles, win: win)
        var blocks: [Block] = []
        for (index, entry) in roles.enumerated() {
            let text: String
            if entry.role == .content, let edge = edges[index] {
                text = render(entry.boxes, left: edge, stacked: true)
            } else {
                text = render(entry.boxes, flat: true, stacked: true)
            }
            blocks.append(Block(role: entry.role, rule: entry.rule, boxes: entry.boxes, text: text))
        }
        if !numbers.isEmpty {
            blocks.append(Block(role: .chrome, rule: "gutter", boxes: numbers,
                                text: stableSorted(numbers, by: \.cy).map(\.trimmed).joined(separator: " ")))
        }
        if !marks.isEmpty {
            blocks.append(Block(role: .chrome, rule: "glyph", boxes: marks,
                                text: rows(marks).joined().map(\.trimmed).joined(separator: " ")))
        }
        if !blocks.contains(where: { $0.role == .content }) && unplaced.isEmpty {
            // Nothing reads as content. When unsure, it is content: store the
            // reading unclassified.
            return unclassified(boxes, unplaced: unplaced, separators: seps, width: width, height: height,
                                lineHeight: lineHeight)
        }
        if !unplaced.isEmpty {
            blocks.append(Block(role: .content, rule: "unplaced", boxes: [], text: unplaced.joined(separator: "\n")))
        }
        return Reading(blocks: blocks, stored: storedText(blocks), classified: true)
    }

    /// Content blocks in reading order, then the separator, then chrome blocks
    /// in reading order. Lines without a place end the content, one per line.
    static func storedText(_ blocks: [Block]) -> String {
        var main = blocks.filter { $0.role == .content && $0.rule != "unplaced" }.map(\.text)
            .joined(separator: "\n\n")
        main = ((main.isEmpty ? [] : [main]) + blocks.filter { $0.rule == "unplaced" }.map(\.text))
            .joined(separator: "\n")
        return main + chromeSeparator + blocks.filter { $0.role == .chrome }.map(\.text).joined(separator: "\n\n")
    }
}
