#if DEBUG
import AppKit
import RecallUIKit

/// Drawn stand-ins for real windows, for the off-screen renderer's History:
/// a code editor, a web article, a chat, a terminal and a document, each the
/// whole front window as the capture helper keeps it (1440 × 900, JPEG).
/// Every word and every pixel is made up.
@MainActor
enum SyntheticScreens {
    enum Screen: CaseIterable {
        case editor, article, chat, terminal, document
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
        // Top-left origin, as a window is laid out.
        let cg = base.cgContext
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        switch screen {
        case .editor: editor()
        case .article: article()
        case .chat: chat()
        case .terminal: terminal()
        case .document: document()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }

    // MARK: Screens

    private static func editor() {
        fill(CGRect(origin: .zero, size: size), hex(0x1E1E1E))
        fill(CGRect(x: 0, y: 0, width: size.width, height: 38), hex(0x323233))
        trafficLights(x: 18, y: 13)
        centered("tax.rs \u{2014} trailhead-shop", y: 11, size: 13, color: hex(0xCCCCCC))
        // Activity bar and explorer.
        fill(CGRect(x: 0, y: 38, width: 50, height: size.height - 62), hex(0x333333))
        for (index, symbol) in ["doc.on.doc", "magnifyingglass", "arrow.triangle.branch", "play.circle",
                                "square.grid.2x2"].enumerated() {
            self.symbol(symbol, in: CGRect(x: 13, y: 56 + CGFloat(index) * 50, width: 24, height: 24),
                        color: index == 0 ? hex(0xFFFFFF) : hex(0x858585))
        }
        fill(CGRect(x: 50, y: 38, width: 250, height: size.height - 62), hex(0x252526))
        text("EXPLORER", 70, 50, size: 11, weight: .medium, color: hex(0xBBBBBB))
        text("\u{25BE}  TRAILHEAD-SHOP", 62, 80, size: 11, weight: .bold, color: hex(0xCCCCCC))
        let tree: [(String, Int, Bool, UInt32?)] = [
            ("\u{25BE}  src", 1, false, nil), ("cart.rs", 2, false, 0xDEA584), ("money.rs", 2, false, 0xDEA584),
            ("tax.rs", 2, true, 0xDEA584), ("main.rs", 2, false, 0xDEA584), ("\u{25B8}  tests", 1, false, nil),
            ("Cargo.toml", 1, false, 0x9CDCFE), ("Cargo.lock", 1, false, 0x9CDCFE), ("README.md", 1, false, 0x519ABA),
        ]
        for (row, item) in tree.enumerated() {
            let y = 104 + CGFloat(row) * 24
            if item.2 { fill(CGRect(x: 50, y: y - 3, width: 250, height: 24), hex(0x37373D)) }
            let x = 62 + CGFloat(item.1) * 14
            if let dot = item.3 {
                round(CGRect(x: x, y: y + 4, width: 9, height: 9), 2, hex(dot))
                text(item.0, x + 16, y, size: 13, color: hex(item.2 ? 0xFFFFFF : 0xCCCCCC))
            } else {
                text(item.0, x, y, size: 13, color: hex(0xCCCCCC))
            }
        }
        text("\u{25B8}  OUTLINE", 62, size.height - 90, size: 11, weight: .bold, color: hex(0xCCCCCC))
        text("\u{25B8}  TIMELINE", 62, size.height - 62, size: 11, weight: .bold, color: hex(0xCCCCCC))
        // Tabs and the path above the code.
        fill(CGRect(x: 300, y: 38, width: size.width - 300, height: 36), hex(0x252526))
        fill(CGRect(x: 300, y: 38, width: 130, height: 36), hex(0x2D2D2D))
        text("cart.rs", 336, 47, size: 13, color: hex(0x969696))
        fill(CGRect(x: 430, y: 38, width: 130, height: 36), hex(0x1E1E1E))
        fill(CGRect(x: 430, y: 38, width: 130, height: 2), hex(0x0078D4))
        text("tax.rs", 466, 47, size: 13, color: hex(0xFFFFFF))
        round(CGRect(x: 316, y: 50, width: 10, height: 10), 2, hex(0xDEA584))
        round(CGRect(x: 446, y: 50, width: 10, height: 10), 2, hex(0xDEA584))
        text("src  \u{203A}  tax.rs  \u{203A}  order_total", 320, 80, size: 12, color: hex(0xA9A9A9))
        let code = [
            "use crate::cart::Line;",
            "use crate::money::Money;",
            "",
            "/// Sales tax for the shop's region, as a fraction of the subtotal.",
            "pub const TAX_RATE: f64 = 0.0875;",
            "",
            "/// Rounds half to even, so totals never drift by a cent.",
            "pub fn round_half_even(amount: Money) -> Money {",
            "    let cents = amount.cents_exact();",
            "    let floor = cents.floor();",
            "    let rest = cents - floor;",
            "    if rest > 0.5 || (rest == 0.5 && floor % 2.0 != 0.0) {",
            "        return Money::from_cents(floor + 1.0);",
            "    }",
            "    Money::from_cents(floor)",
            "}",
            "",
            "pub fn order_total(lines: &[Line]) -> Money {",
            "    let subtotal: Money = lines.iter().map(|l| l.price * l.qty).sum();",
            "    let tax = subtotal * TAX_RATE;",
            "    round_half_even(subtotal + tax)",
            "}",
            "",
            "#[cfg(test)]",
            "mod tests {",
            "    use super::*;",
            "",
            "    #[test]",
            "    fn rounds_half_to_even() {",
            "        assert_eq!(round_half_even(Money::cents(250)), Money::cents(250));",
            "        assert_eq!(round_half_even(Money::cents(350)), Money::cents(350));",
            "    }",
            "}",
        ]
        let mono = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        for (index, line) in code.enumerated() {
            let y = 108 + CGFloat(index) * 22
            if index == 20 { fill(CGRect(x: 300, y: y - 2, width: size.width - 400, height: 22), hex(0x2A2D2E)) }
            let number = "\(index + 1)" as NSString
            let numberWidth = number.size(withAttributes: [.font: mono]).width
            text(String(number), 352 - numberWidth, y, font: mono, color: hex(index == 20 ? 0xC6C6C6 : 0x6E7681))
            draw(rust(line, font: mono), at: CGPoint(x: 380, y: y))
        }
        // The minimap.
        for index in 0..<code.count where !code[index].isEmpty {
            let length = CGFloat(code[index].count) * 1.1
            fill(CGRect(x: 1352, y: 110 + CGFloat(index) * 4, width: min(length, 70), height: 2),
                 hex(index == 20 ? 0x569CD6 : 0x4D4D4D))
        }
        fill(CGRect(x: 0, y: size.height - 24, width: size.width, height: 24), hex(0x007ACC))
        text("\u{2387} main     \u{2297} 0  \u{26A0} 2", 14, size.height - 20, size: 12, color: .white)
        let status = "Ln 21, Col 36    Spaces: 4    UTF-8    LF    Rust" as NSString
        let statusWidth = status.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        text(String(status), size.width - statusWidth - 16, size.height - 20, size: 12, color: .white)
    }

