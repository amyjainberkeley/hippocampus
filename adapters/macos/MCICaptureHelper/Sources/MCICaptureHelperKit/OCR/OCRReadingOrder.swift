import CoreGraphics
import Foundation

/// Rebuilds a page from OCR line boxes, so stored text reads the way the screen
/// does. Engines return boxes, not a page: joining them in engine order
/// interleaves side-by-side columns row by row and splits one visual row into
/// fragments, which on the screen benchmark cost 27% character error.
///
/// 1. Drop low-confidence, blank and duplicate boxes, and remove U+001E, the
///    character the stored text uses to divide content from chrome. A box
///    outside the frame is "unplaced" and its text ends the page.
/// 2. Pane separators: the OCR worker reports long straight edges that no
///    text box crosses. One that spans 90% of a region cuts it before anything
///    else, bars first, then sidebars and panels. A gridline between a table's
///    columns is not a cut; one-row panes between rules that line up are the
///    rows of a ruled table.
/// 3. Recursive XY-cut inside each pane: split at the widest whitespace band
///    no box crosses. Short, row-aligned cells that line up from both sides
///    are a table and read row by row (B1). Two sides that share no row
///    (alternating chat bubbles) are one block, read top to bottom (B2).
///    B3, the tolerant cut across a bridging box, is left out: pane separators
///    cut the bars that used to bridge panes.
/// 4. In a block, boxes sharing a visual row join left to right, and leading
///    indentation is kept relative to the block's left edge. A box that
///    overlaps another on its row is an alternative reading of the same text,
///    so it gets its own line instead of being glued on.
///
/// With a window's geometry the reading is also sorted into content and
/// chrome (`OCRRegionRoles.swift`): the gutter and glyph rules below run
/// before the cut, the role rules after it. Without geometry nothing is
/// classified, as before.
///
/// `tools/ocr/screens/layout.py` is the reference implementation; the
/// `OCRReadingOrder` fixtures pin both to the same output, so thresholds,
/// tie-breaks and the order of floating-point operations follow it exactly.
/// Digits are ASCII 0 to 9, whitespace is `whitespace` below (Unicode
/// White_Space), and lengths count Unicode scalars.
enum OCRReadingOrder {
    /// Horizontal band, in median line heights.
    static let horizontalCut: CGFloat = 0.8
    /// Vertical band, in median line heights.
    static let verticalCut: CGFloat = 1.5
    static let rowOverlap: CGFloat = 0.5
    /// B2: two sides share a row when rows overlap by this share of the smaller height.
    static let parallelOverlap: CGFloat = 0.2
    static let tableMaxWords: Double = 3
    static let tableAligned: Double = 0.7
    /// B1: share of the first column's rows matched in another column.
    static let tableAnchorAligned: Double = 0.7
    /// Rows of two columns are level when their centres are this share of a row height apart.
    static let tableRowAlign: CGFloat = 0.3
    /// A line under a table set off by less than this share of its row gap is a cell that wraps.
    static let wrapGap: CGFloat = 0.75
    static let maxIndent = 40
    /// Earlier boxes of the same text compared for duplicates.
    static let duplicatePositions = 64

    /// Pixels a box must reach past a separator to cross it.
    static let separatorPad: CGFloat = 2.0
    /// A separator cuts a region it spans this share of.
    static let separatorSpan: CGFloat = 0.9
    /// Thinnest pane, in line heights.
    static let paneMin: CGFloat = 0.75
    /// One-row panes between rules that line up, in a run this long, are a
    /// table's rows (a run of two only when its rows are in step).
    static let ruledRun = 3

    static let glyphMaxChars = 2
    static let glyphAspect: ClosedRange<CGFloat> = 0.7...1.5
    /// Gap to a row neighbour, in line heights.
    static let glyphClear: CGFloat = 0.5
    /// Other numbers this close, in line heights, make a number data.
    static let glyphChainReach: CGFloat = 3.0
    /// A label this far to the left makes a number its value.
    static let glyphLabelReach: CGFloat = 6.0
    /// A line of text more than / at most this far above or below, in line heights,
    static let glyphColumnNear: CGFloat = 0.5
    static let glyphColumnFar: CGFloat = 2.0
    /// that starts this close to where a pair starts, makes the pair one of its lines.
    static let glyphColumnAlign: CGFloat = 0.5
    static let codePunctuation = Set("{}[]();,".unicodeScalars)

    /// Numbers in a gutter chain.
    static let gutterMin = 3
    static let gutterMaxDigits = 5
    /// A chain may skip a few numbers (a line read as nothing).
    static let gutterMaxStep = 4
    /// Right edges of lone numbers line up within this, in line heights.
    static let gutterAlign: CGFloat = 1.0
    /// Line numbers sit this close to their lines (median), in line heights, unless the lines are code.
    static let gutterReach: CGFloat = 3.0
    /// Consecutive numbers of a gutter are at most this far apart, in line heights.
    static let gutterGap: CGFloat = 10.0

    static let chatIndent = 4

