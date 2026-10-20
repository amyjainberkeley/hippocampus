#if DEBUG
import AppKit

/// Debug-only screenshots for Today's renders, drawn like the windows Sam
/// worked in on the fixtures' Monday, beside `SyntheticScreens`: Figma with
/// the pricing page, a Zoom call, Notes with the pricing draft, and Mail with
/// an invoice. Every name and word is made up; nothing is read from disk or
/// from any screen.
enum TodayPreviewScreens {
    enum Screen: CaseIterable {
        case design, call, notes, mail
    }

    static let size = CGSize(width: 1440, height: 900)

    /// The screen as the capture helper keeps it: a JPEG of the window.
    static func jpeg(_ screen: Screen) -> Data? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0),
            let base = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        let cg = base.cgContext
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        switch screen {
        case .design: design()
        case .call: call()
        case .notes: notes()
        case .mail: mail()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }

    // MARK: Figma: the pricing page

    private static func design() {
        fill(CGRect(origin: .zero, size: size), hex(0xF5F5F5))
        // Toolbar.
        fill(CGRect(x: 0, y: 0, width: size.width, height: 48), hex(0x2C2C2C))
        lights(x: 18, y: 18)
        for (index, name) in ["cursorarrow", "number", "square", "pencil.tip", "textformat", "bubble.left"].enumerated() {
            symbol(name, in: CGRect(x: 96 + CGFloat(index) * 40, y: 14, width: 20, height: 20), color: hex(0xE6E6E6))
        }
        centered("Trailhead pricing v3", y: 15, size: 14, weight: .semibold, color: .white)
        round(CGRect(x: size.width - 104, y: 10, width: 84, height: 28), 6, hex(0x0D99FF))
        text("Share", size.width - 82, 15, size: 14, weight: .semibold, color: .white)
        // Layers.
        fill(CGRect(x: 0, y: 48, width: 240, height: size.height - 48), .white)
        fill(CGRect(x: 240, y: 48, width: 1, height: size.height - 48), hex(0xE5E5E5))
        text("Layers", 16, 64, size: 13, weight: .semibold, color: hex(0x333333))
        let layers = ["Pricing page", "Navigation", "Hero", "Plan cards", "Ride", "Tour", "Club", "Questions", "Footer"]
        for (index, layer) in layers.enumerated() {
            let y = 98 + CGFloat(index) * 30
            let indent: CGFloat = index == 0 ? 16 : (4...6).contains(index) ? 52 : 34
            if index == 3 { round(CGRect(x: 8, y: y - 6, width: 224, height: 28), 4, hex(0xE5F4FF)) }
            symbol(index == 0 ? "number" : "square.on.square", in: CGRect(x: indent, y: y, width: 14, height: 14),
                   color: hex(0x8C8C8C))
            text(layer, indent + 22, y - 1, size: 13, color: hex(0x333333))
        }
        // Properties.
        fill(CGRect(x: size.width - 240, y: 48, width: 240, height: size.height - 48), .white)
        fill(CGRect(x: size.width - 241, y: 48, width: 1, height: size.height - 48), hex(0xE5E5E5))
        text("Design", size.width - 224, 64, size: 13, weight: .semibold, color: hex(0x333333))
        for (index, label) in ["Frame", "Auto layout", "Fill", "Stroke", "Effects", "Export"].enumerated() {
            let y = 104 + CGFloat(index) * 64
            text(label, size.width - 224, y, size: 12, weight: .semibold, color: hex(0x333333))
            round(CGRect(x: size.width - 224, y: y + 22, width: 96, height: 24), 4, hex(0xF0F0F0))
            round(CGRect(x: size.width - 118, y: y + 22, width: 96, height: 24), 4, hex(0xF0F0F0))
        }
        // The page on the canvas.
        let page = CGRect(x: 330, y: 92, width: 780, height: 760)
        text("Pricing page", page.minX, page.minY - 22, size: 12, color: hex(0x8C8C8C))
        fill(page, .white)
        fill(CGRect(x: page.minX, y: page.minY, width: page.width, height: 56), .white)
        text("Trailhead", page.minX + 32, page.minY + 18, size: 18, weight: .bold, color: hex(0x1B2B24))
        for (index, item) in ["Bikes", "Rentals", "Repairs", "Pricing"].enumerated() {
            text(item, page.minX + 420 + CGFloat(index) * 82, page.minY + 20, size: 14,
                 weight: index == 3 ? .semibold : .regular, color: hex(index == 3 ? 0x1B2B24 : 0x5F6B66))
        }
        fill(CGRect(x: page.minX, y: page.minY + 56, width: page.width, height: 1), hex(0xEDEDED))
        centered("One plan for every rider", x: page.minX, width: page.width, y: page.minY + 104, size: 34,
                 weight: .bold, color: hex(0x1B2B24))
        centered("Start free, then $18 a month for the whole team.", x: page.minX, width: page.width,
                 y: page.minY + 156, size: 16, color: hex(0x5F6B66))
        let plans: [(String, String, String, Bool)] = [
            ("Ride", "$0", "For trying it out", false),
            ("Tour", "$18", "For small shops", true),
            ("Club", "$36", "For busy shops", false),
        ]
        for (index, plan) in plans.enumerated() {
            let card = CGRect(x: page.minX + 40 + CGFloat(index) * 240, y: page.minY + 220, width: 220, height: 330)
            round(card, 12, plan.3 ? hex(0x1B2B24) : hex(0xF4F6F5))
            let ink = plan.3 ? NSColor.white : hex(0x1B2B24)
            let soft = plan.3 ? hex(0xB9C7C0) : hex(0x5F6B66)
            text(plan.0, card.minX + 24, card.minY + 26, size: 18, weight: .semibold, color: ink)
            text(plan.1, card.minX + 24, card.minY + 60, size: 40, weight: .bold, color: ink)
            text("a month", card.minX + 24 + width(plan.1, size: 40, weight: .bold) + 8, card.minY + 82, size: 14,
                 color: soft)
            text(plan.2, card.minX + 24, card.minY + 118, size: 14, color: soft)
            for row in 0..<4 {
                let y = card.minY + 160 + CGFloat(row) * 28
                symbol("checkmark", in: CGRect(x: card.minX + 24, y: y + 2, width: 13, height: 13),
                       color: plan.3 ? hex(0x7DD3A8) : hex(0x2E8B57))
                fill(CGRect(x: card.minX + 46, y: y + 6, width: CGFloat(110 + (row * 23 + index * 17) % 40),
                            height: 7), plan.3 ? hex(0x52675D) : hex(0xD9DEDB))
            }
            round(CGRect(x: card.minX + 24, y: card.maxY - 60, width: 172, height: 38), 8,
                  plan.3 ? hex(0x7DD3A8) : .white)
            centered(plan.3 ? "Start free" : "Choose", x: card.minX + 24, width: 172, y: card.maxY - 50, size: 14,
                     weight: .semibold, color: hex(0x1B2B24))
        }
        text("Questions", page.minX + 40, page.minY + 590, size: 20, weight: .semibold, color: hex(0x1B2B24))
        for row in 0..<3 {
            let y = page.minY + 630 + CGFloat(row) * 36
            fill(CGRect(x: page.minX + 40, y: y, width: 700, height: 1), hex(0xEDEDED))
            fill(CGRect(x: page.minX + 40, y: y + 14, width: CGFloat(260 + row * 70), height: 8), hex(0xD9DEDB))
        }
        // The selection on the middle card.
        let selected = CGRect(x: page.minX + 280, y: page.minY + 220, width: 220, height: 330)
        let path = NSBezierPath(rect: selected.insetBy(dx: -2, dy: -2))
        path.lineWidth = 1.5
        hex(0x0D99FF).setStroke()
        path.stroke()
    }

    // MARK: Zoom: the weekly review

    private static func call() {
        fill(CGRect(origin: .zero, size: size), hex(0x1A1A1A))
        fill(CGRect(x: 0, y: 0, width: size.width, height: 36), hex(0x242424))
        lights(x: 14, y: 12)
        centered("Zoom Meeting", y: 9, size: 13, weight: .medium, color: hex(0xBDBDBD))
        let people: [(String, UInt32)] = [("Maya Chen", 0x6C7A89), ("Jordan Lee", 0x8D6E63), ("Sam", 0x5C7F67),
                                          ("Priya Shah", 0x7E6B8F)]
        let tile = CGSize(width: 640, height: 360)
        for (index, person) in people.enumerated() {
            let x = 64 + CGFloat(index % 2) * (tile.width + 32)
            let y = 64 + CGFloat(index / 2) * (tile.height + 24)
            round(CGRect(x: x, y: y, width: tile.width, height: tile.height), 10, hex(0x2B2B2B))
            round(CGRect(x: x + tile.width / 2 - 56, y: y + tile.height / 2 - 56, width: 112, height: 112), 56,
                  hex(person.1))
            centered(String(person.0.prefix(1)), x: x + tile.width / 2 - 56, width: 112, y: y + tile.height / 2 - 24,
                     size: 40, weight: .semibold, color: .white)
            round(CGRect(x: x + 12, y: y + tile.height - 40, width: width(person.0, size: 14) + 20, height: 28), 6,
                  hex(0x000000, alpha: 0.55))
            text(person.0, x + 22, y + tile.height - 35, size: 14, color: .white)
            if index == 1 {
                let ring = NSBezierPath(roundedRect: CGRect(x: x, y: y, width: tile.width, height: tile.height),
                                        xRadius: 10, yRadius: 10)
                ring.lineWidth = 3
                hex(0x2D8CFF).setStroke()
                ring.stroke()
            }
        }
        fill(CGRect(x: 0, y: size.height - 70, width: size.width, height: 70), hex(0x242424))
        for (index, name) in ["mic.fill", "video.fill", "person.2.fill", "bubble.left.fill", "square.and.arrow.up"]
            .enumerated() {
            symbol(name, in: CGRect(x: 520 + CGFloat(index) * 84, y: size.height - 52, width: 26, height: 22),
                   color: hex(0xE0E0E0))
        }
        round(CGRect(x: size.width - 120, y: size.height - 52, width: 84, height: 32), 8, hex(0xE02828))
        text("End", size.width - 92, size.height - 45, size: 15, weight: .semibold, color: .white)
    }

    // MARK: Notes: the pricing draft

    private static func notes() {
        fill(CGRect(origin: .zero, size: size), .white)
        fill(CGRect(x: 0, y: 0, width: 260, height: size.height), hex(0xF6F5F2))
        lights(x: 20, y: 20)
        text("iCloud", 20, 60, size: 12, weight: .semibold, color: hex(0x9A9A9A))
        for (index, folder) in ["All iCloud", "Notes", "Launch", "Recently Deleted"].enumerated() {
            let y = 86 + CGFloat(index) * 30
            if index == 2 { round(CGRect(x: 10, y: y - 5, width: 240, height: 28), 6, hex(0xE8E4DA)) }
            symbol("folder", in: CGRect(x: 22, y: y, width: 16, height: 14), color: hex(0xE0A800))
            text(folder, 46, y - 1, size: 14, color: hex(0x333333))
        }
        fill(CGRect(x: 260, y: 0, width: 300, height: size.height), hex(0xFBFBFA))
        fill(CGRect(x: 260, y: 0, width: 1, height: size.height), hex(0xE2E0DA))
        let list: [(String, String)] = [("Pricing page draft", "2:36 PM  Three plans: Ride, Tour"),
                                        ("Launch checklist", "1:34 PM  Rounding fix merged"),
                                        ("Gift card copy", "Yesterday  Give a ride"),
                                        ("Supplier list", "Friday  Spokewise, Velo")]
        for (index, note) in list.enumerated() {
            let y = 60 + CGFloat(index) * 70
            if index == 0 { round(CGRect(x: 270, y: y - 8, width: 280, height: 62), 8, hex(0xF6E7A8)) }
            text(note.0, 288, y, size: 14, weight: .semibold, color: hex(0x222222))
            text(note.1, 288, y + 22, size: 12, color: hex(0x777777))
        }
        fill(CGRect(x: 560, y: 0, width: 1, height: size.height), hex(0xE2E0DA))
        let x: CGFloat = 640
        text("Oct 12, 2026 at 2:36 PM", x + 180, 30, size: 12, color: hex(0x9A9A9A))
        text("Pricing page draft", x, 80, size: 30, weight: .bold, color: hex(0x1F1F1F))
        text("Hero", x, 140, size: 18, weight: .semibold, color: hex(0x1F1F1F))
        text("One plan for every rider. Start free, then $18 a month.", x, 172, size: 16, color: hex(0x333333))
        text("Plans", x, 222, size: 18, weight: .semibold, color: hex(0x1F1F1F))
        for (index, line) in ["Ride: free, one bike, rentals only", "Tour: $18 a month, up to 10 bikes",
                              "Club: $36 a month, the whole shop"].enumerated() {
            let y = 256 + CGFloat(index) * 30
            round(CGRect(x: x + 4, y: y + 8, width: 6, height: 6), 3, hex(0x333333))
            text(line, x + 22, y, size: 16, color: hex(0x333333))
        }
        text("Questions", x, 366, size: 18, weight: .semibold, color: hex(0x1F1F1F))
        paragraph("""
            Can I change plans later? Yes, any time. What counts as a bike? Anything with a frame number.
            """, in: CGRect(x: x, y: 398, width: 640, height: 60), font: .systemFont(ofSize: 16), color: hex(0x333333))
    }

    // MARK: Mail: an invoice

    private static func mail() {
        fill(CGRect(origin: .zero, size: size), .white)
        fill(CGRect(x: 0, y: 0, width: 220, height: size.height), hex(0xF2F2F5))
        lights(x: 20, y: 20)
        for (index, box) in ["Inbox", "Drafts", "Sent", "Archive"].enumerated() {
            let y = 64 + CGFloat(index) * 30
            if index == 0 { round(CGRect(x: 10, y: y - 5, width: 200, height: 28), 6, hex(0xDCDCE2)) }
            symbol(index == 0 ? "tray" : "doc", in: CGRect(x: 22, y: y, width: 16, height: 14), color: hex(0x1A73E8))
            text(box, 46, y - 1, size: 14, color: hex(0x222222))
        }
        fill(CGRect(x: 220, y: 0, width: 360, height: size.height), hex(0xFAFAFC))
        fill(CGRect(x: 220, y: 0, width: 1, height: size.height), hex(0xE0E0E5))
        let list: [(String, String, String)] = [("Spokewise Supply", "Invoice 2291", "9:12 AM"),
                                                ("Velo Parts", "Your order has shipped", "8:40 AM"),
                                                ("Northwind Studio", "Notes from Friday", "Yesterday")]
        for (index, mail) in list.enumerated() {
            let y = 60 + CGFloat(index) * 78
            if index == 0 { round(CGRect(x: 228, y: y - 10, width: 344, height: 70), 8, hex(0x1A73E8)) }
            let ink = index == 0 ? NSColor.white : hex(0x222222)
            text(mail.0, 244, y, size: 14, weight: .semibold, color: ink)
            text(mail.1, 244, y + 22, size: 13, color: index == 0 ? hex(0xE3EEFF) : hex(0x555555))
            text(mail.2, 500, y, size: 12, color: index == 0 ? hex(0xE3EEFF) : hex(0x999999))
        }
        fill(CGRect(x: 580, y: 0, width: 1, height: size.height), hex(0xE0E0E5))
        let x: CGFloat = 630
        text("Invoice 2291", x, 60, size: 26, weight: .bold, color: hex(0x1F1F1F))
        text("Spokewise Supply  \u{00B7}  To: Sam  \u{00B7}  9:12 AM", x, 102, size: 13, color: hex(0x777777))
        fill(CGRect(x: x, y: 132, width: 760, height: 1), hex(0xEEEEEE))
        paragraph("""
            Hi Sam, your October order is on its way. The invoice is attached. Payment is due at the end of \
            the month, and the usual account applies.
            """, in: CGRect(x: x, y: 156, width: 720, height: 70), font: .systemFont(ofSize: 16), color: hex(0x333333))
        let rows = [("Brake pads, 40", "$320.00"), ("Inner tubes, 120", "$540.00"), ("Chain lube, 24", "$168.00")]
        for (index, row) in rows.enumerated() {
            let y = 260 + CGFloat(index) * 40
            fill(CGRect(x: x, y: y - 8, width: 520, height: 1), hex(0xEEEEEE))
            text(row.0, x, y, size: 15, color: hex(0x333333))
            text(row.1, x + 440, y, size: 15, color: hex(0x333333))
        }
        fill(CGRect(x: x, y: 372, width: 520, height: 1), hex(0xCCCCCC))
        text("Total", x, 384, size: 15, weight: .semibold, color: hex(0x1F1F1F))
        text("$1,028.00", x + 428, 384, size: 15, weight: .semibold, color: hex(0x1F1F1F))
        round(CGRect(x: x, y: 440, width: 210, height: 54), 8, hex(0xF2F2F5))
        symbol("doc.richtext", in: CGRect(x: x + 14, y: 452, width: 24, height: 30), color: hex(0xD93025))
        text("invoice-2291.pdf", x + 50, 456, size: 14, color: hex(0x333333))
        text("48 KB", x + 50, 474, size: 12, color: hex(0x888888))
    }

    // MARK: Pieces

    private static func lights(x: CGFloat, y: CGFloat) {
        for (index, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            round(CGRect(x: x + CGFloat(index) * 20, y: y, width: 12, height: 12), 6, hex(UInt32(color)))
        }
    }

    private static func symbol(_ name: String, in rect: CGRect, color: NSColor) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: rect.height, weight: .regular)) else { return }
        let tinted = NSImage(size: image.size, flipped: false) { bounds in
            image.draw(in: bounds)
            color.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private static func fill(_ rect: CGRect, _ color: NSColor) {
        color.setFill()
        rect.fill()
    }

    private static func round(_ rect: CGRect, _ radius: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    private static func text(_ string: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 13,
                             weight: NSFont.Weight = .regular, color: NSColor) {
        (string as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        ])
    }

    private static func width(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
    }

    private static func centered(_ string: String, x: CGFloat = 0, width: CGFloat = TodayPreviewScreens.size.width,
                                 y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
        let measured = self.width(string, size: size, weight: weight)
        text(string, x + (width - measured) / 2, y, size: size, weight: weight, color: color)
    }

    private static func paragraph(_ string: String, in rect: CGRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
    }

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}
#endif
