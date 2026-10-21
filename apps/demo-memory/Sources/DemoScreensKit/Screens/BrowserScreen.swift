// SPDX-License-Identifier: Apache-2.0
//
// BrowserScreen.swift — Chrome, with its tabs and address bar, and the page
// it shows: Stripe's dashboard, pricing page and docs (no logo, and only
// the week's own words), a Google search,
// Google Docs and Sheets, a chat with Claude, an article and a pricing page.

import AppKit

@MainActor
struct BrowserScreen {
    let spec: DemoScreenSpec
    let canvas: Canvas

    var meta: DemoJSON { spec.meta }
    /// Where the page starts.
    static let pageTop: CGFloat = 80

    func draw() {
        drawChrome()
        let page = CGRect(x: 0, y: Self.pageTop, width: canvas.size.width, height: canvas.size.height - Self.pageTop)
        switch meta["page"]?.text ?? "" {
        case "stripe": StripeDashboard(screen: self, page: page).draw()
        case "stripe-pricing": StripePricing(screen: self, page: page).draw()
        case "docs": DocsPage(screen: self, page: page).draw()
        case "search": SearchPage(screen: self, page: page).draw()
        case "gdocs": GoogleDoc(screen: self, page: page).draw()
        case "gsheets": GoogleSheet(screen: self, page: page).draw()
        case "claude": ClaudeChat(screen: self, page: page).draw()
        case "pricing": PricingPage(screen: self, page: page).draw()
        default: ArticlePage(screen: self, page: page).draw()
        }
    }

    /// The site's mark in a tab: a little square or circle in its colour.
    func favicon(_ title: String, _ rect: CGRect) {
        let c = canvas
        let lower = title.lowercased()
        if lower.contains("google docs") {
            c.round(rect.insetBy(dx: 1.5, dy: 0), 2, hex(0x4285F4))
            for line in 0..<3 {
                c.fill(CGRect(x: rect.minX + 4, y: rect.minY + 4 + CGFloat(line) * 3, width: rect.width - 8, height: 1.2), .white)
            }
        } else if lower.contains("google sheets") {
            c.round(rect.insetBy(dx: 1.5, dy: 0), 2, hex(0x0F9D58))
            c.stroke(CGRect(x: rect.minX + 4, y: rect.minY + 4, width: rect.width - 8, height: rect.height - 8), 0, .white, width: 1.2)
            c.vline(rect.midX, rect.minY + 4, rect.height - 8, .white, thickness: 1.2)
        } else if lower.contains("google search") {
            c.circle(CGPoint(x: rect.midX, y: rect.midY), rect.width / 2, .white)
            c.centered("G", rect.minX, rect.width, rect.minY, Face.ui(rect.height * 0.85, .bold), hex(0x4285F4))
        } else if lower.contains("claude") {
            c.round(rect, 3, hex(0xD97757))
            c.symbol("asterisk", rect.insetBy(dx: 2.5, dy: 2.5), .white, weight: .bold)
        } else {
            c.round(rect, 3, hex(0x5C6B7A))
            c.centered(String(title.prefix(1)), rect.minX, rect.width, rect.minY + 0.5,
                       Face.ui(rect.height * 0.72, .bold), .white)
        }
    }

    private func drawChrome() {
        let c = canvas
        let width = c.size.width
        c.fill(CGRect(x: 0, y: 0, width: width, height: 42), hex(0xDFE3E8))
        c.trafficLights(14, 15)
        let tabs = meta["tabs"]?.texts ?? [spec.title]
        let active = meta["active_tab"]?.int ?? 0
        let tabWidth: CGFloat = 240
        for (index, title) in tabs.enumerated() {
            let x = 82 + CGFloat(index) * (tabWidth + 2)
            let rect = CGRect(x: x, y: 7, width: tabWidth, height: 35)
            if index == active {
                c.roundTop(rect, 9, .white)
            } else if index != active - 1 && index < tabs.count - 1 {
                c.vline(x + tabWidth + 1, 16, 18, hex(0xA9AEB4))
            }
            favicon(title, CGRect(x: x + 13, y: 17, width: 15, height: 15))
            c.text(title, x + 36, 16.5, Face.ui(12), index == active ? hex(0x1F1F1F) : hex(0x3C4043),
                   maxWidth: tabWidth - 66)
            c.text("\u{00D7}", x + tabWidth - 24, 14, Face.ui(15), hex(0x5F6368))
        }
        c.text("+", 82 + CGFloat(tabs.count) * (tabWidth + 2) + 10, 12, Face.ui(20), hex(0x3C4043))
        c.symbol("chevron.down", CGRect(x: width - 32, y: 18, width: 12, height: 9), hex(0x3C4043))
        // Toolbar.
        c.fill(CGRect(x: 0, y: 42, width: width, height: 38), .white)
        for (index, name) in ["arrow.left", "arrow.right", "arrow.clockwise"].enumerated() {
            c.symbol(name, CGRect(x: 16 + CGFloat(index) * 34, y: 52, width: 16, height: 16),
                     index == 1 ? hex(0xBDC1C6) : hex(0x5F6368))
        }
        let field = CGRect(x: 120, y: 47, width: width - 250, height: 28)
        c.round(field, 14, hex(0xF1F3F4))
        c.symbol("lock", CGRect(x: field.minX + 14, y: 53, width: 13, height: 15), hex(0x5F6368))
        let address = meta["address"]?.text ?? (spec.url ?? "")
        let host = address.split(separator: "/").first.map(String.init) ?? address
        let path = String(address.dropFirst(host.count))
        let x = field.minX + 38
        let hostWidth = c.text(host, x, 52, Face.ui(14), hex(0x202124))
        c.text(path, x + hostWidth, 52, Face.ui(14), hex(0x5F6368), maxWidth: field.width - hostWidth - 80)
        c.symbol("star", CGRect(x: field.maxX - 30, y: 53, width: 15, height: 15), hex(0x5F6368))
        c.symbol("puzzlepiece.extension", CGRect(x: width - 116, y: 52, width: 17, height: 17), hex(0x5F6368))
        c.avatar("Ren Alder", CGRect(x: width - 82, y: 49, width: 24, height: 24), hex(0x2E9E8F),
                 font: Face.ui(10, .semibold))
        c.symbol("ellipsis", CGRect(x: width - 42, y: 58, width: 16, height: 4), hex(0x5F6368))
        c.hline(0, 79, width, hex(0xDADCE0))
    }
}