    private static func article() {
        fill(CGRect(origin: .zero, size: size), .white)
        browserChrome(tabs: ["Rounding half to even \u{00B7} Dev Notes", "Northwind - Calendar",
                             "Q4 planning - Google Docs", "#launch - Slack"],
                      active: 0, address: "devnotes.example/rounding")
        text("Dev Notes", 160, 116, size: 22, weight: .bold, color: hex(0x111111))
        text("Articles", 900, 120, size: 15, color: hex(0x444444))
        text("Topics", 990, 120, size: 15, color: hex(0x444444))
        text("About", 1068, 120, size: 15, color: hex(0x444444))
        round(CGRect(x: 1150, y: 110, width: 116, height: 36), 18, hex(0x1A73E8))
        text("Subscribe", 1173, 118, size: 15, weight: .semibold, color: .white)
        fill(CGRect(x: 0, y: 168, width: size.width, height: 1), hex(0xEEEEEE))
        let column: CGFloat = 360
        text("MONEY & ROUNDING", column, 204, size: 12, weight: .bold, color: hex(0x1A73E8))
        text("Rounding half to even", column, 226,
             font: NSFont(name: "Georgia-Bold", size: 46) ?? .boldSystemFont(ofSize: 46), color: hex(0x111111))
        text("Why banker\u{2019}s rounding keeps order totals from drifting by a cent", column, 292,
             size: 20, color: hex(0x555555))
        round(CGRect(x: column, y: 338, width: 32, height: 32), 16, hex(0xC9D7F2))
        text("Priya Shah  \u{00B7}  Oct 12, 2026  \u{00B7}  6 min read", column + 44, 344, size: 14,
             color: hex(0x777777))
        let body = NSFont(name: "Georgia", size: 19) ?? .systemFont(ofSize: 19)
        paragraph("""
            Round half up looks fair, but every tie goes the same way. Over thousands of orders the extra \
            half cents add up, and the books stop matching the bank by a few dollars a month.
            """, in: CGRect(x: column, y: 396, width: 720, height: 90), font: body, color: hex(0x333333))
        paragraph("""
            Round half to even sends each tie to the even neighbour instead, so half the ties go down and \
            half go up. The errors cancel out:
            """, in: CGRect(x: column, y: 494, width: 720, height: 64), font: body, color: hex(0x333333))
        round(CGRect(x: column, y: 572, width: 720, height: 96), 8, hex(0xF6F8FA))
        let mono = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        text("round_half_even(2.5)   // 2.0", column + 24, 592, font: mono, color: hex(0x24292F))
        text("round_half_even(3.5)   // 4.0", column + 24, 624, font: mono, color: hex(0x24292F))
        paragraph("""
            Most payment processors already round this way. Matching them means the total a customer sees \
            is the total that settles, to the cent.
            """, in: CGRect(x: column, y: 690, width: 720, height: 90), font: body, color: hex(0x333333))
        fill(CGRect(x: column, y: 800, width: 720, height: 1), hex(0xEEEEEE))
        text("Next: Currency math without floats", column, 822, size: 16, weight: .semibold, color: hex(0x1A73E8))
    }

