// SPDX-License-Identifier: TBD-private
//
// Writes every hi mark asset from HiMarkGeometry.swift: the app icon PNGs,
// the browser toolbar icons, the website favicon and touch icon, and the
// SVGs. scripts/generate-brand-assets.sh compiles and runs it, then builds
// the .icns and its copies.
//
//   generate <repo-root>         write every asset
//   generate --svg <directory>   write only the SVGs (for --check)

import CoreGraphics
import Foundation
import ImageIO

@main
enum GenerateBrandAssets {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 2, arguments[0] == "--svg" {
            try SVG.writeAll(to: URL(fileURLWithPath: arguments[1], isDirectory: true))
        } else if arguments.count == 1 {
            try writeAll(root: URL(fileURLWithPath: arguments[0], isDirectory: true))
        } else {
            FileHandle.standardError.write(Data("usage: generate <repo-root> | --svg <directory>\n".utf8))
            exit(64)
        }
    }

    static func writeAll(root: URL) throws {
        let branding = root.appendingPathComponent("assets/branding")
        try SVG.writeAll(to: branding)

        let iconset = branding.appendingPathComponent("AppIcon.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for (name, side) in Icon.iconset {
            try PNG.encode(Icon.appIcon(side: side)).write(to: iconset.appendingPathComponent(name))
        }

        // Encoded once, so both browsers get the same bytes.
        let toolbars = ["extensions/chromium/icons", "extensions/safari/icons"].map { root.appendingPathComponent($0) }
        for side in Icon.toolbarSides {
            let bytes = try PNG.encode(Icon.fullBleed(side: side))
            for folder in toolbars {
                try bytes.write(to: folder.appendingPathComponent("toolbar-\(side).png"))
            }
        }

        // A browser shrinking the 32 px favicon to 16 blurs the h into the
        // i, so 1x displays get their own 16 px drawing.
        let website = root.appendingPathComponent("website/public")
        try PNG.encode(Icon.fullBleed(side: 32)).write(to: website.appendingPathComponent("favicon.png"))
        try PNG.encode(Icon.fullBleed(side: 16)).write(to: website.appendingPathComponent("favicon-16.png"))
        try PNG.encode(Icon.touch(side: 180)).write(to: website.appendingPathComponent("apple-touch-icon.png"))
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - PNG

enum Icon {
    static let iconset: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    static let toolbarSides = [16, 19, 32, 38, 48, 72, 96, 128]

    /// The app icon on Apple's grid: the 824 tile inside a 100 gutter, with
    /// the tile's shadow.
    static func appIcon(side: Int) -> CGImage {
        let k = CGFloat(side) / 1024
        let tile = CGRect(x: HiMark.iconTileRect.minX * k, y: HiMark.iconTileRect.minY * k,
                          width: HiMark.iconTileRect.width * k, height: HiMark.iconTileRect.height * k)
        return draw(side: side, tile: tile, shape: .squircle, tileShadow: true, stem: side == 16 ? 1.5 : nil)
    }

    /// The tile filling the canvas, with no gutter and no tile shadow: the
    /// browser toolbar icons and the favicon.
    static func fullBleed(side: Int) -> CGImage {
        let stems: [Int: CGFloat] = [16: 1.5, 19: 2, 32: 3]
        return draw(side: side, tile: CGRect(x: 0, y: 0, width: side, height: side), shape: .squircle, tileShadow: false, stem: stems[side])
    }

    /// An opaque square for iOS, which rounds the corners itself.
    static func touch(side: Int) -> CGImage {
        draw(side: side, tile: CGRect(x: 0, y: 0, width: side, height: side), shape: .square, tileShadow: false, stem: nil)
    }

    enum Shape { case squircle, square }

    /// Draws the tile and the mark, y growing downward. Sizes are those of
    /// the 1024 grid scaled with the tile. `stem` (pixels) grows the mark
    /// about its center at small sizes, where the scaled drawing would merge
    /// the h, the i and the dot. Below 64 px the letter shadow is left out.
    static func draw(side: Int, tile: CGRect, shape: Shape, tileShadow: Bool, stem: CGFloat?) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let opaque = shape == .square
        let bitmapInfo = (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: bitmapInfo)!
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        // Pixels per unit of the 1024 grid, measured along the tile.
        let k = tile.width / HiMark.iconTileRect.width

        let outline: CGPath
        switch shape {
        case .squircle:
            var place = CGAffineTransform(translationX: tile.minX, y: tile.minY)
            outline = HiMark.tile(side: tile.width).copy(using: &place)!
        case .square:
            outline = CGPath(rect: tile, transform: nil)
        }

        if tileShadow {
            // Offset 12, sigma 16, black 30%. Core Graphics blur is twice the sigma.
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 32 * k, color: black(0.30))
            context.addPath(outline)
            context.setFillColor(color(HiMark.tileBottomRGB))
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(outline)
        context.clip()
        let gradient = CGGradient(colorsSpace: space, colors: [color(HiMark.tileTopRGB), color(HiMark.tileBottomRGB)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
        if shape == .squircle, !tileShadow {
            // Full bleed: only the inner half of the hairline would survive the canvas edge, so draw just that.
            context.addPath(outline)
            context.setStrokeColor(black(0.10))
            context.setLineWidth(2 * 4.9 * k)
            context.strokePath()
        }
        context.restoreGState()
        if shape == .squircle, tileShadow {
            context.addPath(outline)
            context.setStrokeColor(black(0.10))
            context.setLineWidth(4.9 * k)
            context.strokePath()
        }

        drawMark(in: context, tile: tile, k: k, stem: stem, shadow: side >= 64)
        return context.makeImage()!
    }

    /// The mark at 56% of the tile's width. The h stem's left edge, the i's
    /// left edge and the baseline land on whole pixels, and the dot is
    /// centered on the i.
    static func drawMark(in context: CGContext, tile: CGRect, k: CGFloat, stem: CGFloat?, shadow: Bool) {
        var unit = HiMark.iconMarkScale * k
        var origin = CGPoint(x: tile.minX + (HiMark.iconMarkOrigin.x - HiMark.iconTileRect.minX) * k,
                             y: tile.minY + (HiMark.iconMarkOrigin.y - HiMark.iconTileRect.minY) * k)
        if let stem {
            let box = HiMark.inkBounds
            let center = CGPoint(x: origin.x + box.midX * unit, y: origin.y + box.midY * unit)
            unit = stem / HiMark.stemWidth
            origin = CGPoint(x: center.x - box.midX * unit, y: center.y - box.midY * unit)
        }
        let hLeft = origin.x.rounded()
        let baseline = (origin.y + HiMark.baseline * unit).rounded()
        let top = baseline - HiMark.baseline * unit
        let iLeft = (hLeft + HiMark.iStemLeft * unit).rounded()
        let dotX = iLeft + HiMark.stemWidth / 2 * unit
        let phase = dotX - dotX.rounded(.down)
        let dotY = (top + HiMark.dotCenter.y * unit - phase).rounded() + phase
        let dotRadius = HiMark.dotRadius * unit

        context.saveGState()
        if shadow {
            // Under the letters and dot together: offset 7.4, sigma 7.4, black 14%.
            context.setShadow(offset: CGSize(width: 0, height: -7.4 * k), blur: 14.8 * k, color: black(0.14))
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.addPath(placed(HiMark.hOnly(), x: hLeft, y: top, unit: unit))
        context.addPath(placed(HiMark.iStem(), x: iLeft - HiMark.iStemLeft * unit, y: top, unit: unit))
        context.setFillColor(color(HiMark.lettersRGB))
        context.fillPath(using: .winding)
        context.setFillColor(color(HiMark.dotRGB))
        context.fillEllipse(in: CGRect(x: dotX - dotRadius, y: dotY - dotRadius, width: 2 * dotRadius, height: 2 * dotRadius))
        context.endTransparencyLayer()
        context.restoreGState()
    }

    static func placed(_ path: CGPath, x: CGFloat, y: CGFloat, unit: CGFloat) -> CGPath {
        var transform = CGAffineTransform(translationX: x, y: y).scaledBy(x: unit, y: unit)
        return path.copy(using: &transform)!
    }

    static func color(_ rgb: UInt32) -> CGColor {
        let c = HiMark.components(rgb)
        return CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }

    static func black(_ alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha)
    }
}

enum PNG {
    /// Pixels and nothing else. ImageIO adds sRGB and eXIf chunks on its
    /// own, so only the chunks that carry pixels are kept.
    static func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw Failure("the PNG encoder is unavailable")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure("PNG encoding failed") }
        return try pixelChunksOnly(data as Data)
    }

    static func pixelChunksOnly(_ png: Data) throws -> Data {
        let bytes = [UInt8](png)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.starts(with: signature) else { throw Failure("not a PNG") }
        var output = Data(signature)
        var offset = signature.count
        while offset + 12 <= bytes.count {
            let length = bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let end = offset + 12 + length
            guard end <= bytes.count else { throw Failure("truncated PNG chunk") }
            let type = String(decoding: bytes[offset + 4 ..< offset + 8], as: UTF8.self)
            if ["IHDR", "PLTE", "tRNS", "IDAT", "IEND"].contains(type) {
                output.append(contentsOf: bytes[offset ..< end])
            }
            if type == "IEND" { return output }
            offset = end
        }
        throw Failure("PNG has no end")
    }
}

