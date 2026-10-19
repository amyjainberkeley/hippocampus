import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

// A picture of the installer window as Finder lays it out, drawn headlessly
// from layout.json: the title bar, the background below it, each item's icon
// centred on its saved position and its name underneath. It is a mock-up
// for judging the design, not a screenshot; nothing opens in Finder.
//
// Usage: render-window-preview.swift LAYOUT.json BACKGROUND.png STAGING APP_ICON.icns OUTPUT.png
//
// STAGING mirrors the disk image's top level: every item other than the app
// takes the icon macOS gives it there (the Applications link, the Legal
// folder with its own icon).

struct Layout: Decodable {
    struct Window: Decodable { let x, y, width, height: Int }
    let window: Window
    let titleBarHeight: Int
    let iconSize: Int
    let textSize: Int
    let items: [String: [Int]]
}

let arguments = CommandLine.arguments
guard arguments.count == 6 else {
    FileHandle.standardError.write(Data(
        "usage: render-window-preview.swift LAYOUT.json BACKGROUND.png STAGING APP_ICON.icns OUTPUT.png\n".utf8))
    exit(2)
}
let layout: Layout
do {
    layout = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
} catch {
    fatalError("Could not read the installer layout: \(error)")
}
guard let backgroundSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL, nil),
      let background = CGImageSourceCreateImageAtIndex(backgroundSource, 0, nil),
      let appIcon = NSImage(contentsOfFile: arguments[4]) else {
    fatalError("Could not read the background or the app icon")
}
let staging = URL(fileURLWithPath: arguments[3])

let width = CGFloat(layout.window.width)
let height = CGFloat(layout.window.height)
let titleBar = CGFloat(layout.titleBarHeight)
let margin: CGFloat = 56
let scale: CGFloat = 2
let canvas = CGSize(width: width + margin * 2, height: height + margin * 2)

func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: Int(canvas.width * scale), height: Int(canvas.height * scale),
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Could not create the preview bitmap")
}
context.scaleBy(x: scale, y: scale)
context.translateBy(x: 0, y: canvas.height)
context.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

// A plain desk for the window to sit on.
if let desk = CGGradient(colorsSpace: space, colors: [srgb(0xE6E9EE), srgb(0xD3D8E0)] as CFArray, locations: [0, 1]) {
    context.drawLinearGradient(desk, start: .zero, end: CGPoint(x: 0, y: canvas.height), options: [])
}

let frame = CGRect(x: margin, y: margin, width: width, height: height)
let shape = CGPath(roundedRect: frame, cornerWidth: 16, cornerHeight: 16, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 18), blur: 44, color: srgb(0x000000, alpha: 0.28))
context.addPath(shape)
context.setFillColor(srgb(0xFFFFFF))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(shape)
context.clip()

// Finder draws the background from the top of the area under the title bar;
// the window's bottom edge cuts off what the title bar pushed down.
func drawImage(_ image: CGImage, in rect: CGRect) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
}
drawImage(background, in: CGRect(x: frame.minX, y: frame.minY + titleBar, width: width, height: height))

func draw(_ value: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, centerX: CGFloat, top: CGFloat) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(x: (centerX - lineWidth / 2).rounded(), y: (top + font.ascender).rounded())
    CTLineDraw(line, context)
}

// Each item: its icon centred on the saved position, its name underneath.
let iconSize = CGFloat(layout.iconSize)
for (name, position) in layout.items.sorted(by: { $0.key < $1.key }) {
    let center = CGPoint(x: frame.minX + CGFloat(position[0]), y: frame.minY + titleBar + CGFloat(position[1]))
    let icon = name == "Hippocampus.app" ? appIcon : NSWorkspace.shared.icon(forFile: staging.appendingPathComponent(name).path)
    icon.draw(in: CGRect(x: center.x - iconSize / 2, y: center.y - iconSize / 2, width: iconSize, height: iconSize),
              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    let label = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    draw(label, size: CGFloat(layout.textSize), weight: .regular, color: srgb(0x000000, alpha: 0.85),
         centerX: center.x, top: center.y + iconSize / 2 + 3)
}

// The title bar: the window buttons and the volume's name with its icon.
context.setFillColor(srgb(0xF6F6F7))
context.fill(CGRect(x: frame.minX, y: frame.minY, width: width, height: titleBar))
context.setFillColor(srgb(0x000000, alpha: 0.09))
context.fill(CGRect(x: frame.minX, y: frame.minY + titleBar - 0.5, width: width, height: 0.5))
for (index, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
    let light = CGRect(x: frame.minX + 14 + CGFloat(index) * 20, y: frame.minY + titleBar / 2 - 6, width: 12, height: 12)
    context.setFillColor(srgb(hex))
    context.fillEllipse(in: light)
    context.setStrokeColor(srgb(0x000000, alpha: 0.12))
    context.setLineWidth(0.5)
    context.strokeEllipse(in: light.insetBy(dx: 0.25, dy: 0.25))
}
let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
let titleWidth = ("Hippocampus" as NSString).size(withAttributes: [.font: titleFont]).width
let titleLeft = frame.midX - (titleWidth + 20) / 2
appIcon.draw(in: CGRect(x: titleLeft, y: frame.minY + titleBar / 2 - 8, width: 16, height: 16),
             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
draw("Hippocampus", size: 13, weight: .semibold, color: srgb(0x000000, alpha: 0.78),
     centerX: titleLeft + 20 + titleWidth / 2, top: frame.minY + titleBar / 2 - 8)
context.restoreGState()

context.addPath(shape)
context.setStrokeColor(srgb(0x000000, alpha: 0.2))
context.setLineWidth(0.5)
context.strokePath()

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: arguments[5]) as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("Could not create the preview PNG")
}
CGImageDestinationAddImage(destination, image, [
    kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144,
] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write the preview PNG") }