/// Blocks of a page, as the seeder lists them: `[kind, text]`.
@MainActor
func pageBlocks(_ meta: DemoJSON) -> [(String, String)] {
    meta["blocks"]?.rows.compactMap { row in row.count == 2 ? (row[0], row[1]) : nil } ?? []
}

// MARK: Stripe

@MainActor
struct StripeDashboard {
    let screen: BrowserScreen
    let page: CGRect

    func draw() {
        let c = screen.canvas
        let meta = screen.meta
        let purple = hex(0x635BFF)
        let ink = hex(0x1A1F36)
        let muted = hex(0x697386)
        c.fill(page, .white)
        // Side navigation.
        let nav = CGRect(x: 0, y: page.minY, width: 236, height: page.height)
        c.fill(nav, hex(0xF6F8FA))
        c.vline(nav.maxX, page.minY, page.height, hex(0xE3E8EE))
        c.round(CGRect(x: 18, y: page.minY + 18, width: 26, height: 26), 6, hex(0x2E9E8F))
        c.centered("P", 18, 26, page.minY + 21.5, Face.ui(15, .bold), .white)
        c.text(meta["account"]?.text ?? "", 54, page.minY + 21, Face.ui(14, .semibold), ink)
        c.symbol("chevron.up.chevron.down", CGRect(x: 205, y: page.minY + 24, width: 9, height: 13), muted)
        let icons = ["house", "building.columns", "arrow.left.arrow.right", "person.2", "shippingbox",
                     "doc.text", "chart.bar", "link", "chevron.left.forwardslash.chevron.right"]
        let selected = meta["selected_nav"]?.text
        for (index, item) in (meta["nav"]?.texts ?? []).enumerated() {
            let y = page.minY + 66 + CGFloat(index) * 34
            let isSelected = item == selected
            if isSelected { c.round(CGRect(x: 10, y: y - 6, width: 216, height: 30), 6, hex(0xEEF0FF)) }
            c.symbol(icons[index % icons.count], CGRect(x: 22, y: y + 1, width: 16, height: 15),
                     isSelected ? purple : muted)
            c.text(item, 48, y, Face.ui(14, isSelected ? .semibold : .medium), isSelected ? purple : hex(0x3C4257))
        }
        // Search and the top bar.
        let left = nav.maxX + 40
        let search = CGRect(x: left, y: page.minY + 16, width: 420, height: 32)
        c.round(search, 8, hex(0xF6F8FA))
        c.symbol("magnifyingglass", CGRect(x: search.minX + 12, y: search.minY + 9, width: 14, height: 14), muted)
        c.text("Search", search.minX + 34, search.minY + 8, Face.ui(14), hex(0x8792A2))
        for (index, name) in ["questionmark.circle", "bell", "gearshape"].enumerated() {
            c.symbol(name, CGRect(x: c.size.width - 150 + CGFloat(index) * 38, y: page.minY + 22, width: 18, height: 18), muted)
        }
        // Heading.
        let heading = meta["heading"]?.text ?? ""
        let top = page.minY + 88
        c.text(heading, left, top, Face.ui(28, .bold), ink)
        if let button = meta["button"]?.text {
            let width = Canvas.width(button, Face.ui(14, .semibold)) + 48
            let rect = CGRect(x: c.size.width - 40 - width, y: top + 2, width: width, height: 34)
            c.round(rect, 8, purple)
            c.symbol("plus", CGRect(x: rect.minX + 14, y: rect.minY + 11, width: 12, height: 12), .white, weight: .semibold)
            c.text(button, rect.minX + 32, rect.minY + 8.5, Face.ui(14, .semibold), .white)
        }
        c.text(meta["subheading"]?.text ?? "", left, top + 44, Face.ui(15), muted)
        // The table.
        let tableTop = top + 96
        let columns = meta["columns"]?.texts ?? []
        let width = c.size.width - 40 - left
        let starts = columnStarts(columns.count, width: width).map { left + $0 }
        c.hline(left, tableTop - 10, width, hex(0xE3E8EE))
        for (index, column) in columns.enumerated() {
            c.text(column.uppercased(), starts[index], tableTop, Face.ui(11.5, .semibold), muted, kern: 0.5)
        }
        c.hline(left, tableTop + 26, width, hex(0xE3E8EE))
        let highlight = meta["highlight_row"]?.int
        for (row, cells) in (meta["rows"]?.rows ?? []).enumerated() {
            let y = tableTop + 36 + CGFloat(row) * 54
            if row == highlight {
                c.round(CGRect(x: left - 12, y: y - 8, width: width + 24, height: 50), 8, hex(0xF5F6FF))
            }
            for (index, cell) in cells.enumerated() where index < starts.count {
                drawCell(cell, column: index, x: starts[index], y: y + 6,
                         width: (index + 1 < starts.count ? starts[index + 1] : left + width) - starts[index] - 16)
            }
            c.hline(left, y + 44, width, hex(0xEEF1F4))
        }
        let rowCount = CGFloat(meta["rows"]?.rows.count ?? 0)
        var below = tableTop + 36 + rowCount * 54 + 18
        if let footer = meta["footer"]?.text {
            c.text(footer, left, below, Face.ui(13.5), muted)
            for (index, label) in ["Previous", "Next"].enumerated() {
                let rect = CGRect(x: left + width - 176 + CGFloat(index) * 92, y: below - 6, width: 84, height: 30)
                c.round(rect, 7, .white)
                c.stroke(rect, 7, hex(0xD5DBE1))
                c.centered(label, rect.minX, rect.width, rect.minY + 6, Face.ui(13.5, .medium), hex(0xA3ACB9))
            }
            below += 48
        }
        let details = meta["details"]?.rows ?? []
        if !details.isEmpty {
            below += 16
            c.text("Details", left, below, Face.ui(20, .bold), ink)
            below += 42
            for detail in details where detail.count == 2 {
                c.text(detail[0], left, below, Face.ui(14.5), muted)
                c.text(detail[1], left + 260, below, Face.ui(14.5), hex(0x3C4257))
                c.hline(left, below + 30, width, hex(0xEEF1F4))
                below += 44
            }
        }
    }

