#if DEBUG
import AppKit
import RecallUIKit

/// Drawn stand-ins for the windows Sam's Working On items show, for the
/// off-screen renders: two Figma files, three Notes notes, a Numbers sheet,
/// a pricing page and a Cursor window, each the whole front window
/// (1440 × 900, JPEG) as the capture helper keeps it. Every word and pixel
/// is made up. The editor, the article, the terminal, the document and the
/// chat come from `SyntheticScreens`.
@MainActor
enum WorkScreens {
    static let size = CGSize(width: 1440, height: 900)

    /// The screen named `name`, as a JPEG: `figma`, `figma-v2`, `checklist`,
    /// `draft`, `gift-card`, `invoices`, `pricing`, `bike-api`, or one of
    /// `SyntheticScreens`' (`editor`, `article`, `terminal`, `document`,
    /// `chat`).
    static func jpeg(_ name: String) -> Data? {
        switch name {
        case "editor": return SyntheticScreens.jpeg(.editor)
        case "article": return SyntheticScreens.jpeg(.article)
        case "terminal": return SyntheticScreens.jpeg(.terminal)
        case "document": return SyntheticScreens.jpeg(.document)
        case "chat": return SyntheticScreens.jpeg(.chat)
        default: break
        }
        let draw: (() -> Void)?
        switch name {
        case "figma": draw = { figma(version: 3) }
        case "figma-v2": draw = { figma(version: 2) }
        case "checklist": draw = { notes(.checklist) }
        case "draft": draw = { notes(.draft) }
        case "gift-card": draw = { notes(.giftCard) }
        case "invoices": draw = invoices
        case "pricing": draw = pricing
        case "bike-api": draw = cursor
        default: draw = nil
        }
        guard let draw else { return nil }
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
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }

    // MARK: Screens

