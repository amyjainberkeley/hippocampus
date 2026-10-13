#if DEBUG
import AppKit
import RecallUIKit

/// Debug-only screenshots for the off-screen renderer: a plain drawing of a
/// window (title bar, the window's name, lines of text) for each moment the
/// fixtures name, in its kind's colour. Nothing is read from disk.
final class OverviewPreviewThumbnails: ThumbnailDataProviding, @unchecked Sendable {
    private let windows: [String: OverviewPreviewBrainReader.Window]
    private let lock = NSLock()
    private var served = 0

    init(windows: [String: OverviewPreviewBrainReader.Window]) {
        self.windows = windows
    }

    /// How many images have been drawn: the renderer waits until this stops
    /// changing.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return served
    }

    func thumbnailData(for url: URL, maxPixelSize: Int) async -> Data? {
        await MainActor.run { draw(url: url, maxPixelSize: maxPixelSize) }
    }

    func screenshotData(for url: URL) async -> Data? {
        await MainActor.run { draw(url: url, maxPixelSize: 1_024) }
    }

    @MainActor
    private func draw(url: URL, maxPixelSize: Int) -> Data? {
        guard url.path.hasPrefix("/preview/keyframes/"), let window = windows[url.path] else { return nil }
        let width = max(64, min(maxPixelSize, 1_024))
        let height = width * 10 / 16
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let w = CGFloat(width)
        let h = CGFloat(height)
        let swatch = DayStripPalette.swatch(for: window.kind)
        let tint = NSColor(red: CGFloat((swatch.light >> 16) & 0xFF) / 255, green: CGFloat((swatch.light >> 8) & 0xFF) / 255,
                           blue: CGFloat(swatch.light & 0xFF) / 255, alpha: 1)
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        // Title bar.
        let bar = h * 0.11
        NSColor(white: 0.86, alpha: 1).setFill()
        NSRect(x: 0, y: h - bar, width: w, height: bar).fill()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.withAlphaComponent(0.8).setFill()
            let d = bar * 0.38
            NSBezierPath(ovalIn: NSRect(x: bar * 0.5 + CGFloat(index) * d * 1.6, y: h - bar / 2 - d / 2,
                                        width: d, height: d)).fill()
        }
        let titleFont = NSFont.systemFont(ofSize: bar * 0.42, weight: .medium)
        let title = "\(window.app) \u{00B7} \(window.title)" as NSString
        title.draw(at: NSPoint(x: bar * 2.6, y: h - bar / 2 - titleFont.pointSize * 0.6),
                   withAttributes: [.font: titleFont, .foregroundColor: NSColor(white: 0.25, alpha: 1)])
        // A sidebar in the kind's colour, then lines of text.
        tint.withAlphaComponent(0.18).setFill()
        NSRect(x: 0, y: 0, width: w * 0.22, height: h - bar).fill()
        tint.withAlphaComponent(0.55).setFill()
        for row in 0..<5 {
            NSRect(x: w * 0.03, y: h - bar - h * 0.1 - CGFloat(row) * h * 0.09, width: w * 0.14, height: h * 0.035).fill()
        }
        let heading = NSFont.systemFont(ofSize: h * 0.075, weight: .semibold)
        (window.title as NSString).draw(
            at: NSPoint(x: w * 0.27, y: h - bar - h * 0.16),
            withAttributes: [.font: heading, .foregroundColor: NSColor(white: 0.15, alpha: 1)])
        NSColor(white: 0.72, alpha: 1).setFill()
        let widths: [CGFloat] = [0.62, 0.55, 0.66, 0.48, 0.6, 0.38, 0.57]
        for (row, fraction) in widths.enumerated() {
            NSRect(x: w * 0.27, y: h - bar - h * 0.27 - CGFloat(row) * h * 0.085, width: w * fraction, height: h * 0.03).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        lock.lock()
        served += 1
        lock.unlock()
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