// MARK: - SVG

enum SVG {
    static let label = "Hippocampus hi mark: a lowercase h and i side by side"

    static func writeAll(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files: [(String, String)] = [
            ("AppIcon.svg", appIcon()),
            ("AppIcon-template.svg", mark(letters: "#000000", dot: "#000000")),
            ("hippocampus-icon.svg", mark(letters: hex(HiMark.lettersRGB), dot: hex(HiMark.dotRGB))),
            ("hi-states-light.svg", states(ink: "#1D1D1F")),
            ("hi-states-dark.svg", states(ink: "#F5F5F7")),
        ]
        for (name, text) in files {
            try Data(text.utf8).write(to: folder.appendingPathComponent(name))
        }
    }

    /// The letters and dot exactly as the tests read them; any transform goes on a parent.
    static func letters(fill: String, dot: String) -> String {
        "<path id=\"letters\" d=\"\(HiMark.lettersSVGPath)\" fill=\"\(fill)\"/>"
            + "<circle id=\"dot\" cx=\"\(n(HiMark.dotCenter.x))\" cy=\"\(n(HiMark.dotCenter.y))\" r=\"\(n(HiMark.dotRadius))\" fill=\"\(dot)\"/>"
    }

    static func appIcon() -> String {
        let shadow = 7.4 / HiMark.iconMarkScale
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="\(label)">
        <title>\(label)</title>
        <defs>
        <linearGradient id="lab" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="\(hex(HiMark.tileTopRGB))"/><stop offset="1" stop-color="\(hex(HiMark.tileBottomRGB))"/></linearGradient>
        <filter id="lift" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="12" stdDeviation="16" flood-color="#000000" flood-opacity="0.3"/></filter>
        <filter id="letter-shadow" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="\(n(shadow))" stdDeviation="\(n(shadow))" flood-color="#000000" flood-opacity="0.14"/></filter>
        </defs>
        <path id="tile" d="\(HiMark.tileSVGPath)" fill="url(#lab)" filter="url(#lift)"/>
        <path d="\(HiMark.tileSVGPath)" fill="none" stroke="#000000" stroke-opacity="0.1" stroke-width="4.9"/>
        <g transform="translate(\(n(HiMark.iconMarkOrigin.x)) \(n(HiMark.iconMarkOrigin.y))) scale(\(n(HiMark.iconMarkScale)))" filter="url(#letter-shadow)">\(letters(fill: hex(HiMark.lettersRGB), dot: hex(HiMark.dotRGB)))</g>
        </svg>

        """
    }

    static func mark(letters fill: String, dot: String) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="-4 -6 102 110" role="img" aria-label="\(label)">
        <title>\(label)</title>
        \(letters(fill: fill, dot: dot))
        </svg>

        """
    }