    /// Trailhead's pricing page in Figma: v3 with three plans, v2 (two
    /// weeks older) with two.
    private static func figma(version: Int) {
        let older = version < 3
        fill(CGRect(origin: .zero, size: size), hex(0xE5E5E5))
        fill(CGRect(x: 0, y: 0, width: size.width, height: 52), hex(0x2C2C2C))
        lights(x: 22, y: 20)
        centered("Trailhead pricing v\(version)", y: 16, size: 17, weight: .medium, color: hex(0xEEEEEE))
        // Layers on the left, properties on the right.
        fill(CGRect(x: 0, y: 52, width: 300, height: size.height - 52), hex(0xFFFFFF))
        text("Pages", 20, 76, size: 15, weight: .semibold, color: hex(0x1E1E1E))
        for (index, page) in ["Pricing", "Checkout", "Gift cards"].enumerated() {
            if index == 0 { fill(CGRect(x: 0, y: 102, width: 300, height: 30), hex(0xE5F4FF)) }
            text(page, 34, 108 + CGFloat(index) * 32, size: 15, color: hex(0x1E1E1E))
        }
        text("Layers", 20, 222, size: 15, weight: .semibold, color: hex(0x1E1E1E))
        for (index, layer) in ["Pricing", "Nav", "Hero", "Plans", "Ride", "Tour", "Club", "Footer"].enumerated() {
            let y = 254 + CGFloat(index) * 32
            if layer == "Plans" { fill(CGRect(x: 0, y: y - 6, width: 300, height: 30), hex(0xE5F4FF)) }
            stroke(CGRect(x: 34, y: y + 2, width: 13, height: 13), hex(0x8A8A8A))
            text(layer, 56, y - 1, size: 15, color: hex(0x1E1E1E))
        }
        fill(CGRect(x: size.width - 320, y: 52, width: 320, height: size.height - 52), hex(0xFFFFFF))
        for (index, label) in ["Frame", "Auto layout", "Fill", "Stroke"].enumerated() {
            let y = 80 + CGFloat(index) * 110
            text(label, size.width - 300, y, size: 15, weight: .semibold, color: hex(0x1E1E1E))
            round(CGRect(x: size.width - 300, y: y + 30, width: 130, height: 30), 4, hex(0xF0F0F0))
            round(CGRect(x: size.width - 160, y: y + 30, width: 130, height: 30), 4, hex(0xF0F0F0))
        }
        // The frame: the pricing page.
        let frame = CGRect(x: 420, y: 130, width: 700, height: 690)
        text("Pricing \u{00B7} Desktop", frame.minX, frame.minY - 26, size: 13, color: hex(0x7A7A7A))
        fill(frame, hex(0xFFFFFF))
        text("Trailhead Bikes", frame.minX + 46, frame.minY + 44, size: 18, weight: .semibold, color: hex(0x123B2A))
        text("Rentals    Tours    Pricing    Sign in", frame.maxX - 300, frame.minY + 46, size: 14, color: hex(0x333333))
        centered(older ? "Ride more, pay less" : "One plan for every team", x: frame.minX, width: frame.width,
                 y: frame.minY + 108, size: 34, weight: .bold, color: hex(0x10251C))
        centered(older ? "Rent by the day, or ride all year." : "Start free, then $18 a seat each month, billed annually.",
                 x: frame.minX, width: frame.width, y: frame.minY + 162, size: 15, color: hex(0x555555))
        let plans = older
            ? [("Day pass", "$12", "a day", "Book a bike"), ("Annual", "$149", "a year", "Ride all year")]
            : [("Ride", "$0", "one person", "Start free"), ("Tour", "$18", "a seat, monthly", "Choose Tour"),
               ("Club", "$29", "a seat, monthly", "Talk to us")]
        let featured = 1
        let width: CGFloat = older ? 280 : 190
        let gap: CGFloat = older ? 40 : 20
        let left = frame.minX + (frame.width - CGFloat(plans.count) * width - CGFloat(plans.count - 1) * gap) / 2
        for (index, plan) in plans.enumerated() {
            let card = CGRect(x: left + CGFloat(index) * (width + gap), y: frame.minY + 236, width: width, height: 250)
            round(card, 10, hex(0xFFFFFF))
            strokeRound(card, 10, index == featured ? hex(0x1F6F4A) : hex(0xDADADA), width: index == featured ? 3 : 1)
            text(plan.0, card.minX + 18, card.minY + 22, size: 18, weight: .semibold, color: hex(0x10251C))
            text(plan.1, card.minX + 18, card.minY + 58, size: 28, weight: .bold, color: hex(0x10251C))
            text(plan.2, card.minX + (older ? 104 : 80), card.minY + 70, size: 12, color: hex(0x666666))
            round(CGRect(x: card.minX + 18, y: card.maxY - 64, width: card.width - 36, height: 34), 6,
                  index == featured ? hex(0x1F6F4A) : hex(0xEEF2EF))
            centered(plan.3, x: card.minX, width: card.width, y: card.maxY - 56, size: 14, weight: .semibold,
                     color: index == featured ? hex(0xFFFFFF) : hex(0x1F6F4A))
        }
    }

