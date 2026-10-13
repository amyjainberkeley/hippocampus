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
    /// Low-confidence lines stay out: this runs AFTER the complete raw privacy
    /// scan, and uncertain symbols should not become searchable assertions.
    ///
    /// `geometry` turns on roles: content blocks, then
    /// `OCRReadingOrder.chromeSeparator`, then chrome blocks. Without it the
    /// text is unclassified, exactly as before. `separators` are the OCR
    /// worker's pane separators, in the lines' normalized space.
    static func make(from lines: [OCRLine], pixelSize: CGSize = defaultPixelSize, separators: [CGRect] = [],
                     geometry: OCRWindowGeometry? = nil) -> String {
        reading(from: lines, pixelSize: pixelSize, separators: separators, geometry: geometry).stored
    }

    /// The same, with its blocks and roles (for the content-free trace).
    static func reading(from lines: [OCRLine], pixelSize: CGSize = defaultPixelSize, separators: [CGRect] = [],
                        geometry: OCRWindowGeometry? = nil) -> OCRReadingOrder.Reading {
        OCRReadingOrder.read(lines, pixelSize: pixelSize, separators: separators, window: geometry)
    }

    /// A 16:10 frame, for callers that do not know the capture size.
    static let defaultPixelSize = CGSize(width: 1600, height: 1000)
}
