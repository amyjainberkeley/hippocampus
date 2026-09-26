import CoreGraphics
import CoreText
import Foundation
import ImageIO

// Headless bitmap rendering only. Coordinates match the 640x420 Finder layout.
let width = 640
let height = 420
guard CommandLine.arguments.count == 3,
      let context = CGContext(data: nil, width: width * 2, height: height * 2,
                              bitsPerComponent: 8, bytesPerRow: width * 8,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Could not create installer bitmap")
}
context.scaleBy(x: 2, y: 2)
context.setFillColor(CGColor(gray: 0.98, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))

func text(_ value: String, size: CGFloat, baselineFromTop: CGFloat, gray: CGFloat, left: CGFloat? = nil) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
    let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
    guard lineWidth <= 568 else { fatalError("Installer text exceeds layout bounds") }
    context.textPosition = CGPoint(x: left ?? (640 - lineWidth) / 2, y: 420 - baselineFromTop)
    CTLineDraw(line, context)
}

text("Drag Hippocampus to Applications.", size: 20, baselineFromTop: 78, gray: 0.18)
context.setStrokeColor(CGColor(gray: 0.56, alpha: 1))
context.setLineWidth(2)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: 292, y: 235))
context.addLine(to: CGPoint(x: 348, y: 235))
context.move(to: CGPoint(x: 338, y: 245))
context.addLine(to: CGPoint(x: 348, y: 235))
context.addLine(to: CGPoint(x: 338, y: 225))
context.strokePath()
text("Updating? Quit Hippocampus from the menu bar first.", size: 12, baselineFromTop: 290, gray: 0.4)
text(CommandLine.arguments[2], size: 11, baselineFromTop: 378, gray: 0.42, left: 36)

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, "public.png" as CFString, 1, nil
      ) else { fatalError("Could not create installer PNG") }
// Preserve 640x420 point size on both Retina and non-Retina Finder displays.
CGImageDestinationAddImage(destination, image, [
    kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144,
] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write installer PNG") }