    private func columnStarts(_ count: Int, width: CGFloat) -> [CGFloat] {
        switch count {
        case 4: [0, width * 0.18, width * 0.38, width * 0.68]
        case 3: [0, width * 0.42, width * 0.82]
        default: (0..<max(count, 1)).map { CGFloat($0) * width / CGFloat(max(count, 1)) }
        }
    }

    private func drawCell(_ cell: String, column: Int, x: CGFloat, y: CGFloat, width: CGFloat) {
        let c = screen.canvas
        let badges: [String: (UInt32, UInt32)] = [
            "Active": (0xD7F7C2, 0x05690D), "Succeeded": (0xD7F7C2, 0x05690D), "Default": (0xE3E8EE, 0x3C4257),
            "New": (0xE0E3FF, 0x3D3BCC), "Refunded": (0xE3E8EE, 0x3C4257), "Archived": (0xE3E8EE, 0x697386),
        ]
        if let (background, ink) = badges[cell] {
            let font = Face.ui(12.5, .semibold)
            let rect = CGRect(x: x, y: y - 2, width: Canvas.width(cell, font) + 18, height: 22)
            c.round(rect, 5, hex(background))
            c.text(cell, x + 9, y + 1, font, hex(ink))
            if cell == "Succeeded" {
                c.symbol("checkmark", CGRect(x: rect.maxX - 2, y: y + 3, width: 0, height: 0), hex(ink))
            }
            return
        }
        if column == 0 {
            switch screen.meta["row_icon"]?.text ?? "product" {
            case "card":
                c.round(CGRect(x: x, y: y + 1, width: 28, height: 18), 3, hex(0x1A1F71))
                c.text("VISA", x + 3.5, y + 3.5, Face.ui(9, .heavy).withItalic(), .white)
                c.text(cell, x + 42, y, Face.ui(15, .semibold), hex(0x1A1F36), maxWidth: width - 42)
            case "none":
                c.text(cell, x, y, Face.ui(15, .semibold), hex(0x1A1F36), maxWidth: width)
            default:
                c.round(CGRect(x: x, y: y - 6, width: 30, height: 30), 6, hex(0xF0F2FF))
                c.symbol("shippingbox", CGRect(x: x + 7, y: y + 1, width: 16, height: 16), hex(0x635BFF))
                c.text(cell, x + 42, y, Face.ui(15, .semibold), hex(0x1A1F36), maxWidth: width - 42)
            }
        } else {
            c.text(cell, x, y, Face.ui(15), hex(0x3C4257), maxWidth: width)
        }
    }
}

@MainActor
struct StripePricing {
    let screen: BrowserScreen
    let page: CGRect

    func draw() {
        let c = screen.canvas
        let meta = screen.meta
        let ink = hex(0x0A2540)
        c.fill(page, .white)
        // The page's colour band, behind the header.
        let band = CGRect(x: 0, y: page.minY, width: page.width, height: 420)
        // A plain band: no logo and no artwork of the real site's.
        c.gradient(band, [hex(0xF6F9FC), hex(0xF2F4F8)], angle: 0)
        var navX: CGFloat = 120
        for item in ["Products", "Solutions", "Developers", "Resources", "Pricing"] {
            navX += c.text(item, navX, page.minY + 38, Face.ui(15, .semibold), item == "Pricing" ? hex(0x635BFF) : ink) + 34
        }
        c.round(CGRect(x: page.width - 260, y: page.minY + 30, width: 132, height: 36), 18, ink)
        c.text("Contact sales", page.width - 245, page.minY + 39, Face.ui(14, .semibold), .white)
        c.paragraph(meta["headline"]?.text ?? "", CGRect(x: 120, y: page.minY + 116, width: 720, height: 160),
                    Face.ui(52, .bold), ink, lineSpacing: 2)
        c.text(meta["subheadline"]?.text ?? "", 120, page.minY + 262, Face.ui(20), hex(0x425466))
        let cards = meta["cards"]?.rows ?? []
        let width: CGFloat = (page.width - 240 - 48) / 3
        for (index, card) in cards.enumerated() where card.count >= 3 {
            let x = 120 + CGFloat(index) * (width + 24)
            let rect = CGRect(x: x, y: page.minY + 340, width: width, height: 260)
            c.shadow(rect, 12, blur: 24, alpha: 0.1, offset: 6)
            c.text(card[0], x + 28, rect.minY + 28, Face.ui(18, .semibold), hex(0x635BFF))
            c.text(card[1], x + 28, rect.minY + 70, Face.ui(40, .bold), ink)
            c.paragraph(card[2], CGRect(x: x + 28, y: rect.minY + 130, width: width - 56, height: 60), Face.ui(16), hex(0x425466))
            c.hline(x + 28, rect.minY + 196, width - 56, hex(0xE6EBF1))
            c.text("Learn more \u{203A}", x + 28, rect.minY + 212, Face.ui(15, .semibold), hex(0x635BFF))
        }
    }
}