    // MARK: - Text, explicitly

    /// Unicode White_Space, as `layout.py` spells it out. U+001C to U+001F are
    /// not in it (Python's own `str.split` would treat them as space).
    static let whitespace: Set<UInt32> = Set(
        [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
            + Array(0x2000...0x200A))

    static func isSpace(_ scalar: Unicode.Scalar) -> Bool { whitespace.contains(scalar.value) }

    static func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 0x30 && scalar.value <= 0x39 }

    /// Unicode general category L*.
    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// Unicode general category L* or N*.
    static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return isLetter(scalar)
        }
    }

    /// `text` split at runs of whitespace.
    static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isSpace(scalar) {
                if !current.isEmpty {
                    out.append(String(current))
                    current = String.UnicodeScalarView()
                }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    static func trim(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isSpace($0) }),
              let last = scalars.lastIndex(where: { !isSpace($0) }) else { return "" }
        return String(String.UnicodeScalarView(scalars[first...last]))
    }

    static func length(_ text: String) -> Int { text.unicodeScalars.count }

    static func isNumber(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy(isDigit)
    }

    static func hasLetter(_ text: String) -> Bool { text.unicodeScalars.contains(where: isLetter) }

    /// (digits, rest) when `text` starts with up to `gutterMaxDigits` ASCII
    /// digits followed by whitespace or nothing. The digits are kept as read.
    static func leadingNumber(_ text: String) -> (digits: String, rest: String)? {
        let scalars = Array(text.unicodeScalars)
        var count = 0
        while count < scalars.count, isDigit(scalars[count]) { count += 1 }
        guard count > 0, count <= gutterMaxDigits else { return nil }
        if count < scalars.count, !isSpace(scalars[count]) { return nil }
        var digits = String.UnicodeScalarView(), rest = String.UnicodeScalarView()
        digits.append(contentsOf: scalars[..<count])
        rest.append(contentsOf: scalars[count...])
        return (String(digits), trim(String(rest)))
    }

    /// Scalar-exact prefix and suffix tests (Swift's own compare Characters).
    static func hasPrefix(_ text: String, _ prefix: String) -> Bool {
        let a = Array(text.unicodeScalars), b = Array(prefix.unicodeScalars)
        return a.count >= b.count && Array(a[..<b.count]) == b
    }

    static func hasSuffix(_ text: String, _ suffix: String) -> Bool {
        let a = Array(text.unicodeScalars), b = Array(suffix.unicodeScalars)
        return a.count >= b.count && Array(a[(a.count - b.count)...]) == b
    }

    /// Scalar-exact substring test.
    static func contains(_ text: String, _ part: String) -> Bool {
        part.isEmpty || text.range(of: part, options: .literal) != nil
    }

    /// Non-overlapping occurrences of `part`, as `str.count` counts them.
    static func occurrences(of part: String, in text: String) -> Int {
        guard !part.isEmpty else { return 0 }
        var count = 0
        var start = text.startIndex
        while let found = text.range(of: part, options: .literal, range: start..<text.endIndex) {
            count += 1
            start = found.upperBound
        }
        return count
    }

    // MARK: - Geometry

    /// A line box in frame pixels with a top-left origin. A class, so the
    /// rules can tell one box from another with the same text and place, as
    /// the reference does.
    final class Box {
        let text: String
        let x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat
        /// `trim(text)`.
        let trimmed: String
        /// The text with its whitespace removed (`''.join(words(text))`).
        let compact: String
        let compactLength: Int
        let wordCount: Int
        /// `len(text)`, in scalars.
        let length: Int

        init(_ text: String, _ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
            self.text = text
            self.x0 = x0
            self.y0 = y0
            self.x1 = x1
            self.y1 = y1
            let parts = OCRReadingOrder.words(text)
            trimmed = OCRReadingOrder.trim(text)
            compact = parts.joined()
            compactLength = compact.unicodeScalars.count
            wordCount = parts.count
            length = text.unicodeScalars.count
        }

        var h: CGFloat { y1 - y0 }
        var w: CGFloat { x1 - x0 }
        var cy: CGFloat { (y0 + y1) / 2 }
        var cx: CGFloat { (x0 + x1) / 2 }
    }

    enum Axis { case horizontal, vertical }

    static func iou(_ a: Box, _ b: Box) -> CGFloat {
        let ix = max(0.0, min(a.x1, b.x1) - max(a.x0, b.x0))
        let iy = max(0.0, min(a.y1, b.y1) - max(a.y0, b.y0))
        let inter = ix * iy
        let union = (a.x1 - a.x0) * a.h + (b.x1 - b.x0) * b.h - inter
        return union > 0 ? inter / union : 0
    }

    /// Gaps between merged [start, end) spans, as (size, cut position).
    static func bands(_ spans: [(CGFloat, CGFloat)]) -> [(size: CGFloat, at: CGFloat)] {
        let sorted = spans.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        guard var end = sorted.first?.1 else { return [] }
        var out: [(CGFloat, CGFloat)] = []
        for (start, stop) in sorted.dropFirst() {
            if start > end { out.append((start - end, (start + end) / 2)) }
            end = max(end, stop)
        }
        return out
    }

    /// Best cut, or nil for a leaf.
    static func split(_ boxes: [Box], lineHeight: CGFloat) -> (axis: Axis, at: CGFloat)? {
        var best: (score: CGFloat, axis: Axis, at: CGFloat)?
        for (axis, threshold) in [(Axis.horizontal, horizontalCut), (Axis.vertical, verticalCut)] {
            let spans = boxes.map { axis == .horizontal ? ($0.y0, $0.y1) : ($0.x0, $0.x1) }
            for band in bands(spans) {
                let score = band.size / (lineHeight * threshold)
                if score >= 1, best.map({ score > $0.score }) ?? true {
                    best = (score, axis, band.at)
                }
            }
        }
        return best.map { ($0.axis, $0.at) }
    }

    /// Visual rows, top to bottom; each row left to right. A box joins the
    /// last row when it overlaps the row's whole height by half the smaller
    /// of the two heights. Ties keep the order the boxes came in.
    static func rows(_ boxes: [Box]) -> [[Box]] {
        let ordered = boxes.enumerated().sorted { a, b in
            if a.element.cy != b.element.cy { return a.element.cy < b.element.cy }
            if a.element.x0 != b.element.x0 { return a.element.x0 < b.element.x0 }
            return a.offset < b.offset
        }.map(\.element)
        var out: [[Box]] = []
        var top: CGFloat = 0, bottom: CGFloat = 0
        for box in ordered {
            if !out.isEmpty {
                let overlap = min(bottom, box.y1) - max(top, box.y0)
                if overlap >= rowOverlap * min(box.h, bottom - top) {
                    out[out.count - 1].append(box)
                    top = min(top, box.y0)
                    bottom = max(bottom, box.y1)
                    continue
                }
            }
            out.append([box])
            top = box.y0
            bottom = box.y1
        }
        return out.map { row in
            row.enumerated().sorted { a, b in
                a.element.x0 != b.element.x0 ? a.element.x0 < b.element.x0 : a.offset < b.offset
            }.map(\.element)
        }
    }

    /// Layers of horizontally disjoint boxes, in x order.
    static func readings(_ row: [Box]) -> [[Box]] {
        var out: [[Box]] = []
        for box in row {
            if let index = out.firstIndex(where: { layer in
                let last = layer[layer.count - 1]
                let overlap = min(last.x1, box.x1) - max(last.x0, box.x0)
                return overlap < 0.5 * min(last.x1 - last.x0, box.x1 - box.x0)
            }) {
                out[index].append(box)
            } else {
                out.append([box])
            }
        }
        return out
    }

    /// Lines of a block. Indentation is kept relative to `left`, up to
    /// `maxIndent`; `flat` makes any indent `chatIndent` spaces (prose and
    /// chat). `stacked` puts a row's layers in the order they sit on screen,
    /// top first, not the order they formed.
    static func renderRows(_ boxes: [Box], left: CGFloat, flat: Bool = false, stacked: Bool = false) -> [String] {
        let widths = boxes.compactMap { box -> Double? in
            box.length >= 4 ? Double(box.x1 - box.x0) / Double(box.length) : nil
        }
        let charWidth = widths.isEmpty ? 0 : median(widths)
        var lines: [String] = []
        for row in rows(boxes) {
            var layers = readings(row)
            if stacked {
                layers = layers.enumerated().sorted { a, b in
                    let top = a.element.map(\.y0).min()!, other = b.element.map(\.y0).min()!
                    return top != other ? top < other : a.offset < b.offset
                }.map(\.element)
            }
            for layer in layers {
                let text = layer.map(\.trimmed).joined(separator: " ")
                var indent = 0
                if charWidth != 0 {
                    let columns = Double(layer[0].x0 - left) / charWidth
                    if flat {
                        // Outside code an indent is none or four spaces, and an
                        // offset shorter than that is not one.
                        indent = columns >= Double(chatIndent) ? chatIndent : 0
                    } else if columns >= 1 {
                        // Less than a character of offset is recognition jitter.
                        indent = Int(min(Double(maxIndent), columns.rounded(.toNearestOrEven)))
                    }
                }
                lines.append(String(repeating: " ", count: max(0, indent)) + text)
            }
        }
        return lines
    }

    static func rowSpan(_ row: [Box]) -> (top: CGFloat, bottom: CGFloat) {
        (row.map(\.y0).min()!, row.map(\.y1).max()!)
    }

    static func centreY(_ row: [Box]) -> CGFloat {
        row.map(\.cy).reduce(0, +) / CGFloat(row.count)
    }

    static func isTable(_ columns: [[Box]]) -> Bool {
        guard columns.count >= 2 else { return false }
        for column in columns where median(column.map { Double($0.wordCount) }) > tableMaxWords {
            return false
        }
        let anchor = rows(columns[0])
        guard !anchor.isEmpty else { return false }
        let centers = anchor.map(centreY)
        let heights = anchor.map { row in row.map(\.y1).max()! - row.map(\.y0).min()! }
        // A row aligns with an anchor row when their centres are within
        // `tableRowAlign` of the anchor row's height; search anchor rows by centre.
        let order = Array(0..<anchor.count).sorted {
            centers[$0] != centers[$1] ? centers[$0] < centers[$1] : $0 < $1
        }
        let ordered = order.map { centers[$0] }
        let reach = tableRowAlign * heights.max()!
        var aligned = 0, total = 0
        var matched = Set<Int>()
        for column in columns.dropFirst() {
            for row in rows(column) {
                let cy = centreY(row)
                total += 1
                let lo = bisectLeft(ordered, cy - reach), hi = bisectRight(ordered, cy + reach)
                var hit = false
                if lo < hi {
                    for k in lo..<hi where abs(cy - centers[order[k]]) <= tableRowAlign * heights[order[k]] {
                        hit = true
                        matched.insert(order[k])
                    }
                }
                if hit { aligned += 1 }
            }
        }
        if total == 0 || Double(aligned) / Double(total) < tableAligned { return false }
        // B1: a table is aligned from both sides. One short row beside a long
        // column is not a table.
        return Double(matched.count) / Double(anchor.count) >= tableAnchorAligned
    }

    /// B2: whether two sides share a row, as columns of text do. Alternating
    /// chat bubbles never do: one sits below the other. One row overlapping by
    /// `parallelOverlap` is enough. A sorted sweep, so a long column costs n log n.
    static func parallel(_ left: [Box], _ right: [Box]) -> Bool {
        let a = rows(left), b = rows(right)
        let (fewer, more) = a.count <= b.count ? (a, b) : (b, a)
        if fewer.isEmpty { return true }
        let spans = more.map(rowSpan).sorted { $0.top != $1.top ? $0.top < $1.top : $0.bottom < $1.bottom }
        let tops = spans.map(\.top)
        let tallest = spans.map { $0.bottom - $0.top }.max()!
        for row in fewer {
            let (top, bottom) = rowSpan(row)
            let height = bottom - top
            // Rows of the other side that start before this one ends and no
            // earlier than the tallest of them could reach.
            let lo = bisectLeft(tops, top - tallest), hi = bisectLeft(tops, bottom)
            guard lo < hi else { continue }
            for other in spans[lo..<hi] {
                let overlap = min(bottom, other.bottom) - max(top, other.top)
                if overlap >= parallelOverlap * min(height, other.bottom - other.top) { return true }
            }
        }
        return false
    }

    /// Whether the first of three or more columns is text beside a table, not
    /// the table's first column (a form beside an order summary): the other
    /// columns form a table without it, and the first column runs on below
    /// that table's last row, set off from its line above about as far as the
    /// table's rows are set off from each other. A title above a table, a cell
    /// that wraps, and a column of labels are the table's own.
    static func standsApart(_ columns: [[Box]]) -> Bool {
        guard columns.count >= 3, isTable(Array(columns.dropFirst())) else { return false }
        let spans = rows(columns.dropFirst().flatMap { $0 }).map(rowSpan)
        let last = spans.map(\.bottom).max()!
        let gaps = zip(spans, spans.dropFirst()).map { Double($1.top - $0.bottom) }
        let gap = CGFloat(gaps.isEmpty ? 0 : median(gaps))
        let first = rows(columns[0]).map(rowSpan)
        return zip(first, first.dropFirst()).contains { above, below in
            below.top >= last && below.top - above.bottom >= wrapGap * gap
        }
    }

    /// A region of a pane in reading order; `table` when its columns form a table.
    struct Cut {
        let boxes: [Box]
        let table: Bool
    }

    /// Regions in reading order. Depth-first with an explicit stack, so a
    /// screen of many stacked lines cannot exhaust a worker thread's stack.
    static func cut(_ boxes: [Box], lineHeight: CGFloat) -> [Cut] {
        var out: [Cut] = []
        var stack = [boxes]
        while let region = stack.popLast() {
            guard let (axis, at) = split(region, lineHeight: lineHeight) else {
                out.append(Cut(boxes: region, table: false))
                continue
            }
            if axis == .horizontal {
                stack.append(region.filter { $0.cy >= at })
                stack.append(region.filter { $0.cy < at })
                continue
            }
            var columns = [region.filter { $0.cx < at }, region.filter { $0.cx >= at }]
            if !parallel(columns[0], columns[1]) {
                out.append(Cut(boxes: region, table: false))
                continue
            }
            // Peel further vertical splits so a table's columns are judged together.
            while let more = split(columns[columns.count - 1], lineHeight: lineHeight), more.axis == .vertical {
                let last = columns.removeLast()
                columns.append(last.filter { $0.cx < more.at })
                columns.append(last.filter { $0.cx >= more.at })
            }
            if isTable(columns) && !standsApart(columns) {
                out.append(Cut(boxes: region, table: true))
                continue
            }
            // A table can sit beside other text: keep the columns that form one
            // together, and read the text beside it on its own.
            if columns.count > 2 {
                for i in 1..<(columns.count - 1) where isTable(Array(columns[i...])) {
                    columns = Array(columns[..<i]) + [columns[i...].flatMap { $0 }]
                    break
                }
            }
            stack.append(contentsOf: columns.reversed())
        }
        return out
    }

    // MARK: - Panes

    struct Separator {
        let vertical: Bool
        let at: CGFloat, start: CGFloat, end: CGFloat
    }

    /// Worker separators (normalized, bottom-left, one of width and height
    /// zero) as pixels with a top-left origin. Anything else is ignored.
    static func toSeparators(_ normalized: [CGRect], width: CGFloat, height: CGFloat) -> [Separator] {
        var out: [Separator] = []
        for item in normalized {
            let x = item.origin.x, y = item.origin.y, w = item.size.width, h = item.size.height
            guard x.isFinite, y.isFinite, w.isFinite, h.isFinite else { continue }
            if w == 0 && h > 0 {
                out.append(Separator(vertical: true, at: x * width, start: (1 - y - h) * height, end: (1 - y) * height))
            } else if h == 0 && w > 0 {
                out.append(Separator(vertical: false, at: (1 - y) * height, start: x * width, end: (x + w) * width))
            }
        }
        return out
    }

    /// Whether two sides pair one to one, row for row, as a table's columns do.
    static func pairedRows(_ left: [Box], _ right: [Box]) -> Bool {
        let a = rows(left), b = rows(right)
        guard a.count == b.count else { return false }
        for (rowA, rowB) in zip(a, b) {
            let spanA = rowSpan(rowA), spanB = rowSpan(rowB)
            let height = min(spanA.bottom - spanA.top, spanB.bottom - spanB.top)
            if abs(centreY(rowA) - centreY(rowB)) > tableRowAlign * height { return false }
        }
        return true
    }

    static func crossed(_ s: Separator, _ boxes: [Box]) -> Bool {
        if s.vertical {
            return boxes.contains { b in
                b.x0 < s.at - separatorPad && b.x1 > s.at + separatorPad && b.y1 > s.start && b.y0 < s.end
            }
        }
        return boxes.contains { b in
            b.y0 < s.at - separatorPad && b.y1 > s.at + separatorPad && b.x1 > s.start && b.x0 < s.end
        }
    }

    struct Rect {
        let x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat
    }

    /// The window cut at its separators, in reading order: bars before what
    /// they sit on, left before right.
    static func panes(_ boxes: [Box], separators: [Separator], rect: Rect,
                      lineHeight: CGFloat) -> [(rect: Rect, boxes: [Box])] {
        let usable = separators.filter { !crossed($0, boxes) }
        let minimum = paneMin * lineHeight
        var out: [(rect: Rect, boxes: [Box])] = []
        var stack: [(rect: Rect, boxes: [Box])] = [(rect, boxes)]
        while let (r, members) = stack.popLast() {
            var chosen: [(rect: Rect, boxes: [Box])]?
            let across = stableSorted(usable.filter { s in
                !s.vertical && r.y0 + minimum <= s.at && s.at <= r.y1 - minimum
                    && min(s.end, r.x1) - max(s.start, r.x0) >= separatorSpan * (r.x1 - r.x0)
            }, by: \.at)
            if let first = across.first {
                let at = first.at
                chosen = [(Rect(x0: r.x0, y0: r.y0, x1: r.x1, y1: at), members.filter { $0.cy < at }),
                          (Rect(x0: r.x0, y0: at, x1: r.x1, y1: r.y1), members.filter { $0.cy >= at })]
            } else {
                let down = stableSorted(usable.filter { s in
                    s.vertical && r.x0 + minimum <= s.at && s.at <= r.x1 - minimum
                        && min(s.end, r.y1) - max(s.start, r.y0) >= separatorSpan * (r.y1 - r.y0)
                }, by: \.at)
                for s in down {
                    let left = members.filter { $0.cx < s.at }, right = members.filter { $0.cx >= s.at }
                    // A gridline between a table's columns is not a pane edge:
                    // the two sides pair row for row.
                    if !left.isEmpty && !right.isEmpty && pairedRows(left, right) && isTable([left, right]) {
                        continue
                    }
                    chosen = [(Rect(x0: r.x0, y0: r.y0, x1: s.at, y1: r.y1), left),
                              (Rect(x0: s.at, y0: r.y0, x1: r.x1, y1: r.y1), right)]
                    break
                }
            }
            if let chosen {
                stack.append(contentsOf: chosen.reversed())
            } else {
                out.append((r, members))
            }
        }
        return out
    }

    /// Indexes of the panes that are rows of a ruled table (a receipt, a
    /// spreadsheet's gridlines): each holds one row between rules, spans the
    /// same columns as the pane with text before it, and its row lines up with
    /// that pane's row. A run of `ruledRun` or more is a table's rows, and so
    /// is a run of two whose rows are in step. A pane with no text between two
    /// (a double rule) does not break the run.
    static func ruledRows(_ windowPanes: [(rect: Rect, boxes: [Box])], lineHeight: CGFloat) -> Set<Int> {
        var found = Set<Int>()
        var run: [Int] = []
        var steps: [Bool] = []
        var previous: (index: Int, rect: Rect, row: [Box])?
        func close() {
            if run.count >= ruledRun || (run.count == 2 && steps[0]) { found.formUnion(run) }
        }
        for (i, pane) in windowPanes.enumerated() where !pane.boxes.isEmpty {
            let lines = rows(pane.boxes)
            let current: (index: Int, rect: Rect, row: [Box])? = lines.count == 1 ? (i, pane.rect, lines[0]) : nil
            if let current, let previous, abs(previous.rect.x0 - pane.rect.x0) < 1,
               abs(previous.rect.x1 - pane.rect.x1) < 1, grid(previous.row, current.row, lineHeight: lineHeight) {
                run = (run.isEmpty ? [previous.index] : run) + [i]
                steps.append(inStep(previous.row, current.row, lineHeight: lineHeight))
            } else {
                close()
                run = []
                steps = []
            }
            previous = current
        }
        close()
        return found
    }

    // MARK: - Gutter

    struct GutterEntry {
        let box: Box
        let number: Int
        let rest: String
    }

    /// The longest ascending chain of integers down one column, each number
    /// alone in its box (rest "") or glued to the start of a line. A chain
    /// grows greedily from its first number: the next is the first box, top to
    /// bottom then left to right, that is 1 to `gutterMaxStep` more, at least
    /// half a line lower and at most `gutterGap` lines lower than the last, and
    /// lines up with the first number. The first chain of the greatest length
    /// wins, and a number already in a chain found earlier starts none. Boxes
    /// are looked up by their number.
    static func gutterChain(_ boxes: [Box], lineHeight: CGFloat) -> [GutterEntry] {
        var candidates: [GutterEntry] = []
        for box in boxes {
            if let parsed = leadingNumber(box.trimmed), let number = Int(parsed.digits) {
                candidates.append(GutterEntry(box: box, number: number, rest: parsed.rest))
            }
        }
        guard candidates.count >= gutterMin else { return [] }
        candidates = candidates.enumerated().sorted { a, b in
            if a.element.box.cy != b.element.box.cy { return a.element.box.cy < b.element.box.cy }
            if a.element.box.x0 != b.element.box.x0 { return a.element.box.x0 < b.element.box.x0 }
            return a.offset < b.offset
        }.map(\.element)
        var byNumber: [Int: (positions: [Int], centres: [CGFloat])] = [:]
        for (i, entry) in candidates.enumerated() {
            byNumber[entry.number, default: ([], [])].positions.append(i)
            byNumber[entry.number, default: ([], [])].centres.append(entry.box.cy)
        }

        func aligned(_ box: Box, _ anchor: Box) -> Bool {
            // Lone numbers are right-aligned; numbers glued to a line start
            // where the column starts.
            abs(box.x1 - anchor.x1) <= gutterAlign * lineHeight || abs(box.x0 - anchor.x0) <= gutterAlign * lineHeight
        }

        func after(_ last: Int, _ anchor: Box) -> Int? {
            let box = candidates[last].box, number = candidates[last].number
            var found: Int?
            for step in 1...gutterMaxStep {
                guard let entry = byNumber[number + step] else { continue }
                var k = bisectLeft(entry.centres, box.cy + 0.5 * lineHeight)
                while k < entry.positions.count {
                    if entry.centres[k] > box.cy + gutterGap * lineHeight
                        || (found.map { entry.positions[k] > $0 } ?? false) {
                        break  // a gutter numbers every line; past this, it has stopped
                    }
                    if aligned(candidates[entry.positions[k]].box, anchor) {
                        found = entry.positions[k]
                        break
                    }
                    k += 1
                }
            }
            return found
        }

        var best: [Int] = []
        var chained = Set<ObjectIdentifier>()
        for (start, entry) in candidates.enumerated() {
            if best.count >= candidates.count - start { break }  // no later start can make a longer chain
            if chained.contains(ObjectIdentifier(entry.box)) { continue }
            var chain = [start]
            while let following = after(chain[chain.count - 1], entry.box) { chain.append(following) }
            for i in chain { chained.insert(ObjectIdentifier(candidates[i].box)) }
            if chain.count > best.count { best = chain }
        }
        return best.map { candidates[$0] }
    }

    /// An editor's line numbers: the boxes of `gutterChain` by identity, when
    /// they sit close to the left edge of the lines they number or number
    /// lines of code, and those lines (`numbered`). A table's column of
    /// numbers stands far from cells that are not code, and is not a gutter.
    static func gutter(_ boxes: [Box], lineHeight: CGFloat)
        -> (numbers: [ObjectIdentifier: GutterEntry], numbered: [Box])
    {
        let best = gutterChain(boxes, lineHeight: lineHeight)
        guard best.count >= gutterMin else { return ([:], []) }
        var neighbour: [ObjectIdentifier: Box] = [:]
        for row in rows(boxes) {
            for (i, box) in row.enumerated() where i + 1 < row.count {
                neighbour[ObjectIdentifier(box)] = row[i + 1]
            }
        }
        var gaps: [Double] = [], texts: [String] = [], numbered: [Box] = []
        for entry in best {
            if !entry.rest.isEmpty {
                gaps.append(0)
                texts.append(entry.rest)
                numbered.append(entry.box)
            } else if let next = neighbour[ObjectIdentifier(entry.box)] {
                gaps.append(Double(next.x0 - entry.box.x1))
                texts.append(next.trimmed)
                numbered.append(next)
            }
        }
        let close = gaps.isEmpty || CGFloat(median(gaps)) <= gutterReach * lineHeight
        let code = !texts.isEmpty
            && Double(texts.filter(looksLikeCode).count) >= codeShare * Double(texts.count)
        guard close || code else { return ([:], []) }
        var numbers: [ObjectIdentifier: GutterEntry] = [:]
        for entry in best { numbers[ObjectIdentifier(entry.box)] = entry }
        return (numbers, numbered)
    }

    /// The width of a character in the lines a gutter numbers: measured on the
    /// lines beside lone numbers, else on the lines numbers are glued to, else
    /// on every other box of four characters or more.
    static func codeCharWidth(_ numbers: [ObjectIdentifier: GutterEntry], numbered: [Box], boxes: [Box]) -> Double {
        let pools = [numbered.filter { numbers[ObjectIdentifier($0)] == nil },
                     numbered.filter { numbers[ObjectIdentifier($0)] != nil },
                     boxes.filter { numbers[ObjectIdentifier($0)] == nil }]
        for pool in pools {
            let widths = pool.compactMap { box -> Double? in
                let count = length(box.trimmed)
                return count >= 4 ? Double(box.x1 - box.x0) / Double(count) : nil
            }
            if !widths.isEmpty { return median(widths) }
        }
        return 0
    }

    /// (boxes with line numbers taken out, the line numbers).
    static func withoutGutter(_ boxes: [Box], lineHeight: CGFloat) -> (kept: [Box], taken: [Box]) {
        let (numbers, numbered) = gutter(boxes, lineHeight: lineHeight)
        guard !numbers.isEmpty else { return (boxes, []) }
        let charWidth = codeCharWidth(numbers, numbered: numbered, boxes: boxes)
        var kept: [Box] = [], taken: [Box] = []
        for box in boxes {
            guard let entry = numbers[ObjectIdentifier(box)] else {
                kept.append(box)
                continue
            }
            if entry.rest.isEmpty {
                taken.append(box)
                continue
            }
            // Glued to its line, with the gap between them read as one space:
            // the line ends where the box ends and is as wide as its
            // characters, so it starts that far back from the right.
            let digits = leadingNumber(box.trimmed)?.digits ?? ""
            let digitsEnd = box.x0 + box.w * CGFloat(length(digits)) / CGFloat(max(1, length(box.trimmed)))
            let at = charWidth != 0
                ? max(digitsEnd, box.x1 - CGFloat(length(entry.rest)) * CGFloat(charWidth)) : digitsEnd
            taken.append(Box(digits, box.x0, box.y0, digitsEnd, box.y1))
            kept.append(Box(entry.rest, at, box.y0, box.x1, box.y1))
        }
        return (kept, taken)
    }

    // MARK: - Glyphs

    /// Two letters or digits of any script.
    static func isPair(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        return scalars.count == 2 && scalars.allSatisfy(isLetterOrNumber)
    }

    /// Text longer than an icon's characters: a line.
    static func isLine(_ text: String) -> Bool { length(text) > glyphMaxChars }

    /// The boxes whose text (whitespace removed) is of one kind, by height on the screen.
    struct Cells {
        let boxes: [Box]
        let centres: [CGFloat]
        let tallest: CGFloat

        init(_ all: [Box], kind: (String) -> Bool) {
            boxes = all.filter { kind($0.compact) }.enumerated().sorted { a, b in
                a.element.cy != b.element.cy ? a.element.cy < b.element.cy : a.offset < b.offset
            }.map(\.element)
            centres = boxes.map(\.cy)
            tallest = boxes.map(\.h).max() ?? 0
        }

        func near(_ box: Box, _ reach: CGFloat) -> ArraySlice<Box> {
            let lo = OCRReadingOrder.bisectLeft(centres, box.cy - reach)
            let hi = OCRReadingOrder.bisectRight(centres, box.cy + reach)
            return lo < hi ? boxes[lo..<hi] : []
        }

        /// Whether another of these cells stands in the box's column or on its row, near it.
        func lineUp(_ box: Box, lineHeight: CGFloat) -> Bool {
            let reach = OCRReadingOrder.glyphChainReach
            for other in near(box, max(reach * lineHeight, tallest)) where other !== box {
                let sameColumn = min(box.x1, other.x1) - max(box.x0, other.x0) > 0
                    && abs(other.cy - box.cy) <= reach * lineHeight
                let sameRow = min(box.y1, other.y1) - max(box.y0, other.y0)
                    >= OCRReadingOrder.rowOverlap * min(box.h, other.h)
                    && abs(other.cx - box.cx) <= 2 * reach * lineHeight
                if sameColumn || sameRow { return true }
            }
            return false
        }
    }

    /// Whether a box of digits is data: in a column or row of other numbers,
    /// or the value of a label on its own row ("Estimate  3").
    static func numberInPlace(_ box: Box, row: [Box], index: Int, numbers: Cells, lineHeight: CGFloat) -> Bool {
        guard isNumber(box.compact) else { return false }
        if numbers.lineUp(box, lineHeight: lineHeight) { return true }
        return row[..<index].contains { other in
            hasLetter(other.text) && box.x0 - other.x1 <= glyphLabelReach * lineHeight
        }
    }

    /// Whether the box is a line of a column of text: a line off its row, at
    /// most `glyphColumnFar` line heights away, starts or ends where the box
    /// does, and lies above it (a reply under its sender's name) or below it
    /// while the box's row holds a line too (a header over its column).
    static func inColumn(_ box: Box, row: [Box], lines: Cells, lineHeight: CGFloat) -> Bool {
        let reach = glyphColumnAlign * lineHeight
        let header = row.contains { isLine($0.compact) }
        for other in lines.near(box, glyphColumnFar * lineHeight) {
            if abs(other.cy - box.cy) <= glyphColumnNear * lineHeight { continue }
            if (abs(other.x0 - box.x0) <= reach || abs(other.x1 - box.x1) <= reach) && (other.cy < box.cy || header) {
                return true
            }
        }
        return false
    }

    /// Whether two letters or digits ("P1", "ID", "ok") are data or text in
    /// their place, not an icon: in a column or row of other pairs, a line of
    /// a column of text, or the value of a label that is text.
    static func pairInPlace(_ box: Box, row: [Box], index: Int, pairs: Cells, lines: Cells,
                            lineHeight: CGFloat) -> Bool {
        guard isPair(box.compact) else { return false }
        if pairs.lineUp(box, lineHeight: lineHeight) || inColumn(box, row: row, lines: lines, lineHeight: lineHeight) {
            return true
        }
        return row[..<index].contains { other in
            hasLetter(other.text) && !glyphShaped(other) && box.x0 - other.x1 <= glyphLabelReach * lineHeight
        }
    }

    /// One or two characters, about square (RULINGS T3). Code punctuation is code.
    static func glyphShaped(_ box: Box) -> Bool {
        guard box.compactLength > 0, box.compactLength <= glyphMaxChars, box.h > 0 else { return false }
        if box.compact.unicodeScalars.allSatisfy({ codePunctuation.contains($0) }) { return false }
        return glyphAspect.contains(box.w / box.h)
    }

    /// Boxes that are icons read as characters: glyph-shaped, and at least
    /// `glyphClear` line heights from any text on their row. Icons side by
    /// side stand together, so only text counts as a neighbour. Numbers and
    /// pairs in place are data or text.
    static func glyphs(_ boxes: [Box], lineHeight: CGFloat) -> [Box] {
        let numbers = Cells(boxes, kind: isNumber)
        let pairs = Cells(boxes, kind: isPair)
        let lines = Cells(boxes, kind: isLine)
        var out: [Box] = []
        for row in rows(boxes) {
            let shaped = row.map(glyphShaped)
            for (i, box) in row.enumerated() where shaped[i] {
                let before = (0..<i).reversed().first { !shaped[$0] }.map { row[$0] }
                let after = ((i + 1)..<row.count).first { !shaped[$0] }.map { row[$0] }
                if let before, box.x0 - before.x1 < glyphClear * lineHeight { continue }
                if let after, after.x0 - box.x1 < glyphClear * lineHeight { continue }
                if numberInPlace(box, row: row, index: i, numbers: numbers, lineHeight: lineHeight)
                    || pairInPlace(box, row: row, index: i, pairs: pairs, lines: lines, lineHeight: lineHeight) {
                    continue
                }
                out.append(box)
            }
        }
        return out
    }

    // MARK: - Helpers

    /// `statistics.median`: the mean of the middle pair for even counts.
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    static func bisectLeft(_ values: [CGFloat], _ x: CGFloat) -> Int {
        var lo = 0, hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if values[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    static func bisectRight(_ values: [CGFloat], _ x: CGFloat) -> Int {
        var lo = 0, hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if x < values[mid] { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    /// Python's stable `sorted(key=...)`.
    static func stableSorted<T>(_ items: [T], by key: (T) -> CGFloat) -> [T] {
        items.enumerated().sorted { a, b in
            let ka = key(a.element), kb = key(b.element)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
    }
}