    /// The menu bar's four pictures with their words, one color, for the README.
    static func states(ink: String) -> String {
        let words: [(HiMark.State, String)] = [
            (.remembering, "Remembering"), (.skipping, "Password field"),
            (.off, "Paused or off"), (.needsYou, "Needs you"),
        ]
        let cell: CGFloat = 180, scale: CGFloat = 0.6
        let box = HiMark.inkBounds
        var body = ""
        for (index, (state, word)) in words.enumerated() {
            let centerX = cell * (CGFloat(index) + 0.5)
            let x = centerX - box.midX * scale, y = 58 - box.midY * scale
            var parts = ""
            var letters = ""
            for part in HiMark.parts(for: state) {
                switch part {
                case .h: letters += "<path d=\"\(HiMark.hSVGPath)\"/>"
                case .iStem: letters += "<path d=\"\(HiMark.iStemSVGPath)\"/>"
                case .bangStem: letters += "<path d=\"\(HiMark.bangStemSVGPath)\"/>"
                case .dot: parts += circle(HiMark.dotCenter, HiMark.dotRadius)
                case .bangDot: parts += circle(HiMark.bangDotCenter, HiMark.dotRadius)
                case .ring:
                    let radius = (HiMark.ringOuterRadius + HiMark.ringInnerRadius) / 2
                    let width = HiMark.ringOuterRadius - HiMark.ringInnerRadius
                    parts += "<circle cx=\"\(n(HiMark.ringCenter.x))\" cy=\"\(n(HiMark.ringCenter.y))\" r=\"\(n(radius))\" fill=\"none\" stroke=\"\(ink)\" stroke-width=\"\(n(width))\"/>"
                }
            }
            let strength = HiMark.letterStrength(for: state)
            if strength < 1 { letters = "<g opacity=\"\(n(strength))\">\(letters)</g>" }
            body += "<g transform=\"translate(\(n(x)) \(n(y))) scale(\(n(scale)))\">\(letters)\(parts)</g>\n"
            body += "<text x=\"\(n(centerX))\" y=\"136\" text-anchor=\"middle\">\(word)</text>\n"
        }
        let title = "The menu-bar icon: remembering, password field, paused or off, needs you"
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(n(cell * 4)) 160" role="img" aria-label="\(title)">
        <title>\(title)</title>
        <g font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif" font-size="15" fill="\(ink)">
        \(body)</g>
        </svg>

        """
    }

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> String {
        "<circle cx=\"\(n(center.x))\" cy=\"\(n(center.y))\" r=\"\(n(radius))\"/>"
    }

    static func hex(_ rgb: UInt32) -> String { String(format: "#%06X", rgb) }

    /// At most four decimals, no trailing zeros: 5.1088, 281.28, 0.3.
    static func n(_ value: CGFloat) -> String {
        var text = String(format: "%.4f", Double(value))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}