// MARK: Docs, articles and search

@MainActor
struct DocsPage {
    let screen: BrowserScreen
    let page: CGRect

    func draw() {
        let c = screen.canvas
        let meta = screen.meta
        let ink = hex(0x1A1F36)
        // A neutral accent: the page is the site in use, never a copy of its
        // look, and its header names it in plain type, with no logo.
        let accent = hex(0x3B5B8C)
        c.fill(page, .white)
        c.hline(0, page.minY + 60, page.width, hex(0xE3E8EE))
        c.text(meta["site"]?.text ?? "", 32, page.minY + 19, Face.ui(17, .semibold), ink)
        let search = CGRect(x: 520, y: page.minY + 14, width: 400, height: 32)
        c.round(search, 8, hex(0xF6F8FA))
        c.stroke(search, 8, hex(0xE3E8EE))
        c.symbol("magnifyingglass", CGRect(x: search.minX + 12, y: search.minY + 9, width: 14, height: 14), hex(0x697386))
        c.text("Search the docs", search.minX + 34, search.minY + 7, Face.ui(14), hex(0x8792A2))
        c.text("Sign in", page.width - 120, page.minY + 21, Face.ui(14, .semibold), accent)
        // Side list.
        let selected = meta["selected"]?.text
        for (index, item) in (meta["sidebar"]?.texts ?? []).enumerated() {
            let y = page.minY + 92 + CGFloat(index) * 32
            if item == selected {
                c.fill(CGRect(x: 32, y: y - 4, width: 2, height: 26), accent)
            }
            c.text(item, 48, y, Face.ui(14, item == selected ? .semibold : .regular),
                   item == selected ? accent : hex(0x425466))
        }
        // The article.
        let left: CGFloat = 340
        let width: CGFloat = 720
        var y = page.minY + 88
        c.text(meta["breadcrumb"]?.text ?? "", left, y, Face.ui(13, .medium), hex(0x697386))
        y += 34
        for (kind, text) in pageBlocks(meta) {
            switch kind {
            case "h1":
                c.text(text, left, y, Face.ui(34, .bold), ink)
                y += 58
            case "h2":
                y += 10
                c.text(text, left, y, Face.ui(22, .semibold), ink)
                y += 38
            case "code":
                let lines = text.components(separatedBy: "\n")
                let rect = CGRect(x: left, y: y, width: width, height: CGFloat(lines.count) * 24 + 32)
                c.round(rect, 8, hex(0x1F2933))
                for (index, line) in lines.enumerated() {
                    let parts = line.components(separatedBy: ": ")
                    let key = parts.first ?? line
                    let x = c.text(key, left + 20, y + 16 + CGFloat(index) * 24, Face.mono(14), hex(0x9CCBF0))
                    if parts.count > 1 {
                        c.text(": " + parts.dropFirst().joined(separator: ": "), left + 20 + x,
                               y + 16 + CGFloat(index) * 24, Face.mono(14), hex(0xA8D8B9))
                    }
                }
                y += rect.height + 20
            default:
                y += c.paragraph(text, CGRect(x: left, y: y, width: width, height: 200), Face.ui(16.5), hex(0x425466),
                                 lineSpacing: 7) + 18
            }
        }
        // On this page.
        c.text("ON THIS PAGE", page.width - 280, page.minY + 120, Face.ui(11.5, .semibold), hex(0x697386), kern: 0.6)
        for (index, item) in pageBlocks(meta).filter({ $0.0 == "h2" }).enumerated() {
            c.text(item.1, page.width - 280, page.minY + 150 + CGFloat(index) * 28, Face.ui(13.5), hex(0x425466),
                   maxWidth: 240)
        }
    }
}

@MainActor
struct ArticlePage {
    let screen: BrowserScreen
    let page: CGRect

    func draw() {
        let c = screen.canvas
        let meta = screen.meta
        c.fill(page, .white)
        c.text(meta["site"]?.text ?? "", 150, page.minY + 26, Face.ui(20, .bold), hex(0x15233C))
        var x = page.width - 150
        for item in (meta["nav"]?.texts ?? []).reversed() {
            let width = Canvas.width(item, Face.ui(15))
            x -= width
            c.text(item, x, page.minY + 30, Face.ui(15), hex(0x444C59))
            x -= 32
        }
        c.hline(0, page.minY + 78, page.width, hex(0xEDEEF0))
        let left: CGFloat = 320
        let width: CGFloat = 760
        var y = page.minY + 124
        for (kind, text) in pageBlocks(meta) {
            switch kind {
            case "h1":
                y += c.paragraph(text, CGRect(x: left, y: y, width: width, height: 200), Face.serif(42, .bold),
                                 hex(0x111418), lineSpacing: 4) + 14
                c.text(meta["byline"]?.text ?? "", left, y, Face.ui(14), hex(0x7A7F87))
                y += 48
            case "h2":
                y += 8
                c.text(text, left, y, Face.serif(24, .semibold), hex(0x111418))
                y += 42
            default:
                y += c.paragraph(text, CGRect(x: left, y: y, width: width, height: 200), Face.serif(19), hex(0x2B2F36),
                                 lineSpacing: 9) + 22
            }
        }
    }
}