    private static func chat() {
        fill(CGRect(origin: .zero, size: size), .white)
        fill(CGRect(x: 0, y: 0, width: 340, height: size.height), hex(0xF2F2F7))
        trafficLights(x: 20, y: 20)
        round(CGRect(x: 16, y: 56, width: 308, height: 30), 8, hex(0xE3E3E8))
        symbol("magnifyingglass", in: CGRect(x: 26, y: 63, width: 15, height: 15), color: hex(0x8E8E93))
        text("Search", 48, 62, size: 14, color: hex(0x8E8E93))
        let conversations: [(String, String, String, UInt32)] = [
            ("Sam Lee", "Bringing the printouts", "2:27 PM", 0x8E9AAF),
            ("Maya Chen", "Sent you the deck", "1:12 PM", 0xC3A6A0),
            ("Design crit", "Jordan: love the new header", "12:05 PM", 0x9FB8AD),
            ("Northwind Supplies", "Thanks, invoice attached", "11:40 AM", 0xB6A6CA),
            ("Jonas Weber", "Call when you can", "Yesterday", 0xA3B4C8),
        ]
        for (index, item) in conversations.enumerated() {
            let y = 100 + CGFloat(index) * 74
            let selected = index == 0
            if selected { round(CGRect(x: 8, y: y, width: 324, height: 68), 10, hex(0x0A84FF)) }
            round(CGRect(x: 20, y: y + 12, width: 44, height: 44), 22, hex(item.3))
            centered(String(item.0.prefix(1)), x: 20, width: 44, y: y + 23, size: 18, weight: .semibold, color: .white)
            text(item.0, 76, y + 14, size: 15, weight: .semibold, color: selected ? .white : hex(0x111111))
            text(item.1, 76, y + 36, size: 13, color: selected ? hex(0xE5F0FF) : hex(0x8E8E93))
            let time = item.2 as NSString
            let width = time.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
            text(item.2, 320 - width, y + 16, size: 12, color: selected ? hex(0xE5F0FF) : hex(0x8E8E93))
        }
        fill(CGRect(x: 340, y: 0, width: 1, height: size.height), hex(0xD9D9DE))
        fill(CGRect(x: 341, y: 0, width: size.width - 341, height: 64), hex(0xFAFAFA))
        centered("Sam Lee", x: 341, width: size.width - 341, y: 22, size: 15, weight: .semibold, color: hex(0x111111))
        fill(CGRect(x: 341, y: 64, width: size.width - 341, height: 1), hex(0xE5E5EA))
        centered("Today 2:21 PM", x: 341, width: size.width - 341, y: 96, size: 12, color: hex(0x8E8E93))
        let bubbles: [(String, Bool)] = [
            ("Are we still on for 3?", false),
            ("Yes, running five minutes late", true),
            ("No rush. I grabbed the corner table", false),
            ("See you there", false),
            ("Bringing the printouts", true),
        ]
        var y: CGFloat = 130
        for (text, outgoing) in bubbles {
            let font = NSFont.systemFont(ofSize: 16)
            let width = (text as NSString).size(withAttributes: [.font: font]).width + 30
            let x = outgoing ? size.width - 40 - width : 370
            round(CGRect(x: x, y: y, width: width, height: 38), 19, outgoing ? hex(0x0A84FF) : hex(0xE9E9EB))
            self.text(text, x + 15, y + 9, font: font, color: outgoing ? .white : hex(0x111111))
            y += 50
        }
        let delivered = "Delivered" as NSString
        let deliveredWidth = delivered.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
        text("Delivered", size.width - 44 - deliveredWidth, y - 8, size: 11, color: hex(0x8E8E93))
        round(CGRect(x: 370, y: size.height - 56, width: size.width - 410, height: 36), 18, hex(0xD1D1D6))
        round(CGRect(x: 371, y: size.height - 55, width: size.width - 412, height: 34), 17, .white)
        text("iMessage", 390, size.height - 47, size: 14, color: hex(0xAEAEB2))
    }

