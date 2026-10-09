import CoreGraphics
import Foundation

/// Rebuilds a page from OCR line boxes, so stored text reads the way the screen
/// does. Engines return boxes, not a page: joining them in engine order
/// interleaves side-by-side columns row by row and splits one visual row into
/// fragments, which on the screen benchmark cost 27% character error.
///
/// 1. Recursive XY-cut: split a region at the widest whitespace band no box
///    crosses, horizontally or vertically, until no band is wide enough.
/// 2. Side-by-side regions that are all short, row-aligned cells are a table
///    and read row by row; anything else reads column by column.
/// 3. In a leaf, boxes sharing a visual row join left to right, and leading
///    indentation is kept relative to the region's left edge. A box that
///    overlaps another on its row horizontally is an alternative reading of
///    the same text (overlapping recognition passes produce these), so it
///    gets its own line instead of being glued on.
///
/// `tools/ocr/screens/layout.py` is the reference implementation; the
/// `OCRReadingOrder` fixtures pin both to the same output.
enum OCRReadingOrder {
    /// Horizontal band, in median line heights.
    static let horizontalCut: CGFloat = 0.8
    /// Vertical band, in median line heights.
    static let verticalCut: CGFloat = 1.5
    static let rowOverlap: CGFloat = 0.5
    static let tableMaxWords: Double = 3
    static let tableAligned: Double = 0.7
    static let maxIndent = 40

    struct Box {
        let text: String
        let x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat
        var h: CGFloat { y1 - y0 }
        var cy: CGFloat { (y0 + y1) / 2 }
        var cx: CGFloat { (x0 + x1) / 2 }
    }

    enum Axis { case horizontal, vertical }

    /// `lines` hold normalized boxes with a bottom-left origin. `pixelSize`
    /// restores the frame's aspect so horizontal and vertical gaps compare in
    /// one unit.
    static func assemble(_ lines: [(text: String, box: CGRect)], pixelSize: CGSize) -> String {
        let width = pixelSize.width > 0 ? pixelSize.width : 1
        let height = pixelSize.height > 0 ? pixelSize.height : 1
        let boxes = lines.map { line in
            // Same operation order as the reference, so fixtures match exactly.
            Box(text: line.text,
                x0: line.box.origin.x * width,
                y0: (1 - line.box.origin.y - line.box.size.height) * height,
                x1: (line.box.origin.x + line.box.size.width) * width,
                y1: (1 - line.box.origin.y) * height)
        }
        guard !boxes.isEmpty else { return "" }
        let lineHeight = median(boxes.map { Double($0.h) })
        return cut(boxes, lineHeight: CGFloat(lineHeight)).map { region in
            let left = region.map(\.x0).min() ?? 0
            return renderRows(region, left: left).joined(separator: "\n")
        }.joined(separator: "\n\n")
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

    /// Visual rows, top to bottom; each row left to right.
    static func rows(_ boxes: [Box]) -> [[Box]] {
        var out: [[Box]] = []
        let ordered = boxes.enumerated().sorted { a, b in
            if a.element.cy != b.element.cy { return a.element.cy < b.element.cy }
            if a.element.x0 != b.element.x0 { return a.element.x0 < b.element.x0 }
            return a.offset < b.offset
        }.map(\.element)
        for box in ordered {
            if let row = out.last {
                let top = row.map(\.y0).min()!, bottom = row.map(\.y1).max()!
                let overlap = min(bottom, box.y1) - max(top, box.y0)
                if overlap >= rowOverlap * min(box.h, bottom - top) {
                    out[out.count - 1].append(box)
                    continue
                }
            }
            out.append([box])
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

    static func renderRows(_ boxes: [Box], left: CGFloat) -> [String] {
        let widths = boxes.compactMap { box -> Double? in
            let length = box.text.unicodeScalars.count
            return length >= 4 ? Double(box.x1 - box.x0) / Double(length) : nil
        }
        let charWidth = widths.isEmpty ? nil : median(widths)
        return rows(boxes).flatMap(readings).map { layer in
            let text = layer.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " ")
            var indent = 0
            if let charWidth, charWidth > 0 {
                // Less than a character of offset is recognition jitter.
                let columns = Double(layer[0].x0 - left) / charWidth
                if columns >= 1 {
                    indent = Int(min(Double(maxIndent), columns.rounded(.toNearestOrEven)))
                }
            }
            return String(repeating: " ", count: indent) + text
        }
    }

    static func isTable(_ columns: [[Box]]) -> Bool {
        guard columns.count >= 2 else { return false }
        for column in columns {
            let words = column.map { Double($0.text.split(whereSeparator: \.isWhitespace).count) }
            if median(words) > tableMaxWords { return false }
        }
        let anchor = rows(columns[0])
        let centers = anchor.map { row in row.map(\.cy).reduce(0, +) / CGFloat(row.count) }
        let heights = anchor.map { row in row.map(\.y1).max()! - row.map(\.y0).min()! }
        var aligned = 0, total = 0
        for column in columns.dropFirst() {
            for row in rows(column) {
                let cy = row.map(\.cy).reduce(0, +) / CGFloat(row.count)
                total += 1
                if zip(centers, heights).contains(where: { abs(cy - $0.0) <= 0.3 * $0.1 }) {
                    aligned += 1
                }
            }
        }
        return total > 0 && Double(aligned) / Double(total) >= tableAligned
    }

    /// Regions in reading order. Depth-first with an explicit stack, so a
    /// screen of many stacked lines cannot exhaust a worker thread's stack.
    static func cut(_ boxes: [Box], lineHeight: CGFloat) -> [[Box]] {
        var out: [[Box]] = []
        var stack = [boxes]
        while let region = stack.popLast() {
            guard let (axis, at) = split(region, lineHeight: lineHeight) else {
                out.append(region)
                continue
            }
            if axis == .horizontal {
                stack.append(region.filter { $0.cy >= at })
                stack.append(region.filter { $0.cy < at })
                continue
            }
            var columns = [region.filter { $0.cx < at }, region.filter { $0.cx >= at }]
            // Peel further vertical splits so a table's columns are judged together.
            while let more = split(columns[columns.count - 1], lineHeight: lineHeight),
                  more.axis == .vertical {
                let last = columns.removeLast()
                columns.append(last.filter { $0.cx < more.at })
                columns.append(last.filter { $0.cx >= more.at })
            }
            if isTable(columns) {
                out.append(region)
                continue
            }
            stack.append(contentsOf: columns.reversed())
        }
        return out
    }

    /// `statistics.median`: the mean of the middle pair for even counts.
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