@MainActor
struct SearchPage {
    let screen: BrowserScreen
    let page: CGRect

    func draw() {
        let c = screen.canvas
        let meta = screen.meta
        c.fill(page, .white)
        // The logo, in its four colours.
        var x: CGFloat = 32
        for (letter, color) in zip(["G", "o", "o", "g", "l", "e"], [0x4285F4, 0xEA4335, 0xFBBC05, 0x4285F4, 0x34A853, 0xEA4335] as [UInt32]) {
            x += c.text(letter, x, page.minY + 24, Face.ui(30, .medium), hex(color == 0xFBBC05 ? 0xF29900 : color))
        }
        let field = CGRect(x: 180, y: page.minY + 20, width: 690, height: 46)
        c.shadow(field, 23, blur: 6, alpha: 0.18, offset: 1)
        c.text(meta["query"]?.text ?? "", field.minX + 24, field.minY + 13, Face.ui(16), hex(0x202124))
        c.symbol("xmark", CGRect(x: field.maxX - 100, y: field.minY + 15, width: 14, height: 14), hex(0x70757A))
        c.vline(field.maxX - 76, field.minY + 11, 24, hex(0xDADCE0))
        c.symbol("mic.fill", CGRect(x: field.maxX - 62, y: field.minY + 13, width: 14, height: 19), hex(0x4285F4))
        c.symbol("magnifyingglass", CGRect(x: field.maxX - 34, y: field.minY + 14, width: 18, height: 18), hex(0x4285F4))
        let tabs = ["All", "Images", "Videos", "News", "Shopping", "Forums", "More"]
        var tx: CGFloat = 196
        for (index, tab) in tabs.enumerated() {
            let width = c.text(tab, tx, page.minY + 88, Face.ui(14, index == 0 ? .medium : .regular),
                               index == 0 ? hex(0x1A73E8) : hex(0x5F6368))
            if index == 0 { c.fill(CGRect(x: tx - 2, y: page.minY + 112, width: width + 4, height: 3), hex(0x1A73E8)) }
            tx += width + 28
        }
        c.hline(0, page.minY + 115, page.width, hex(0xEBEBEB))
        if let stats = meta["stats"]?.text {
            c.text(stats, 196, page.minY + 128, Face.ui(13), hex(0x70757A))
        }
        var y = page.minY + 162
        for result in meta["results"]?.rows ?? [] where result.count >= 3 {
            let site = result[1].components(separatedBy: " \u{203A} ").first ?? result[1]
            c.circle(CGPoint(x: 196 + 13, y: y + 13), 13, hex(0xF1F3F4))
            c.centered(String(site.prefix(1)).uppercased(), 196, 26, y + 5, Face.ui(13, .bold), hex(0x5F6368))
            c.text(site, 232, y, Face.ui(14), hex(0x202124))
            c.text(result[1], 232, y + 19, Face.ui(12.5), hex(0x4D5156), maxWidth: 560)
            c.text(result[0], 196, y + 44, Face.ui(20), hex(0x1A0DAB), maxWidth: 650)
            let height = c.paragraph(result[2], CGRect(x: 196, y: y + 76, width: 652, height: 60), Face.ui(14.5), hex(0x4D5156),
                                     lineSpacing: 4)
            y += 96 + height
        }
    }
}

// MARK: Google Docs and Sheets

@MainActor
struct GoogleDoc {
    let screen: BrowserScreen
    let page: CGRect

    func draw() {
        let c = screen.canvas
        let meta = screen.meta
        c.fill(page, hex(0xF9FBFD))
        googleHeader(c, page: page, title: meta["doc_title"]?.text ?? "", iconColor: hex(0x4285F4), sheets: false)
        // The page.
        let paper = CGRect(x: (page.width - 816) / 2, y: page.minY + 128, width: 816, height: page.height - 110)
        c.fill(paper.offsetBy(dx: 0, dy: 1), hex(0xDADCE0))
        c.fill(paper, .white)
        let left = paper.minX + 96
        let width = paper.width - 192
        var y = paper.minY + 72
        for (kind, text) in pageBlocks(meta) {
            switch kind {
            case "h1":
                c.text(text, left, y, Face.ui(30), hex(0x202124))
                y += 50
            case "h2":
                y += 8
                c.text(text, left, y, Face.ui(19, .semibold), hex(0x202124))
                y += 34
            case "li":
                c.circle(CGPoint(x: left + 14, y: y + 10), 2.8, hex(0x202124))
                y += c.paragraph(text, CGRect(x: left + 30, y: y, width: width - 30, height: 80), Face.ui(15), hex(0x202124),
                                 lineSpacing: 5) + 8
            default:
                y += c.paragraph(text, CGRect(x: left, y: y, width: width, height: 120), Face.ui(15), hex(0x202124),
                                 lineSpacing: 5) + 12
            }
        }
        // The cursor, where the writing stopped.
        c.fill(CGRect(x: left + 2, y: y + 2, width: 1.5, height: 20), hex(0x202124))
        // Who else has it open.
        c.avatar("Mira Castell", CGRect(x: page.width - 230, y: page.minY + 17, width: 30, height: 30), avatarColor("Mira Castell"),
                 font: Face.ui(12, .semibold))
    }
}