    /// bike-api in Cursor, two weeks back: its routes, dark.
    private static func cursor() {
        fill(CGRect(origin: .zero, size: size), hex(0x1E1E1E))
        fill(CGRect(x: 0, y: 0, width: size.width, height: 40), hex(0x2B2B2B))
        lights(x: 18, y: 14)
        centered("routes.rs \u{2014} bike-api", y: 11, size: 13, color: hex(0xB8B8B8))
        // Files.
        fill(CGRect(x: 0, y: 40, width: 250, height: size.height - 64), hex(0x252526))
        text("BIKE-API", 20, 56, size: 11, weight: .semibold, color: hex(0x9D9D9D))
        let files: [(String, CGFloat, Bool)] = [("src", 20, false), ("bikes.rs", 38, false), ("main.rs", 38, false),
                                                ("rentals.rs", 38, false), ("routes.rs", 38, true),
                                                ("Cargo.toml", 20, false), ("README.md", 20, false)]
        for (index, file) in files.enumerated() {
            let y = 84 + CGFloat(index) * 26
            if file.2 { fill(CGRect(x: 0, y: y - 4, width: 250, height: 24), hex(0x37373D)) }
            text(file.0, file.1, y, size: 13, color: file.2 ? hex(0xFFFFFF) : hex(0xCCCCCC))
        }
        // The tab and the code.
        fill(CGRect(x: 250, y: 40, width: size.width - 250, height: 34), hex(0x252526))
        fill(CGRect(x: 250, y: 40, width: 150, height: 34), hex(0x1E1E1E))
        text("routes.rs", 272, 49, size: 13, color: hex(0xFFFFFF))
        let keyword = hex(0x569CD6), type = hex(0x4EC9B0), plain = hex(0xD4D4D4), comment = hex(0x6A9955)
        let string = hex(0xCE9178), function = hex(0xDCDCAA)
        let lines: [[(String, NSColor)]] = [
            [("use ", keyword), ("axum::{routing::get, Json, Router};", plain)],
            [("use ", keyword), ("crate::bikes::", plain), ("Bike", type), (";", plain)],
            [],
            [("/// Every bike in the shop, and where it is now.", comment)],
            [("pub fn ", keyword), ("routes", function), ("() -> ", plain), ("Router", type), (" {", plain)],
            [("    Router::", plain), ("new", function), ("()", plain)],
            [("        .", plain), ("route", function), ("(", plain), ("\"/bikes\"", string), (", get(list_bikes))", plain)],
            [("        .", plain), ("route", function), ("(", plain), ("\"/bikes/:id\"", string), (", get(bike))", plain)],
            [("        .", plain), ("route", function), ("(", plain), ("\"/rentals\"", string), (", get(rentals))", plain)],
            [("}", plain)],
            [],
            [("async fn ", keyword), ("list_bikes", function), ("() -> ", plain), ("Json", type), ("<", plain),
             ("Vec", type), ("<", plain), ("Bike", type), (">> {", plain)],
            [("    Json(", plain), ("Bike", type), ("::", plain), ("all", function), ("().", plain), ("await", keyword),
             (")", plain)],
            [("}", plain)],
        ]
        for (index, line) in lines.enumerated() {
            let y = 96 + CGFloat(index) * 24
            text("\(index + 1)", 266, y, size: 13, color: hex(0x858585))
            var x: CGFloat = 310
            for (part, color) in line {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: color,
                ]
                (part as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
                x += (part as NSString).size(withAttributes: attributes).width
            }
        }
        fill(CGRect(x: 0, y: size.height - 24, width: size.width, height: 24), hex(0x181818))
        text("main", 16, size.height - 20, size: 12, color: hex(0xB8B8B8))
        text("Ln 7, Col 21    Rust", size.width - 170, size.height - 20, size: 12, color: hex(0xB8B8B8))
    }

    private enum Note { case checklist, draft, giftCard }

