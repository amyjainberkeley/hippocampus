import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

// Renders the installer window's background, headless, from layout.json.
//
// The picture is the size of the whole window frame Finder restores
// (layout.json "window"), so it fills the window whether or not Finder counts
// the title bar. Everything a person reads sits in the area below the title
// bar: "height" minus "titleBarHeight".
//
// Usage: render-background.swift OUTPUT.png LAYOUT.json

// The only words the window shows. build-installer.sh --verify-assets reads
// the rendered picture back and fails on anything else.
let dragCue = "Drag to Applications"
let updateNote = "Updating? Quit Hippocampus from the menu bar first."

struct Layout: Decodable {
    struct Window: Decodable { let x, y, width, height: Int }
    let window: Window
    let titleBarHeight: Int
    let iconSize: Int
    let textSize: Int
    let items: [String: [Int]]
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: render-background.swift OUTPUT.png LAYOUT.json\n".utf8))
    exit(2)
}
let layout: Layout
do {
    layout = try JSONDecoder().decode(
        Layout.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
} catch {
    fatalError("Could not read the installer layout: \(error)")
}
guard let app = layout.items["Hippocampus.app"], let applications = layout.items["Applications"] else {
    fatalError("The installer layout must place Hippocampus.app and Applications")
}

let width = CGFloat(layout.window.width)
let height = CGFloat(layout.window.height)
let visibleHeight = height - CGFloat(layout.titleBarHeight)
let iconSize = CGFloat(layout.iconSize)
let scale: CGFloat = 2

// Brand colours: the hi mark's Lab tile, its dot, and graphite for quiet text
// (assets/branding/README.md and colors.json).
func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let labTop = srgb(0xFFFFFF)
let labBottom = srgb(0xE9EEF6)
let dot = srgb(0x2F6BFF)
let graphite = srgb(0x6E6E73)

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale),
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Could not create installer bitmap")
}
context.scaleBy(x: scale, y: scale)
// From here on y runs down from the top, as Finder measures icon positions.
context.translateBy(x: 0, y: height)
context.scaleBy(x: 1, y: -1)

func linear(_ colors: [CGColor], _ locations: [CGFloat], from start: CGPoint, to end: CGPoint) {
    guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else {
        fatalError("Could not create installer gradient")
    }
    context.drawLinearGradient(gradient, start: start, end: end,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// The canvas: the tile's white-to-mist gradient over the visible area.
linear([labTop, labBottom], [0, 1], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: visibleHeight))
let row = CGFloat(app[1])
let gapStart = CGFloat(app[0]) + iconSize / 2
let gapEnd = CGFloat(applications[0]) - iconSize / 2
let middle = (gapStart + gapEnd) / 2

// The arrow: centred in the gap between the two icons, on their centre line,
// fading in from the app's side and ending in the hi dot's blue.
let arrowLength: CGFloat = 96
let arrowStart = CGPoint(x: middle - arrowLength / 2, y: row)
let arrowEnd = CGPoint(x: middle + arrowLength / 2, y: row)
let stroke: CGFloat = 2
let shaft = CGMutablePath()
shaft.move(to: arrowStart)
shaft.addLine(to: CGPoint(x: arrowEnd.x - stroke / 2, y: row))
context.saveGState()
context.addPath(shaft.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 4))
context.clip()
linear([srgb(0x2F6BFF, alpha: 0), dot], [0, 1], from: arrowStart, to: arrowEnd)
context.restoreGState()
let arm: CGFloat = 8
context.setStrokeColor(dot)
context.setLineWidth(stroke)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: arrowEnd.x - arm * 0.766, y: row - arm * 0.643))
context.addLine(to: arrowEnd)
context.addLine(to: CGPoint(x: arrowEnd.x - arm * 0.766, y: row + arm * 0.643))
context.strokePath()

// One line of text, centred on centerX, in the system font Finder uses.
func text(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular, color: CGColor,
          centerX: CGFloat, baselineFromTop: CGFloat) {
    guard !value.isEmpty else { return }
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): NSFont.systemFont(ofSize: size, weight: weight),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    guard lineWidth <= width - 64 else { fatalError("Installer text is wider than the window: \(value)") }
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(x: (centerX - lineWidth / 2).rounded(), y: baselineFromTop)
    CTLineDraw(line, context)
}

text(dragCue, size: 12, weight: .medium, color: graphite, centerX: middle, baselineFromTop: row - 16)
text(updateNote, size: 11, color: graphite, centerX: width / 2, baselineFromTop: visibleHeight - 28)

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, "public.png" as CFString, 1, nil
      ) else { fatalError("Could not create installer PNG") }
// 144 dpi: Finder shows the 2x bitmap at the window's point size, crisp on
// Retina and scaled down on other displays.
CGImageDestinationAddImage(destination, image, [
    kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144,
] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write installer PNG") }