@MainActor
func googleHeader(_ c: Canvas, page: CGRect, title: String, iconColor: NSColor, sheets: Bool) {
    c.round(CGRect(x: 20, y: page.minY + 14, width: 30, height: 40), 4, iconColor)
    if sheets {
        c.stroke(CGRect(x: 27, y: page.minY + 26, width: 16, height: 16), 0, .white, width: 1.6)
        c.vline(35, page.minY + 26, 16, .white, thickness: 1.6)
        c.hline(27, page.minY + 34, 16, .white, thickness: 1.6)
    } else {
        for line in 0..<4 {
            c.fill(CGRect(x: 28, y: page.minY + 25 + CGFloat(line) * 5, width: line == 3 ? 9 : 14, height: 2), .white)
        }
    }
    c.text(title, 64, page.minY + 10, Face.ui(18), hex(0x1F1F1F))
    let titleWidth = Canvas.width(title, Face.ui(18))
    for (index, name) in ["star", "folder", "icloud"].enumerated() {
        c.symbol(name, CGRect(x: 64 + titleWidth + 16 + CGFloat(index) * 28, y: page.minY + 13, width: 16, height: 15), hex(0x444746))
    }
    let menus = ["File", "Edit", "View", "Insert", "Format", sheets ? "Data" : "Tools", sheets ? "Tools" : "Extensions",
                 sheets ? "Extensions" : "Help"] + (sheets ? ["Help"] : [])
    var x: CGFloat = 64
    for menu in menus {
        x += c.text(menu, x, page.minY + 37, Face.ui(14), hex(0x1F1F1F)) + 16
    }
    let share = CGRect(x: page.width - 140, y: page.minY + 12, width: 108, height: 40)
    c.round(share, 20, hex(0xC2E7FF))
    c.symbol("lock", CGRect(x: share.minX + 18, y: share.minY + 12, width: 13, height: 15), hex(0x001D35))
    c.text("Share", share.minX + 40, share.minY + 10.5, Face.ui(15, .medium), hex(0x001D35))
    c.avatar("Ren Alder", CGRect(x: page.width - 186, y: page.minY + 17, width: 30, height: 30), hex(0x2E9E8F),
             font: Face.ui(12, .semibold))
    c.symbol("clock.arrow.circlepath", CGRect(x: page.width - 330, y: page.minY + 22, width: 20, height: 18), hex(0x444746))
    c.symbol("bubble.left", CGRect(x: page.width - 290, y: page.minY + 22, width: 20, height: 18), hex(0x444746))
    // The toolbar.
    let bar = CGRect(x: 16, y: page.minY + 66, width: page.width - 32, height: 40)
    c.round(bar, 20, hex(0xEDF2FA))
    var x2: CGFloat = 36
    let common = ["magnifyingglass", "arrow.uturn.backward", "arrow.uturn.forward", "printer", "paintbrush"]
    for tool in common {
        c.symbol(tool, CGRect(x: x2, y: bar.minY + 11, width: 18, height: 18), hex(0x444746))
        x2 += 36
    }
    x2 += c.text("100%", x2, bar.minY + 11, Face.ui(14), hex(0x444746)) + 24
    if sheets {
        for item in ["$", "%", ".0", ".00", "123"] {
            x2 += c.text(item, x2, bar.minY + 11, Face.ui(14, .medium), hex(0x444746)) + 24
        }
        x2 += c.text("Default\u{2026}", x2, bar.minY + 11, Face.ui(14), hex(0x444746)) + 24
        x2 += c.text("10", x2, bar.minY + 11, Face.ui(14), hex(0x444746)) + 24
        for tool in ["bold", "italic", "strikethrough", "textformat", "paintbrush.pointed", "square.grid.3x3", "rectangle.split.3x1"] {
            c.symbol(tool, CGRect(x: x2, y: bar.minY + 11, width: 18, height: 18), hex(0x444746))
            x2 += 36
        }
    } else {
        x2 += c.text("Normal text", x2, bar.minY + 11, Face.ui(14), hex(0x444746)) + 24
        x2 += c.text("Arial", x2, bar.minY + 11, Face.ui(14), hex(0x444746)) + 24
        x2 += c.text("11", x2, bar.minY + 11, Face.ui(14), hex(0x444746)) + 24
        for tool in ["bold", "italic", "underline", "textformat", "link", "text.bubble", "photo", "text.alignleft",
                     "list.bullet", "list.number", "decrease.indent", "increase.indent"] {
            c.symbol(tool, CGRect(x: x2, y: bar.minY + 11, width: 18, height: 18), hex(0x444746))
            x2 += 36
        }
    }
}

@MainActor
struct GoogleSheet {
    let screen: BrowserScreen
    let page: CGRect

