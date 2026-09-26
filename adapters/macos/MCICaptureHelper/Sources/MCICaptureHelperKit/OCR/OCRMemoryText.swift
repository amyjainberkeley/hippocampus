import CoreGraphics
import Foundation

/// A readable transcript after the complete, ordered OCR passes clear privacy.
/// Never use this in place of the original readings for secret detection.
enum OCRMemoryText {
    static func make(from lines: [OCRLine]) -> String {
        var retained: [String] = []
        var positions: [Data: [CGRect]] = [:]
        for line in lines {
            let box = line.boundingBox
            guard valid(box) else {
                retained.append(line.text)
                continue
            }
            let literal = Data(line.text.utf8)
            let previous = positions[literal, default: []]
            if previous.contains(where: { samePosition($0, box) }) { continue }
            retained.append(line.text)
            // Bound comparison work even on a screen with thousands of identical
            // labels. Beyond this cache, keep text instead of guessing it repeats.
            if previous.count < 64 { positions[literal, default: []].append(box) }
        }
        return retained.joined(separator: "\n")
    }

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