    private static func terminal() {
        fill(CGRect(origin: .zero, size: size), hex(0x1C1C1E))
        fill(CGRect(x: 0, y: 0, width: size.width, height: 30), hex(0x2C2C2E))
        trafficLights(x: 14, y: 9)
        centered("trailhead-shop \u{2014} zsh \u{2014} 160\u{00D7}40", y: 7, size: 13, weight: .medium,
                 color: hex(0xA1A1A6))
        let mono = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let prompt = "dev@studio trailhead-shop % "
        let lines: [(String, String, UInt32)] = [
            (prompt, "cargo test tax", 0xE5E5E7),
            ("", "   Compiling trailhead-shop v0.4.2 (/Users/dev/trailhead-shop)", 0x32D74B),
            ("", "    Finished `test` profile [unoptimized + debuginfo] target(s) in 3.41s", 0x32D74B),
            ("", "     Running unittests src/lib.rs (target/debug/deps/trailhead_shop-3f9c2a1b)", 0x32D74B),
            ("", "", 0xE5E5E7),
            ("", "running 6 tests", 0xE5E5E7),
            ("", "test cart::tests::discount_applies_once ... ok", 0xE5E5E7),
            ("", "test cart::tests::quantities_multiply ... ok", 0xE5E5E7),
            ("", "test tax::tests::order_total_includes_tax ... ok", 0xE5E5E7),
            ("", "test tax::tests::rounds_down_below_half ... ok", 0xE5E5E7),
            ("", "test tax::tests::rounds_half_to_even ... ok", 0xE5E5E7),
            ("", "test tax::tests::zero_lines_cost_nothing ... ok", 0xE5E5E7),
            ("", "", 0xE5E5E7),
            ("", "test result: ok. 6 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s",
             0xE5E5E7),
            ("", "", 0xE5E5E7),
            (prompt, "git status --short", 0xE5E5E7),
            ("", " M src/cart.rs", 0xFF6961),
            ("", " M src/tax.rs", 0xFF6961),
            (prompt, "git commit -am \"Round order totals half to even\"", 0xE5E5E7),
            ("", "[rounding 8c41d2e] Round order totals half to even", 0xE5E5E7),
            ("", " 2 files changed, 31 insertions(+), 6 deletions(-)", 0xE5E5E7),
            (prompt, "", 0xE5E5E7),
        ]
        for (index, line) in lines.enumerated() {
            let y = 44 + CGFloat(index) * 21
            var x: CGFloat = 16
            if !line.0.isEmpty {
                text(line.0, x, y, font: mono, color: hex(0x64D2FF))
                x += (line.0 as NSString).size(withAttributes: [.font: mono]).width
            }
            if line.1.hasSuffix(" ok") {
                let head = String(line.1.dropLast(2))
                text(head, x, y, font: mono, color: hex(0xE5E5E7))
                let width = (head as NSString).size(withAttributes: [.font: mono]).width
                text("ok", x + width, y, font: mono, color: hex(0x32D74B))
            } else {
                text(line.1, x, y, font: mono, color: hex(line.2))
            }
            if index == lines.count - 1 {
                fill(CGRect(x: x + 2, y: y + 1, width: 9, height: 18), hex(0xE5E5E7))
            }
        }
    }