    func draw() {
        let c = screen.canvas
        let meta = screen.meta
        c.fill(page, .white)
        googleHeader(c, page: page, title: meta["doc_title"]?.text ?? "", iconColor: hex(0x0F9D58), sheets: true)
        let rows = meta["rows"]?.rows ?? []
        let selectedRow = meta["selected_row"]?.int ?? 0
        // Formula bar.
        let barTop = page.minY + 114
        c.hline(0, barTop, page.width, hex(0xE1E3E1))
        c.text("A\(selectedRow + 2)", 28, barTop + 8, Face.ui(14), hex(0x1F1F1F))
        c.vline(110, barTop + 6, 20, hex(0xE1E3E1))
        c.text("fx", 124, barTop + 7, Face.serif(15).withItalic(), hex(0x5F6368))
        let selected = rows.indices.contains(selectedRow) ? rows[selectedRow].first ?? "" : ""
        c.text(selected, 156, barTop + 8, Face.ui(14), hex(0x1F1F1F))
        // The grid.
        let gridTop = barTop + 34
        let rowHeight: CGFloat = 30
        let header: CGFloat = 46
        let widths: [CGFloat] = [250, 150, 150, 150, 150, 170]
        let letters = ["A", "B", "C", "D", "E", "F", "G", "H"]
        c.fill(CGRect(x: 0, y: gridTop, width: page.width, height: 26), hex(0xF8F9FA))
        c.fill(CGRect(x: 0, y: gridTop, width: header, height: page.height), hex(0xF8F9FA))
        var x = header
        for (index, width) in (widths + [140, 140]).enumerated() {
            c.centered(letters[index], x, width, gridTop + 5, Face.ui(12), hex(0x5F6368))
            c.vline(x, gridTop, page.maxY - gridTop, hex(0xE1E3E1))
            x += width
        }
        let columns = meta["columns"]?.texts ?? []
        let table = [columns] + rows
        let bold = Set((meta["bold_rows"]?.items.compactMap(\.int) ?? []).map { $0 + 1 })
        for row in 0..<24 {
            let y = gridTop + 26 + CGFloat(row) * rowHeight
            guard y < page.maxY - 40 else { break }
            c.hline(0, y, page.width, hex(0xE1E3E1))
            c.centered("\(row + 1)", 0, header, y + 7, Face.ui(12), hex(0x5F6368))
            guard row < table.count else { continue }
            var cx = header
            for (column, cell) in table[row].enumerated() where column < widths.count {
                let isHeader = row == 0
                let font = Face.ui(14, isHeader || bold.contains(row) ? .semibold : .regular)
                if column == 0 || isHeader {
                    c.text(cell, cx + 8, y + 6, font, isHeader ? hex(0x1F1F1F) : hex(0x1F1F1F))
                } else {
                    c.textRight(cell, cx + widths[column] - 10, y + 6, font, hex(0x1F1F1F))
                }
                cx += widths[column]
            }
            if row == 0 {
                c.fill(CGRect(x: header, y: y, width: widths.reduce(0, +), height: rowHeight), hex(0x0F9D58, alpha: 0.06))
            }
        }
        // The selected cell.
        let selectedY = gridTop + 26 + CGFloat(selectedRow + 1) * rowHeight
        c.stroke(CGRect(x: header - 1, y: selectedY - 1, width: widths[0] + 2, height: rowHeight + 2), 0, hex(0x1A73E8), width: 2)
        c.fill(CGRect(x: header + widths[0] - 4, y: selectedY + rowHeight - 4, width: 6, height: 6), hex(0x1A73E8))
        // Sheet tabs.
        let tabsTop = page.maxY - 40
        c.fill(CGRect(x: 0, y: tabsTop, width: page.width, height: 40), hex(0xF8F9FA))
        c.hline(0, tabsTop, page.width, hex(0xE1E3E1))
        c.symbol("plus", CGRect(x: 18, y: tabsTop + 13, width: 14, height: 14), hex(0x444746))
        c.symbol("line.3.horizontal", CGRect(x: 50, y: tabsTop + 14, width: 16, height: 12), hex(0x444746))
        var sx: CGFloat = 90
        let active = meta["active_sheet"]?.int ?? 0
        for (index, sheet) in (meta["sheets"]?.texts ?? []).enumerated() {
            let width = Canvas.width(sheet, Face.ui(14, .medium)) + 40
            if index == active {
                c.round(CGRect(x: sx, y: tabsTop + 5, width: width, height: 30), 6, hex(0xE1F0E6))
            }
            c.text(sheet, sx + 20, tabsTop + 11, Face.ui(14, .medium), index == active ? hex(0x0B8043) : hex(0x444746))
            sx += width + 6
        }
    }
}

// MARK: Claude, and a pricing page

@MainActor
struct ClaudeChat {
    let screen: BrowserScreen
    let page: CGRect