    private static func notes(_ shown: Note) {
        let checklist = shown == .checklist
        fill(CGRect(origin: .zero, size: size), hex(0xFFFFFF))
        fill(CGRect(x: 0, y: 0, width: size.width, height: 52), hex(0xF6F6F6))
        lights(x: 22, y: 20)
        centered("Notes", y: 16, size: 16, weight: .medium, color: hex(0x333333))
        fill(CGRect(x: 0, y: 52, width: 220, height: size.height - 52), hex(0xF2F2F2))
        text("iCloud", 24, 80, size: 13, weight: .semibold, color: hex(0x8A8A8A))
        for (index, folder) in ["All iCloud", "Notes", "Trailhead", "Quick Notes"].enumerated() {
            let y = 110 + CGFloat(index) * 34
            if index == 1 { round(CGRect(x: 12, y: y - 6, width: 196, height: 30), 6, hex(0xDCDCDC)) }
            text(folder, 24, y, size: 15, color: hex(0x1E1E1E))
        }
        fill(CGRect(x: 220, y: 52, width: 380, height: size.height - 52), hex(0xFFFFFF))
        stroke(CGRect(x: 600, y: 52, width: 1, height: size.height - 52), hex(0xE2E2E2))
        text("Today", 244, 78, size: 13, weight: .semibold, color: hex(0x8A8A8A))
        let list = [("Pricing page draft", "10:38 AM  Three plans: Ride, Tour and Club"),
                    ("Launch checklist", "1:34 PM  Rounding fix merged")]
        for (index, note) in list.enumerated() {
            let y = 106 + CGFloat(index) * 64
            let selected = shown != .giftCard && (note.0 == "Launch checklist") == checklist
            if selected { round(CGRect(x: 232, y: y - 8, width: 356, height: 56), 8, hex(0xDCDCDC)) }
            text(note.0, 248, y, size: 15, weight: .semibold, color: hex(0x1E1E1E))
            text(note.1, 248, y + 22, size: 13, color: hex(0x7A7A7A))
        }
        text("Previous 7 Days", 244, 254, size: 13, weight: .semibold, color: hex(0x8A8A8A))
        if shown == .giftCard { round(CGRect(x: 232, y: 274, width: 356, height: 56), 8, hex(0xDCDCDC)) }
        text("Gift card copy", 248, 282, size: 15, weight: .semibold, color: hex(0x1E1E1E))
        text("Friday  Give the ride", 248, 304, size: 13, color: hex(0x7A7A7A))
        text(shown == .giftCard ? "October 9, 2026 at 9:05 AM" : "October 12, 2026 at 1:34 PM", 880, 96, size: 13,
             color: hex(0x9A9A9A))
        if shown == .giftCard {
            text("Gift card copy", 660, 140, size: 30, weight: .bold, color: hex(0x1E1E1E))
            text("Give the ride", 662, 206, size: 22, weight: .semibold, color: hex(0x1E1E1E))
            paragraph("Trailhead gift cards work for rentals, tours and anything in the shop. They never expire, and there are no fees.",
                      CGRect(x: 662, y: 246, width: 700, height: 60), size: 18)
            text("Amounts", 662, 330, size: 22, weight: .semibold, color: hex(0x1E1E1E))
            for (index, line) in ["$25: a day on a city bike", "$50: a half-day tour for one",
                                  "$100: a weekend on a trail bike"].enumerated() {
                text("\u{2022}  \(line)", 662, 372 + CGFloat(index) * 36, size: 18, color: hex(0x1E1E1E))
            }
        } else if checklist {
            text("Launch checklist", 660, 140, size: 30, weight: .bold, color: hex(0x1E1E1E))
            let items: [(Bool, String)] = [(true, "Rounding fix merged"), (true, "Changelog updated"),
                                           (false, "Gift card copy reviewed"), (false, "Beta group told about 0.4"),
                                           (false, "Pricing page live before the October sale")]
            for (index, item) in items.enumerated() {
                let y = 206 + CGFloat(index) * 44
                let circle = CGRect(x: 662, y: y, width: 22, height: 22)
                if item.0 {
                    hex(0x8E8E93).setFill()
                    NSBezierPath(ovalIn: circle).fill()
                } else {
                    hex(0xAEAEB2).setStroke()
                    let path = NSBezierPath(ovalIn: circle.insetBy(dx: 1, dy: 1))
                    path.lineWidth = 1.5
                    path.stroke()
                }
                text(item.1, 698, y - 1, size: 18, color: item.0 ? hex(0x8E8E93) : hex(0x1E1E1E))
            }
        } else {
            text("Pricing page draft", 660, 140, size: 30, weight: .bold, color: hex(0x1E1E1E))
            paragraph("Three plans: Ride, Tour and Club. The team plan sits in the middle.",
                      CGRect(x: 662, y: 200, width: 700, height: 60), size: 18)
            text("Plans", 662, 270, size: 22, weight: .semibold, color: hex(0x1E1E1E))
            for (index, line) in ["Ride: free for one person. Book rentals, keep trip history.",
                                  "Tour: $18 a seat each month. Team bookings and shared routes.",
                                  "Club: $29 a seat each month. Everything in Tour, and fleet reports."].enumerated() {
                text("\u{2022}  \(line)", 662, 312 + CGFloat(index) * 36, size: 18, color: hex(0x1E1E1E))
            }
            text("Hero", 662, 440, size: 22, weight: .semibold, color: hex(0x1E1E1E))
            paragraph("One plan for every team. Start free, then $18 a seat each month, billed annually.",
                      CGRect(x: 662, y: 480, width: 700, height: 60), size: 18)
        }
    }