    private static func document() {
        fill(CGRect(origin: .zero, size: size), hex(0xF9FBFD))
        browserChrome(tabs: ["Q4 planning - Google Docs", "Rounding half to even \u{00B7} Dev Notes",
                             "Northwind - Calendar"],
                      active: 0, address: "docs.google.com/document/d/q4-planning/edit")
        round(CGRect(x: 20, y: 102, width: 28, height: 36), 3, hex(0x4285F4))
        fill(CGRect(x: 27, y: 114, width: 14, height: 2), .white)
        fill(CGRect(x: 27, y: 120, width: 14, height: 2), .white)
        fill(CGRect(x: 27, y: 126, width: 10, height: 2), .white)
        text("Q4 planning", 62, 98, size: 18, color: hex(0x1F1F1F))
        text("File   Edit   View   Insert   Format   Tools   Extensions   Help", 62, 124, size: 14,
             color: hex(0x444746))
        round(CGRect(x: 1290, y: 104, width: 116, height: 38), 19, hex(0xC2E7FF))
        text("Share", 1326, 113, size: 15, weight: .medium, color: hex(0x001D35))
        round(CGRect(x: 16, y: 156, width: size.width - 32, height: 40), 20, hex(0xEDF2FA))
        let tools = ["arrow.uturn.backward", "arrow.uturn.forward", "printer", "textformat.abc", "bold",
                     "italic", "underline", "paintbrush", "link", "photo", "list.bullet", "list.number"]
        for (index, tool) in tools.enumerated() {
            symbol(tool, in: CGRect(x: 36 + CGFloat(index) * 40, y: 166, width: 20, height: 20), color: hex(0x444746))
        }
        let page = CGRect(x: 370, y: 216, width: 700, height: 700)
        fill(page.offsetBy(dx: 0, dy: 2), hex(0xE3E7ED))
        fill(page, .white)
        let x = page.minX + 72
        text("Q4 planning", x, page.minY + 64, size: 28, weight: .semibold, color: hex(0x202124))
        text("Owner: Priya Shah  \u{00B7}  Updated Oct 12", x, page.minY + 108, size: 13, color: hex(0x5F6368))
        text("Goals", x, page.minY + 152, size: 19, weight: .semibold, color: hex(0x202124))
        let goals = ["Ship the rounding fix before the holiday sale",
                     "Cut checkout to under 30 seconds on mobile",
                     "Launch gift cards in two markets",
                     "Close the books each month with no cent drift"]
        for (index, goal) in goals.enumerated() {
            let y = page.minY + 190 + CGFloat(index) * 32
            round(CGRect(x: x + 4, y: y + 8, width: 6, height: 6), 3, hex(0x202124))
            text(goal, x + 22, y, size: 16, color: hex(0x202124))
        }
        text("Owners", x, page.minY + 340, size: 19, weight: .semibold, color: hex(0x202124))
        let owners = [("Rounding fix", "Sam"), ("Checkout speed", "Maya"), ("Gift cards", "Jordan")]
        for (index, owner) in owners.enumerated() {
            let y = page.minY + 380 + CGFloat(index) * 36
            fill(CGRect(x: x, y: y - 6, width: 556, height: 1), hex(0xDADCE0))
            text(owner.0, x + 8, y + 4, size: 15, color: hex(0x202124))
            text(owner.1, x + 300, y + 4, size: 15, color: hex(0x202124))
        }
        fill(CGRect(x: x, y: page.minY + 482, width: 556, height: 1), hex(0xDADCE0))
        paragraph("""
            Rounding ships first: every other goal depends on totals that match the processor to the cent.
            """, in: CGRect(x: x, y: page.minY + 516, width: 556, height: 60),
            font: .systemFont(ofSize: 15), color: hex(0x3C4043))
    }

    // MARK: Pieces

