// SPDX-License-Identifier: Apache-2.0
//
// Canvas.swift — the few drawing calls every screen uses, in points with
// the origin at the top left, as a window is laid out.

import AppKit

/// An sRGB colour from `0xRRGGBB`.
func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

/// The system's typefaces, as real apps use them.
enum Face {
    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// New York, the system's serif.
    static func serif(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// SF Pro Rounded.
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

/// Drawing in a window-sized, top-left space.
@MainActor
struct Canvas {
    let size: CGSize

    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    func fill(_ rect: CGRect, _ color: NSColor) {
        color.setFill()
        rect.fill()
    }

    func round(_ rect: CGRect, _ radius: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// Rounded only at the top: a tab, a card's header.
    func roundTop(_ rect: CGRect, _ radius: CGFloat, _ color: NSColor) {
        round(rect, radius, color)
        fill(CGRect(x: rect.minX, y: rect.maxY - radius, width: rect.width, height: radius), color)
    }

    func stroke(_ rect: CGRect, _ radius: CGFloat, _ color: NSColor, width: CGFloat = 1) {
        color.setStroke()
        let inset = rect.insetBy(dx: width / 2, dy: width / 2)
        let path = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
        path.lineWidth = width
        path.stroke()
    }

    func circle(_ center: CGPoint, _ radius: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
    }

    func ring(_ center: CGPoint, _ radius: CGFloat, _ color: NSColor, width: CGFloat) {
        color.setStroke()
        let path = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
        path.lineWidth = width
        path.stroke()
    }

    /// A hairline, horizontal or vertical.
    func hline(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ color: NSColor, thickness: CGFloat = 1) {
        fill(CGRect(x: x, y: y, width: width, height: thickness), color)
    }

    func vline(_ x: CGFloat, _ y: CGFloat, _ height: CGFloat, _ color: NSColor, thickness: CGFloat = 1) {
        fill(CGRect(x: x, y: y, width: thickness, height: height), color)
    }

    /// A left-to-right gradient.
    func gradient(_ rect: CGRect, _ colors: [NSColor], radius: CGFloat = 0, angle: CGFloat = 0) {
        guard let gradient = NSGradient(colors: colors) else { return }
        gradient.draw(in: NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius), angle: angle)
    }

    static func width(_ string: String, _ font: NSFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    /// `string` cut by whole characters to fit `width`, with an ellipsis.
    static func fit(_ string: String, _ font: NSFont, _ width: CGFloat) -> String {
        guard Self.width(string, font) > width else { return string }
        var shown = string
        while !shown.isEmpty, Self.width(shown + "\u{2026}", font) > width {
            shown.removeLast()
        }
        return shown.trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// One line at `x`, `y` (its top). Returns its width.
    @discardableResult
    func text(_ string: String, _ x: CGFloat, _ y: CGFloat, _ font: NSFont, _ color: NSColor,
              maxWidth: CGFloat? = nil, kern: CGFloat = 0) -> CGFloat {
        let shown = maxWidth.map { Self.fit(string, font, $0) } ?? string
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if kern != 0 { attributes[.kern] = kern }
        (shown as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
        return Self.width(shown, font)
    }

    /// One line ending at `right`.
    @discardableResult
    func textRight(_ string: String, _ right: CGFloat, _ y: CGFloat, _ font: NSFont, _ color: NSColor) -> CGFloat {
        let width = Self.width(string, font)
        text(string, right - width, y, font, color)
        return width
    }

    /// One line centered in `[x, x + width]`.
    func centered(_ string: String, _ x: CGFloat, _ width: CGFloat, _ y: CGFloat, _ font: NSFont, _ color: NSColor) {
        let measured = Self.width(string, font)
        text(string, x + (width - measured) / 2, y, font, color)
    }

    /// Wrapped text in `rect`. Returns the height it took.
    @discardableResult
    func paragraph(_ string: String, _ rect: CGRect, _ font: NSFont, _ color: NSColor,
                   lineSpacing: CGFloat? = nil, alignment: NSTextAlignment = .left) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing ?? font.pointSize * 0.35
        style.alignment = alignment
        let attributed = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
        let bounds = attributed.boundingRect(with: CGSize(width: rect.width, height: 10_000),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading])
        attributed.draw(with: CGRect(x: rect.minX, y: rect.minY, width: rect.width,
                                     height: max(rect.height, bounds.height)),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounds.height)
    }

    /// The height `string` takes wrapped at `width`.
    static func height(_ string: String, _ width: CGFloat, _ font: NSFont, lineSpacing: CGFloat? = nil) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing ?? font.pointSize * 0.35
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .paragraphStyle: style])
        return ceil(attributed.boundingRect(with: CGSize(width: width, height: 10_000),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    func draw(_ attributed: NSAttributedString, _ x: CGFloat, _ y: CGFloat) {
        attributed.draw(at: CGPoint(x: x, y: y))
    }

    /// An SF Symbol, fitted in `rect`.
    func symbol(_ name: String, _ rect: CGRect, _ color: NSColor, weight: NSFont.Weight = .regular) {
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        let fitted = image.size.width > 0 && image.size.height > 0
            ? min(rect.width / image.size.width, rect.height / image.size.height) : 1
        let drawn = CGSize(width: image.size.width * fitted, height: image.size.height * fitted)
        image.draw(in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                              width: drawn.width, height: drawn.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// The three window buttons.
    func trafficLights(_ x: CGFloat, _ y: CGFloat) {
        for (index, color) in [hex(0xFF5F57), hex(0xFEBC2E), hex(0x28C840)].enumerated() {
            circle(CGPoint(x: x + 6 + CGFloat(index) * 20, y: y + 6), 6, color)
            ring(CGPoint(x: x + 6 + CGFloat(index) * 20, y: y + 6), 6, hex(0x000000, alpha: 0.12), width: 0.5)
        }
    }

    /// A person's initials in a filled circle or rounded square.
    func avatar(_ name: String, _ rect: CGRect, _ color: NSColor, radius: CGFloat? = nil,
                font: NSFont? = nil, textColor: NSColor = .white) {
        round(rect, radius ?? rect.width / 2, color)
        let initials = Self.initials(name)
        let face = font ?? Face.ui(rect.height * 0.4, .semibold)
        let height = face.ascender - face.descender
        centered(initials, rect.minX, rect.width, rect.midY - height / 2, face, textColor)
    }

    static func initials(_ name: String) -> String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    /// A soft drop shadow under `rect`, as a card or a popover casts.
    func shadow(_ rect: CGRect, _ radius: CGFloat, blur: CGFloat = 12, alpha: CGFloat = 0.12, offset: CGFloat = 2) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.shadowBlurRadius = blur
        // The space is flipped: a positive offset falls downward on screen.
        shadow.shadowOffset = NSSize(width: 0, height: -offset)
        shadow.set()
        round(rect, radius, .white)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A stable colour for a person's avatar: the week's people each have
/// their own, and anyone else one from the same calm palette.
func avatarColor(_ name: String) -> NSColor {
    let known: [String: UInt32] = [
        "Ren Alder": 0x2E9E8F, "Iris Lindgren": 0xD9604C, "Theo Brandt": 0x3F8F5F, "Nadia Rahim": 0x7B61FF,
        "Malik Osei": 0x3A7BD5, "Joy Tran": 0xC2477A, "Mira Castell": 0x5A67D8, "Owen Pryce": 0x5B6B7F,
    ]
    if let color = known[name] { return hex(color) }
    let palette: [UInt32] = [0x5B7FDB, 0x2E9E8F, 0xC2477A, 0x7B61FF, 0xD9604C, 0x3A7BD5, 0x5B6B7F, 0x3F8F5F]
    let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    return hex(palette[sum % palette.count])
}
