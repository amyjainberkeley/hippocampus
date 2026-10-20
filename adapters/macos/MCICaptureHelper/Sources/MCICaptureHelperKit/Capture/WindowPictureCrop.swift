// SPDX-License-Identifier: Apache-2.0
//
// WindowPictureCrop — the picture of a window beside the one in front, made
// from the very display frame its text was read from (SPEC 6.4).
//
// PRIVACY: a side picture must never show another window's pixels. So the
// crop is rounded inward (every pixel kept lies inside the window), every
// window drawn in front of it is masked out rounded outward (every pixel it
// touches is covered), and the masks are applied to the full-size crop
// before anything is scaled, so no covered pixel can bleed into the result
// through resampling. The window's rounded corners are masked too, since
// what shows outside them belongs to whatever is behind. The JPEG carries
// no metadata: every APPn segment but the JFIF header, and every comment,
// is removed after encoding.

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum WindowPictureCrop {
    /// A side picture is at most this many pixels on its long edge. The
    /// window in front keeps its own rule (3,840 at 0.88).
    public static let maximumLongEdge = 1_600
    public static let jpegQuality = 0.80
    /// Enough of the window must be seen: this share of its whole area,
    /// unmasked, on the display being read...
    public static let minimumVisibleFraction = 0.6
    /// ...and at least this much of it on that display, in points.
    public static let minimumVisibleSize = CGSize(width: 200, height: 120)
    /// Rounded window corners, in points: generous enough for every macOS
    /// window shape, so nothing behind a corner shows.
    public static let cornerRadius: CGFloat = 26
    /// The flat neutral fill over everything that is not the window's own.
    public static let maskRGB: (red: UInt8, green: UInt8, blue: UInt8) = (142, 142, 147)
    /// A picture whose unmasked pixels nearly all sit this close to one
    /// luma is almost one colour (protected video draws black).
    static let oneColourLumaTolerance = 10
    static let oneColourShare = 0.98

    /// Where the picture comes from in the frame, and what is masked.
    public struct Plan: Sendable, Equatable {
        /// The window's part on this display, in frame pixels, top-left
        /// origin, rounded inward.
        public let crop: CGRect
        /// Parts of `crop` covered by windows in front, in crop pixels,
        /// top-left origin, rounded outward.
        public let masks: [CGRect]
        /// Corner squares masked outside the window's rounded corners, in
        /// crop pixels: the radius in pixels.
        public let cornerRadiusPixels: CGFloat
        /// The unmasked share of the whole window's area, 0 to 1.
        public let visibleFraction: Double
        /// The window's part on this display, in points.
        public let visibleSize: CGSize

        /// Rule 6.2.4: at least 60% of it seen, and at least 200 by 120 pt.
        public var isVisibleEnough: Bool {
            visibleFraction >= WindowPictureCrop.minimumVisibleFraction
                && visibleSize.width >= WindowPictureCrop.minimumVisibleSize.width
                && visibleSize.height >= WindowPictureCrop.minimumVisibleSize.height
        }
    }

    /// The plan for `window` in a frame of `pixelSize` that shows
    /// `displayBounds` (global points, top-left origin), with `windows`
    /// listed front to back as the window server gave them with the frame.
    /// Nil when the window is not in the list, not on this display, or the
    /// frame has no size.
    ///
    /// A window in front is masked when it is drawn in the pixels. Windows
    /// of apps removed from the pixels (password managers, notification
    /// banners, the Dock's display-sized overlay, Hippocampus, apps the
    /// person left out) leave the window beneath visible there; an ordinary
    /// app window of theirs is masked all the same, so a stale filter can
    /// never show one.
    public static func plan(
        for window: VisibleWindow, displayBounds: CGRect, pixelSize: CGSize,
        windows: [VisibleWindow], excludedBundleIds: Set<String>
    ) -> Plan? {
        guard displayBounds.width > 0, displayBounds.height > 0, pixelSize.width >= 1, pixelSize.height >= 1,
              window.bounds.width > 0, window.bounds.height > 0,
              let index = windows.firstIndex(where: { $0.windowId == window.windowId })
        else { return nil }
        let onDisplay = window.bounds.intersection(displayBounds)
        guard !onDisplay.isNull, onDisplay.width > 0, onDisplay.height > 0 else { return nil }

        // Covered parts, in points, clipped to the visible rectangle.
        var covered: [CGRect] = []
        for other in windows[..<index] {
            if let bundle = other.bundleId, BackgroundCapturePolicy.isExcluded(bundle, from: excludedBundleIds),
               other.layer != 0 {
                continue
            }
            let overlap = other.bounds.intersection(onDisplay)
            if !overlap.isNull, overlap.width > 0, overlap.height > 0 { covered.append(overlap) }
        }
        let visibleArea = Self.area(of: Self.subtract(covered, from: onDisplay))
        let fraction = Double(visibleArea / (window.bounds.width * window.bounds.height))

        let sx = pixelSize.width / displayBounds.width, sy = pixelSize.height / displayBounds.height
        let frame = CGRect(origin: .zero, size: pixelSize)
        func pixels(_ rect: CGRect) -> CGRect {
            CGRect(x: (rect.minX - displayBounds.minX) * sx, y: (rect.minY - displayBounds.minY) * sy,
                   width: rect.width * sx, height: rect.height * sy)
        }
        let crop = Self.inward(pixels(onDisplay)).intersection(frame)
        guard !crop.isNull, crop.width >= 1, crop.height >= 1 else { return nil }
        let masks = covered.compactMap { rect -> CGRect? in
            let masked = Self.outward(pixels(rect)).intersection(crop)
            guard !masked.isNull, masked.width > 0, masked.height > 0 else { return nil }
            return masked.offsetBy(dx: -crop.minX, dy: -crop.minY)
        }
        return Plan(crop: crop, masks: masks, cornerRadiusPixels: (cornerRadius * max(sx, sy)).rounded(.up),
                    visibleFraction: min(1, max(0, fraction)), visibleSize: onDisplay.size)
    }

    /// The masked picture, its dHash and whether it is almost one colour.
    public struct Picture: @unchecked Sendable {
        public let image: CGImage
        public let dhash: DHash
        public let nearlyOneColour: Bool
    }

    /// Crops `pixelBuffer` (32-bit BGRA) to the plan, masks it, then scales
    /// it to at most `maximumLongEdge` in sRGB. Nil for another pixel format
    /// or a plan outside the buffer.
    public static func render(
        _ pixelBuffer: CVPixelBuffer, plan: Plan, maximumLongEdge: Int = Self.maximumLongEdge
    ) -> Picture? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer), bytesPerRow >= width * 4 else { return nil }
        let x0 = Int(plan.crop.minX), y0 = Int(plan.crop.minY)
        let cw = Int(plan.crop.width), ch = Int(plan.crop.height)
        guard x0 >= 0, y0 >= 0, cw > 0, ch > 0, x0 + cw <= width, y0 + ch <= height else { return nil }

        // The window's own pixels, copied row by row.
        var bytes = [UInt8](repeating: 0, count: cw * ch * 4)
        let source = base.assumingMemoryBound(to: UInt8.self)
        bytes.withUnsafeMutableBytes { out in
            guard let destination = out.baseAddress else { return }
            for row in 0..<ch {
                memcpy(destination + row * cw * 4, source + (y0 + row) * bytesPerRow + x0 * 4, cw * 4)
            }
        }
        let masked = Self.maskedCells(plan: plan, width: cw, height: ch)
        let nearlyOneColour = Self.isNearlyOneColour(bytes, width: cw, height: ch, masked: masked)
        // The masks go on before anything is scaled: whole rectangles row by
        // row, then the pixels outside each rounded corner.
        let fill = maskRGB
        var pattern: UInt32 = UInt32(fill.blue) | UInt32(fill.green) << 8 | UInt32(fill.red) << 16 | 0xFF00_0000
        bytes.withUnsafeMutableBytes { out in
            guard let pixels = out.baseAddress else { return }
            func paint(_ x0: Int, _ x1: Int, _ y: Int) {
                guard x1 > x0 else { return }
                memset_pattern4(pixels + (y * cw + x0) * 4, &pattern, (x1 - x0) * 4)
            }
            for mask in plan.masks {
                let mx0 = max(0, Int(mask.minX)), mx1 = min(cw, Int(mask.maxX.rounded(.up)))
                let my0 = max(0, Int(mask.minY)), my1 = min(ch, Int(mask.maxY.rounded(.up)))
                for y in my0..<max(my0, my1) { paint(mx0, mx1, y) }
            }
            let r = Self.cornerSize(plan: plan, width: cw, height: ch)
            guard r > 0 else { return }
            for y in Array(0..<r) + Array((ch - r)..<ch) {
                for x in Array(0..<r) + Array((cw - r)..<cw) where masked(x, y) { paint(x, x + 1, y) }
            }
        }
        let space = CVImageBufferGetColorSpace(pixelBuffer)?.takeUnretainedValue()
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        // Opaque: the frame's alpha byte is ignored, as a JPEG ignores it.
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let full = CGImage(width: cw, height: ch, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cw * 4,
                                 space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                 decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let scale = min(1, Double(maximumLongEdge) / Double(max(cw, ch)))
        let ow = max(1, Int((Double(cw) * scale).rounded())), oh = max(1, Int((Double(ch) * scale).rounded()))
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: srgb, bitmapInfo: info)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: ow, height: oh))
        guard let image = context.makeImage() else { return nil }
        return Picture(image: image, dhash: Self.dhash(of: image), nearlyOneColour: nearlyOneColour)
    }

    /// Whether the crop pixel (x, y), top-left origin, is masked: under a
    /// window in front, or outside the window's rounded corners.
    static func maskedCells(plan: Plan, width: Int, height: Int) -> (Int, Int) -> Bool {
        let masks = plan.masks.map {
            (x0: Int($0.minX), y0: Int($0.minY), x1: Int($0.maxX.rounded(.up)), y1: Int($0.maxY.rounded(.up)))
        }
        let radius = Self.cornerRadius(plan: plan, width: width, height: height)
        let r = Self.cornerSize(plan: plan, width: width, height: height)
        return { x, y in
            for mask in masks where x >= mask.x0 && x < mask.x1 && y >= mask.y0 && y < mask.y1 { return true }
            guard r > 0 else { return false }
            // Outside the quarter circle of the nearest corner.
            let cx: Double? = x < r ? radius : (x >= width - r ? Double(width) - radius : nil)
            let cy: Double? = y < r ? radius : (y >= height - r ? Double(height) - radius : nil)
            guard let cx, let cy else { return false }
            let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
            return dx * dx + dy * dy > radius * radius
        }
    }

    /// The corner radius in crop pixels, at most half the shorter side.
    static func cornerRadius(plan: Plan, width: Int, height: Int) -> Double {
        Double(min(plan.cornerRadiusPixels, CGFloat(min(width, height)) / 2))
    }

    /// The side of each corner square that can hold masked pixels.
    static func cornerSize(plan: Plan, width: Int, height: Int) -> Int {
        Int(cornerRadius(plan: plan, width: width, height: height).rounded(.up))
    }

    /// Almost one colour: nearly every unmasked sample sits close to one luma.
    static func isNearlyOneColour(_ bgra: [UInt8], width: Int, height: Int, masked: (Int, Int) -> Bool) -> Bool {
        let stepX = max(1, width / 48), stepY = max(1, height / 48)
        var histogram = [Int](repeating: 0, count: 256)
        var count = 0
        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) where !masked(x, y) {
                let i = (y * width + x) * 4
                histogram[(Int(bgra[i + 2]) * 77 + Int(bgra[i + 1]) * 150 + Int(bgra[i]) * 29) >> 8] += 1
                count += 1
            }
        }
        guard count > 0 else { return true }
        // The most common luma, and how many samples sit near it.
        var best = 0
        for luma in 0..<256 where histogram[luma] > histogram[best] { best = luma }
        let near = histogram[max(0, best - oneColourLumaTolerance)...min(255, best + oneColourLumaTolerance)]
            .reduce(0, +)
        return Double(near) / Double(count) >= oneColourShare
    }

    /// The 64-bit difference hash of `image`, as the window in front's rule
    /// compares pictures: a 9×8 grayscale thumbnail, each bit whether a
    /// pixel is brighter than its right neighbour.
    public static func dhash(of image: CGImage) -> DHash {
        var gray = [UInt8](repeating: 0, count: 9 * 8)
        let drawn: Bool = gray.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 9, height: 8, bitsPerComponent: 8,
                                          bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        guard drawn else { return DHash(bits: 0) }
        var bits: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 where gray[y * 9 + x] > gray[y * 9 + x + 1] {
                bits |= 1 << UInt64(y * 8 + x)
            }
        }
        return DHash(bits: bits)
    }

    /// The picture as a JPEG with no metadata: no EXIF, XMP, colour profile
    /// or comment, only the JFIF header and the image.
    public static func jpeg(_ image: CGImage, quality: Double = jpegQuality) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString,
                                                                 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return withoutMetadata(data as Data)
    }

    /// `jpeg` without APP1 to APP15 and COM segments. Nil when it is not a
    /// well-formed JPEG up to its first scan.
    static func withoutMetadata(_ jpeg: Data) -> Data? {
        let bytes = [UInt8](jpeg)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var out = Data([0xFF, 0xD8])
        var offset = 2
        while offset + 4 <= bytes.count {
            guard bytes[offset] == 0xFF else { return nil }
            let marker = bytes[offset + 1]
            if marker == 0xDA {
                // Start of scan: the rest is image data and the end marker.
                out.append(contentsOf: bytes[offset...])
                return out
            }
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length >= 2, offset + 2 + length <= bytes.count else { return nil }
            let isMetadata = (0xE1...0xEF).contains(marker) || marker == 0xFE
            if !isMetadata { out.append(contentsOf: bytes[offset..<(offset + 2 + length)]) }
            offset += 2 + length
        }
        return nil
    }

    // MARK: Geometry

    /// `rect` minus every rectangle in `holes`, as disjoint rectangles.
    static func subtract(_ holes: [CGRect], from rect: CGRect) -> [CGRect] {
        var pieces = [rect]
        for hole in holes {
            var next: [CGRect] = []
            for piece in pieces {
                let cut = piece.intersection(hole)
                guard !cut.isNull, cut.width > 0, cut.height > 0 else {
                    next.append(piece)
                    continue
                }
                // Above, below, then left and right of the cut.
                let parts = [
                    CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: cut.minY - piece.minY),
                    CGRect(x: piece.minX, y: cut.maxY, width: piece.width, height: piece.maxY - cut.maxY),
                    CGRect(x: piece.minX, y: cut.minY, width: cut.minX - piece.minX, height: cut.height),
                    CGRect(x: cut.maxX, y: cut.minY, width: piece.maxX - cut.maxX, height: cut.height),
                ]
                next.append(contentsOf: parts.filter { $0.width > 0 && $0.height > 0 })
            }
            pieces = next
        }
        return pieces
    }

    static func area(of rects: [CGRect]) -> CGFloat {
        rects.reduce(0) { $0 + $1.width * $1.height }
    }

    /// The largest whole-pixel rectangle inside `rect`.
    static func inward(_ rect: CGRect) -> CGRect {
        let x0 = rect.minX.rounded(.up), y0 = rect.minY.rounded(.up)
        let x1 = rect.maxX.rounded(.down), y1 = rect.maxY.rounded(.down)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// The smallest whole-pixel rectangle that covers `rect`.
    static func outward(_ rect: CGRect) -> CGRect {
        let x0 = rect.minX.rounded(.down), y0 = rect.minY.rounded(.down)
        let x1 = rect.maxX.rounded(.up), y1 = rect.maxY.rounded(.up)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