    private static func invoices() {
        fill(CGRect(origin: .zero, size: size), hex(0xFFFFFF))
        fill(CGRect(x: 0, y: 0, width: size.width, height: 52), hex(0xF6F6F6))
        lights(x: 22, y: 20)
        centered("October invoices", y: 16, size: 16, weight: .medium, color: hex(0x333333))
        fill(CGRect(x: 0, y: 52, width: size.width, height: 44), hex(0xFAFAFA))
        text("Sheet 1", 30, 64, size: 14, weight: .semibold, color: hex(0x1E1E1E))
        text("October invoices", 80, 132, size: 30, weight: .bold, color: hex(0x1E1E1E))
        let columns: [CGFloat] = [80, 260, 600, 860, 1080]
        let header = ["Invoice", "Supplier", "Amount", "Due", "Status"]
        fill(CGRect(x: 80, y: 200, width: 1280, height: 40), hex(0xE8EEF7))
        for (index, title) in header.enumerated() {
            text(title, columns[index] + 12, 210, size: 15, weight: .semibold, color: hex(0x1E1E1E))
        }
        let rows = [["1042", "Northwind Supplies", "$1,240.00", "Oct 30", "Open"],
                    ["2291", "Spokewise", "$380.00", "Oct 6", "Paid"],
                    ["2307", "Gearbox Parts", "$912.50", "Oct 21", "Open"],
                    ["1188", "Chainline Co.", "$145.00", "Oct 12", "Paid"],
                    ["2312", "Trail Tires", "$2,030.00", "Nov 2", "Open"]]
        for (row, values) in rows.enumerated() {
            let y = 240 + CGFloat(row) * 42
            stroke(CGRect(x: 80, y: y + 41, width: 1280, height: 1), hex(0xE2E2E2))
            for (index, value) in values.enumerated() {
                text(value, columns[index] + 12, y + 11, size: 15, color: hex(0x1E1E1E))
            }
        }
    }

    private static func pricing() {
        fill(CGRect(origin: .zero, size: size), hex(0xFFFFFF))
        fill(CGRect(x: 0, y: 0, width: size.width, height: 86), hex(0xDEE1E6))
        lights(x: 22, y: 18)
        round(CGRect(x: 90, y: 8, width: 300, height: 32), 8, hex(0xFFFFFF))
        text("Per-seat or tiered? How to pri\u{2026}", 110, 15, size: 13, color: hex(0x333333))
        round(CGRect(x: 140, y: 50, width: 900, height: 28), 14, hex(0xF1F3F4))
        text("pricingnotes.example/team-plans", 164, 55, size: 14, color: hex(0x333333))
        text("Pricing Notes", 160, 132, size: 20, weight: .bold, color: hex(0x111111))
        text("Per-seat or tiered? How to price a team plan", 160, 200, size: 34, weight: .bold, color: hex(0x111111))
        paragraph("Most teams choose between charging for every seat and charging by tier. A seat minimum is the usual compromise. Start with per-seat pricing for each user on your team.",
                  CGRect(x: 160, y: 270, width: 900, height: 90), size: 19)
        let columns: [CGFloat] = [160, 420, 700]
        for (index, title) in ["Model", "Charges", "Works for"].enumerated() {
            text(title, columns[index], 400, size: 16, weight: .semibold, color: hex(0x111111))
        }
        for (row, values) in [["Per seat", "Every user", "Small teams"], ["Tiered", "By band", "Growing teams"],
                              ["Volume", "Same per unit", "Large orders"]].enumerated() {
            for (index, value) in values.enumerated() {
                text(value, columns[index], 440 + CGFloat(row) * 36, size: 16, color: hex(0x333333))
            }
        }
    }

    // MARK: Drawing

    private static func lights(x: CGFloat, y: CGFloat) {
        for (index, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            hex(UInt32(color)).setFill()
            NSBezierPath(ovalIn: CGRect(x: x + CGFloat(index) * 20, y: y, width: 12, height: 12)).fill()
        }
    }

    private static func fill(_ rect: CGRect, _ color: NSColor) {
        color.setFill()
        rect.fill()
    }

    private static func stroke(_ rect: CGRect, _ color: NSColor) {
        color.setStroke()
        NSBezierPath(rect: rect).stroke()
    }

    private static func round(_ rect: CGRect, _ radius: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    private static func strokeRound(_ rect: CGRect, _ radius: CGFloat, _ color: NSColor, width: CGFloat) {
        color.setStroke()
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
        path.lineWidth = width
        path.stroke()
    }

    private static func text(_ string: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 13,
                             weight: NSFont.Weight = .regular, color: NSColor) {
        (string as NSString).draw(at: CGPoint(x: x, y: y),
                                  withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                   .foregroundColor: color])
    }

    private static func centered(_ string: String, x: CGFloat = 0, width: CGFloat = WorkScreens.size.width, y: CGFloat,
                                 size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                         .foregroundColor: color]
        let measured = (string as NSString).size(withAttributes: attributes)
        (string as NSString).draw(at: CGPoint(x: x + (width - measured.width) / 2, y: y), withAttributes: attributes)
    }

    private static func paragraph(_ string: String, _ rect: CGRect, size: CGFloat) {
        (string as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size),
                                                             .foregroundColor: hex(0x333333)])
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
#endif