    func draw() {
        let c = screen.canvas
        let meta = screen.meta
        let background = hex(0xFAF9F5)
        let ink = hex(0x1F1E1D)
        c.fill(page, background)
        // The narrow side rail.
        c.fill(CGRect(x: 0, y: page.minY, width: 64, height: page.height), hex(0xF3F1EA))
        c.vline(64, page.minY, page.height, hex(0xE8E6DC))
        c.round(CGRect(x: 18, y: page.minY + 18, width: 28, height: 28), 7, hex(0xD97757))
        c.symbol("asterisk", CGRect(x: 23, y: page.minY + 23, width: 18, height: 18), .white, weight: .bold)
        for (index, name) in ["plus.circle", "bubble.left.and.bubble.right", "folder", "square.grid.2x2"].enumerated() {
            c.symbol(name, CGRect(x: 21, y: page.minY + 74 + CGFloat(index) * 44, width: 22, height: 22), hex(0x73726C))
        }
        c.avatar("Ren Alder", CGRect(x: 18, y: page.maxY - 52, width: 28, height: 28), hex(0x2E9E8F), font: Face.ui(11, .semibold))
        // The title.
        let title = meta["chat_title"]?.text ?? ""
        c.text(title, 96, page.minY + 20, Face.ui(15, .medium), ink)
        c.symbol("chevron.down", CGRect(x: 96 + Canvas.width(title, Face.ui(15, .medium)) + 8, y: page.minY + 26, width: 10, height: 7), hex(0x73726C))
        c.round(CGRect(x: page.width - 120, y: page.minY + 14, width: 88, height: 32), 8, .white)
        c.stroke(CGRect(x: page.width - 120, y: page.minY + 14, width: 88, height: 32), 8, hex(0xE8E6DC))
        c.text("Share", page.width - 96, page.minY + 21, Face.ui(14, .medium), ink)
        // The conversation.
        let column = CGRect(x: (page.width - 760) / 2, y: page.minY + 80, width: 760, height: page.height - 200)
        var y = column.minY
        for message in meta["messages"]?.rows ?? [] where message.count == 2 {
            if message[0] == "user" {
                let font = Face.ui(16)
                let height = Canvas.height(message[1], 560, font, lineSpacing: 5)
                let bubble = CGRect(x: column.maxX - 600, y: y, width: 600, height: height + 32)
                c.round(bubble, 14, hex(0xF0EEE6))
                c.paragraph(message[1], CGRect(x: bubble.minX + 20, y: y + 15, width: 560, height: height), font, ink, lineSpacing: 5)
                y += bubble.height + 28
            } else {
                c.round(CGRect(x: column.minX, y: y + 2, width: 24, height: 24), 6, hex(0xD97757))
                c.symbol("asterisk", CGRect(x: column.minX + 5, y: y + 7, width: 14, height: 14), .white, weight: .bold)
                let height = c.paragraph(message[1], CGRect(x: column.minX + 40, y: y, width: column.width - 40, height: 300),
                                         Face.serif(17), ink, lineSpacing: 8)
                y += height + 34
            }
        }
        // The reply box.
        let box = CGRect(x: (page.width - 780) / 2, y: page.maxY - 118, width: 780, height: 92)
        c.shadow(box, 18, blur: 10, alpha: 0.08, offset: 2)
        c.stroke(box, 18, hex(0xE8E6DC))
        c.text("Reply to Claude\u{2026}", box.minX + 22, box.minY + 18, Face.ui(16), hex(0x9C9A92))
        c.symbol("plus", CGRect(x: box.minX + 22, y: box.maxY - 34, width: 16, height: 16), hex(0x73726C))
        c.round(CGRect(x: box.maxX - 48, y: box.maxY - 44, width: 32, height: 32), 9, hex(0xD97757, alpha: 0.5))
        c.symbol("arrow.up", CGRect(x: box.maxX - 40, y: box.maxY - 36, width: 16, height: 16), .white, weight: .bold)
    }
}

@MainActor
struct PricingPage {
    let screen: BrowserScreen
    let page: CGRect

    func draw() {
        let c = screen.canvas
        let meta = screen.meta
        let teal = hex(0x0E7C66)
        let ink = hex(0x12201C)
        c.fill(page, .white)
        c.round(CGRect(x: 120, y: page.minY + 26, width: 26, height: 26), 7, teal)
        c.text(meta["site"]?.text ?? "", 156, page.minY + 27, Face.ui(20, .bold), ink)
        var navX = page.width - 600
        for item in ["Features", "Studios", "Pricing", "Log in"] {
            navX += c.text(item, navX, page.minY + 31, Face.ui(15), hex(0x3D4A46)) + 36
        }
        c.round(CGRect(x: page.width - 212, y: page.minY + 22, width: 112, height: 36), 18, teal)
        c.text("Start free", page.width - 192, page.minY + 31, Face.ui(14, .semibold), .white)
        c.centered(meta["headline"]?.text ?? "", 0, page.width, page.minY + 110, Face.ui(44, .bold), ink)
        c.centered(meta["subheadline"]?.text ?? "", 0, page.width, page.minY + 172, Face.ui(18), hex(0x52605B))
        let cards = meta["cards"]?.rows ?? []
        let width: CGFloat = 300
        let gap: CGFloat = 28
        let start = (page.width - CGFloat(cards.count) * width - CGFloat(max(cards.count - 1, 0)) * gap) / 2
        for (index, card) in cards.enumerated() where card.count >= 4 {
            let x = start + CGFloat(index) * (width + gap)
            let rect = CGRect(x: x, y: page.minY + 236, width: width, height: 330)
            c.round(rect, 16, index == 1 ? hex(0xF0F8F5) : .white)
            c.stroke(rect, 16, index == 1 ? teal : hex(0xDDE5E2), width: index == 1 ? 2 : 1)
            c.text(card[0], x + 28, rect.minY + 30, Face.ui(20, .semibold), ink)
            let priceWidth = c.text(card[1], x + 28, rect.minY + 70, Face.ui(44, .bold), ink)
            c.text(card[2], x + 36 + priceWidth, rect.minY + 92, Face.ui(15), hex(0x52605B))
            c.paragraph(card[3], CGRect(x: x + 28, y: rect.minY + 146, width: width - 56, height: 60), Face.ui(15), hex(0x3D4A46))
            let button = CGRect(x: x + 28, y: rect.maxY - 70, width: width - 56, height: 42)
            c.round(button, 10, index == 1 ? teal : hex(0xEAF3EF))
            c.centered("Choose \(card[0])", button.minX, button.width, button.minY + 12, Face.ui(15, .semibold),
                       index == 1 ? .white : teal)
        }
    }
}

extension NSFont {
    func withItalic() -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
    }
}
