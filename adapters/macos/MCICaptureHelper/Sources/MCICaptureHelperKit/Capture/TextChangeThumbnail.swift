import CoreVideo
import Foundation

/// A quarter-scale luminance thumbnail, used to notice text that changed since
/// the last frame that was read.
///
/// The dHash gate samples 72 single pixels of the whole window. Typing a
/// paragraph or receiving a chat message rarely moves those samples, so the
/// frame was dropped as a near-duplicate and the new text was never read until
/// something larger changed. One thumbnail pixel per 4×4 block registers a
/// word, while a caret blink touches only a handful.
public struct TextChangeThumbnail: Sendable, Equatable {
    public static let step = 4
    /// A thumbnail pixel counts as changed past this luma difference.
    public static let lumaDelta = 24

    public let width: Int
    public let height: Int
    public let luma: [UInt8]

    public init(width: Int, height: Int, luma: [UInt8]) {
        self.width = width
        self.height = height
        self.luma = luma
    }

    /// Nearest-neighbour sample of a 32-BGRA buffer; nil for other formats.
    public static func make(from pixelBuffer: CVPixelBuffer) -> TextChangeThumbnail? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        let tw = w / step, th = h / step
        guard tw > 0, th > 0,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard bytesPerRow >= w * 4 else { return nil }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var luma = [UInt8](repeating: 0, count: tw * th)
        luma.withUnsafeMutableBufferPointer { out in
            for ty in 0..<th {
                let row = pixels + ty * step * bytesPerRow
                for tx in 0..<tw {
                    let p = row + tx * step * 4
                    // Rec.601 luma, integer, as the dHash grid uses.
                    out[ty * tw + tx] = UInt8((Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) >> 8)
                }
            }
        }
        return TextChangeThumbnail(width: tw, height: th, luma: luma)
    }

    /// Thumbnail pixels whose luma moved past `lumaDelta`; nil when the frames
    /// differ in size, which a window resize already reports as new content.
    public func changedPixels(since other: TextChangeThumbnail) -> Int? {
        guard width == other.width, height == other.height else { return nil }
        var changed = 0
        luma.withUnsafeBufferPointer { a in
            other.luma.withUnsafeBufferPointer { b in
                for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > Self.lumaDelta {
                    changed += 1
                }
            }
        }
        return changed
    }
}

/// When a near-duplicate frame should be read anyway because its text moved on.
public enum TextCatchUpPolicy {
    /// About two short words at Retina scale; a caret blink stays well below.
    public static let changedPixelThreshold = 48
    /// Continuous typing is read at most this often.
    public static let minimumIntervalUs: UInt64 = 3_000_000

    public static func shouldRead(changedPixels: Int?, sinceBaselineUs: UInt64) -> Bool {
        guard let changedPixels else { return false }
        return changedPixels >= changedPixelThreshold && sinceBaselineUs >= minimumIntervalUs
    }
}