    private static func browserChrome(tabs: [String], active: Int, address: String) {
        fill(CGRect(x: 0, y: 0, width: size.width, height: 44), hex(0xDFE1E5))
        trafficLights(x: 16, y: 16)
        for (index, title) in tabs.enumerated() {
            let x = 88 + CGFloat(index) * 236
            let rect = CGRect(x: x, y: 8, width: 232, height: 36)
            if index == active {
                round(rect, 10, .white)
                fill(CGRect(x: x, y: 30, width: 232, height: 14), .white)
            }
            round(CGRect(x: x + 12, y: 20, width: 14, height: 14), 7, hex(index == active ? 0x1A73E8 : 0x9AA0A6))
            let font = NSFont.systemFont(ofSize: 12)
            let width = { (string: String) in (string as NSString).size(withAttributes: [.font: font]).width }
            var shown = title
            if width(shown) > 168 {
                while !shown.isEmpty, width(shown + "\u{2026}") > 168 { shown.removeLast() }
                shown = shown.trimmingCharacters(in: .whitespaces) + "\u{2026}"
            }
            text(shown, x + 34, 19, font: font, color: hex(index == active ? 0x202124 : 0x45474A))
            text("\u{00D7}", x + 210, 16, size: 15, color: hex(0x5F6368))
        }
        text("+", 88 + CGFloat(tabs.count) * 236 + 10, 13, size: 20, color: hex(0x5F6368))
        fill(CGRect(x: 0, y: 44, width: size.width, height: 44), .white)
        for (index, symbol) in ["chevron.left", "chevron.right", "arrow.clockwise"].enumerated() {
            self.symbol(symbol, in: CGRect(x: 18 + CGFloat(index) * 36, y: 56, width: 18, height: 18),
                        color: hex(0x5F6368))
        }
        round(CGRect(x: 130, y: 51, width: 1180, height: 30), 15, hex(0xF1F3F4))
        symbol("lock.fill", in: CGRect(x: 146, y: 58, width: 12, height: 14), color: hex(0x5F6368))
        text(address, 168, 57, size: 14, color: hex(0x202124))
        round(CGRect(x: 1386, y: 52, width: 28, height: 28), 14, hex(0xB7C9E5))
        fill(CGRect(x: 0, y: 88, width: size.width, height: 1), hex(0xDADCE0))
    }

    /// One line of Rust in an editor's dark colours.
    private static func rust(_ line: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: hex(0xD4D4D4)]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#[") {
            return NSAttributedString(string: line, attributes: [.font: font, .foregroundColor:
                trimmed.hasPrefix("//") ? hex(0x6A9955) : hex(0xC586C0)])
        }
        let keywords: Set = ["use", "pub", "fn", "let", "const", "mod", "return", "if", "super", "crate", "self",
                             "mut", "impl", "struct", "for", "in", "as"]
        var word = ""
        func flush(next: Character?) {
            guard !word.isEmpty else { return }
            let color: NSColor = if keywords.contains(word) {
                hex(0x569CD6)
            } else if word.first?.isUppercase == true {
                hex(0x4EC9B0)
            } else if word.first?.isNumber == true {
                hex(0xB5CEA8)
            } else if next == "(" || next == "!" {
                hex(0xDCDCAA)
            } else {
                hex(0x9CDCFE)
            }
            result.append(NSAttributedString(string: word, attributes: [.font: font, .foregroundColor: color]))
            word = ""
        }
        for character in line {
            if character.isLetter || character.isNumber || character == "_" || (character == "." && word.first?.isNumber == true) {
                word.append(character)
            } else {
                flush(next: character)
                result.append(NSAttributedString(string: String(character), attributes: plain))
            }
        }
        flush(next: nil)
        return result
    }

    private static func trafficLights(x: CGFloat, y: CGFloat) {
        for (index, color) in [hex(0xFF5F57), hex(0xFEBC2E), hex(0x28C840)].enumerated() {
            round(CGRect(x: x + CGFloat(index) * 20, y: y, width: 12, height: 12), 6, color)
        }
    }

    private static func symbol(_ name: String, in rect: CGRect, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .regular)
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

    private static func fill(_ rect: CGRect, _ color: NSColor) {
        color.setFill()
        rect.fill()
    }

    private static func round(_ rect: CGRect, _ radius: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    private static func text(_ string: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 13,
                             weight: NSFont.Weight = .regular, font: NSFont? = nil, color: NSColor) {
        let font = font ?? .systemFont(ofSize: size, weight: weight)
        (string as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
    }

    private static func draw(_ string: NSAttributedString, at point: CGPoint) {
        string.draw(at: point)
    }

    private static func centered(_ string: String, x: CGFloat = 0, width: CGFloat = SyntheticScreens.size.width,
                                 y: CGFloat,
                                 size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let measured = (string as NSString).size(withAttributes: [.font: font]).width
        text(string, x + (width - measured) / 2, y, font: font, color: color)
    }

    private static func paragraph(_ string: String, in rect: CGRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = font.pointSize * 0.45
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin],
                                  attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
#endif
