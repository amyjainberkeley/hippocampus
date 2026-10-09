import CoreGraphics
import Foundation

/// A readable transcript after the complete, ordered OCR passes clear privacy.
/// Never use this in place of the original readings for secret detection.
enum OCRMemoryText {
    static func isReadable(_ line: OCRLine) -> Bool {
        line.confidence.isFinite && (0.5...1).contains(line.confidence)
            && !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Readable lines in reading order (see `OCRReadingOrder`). `pixelSize` is
    /// the frame the normalized boxes belong to; it only sets their aspect.
    static func make(from lines: [OCRLine], pixelSize: CGSize = defaultPixelSize) -> String {
        var placed: [(text: String, box: CGRect)] = []
        var unplaced: [String] = []
        var positions: [Data: [CGRect]] = [:]
        for line in lines {
            // This is deliberately AFTER the complete raw privacy scan. Low
            // confidence symbols should not become searchable assertions.
            guard isReadable(line) else { continue }
            let box = line.boundingBox
            guard valid(box) else {
                unplaced.append(line.text)
                continue
            }
            let literal = Data(line.text.utf8)
            let previous = positions[literal, default: []]
            if previous.contains(where: { samePosition($0, box) }) { continue }
            placed.append((line.text, box))
            // Bound comparison work even on a screen with thousands of identical
            // labels. Beyond this cache, keep text instead of guessing it repeats.
            if previous.count < 64 { positions[literal, default: []].append(box) }
        }
        let page = OCRReadingOrder.assemble(placed, pixelSize: pixelSize)
        return ([page].filter { !$0.isEmpty } + unplaced).joined(separator: "\n")
    }

    /// A 16:10 frame, for callers that do not know the capture size.
    static let defaultPixelSize = CGSize(width: 1600, height: 1000)

    private static func valid(_ box: CGRect) -> Bool {
        box.origin.x.isFinite && box.origin.y.isFinite
            && box.size.width.isFinite && box.size.height.isFinite
            && box.width > 0 && box.height > 0
            && CGRect(x: 0, y: 0, width: 1, height: 1).contains(box)
    }

    private static func samePosition(_ first: CGRect, _ second: CGRect) -> Bool {
        let overlap = first.intersection(second)
        guard !overlap.isNull else { return false }
        let intersection = overlap.width * overlap.height
        let union = first.width * first.height + second.width * second.height - intersection
        return union > 0 && intersection / union >= 0.7
    }
}
