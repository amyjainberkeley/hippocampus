import AppKit
import CoreGraphics
import Foundation
import ImageIO

// The Legal folder's icon in the installer window: a small page, so the
// license terms read as fine print and the window's only folder-shaped target
// is Applications. Finder draws every icon in the window at one size; the
// page fills the lower part of that square, just above its label, and the
// rest is transparent.
//
// Usage:
//   render-legal-icon.swift png OUTPUT.png   write the 1024 px icon
//   render-legal-icon.swift apply FOLDER     make it FOLDER's icon, then read
//                                            it back; fails if it did not stick

let side = 1024

func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func renderIcon() -> CGImage {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Could not create the Legal icon bitmap")
    }
    // y runs down from the top.
    context.translateBy(x: 0, y: CGFloat(side))
    context.scaleBy(x: 1, y: -1)

    // A letter-shaped page whose bottom sits where an app icon's tile ends on
    // Apple's 1024 grid, so its label lines up with the other labels.
    let page = CGRect(x: 512 - 152, y: 924 - 392, width: 304, height: 392)
    let fold: CGFloat = 88
    let radius: CGFloat = 36
    let outline = CGMutablePath()
    outline.move(to: CGPoint(x: page.minX + radius, y: page.minY))
    outline.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY))
    outline.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
    outline.addArc(tangent1End: CGPoint(x: page.maxX, y: page.maxY),
                   tangent2End: CGPoint(x: page.minX, y: page.maxY), radius: radius)
    outline.addArc(tangent1End: CGPoint(x: page.minX, y: page.maxY),
                   tangent2End: CGPoint(x: page.minX, y: page.minY), radius: radius)
    outline.addArc(tangent1End: CGPoint(x: page.minX, y: page.minY),
                   tangent2End: CGPoint(x: page.maxX, y: page.minY), radius: radius)
    outline.closeSubpath()

    // Soft lift, like the app icon's tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: srgb(0x000000, alpha: 0.18))
    context.addPath(outline)
    context.setFillColor(srgb(0xFFFFFF))
    context.fillPath()
    context.restoreGState()

    // The tile's white-to-mist gradient and its hairline edge.
    context.saveGState()
    context.addPath(outline)
    context.clip()
    if let gradient = CGGradient(colorsSpace: space, colors: [srgb(0xFFFFFF), srgb(0xE9EEF6)] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: page.minY),
                                   end: CGPoint(x: 0, y: page.maxY), options: [])
    }
    context.restoreGState()
    context.addPath(outline)
    context.setStrokeColor(srgb(0x0F1B3D, alpha: 0.16))
    context.setLineWidth(6)
    context.strokePath()

    // The folded corner.
    let corner = CGMutablePath()
    corner.move(to: CGPoint(x: page.maxX - fold, y: page.minY))
    corner.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY + fold - 20))
    corner.addQuadCurve(to: CGPoint(x: page.maxX - fold + 20, y: page.minY + fold),
                        control: CGPoint(x: page.maxX - fold, y: page.minY + fold))
    corner.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
    corner.closeSubpath()
    // The fold's underside: the tile's mist under a faint wash of the letters' navy.
    for colour in [srgb(0xE9EEF6), srgb(0x0F1B3D, alpha: 0.06)] {
        context.addPath(corner)
        context.setFillColor(colour)
        context.fillPath()
    }
    context.addPath(corner)
    context.setStrokeColor(srgb(0x0F1B3D, alpha: 0.16))
    context.setLineWidth(6)
    context.setLineJoin(.round)
    context.strokePath()

    // Lines of text, in the letters' navy, kept faint.
    let inset: CGFloat = 58
    let widths: [CGFloat] = [0.62, 1, 1, 0.84, 1, 0.56]
    for (index, fraction) in widths.enumerated() {
        let lineWidth = (page.width - inset * 2) * fraction
        let bar = CGRect(x: page.minX + inset, y: page.minY + 124 + CGFloat(index) * 38,
                         width: lineWidth, height: 16)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 8, cornerHeight: 8, transform: nil))
    }
    context.setFillColor(srgb(0x0F1B3D, alpha: 0.2))
    context.fillPath()

    guard let image = context.makeImage() else { fatalError("Could not render the Legal icon") }
    return image
}

let arguments = CommandLine.arguments
guard arguments.count == 3, ["png", "apply"].contains(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: render-legal-icon.swift png OUTPUT.png | apply FOLDER\n".utf8))
    exit(2)
}
let icon = renderIcon()
let target = URL(fileURLWithPath: arguments[2])

if arguments[1] == "png" {
    guard let destination = CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil)
    else { fatalError("Could not create \(target.path)") }
    CGImageDestinationAddImage(destination, icon, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(target.path)") }
    exit(0)
}

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
    FileHandle.standardError.write(Data("ERROR: no folder at \(target.path)\n".utf8))
    exit(1)
}
let representation = NSBitmapImageRep(cgImage: icon)
representation.size = NSSize(width: side / 2, height: side / 2)
let image = NSImage(size: representation.size)
image.addRepresentation(representation)
guard NSWorkspace.shared.setIcon(image, forFile: target.path, options: [.excludeQuickDrawElementsIconCreationOption]) else {
    FileHandle.standardError.write(Data("ERROR: could not set the icon of \(target.path)\n".utf8))
    exit(1)
}
// Read back what Finder reads: the folder's custom-icon flag and the icon
// data in the hidden "Icon\r" file's resource fork.
func attribute(_ name: String, of path: String) -> [UInt8]? {
    let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    guard getxattr(path, name, &bytes, size, 0, XATTR_NOFOLLOW) == size else { return nil }
    return bytes
}
let hasCustomIcon: UInt16 = 0x0400
let finderInfo = attribute("com.apple.FinderInfo", of: target.path) ?? []
let flags = finderInfo.count >= 10 ? UInt16(finderInfo[8]) << 8 | UInt16(finderInfo[9]) : 0
let iconData = attribute("com.apple.ResourceFork", of: target.appendingPathComponent("Icon\r").path) ?? []
guard flags & hasCustomIcon != 0, !iconData.isEmpty else {
    FileHandle.standardError.write(Data("ERROR: the icon of \(target.path) did not persist\n".utf8))
    exit(1)
}
