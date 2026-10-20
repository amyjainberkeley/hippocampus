// SPDX-License-Identifier: Apache-2.0
//
// AppScreens.swift — Slack, a Zoom call, Notion, Figma and Calendar.

import AppKit

/// Slack: the workspace's channels, and one channel's messages.
@MainActor
struct SlackScreen {
    let spec: DemoScreenSpec
    let canvas: Canvas

    func draw() {
        let c = canvas
        let meta = spec.meta
        let size = c.size
        let aubergine = hex(0x3F0E40)
        c.fill(c.bounds, .white)
        // The top bar, with search.
        c.fill(CGRect(x: 0, y: 0, width: size.width, height: 40), hex(0x350D36))
        c.trafficLights(14, 14)
        for (index, name) in ["arrow.left", "arrow.right", "clock"].enumerated() {
            c.symbol(name, CGRect(x: 300 + CGFloat(index) * 32, y: 12, width: 16, height: 16), hex(0xFFFFFF, alpha: 0.7))
        }
        let search = CGRect(x: 420, y: 7, width: 600, height: 26)
        c.round(search, 6, hex(0xFFFFFF, alpha: 0.2))
        c.symbol("magnifyingglass", CGRect(x: search.minX + 12, y: 13, width: 13, height: 13), hex(0xFFFFFF, alpha: 0.85))
        let workspace = meta["workspace"]?.text ?? ""
        c.text("Search \(workspace)", search.minX + 32, 11.5, Face.ui(13), hex(0xFFFFFF, alpha: 0.85))
        c.symbol("questionmark.circle", CGRect(x: size.width - 40, y: 12, width: 17, height: 17), hex(0xFFFFFF, alpha: 0.8))
        // The rail of workspaces.
        c.fill(CGRect(x: 0, y: 40, width: 70, height: size.height - 40), hex(0x350D36))
        c.round(CGRect(x: 15, y: 54, width: 40, height: 40), 10, hex(0x2E9E8F))
        c.centered("P", 15, 40, 63, Face.ui(19, .bold), .white)
        for (index, item) in [("house.fill", "Home"), ("bubble.left.and.bubble.right", "DMs"), ("bell", "Activity"),
                              ("ellipsis", "More")].enumerated() {
            let y = 118 + CGFloat(index) * 64
            if index == 0 { c.round(CGRect(x: 17, y: y - 4, width: 36, height: 36), 9, hex(0xFFFFFF, alpha: 0.18)) }
            c.symbol(item.0, CGRect(x: 25, y: y + 4, width: 20, height: 20), .white)
            c.centered(item.1, 0, 70, y + 36, Face.ui(11, .semibold), .white)
        }
        c.avatar("Ren Alder", CGRect(x: 19, y: size.height - 60, width: 32, height: 32), hex(0x2E9E8F), radius: 8,
                 font: Face.ui(12, .bold))
        // The sidebar.
        let sidebar = CGRect(x: 70, y: 40, width: 260, height: size.height - 40)
        c.fill(sidebar, aubergine)
        c.text(workspace, sidebar.minX + 18, 58, Face.ui(18, .heavy), .white)
        c.symbol("square.and.pencil", CGRect(x: sidebar.maxX - 40, y: 58, width: 19, height: 19), .white)
        c.hline(sidebar.minX, 94, sidebar.width, hex(0xFFFFFF, alpha: 0.12))
        let channel = meta["channel"]?.text ?? ""
        var y: CGFloat = 108
        for (symbol, item) in [("text.bubble", "Threads"), ("bubble.left", "Huddles"), ("paperplane", "Drafts & sent")] {
            c.symbol(symbol, CGRect(x: sidebar.minX + 20, y: y + 2, width: 15, height: 15), hex(0xFFFFFF, alpha: 0.72))
            c.text(item, sidebar.minX + 46, y, Face.ui(15), hex(0xFFFFFF, alpha: 0.72))
            y += 30
        }
        y += 14
        c.text("\u{2304}  Channels", sidebar.minX + 16, y - 6, Face.ui(15, .medium), hex(0xFFFFFF, alpha: 0.72))
        y += 26
        for item in meta["channels"]?.texts ?? [] {
            if item == channel {
                c.round(CGRect(x: sidebar.minX + 8, y: y - 4, width: sidebar.width - 16, height: 28), 6, hex(0x1164A3))
            }
            c.text("#", sidebar.minX + 22, y, Face.ui(15), item == channel ? .white : hex(0xFFFFFF, alpha: 0.72))
            c.text(item, sidebar.minX + 42, y, Face.ui(15, item == channel ? .bold : .regular),
                   item == channel ? .white : hex(0xFFFFFF, alpha: 0.72))
            y += 30
        }
        y += 14
        c.text("\u{2304}  Direct messages", sidebar.minX + 16, y - 6, Face.ui(15, .medium), hex(0xFFFFFF, alpha: 0.72))
        y += 26
        for person in meta["dms"]?.texts ?? [] {
            c.avatar(person, CGRect(x: sidebar.minX + 20, y: y - 1, width: 20, height: 20), avatarColor(person), radius: 5,
                     font: Face.ui(8.5, .bold))
            c.circle(CGPoint(x: sidebar.minX + 40, y: y + 18), 4, hex(0x2BAC76))
            c.text(person, sidebar.minX + 50, y, Face.ui(15), hex(0xFFFFFF, alpha: 0.72))
            y += 30
        }
        // The channel.
        let left = sidebar.maxX
        let width = size.width - left
        c.text("# " + channel, left + 20, 54, Face.ui(18, .heavy), hex(0x1D1C1D))
        c.text(meta["topic"]?.text ?? "", left + 24 + Canvas.width("# " + channel, Face.ui(18, .heavy)) + 12, 58,
               Face.ui(13), hex(0x616061))
        c.symbol("person.2", CGRect(x: size.width - 120, y: 56, width: 22, height: 16), hex(0x616061))
        c.text("\(max(3, (meta["dms"]?.texts.count ?? 3) + 2))", size.width - 94, 55, Face.ui(13), hex(0x616061))
        c.symbol("headphones", CGRect(x: size.width - 60, y: 54, width: 20, height: 20), hex(0x616061))
        c.hline(left, 90, width, hex(0xE2E2E2))
        // Messages, bottom up above the composer, with a divider for each
        // day; one person's messages in a row share their name, as Slack
        // shows them. What doesn't fit scrolled away at the top.
        let all = meta["messages"]?.rows.filter { $0.count >= 3 } ?? []
        let font = Face.ui(15)
        let textWidth = width - 110
        struct Row { let message: [String]; let day: String?; let continues: Bool; let height: CGFloat }
        func layout(_ messages: ArraySlice<[String]>) -> [Row] {
            var rows: [Row] = []
            var last: [String]?
            for message in messages {
                let day = message.count > 3 ? message[3] : "Today"
                let newDay = day != (last.map { $0.count > 3 ? $0[3] : "Today" })
                // One person's messages within five minutes read as one.
                let minute = message.count > 4 ? Int(message[4]) ?? 0 : 0
                let lastMinute = last.flatMap { $0.count > 4 ? Int($0[4]) : nil } ?? -100
                let continues = !newDay && message[0] == last?[0] && minute - lastMinute <= 5
                let text = Canvas.height(message[2], textWidth, font, lineSpacing: 5)
                let height = (newDay ? 56 : 0) + (continues ? text + 8 : text + 44)
                rows.append(Row(message: message, day: newDay ? day : nil, continues: continues, height: height))
                last = message
            }
            return rows
        }
        let composerTop = size.height - 112
        let room = composerTop - 20 - 104
        var first = 0
        var rows = layout(all[...])
        while rows.count > 1, rows.reduce(0, { $0 + $1.height }) > room {
            first += 1
            rows = layout(all[first...])
        }
        var my = composerTop - 20 - rows.reduce(0) { $0 + $1.height }
        for row in rows {
            let message = row.message
            if let day = row.day {
                my += 24
                c.hline(left + 20, my, width - 40, hex(0xE2E2E2))
                let pillWidth = Canvas.width(day, Face.ui(13, .semibold)) + 32
                let pill = CGRect(x: left + width / 2 - pillWidth / 2, y: my - 12, width: pillWidth, height: 24)
                c.round(pill, 12, .white)
                c.stroke(pill, 12, hex(0xE2E2E2))
                c.centered(day, pill.minX, pill.width, pill.minY + 4, Face.ui(13, .semibold), hex(0x1D1C1D))
                my += 32
            }
            let textTop: CGFloat
            if row.continues {
                textTop = my - 16
            } else {
                c.avatar(message[0], CGRect(x: left + 20, y: my, width: 38, height: 38), avatarColor(message[0]), radius: 8,
                         font: Face.ui(14, .bold))
                let nameWidth = c.text(message[0], left + 72, my - 2, Face.ui(15, .heavy), hex(0x1D1C1D))
                c.text(message[1], left + 80 + nameWidth, my + 1, Face.ui(12.5), hex(0x616061))
                textTop = my + 21
            }
            let text = Canvas.height(message[2], textWidth, font, lineSpacing: 5)
            c.paragraph(message[2], CGRect(x: left + 72, y: textTop, width: textWidth, height: text), font,
                        hex(0x1D1C1D), lineSpacing: 5)
            my += row.height - (row.day == nil ? 0 : 56)
        }
        // The composer.
        let composer = CGRect(x: left + 20, y: composerTop, width: width - 40, height: 92)
        c.round(composer, 8, .white)
        c.stroke(composer, 8, hex(0xBBBBBB))
        let tools = ["bold", "italic", "strikethrough", "link", "list.number", "list.bullet", "chevron.left.forwardslash.chevron.right"]
        for (index, tool) in tools.enumerated() {
            c.symbol(tool, CGRect(x: composer.minX + 14 + CGFloat(index) * 32, y: composer.minY + 10, width: 15, height: 15), hex(0x868686))
        }
        c.text("Message #\(channel)", composer.minX + 14, composer.minY + 40, Face.ui(15), hex(0x868686))
        c.symbol("plus.circle", CGRect(x: composer.minX + 14, y: composer.maxY - 28, width: 18, height: 18), hex(0x868686))
        c.symbol("paperplane.fill", CGRect(x: composer.maxX - 34, y: composer.maxY - 28, width: 18, height: 18), hex(0xBBBBBB))
    }
}

/// A Zoom call: initials on dark tiles, names, and the call's controls. No
/// faces, ever.
@MainActor
struct ZoomScreen {
    let spec: DemoScreenSpec
    let canvas: Canvas

    func draw() {
        let c = canvas
        let size = c.size
        c.fill(c.bounds, hex(0x1A1A1A))
        c.fill(CGRect(x: 0, y: 0, width: size.width, height: 38), hex(0x242424))
        c.trafficLights(14, 13)
        c.centered("Zoom Meeting", 0, size.width, 10, Face.ui(14, .medium), hex(0xE6E6E6))
        c.symbol("shield.lefthalf.filled", CGRect(x: 92, y: 12, width: 14, height: 15), hex(0x23D959))
        c.round(CGRect(x: size.width - 112, y: 9, width: 96, height: 22), 5, hex(0x3A3A3A))
        c.symbol("square.grid.2x2", CGRect(x: size.width - 104, y: 13, width: 14, height: 14), hex(0xE6E6E6))
        c.text("View", size.width - 84, 11.5, Face.ui(13), hex(0xE6E6E6))
        let meeting = spec.meta["meeting"]?.text ?? ""
        c.text(meeting, 22, 52, Face.ui(15, .semibold), hex(0xE6E6E6))
        c.text("\u{00B7}  Recording off", 26 + Canvas.width(meeting, Face.ui(15, .semibold)), 53, Face.ui(13), hex(0x9A9A9A))
        let people = spec.meta["participants"]?.texts ?? []
        let speaker = spec.meta["speaker"]?.int ?? 0
        let columns = people.count <= 2 ? 2 : (people.count <= 4 ? 2 : 3)
        let rows = Int(ceil(Double(max(people.count, 1)) / Double(columns)))
        let area = CGRect(x: 22, y: 84, width: size.width - 44, height: size.height - 84 - 92)
        let gap: CGFloat = 10
        let tileWidth = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let tileHeight = min((area.height - gap * CGFloat(rows - 1)) / CGFloat(rows), tileWidth * 0.62)
        let gridHeight = tileHeight * CGFloat(rows) + gap * CGFloat(rows - 1)
        let top = area.minY + (area.height - gridHeight) / 2
        for (index, person) in people.enumerated() {
            let column = index % columns
            let row = index / columns
            let inRow = min(columns, people.count - row * columns)
            let offset = (area.width - (tileWidth * CGFloat(inRow) + gap * CGFloat(inRow - 1))) / 2
            let rect = CGRect(x: area.minX + offset + CGFloat(column) * (tileWidth + gap),
                              y: top + CGFloat(row) * (tileHeight + gap), width: tileWidth, height: tileHeight)
            c.round(rect, 10, hex(0x2B2B2B))
            let radius = min(tileHeight * 0.2, 56)
            c.avatar(person, CGRect(x: rect.midX - radius, y: rect.midY - radius - 8, width: radius * 2, height: radius * 2),
                     avatarColor(person), font: Face.ui(radius * 0.72, .semibold))
            let label = CGRect(x: rect.minX + 10, y: rect.maxY - 34, width: Canvas.width(person, Face.ui(13)) + 34, height: 24)
            c.round(label, 5, hex(0x000000, alpha: 0.55))
            c.symbol(index == speaker ? "mic.fill" : "mic.slash.fill", CGRect(x: label.minX + 8, y: label.minY + 5, width: 12, height: 14),
                     index == speaker ? .white : hex(0xE02828))
            c.text(person, label.minX + 26, label.minY + 4, Face.ui(13), .white)
            if index == speaker { c.stroke(rect, 10, hex(0x23D959), width: 3) }
        }
        // The controls.
        let barTop = size.height - 80
        c.fill(CGRect(x: 0, y: barTop, width: size.width, height: 80), hex(0x242424))
        let controls: [(String, String, UInt32)] = [
            ("mic.fill", "Mute", 0xE6E6E6), ("video.fill", "Stop Video", 0xE6E6E6), ("shield", "Security", 0xE6E6E6),
            ("person.2.fill", "Participants", 0xE6E6E6), ("bubble.left.fill", "Chat", 0xE6E6E6),
            ("square.and.arrow.up.fill", "Share Screen", 0x23D959), ("record.circle", "Record", 0xE6E6E6),
            ("heart", "Reactions", 0xE6E6E6), ("square.grid.2x2.fill", "Apps", 0xE6E6E6),
        ]
        let step: CGFloat = 96
        let start = (size.width - step * CGFloat(controls.count)) / 2 - 40
        for (index, control) in controls.enumerated() {
            let x = start + CGFloat(index) * step
            c.symbol(control.0, CGRect(x: x + step / 2 - 13, y: barTop + 12, width: 26, height: 24), hex(control.2))
            c.centered(control.1, x, step, barTop + 46, Face.ui(12), hex(0xE6E6E6))
        }
        let leave = CGRect(x: size.width - 110, y: barTop + 22, width: 82, height: 34)
        c.round(leave, 8, hex(0xE02828))
        c.centered("Leave", leave.minX, leave.width, leave.minY + 8, Face.ui(14, .semibold), .white)
    }
}

/// Notion: the workspace's pages, and one page.
@MainActor
struct NotionScreen {
    let spec: DemoScreenSpec
    let canvas: Canvas

    func draw() {
        let c = canvas
        let meta = spec.meta
        let size = c.size
        let ink = hex(0x37352F)
        c.fill(c.bounds, .white)
        let sidebar = CGRect(x: 0, y: 0, width: 250, height: size.height)
        c.fill(sidebar, hex(0xF7F7F5))
        c.vline(sidebar.maxX, 0, size.height, hex(0xEDEDEC))
        c.trafficLights(14, 14)
        c.round(CGRect(x: 14, y: 44, width: 22, height: 22), 5, hex(0x2E9E8F))
        c.centered("P", 14, 22, 47, Face.ui(13, .bold), .white)
        c.text(meta["workspace"]?.text ?? "", 44, 46, Face.ui(14, .semibold), ink)
        var y: CGFloat = 84
        for (symbol, item) in [("magnifyingglass", "Search"), ("house", "Home"), ("tray", "Inbox")] {
            c.symbol(symbol, CGRect(x: 18, y: y + 1, width: 15, height: 15), hex(0x91918E))
            c.text(item, 44, y, Face.ui(14), hex(0x5F5E5B))
            y += 28
        }
        y += 16
        c.text("Workspace", 18, y, Face.ui(12, .medium), hex(0x91918E))
        y += 26
        let selected = meta["selected"]?.text
        for (index, item) in (meta["sidebar"]?.texts ?? []).enumerated() {
            let isChild = index > 0
            if item == selected {
                c.round(CGRect(x: 6, y: y - 4, width: sidebar.width - 12, height: 26), 5, hex(0xEFEFED))
            }
            c.symbol(isChild ? "doc.text" : "folder", CGRect(x: isChild ? 34 : 18, y: y + 1, width: 14, height: 15), hex(0x91918E))
            c.text(item, isChild ? 58 : 42, y, Face.ui(14, item == selected ? .medium : .regular),
                   item == selected ? ink : hex(0x5F5E5B))
            y += 28
        }
        // The page's top bar.
        c.text(meta["breadcrumb"]?.text ?? "", sidebar.maxX + 18, 14, Face.ui(14), ink)
        c.text("Edited just now", size.width - 250, 14, Face.ui(14), hex(0x91918E))
        c.text("Share", size.width - 132, 14, Face.ui(14), ink)
        c.symbol("star", CGRect(x: size.width - 78, y: 15, width: 15, height: 15), hex(0x5F5E5B))
        c.symbol("ellipsis", CGRect(x: size.width - 44, y: 21, width: 16, height: 4), hex(0x5F5E5B))
        // The page.
        let left = sidebar.maxX + 150
        let width = size.width - left - 150
        y = 120
        for (kind, text) in pageBlocks(meta) {
            switch kind {
            case "h1":
                c.text(text, left, y, Face.ui(40, .bold), ink)
                y += 78
            case "h2":
                y += 10
                c.text(text, left, y, Face.ui(24, .semibold), ink)
                y += 44
            case "li":
                c.circle(CGPoint(x: left + 9, y: y + 12), 3, ink)
                y += c.paragraph(text, CGRect(x: left + 26, y: y, width: width - 26, height: 100), Face.ui(16), ink,
                                 lineSpacing: 6) + 10
            default:
                y += c.paragraph(text, CGRect(x: left, y: y, width: width, height: 200), Face.ui(16), ink, lineSpacing: 7) + 16
            }
        }
        c.fill(CGRect(x: left, y: y + 4, width: 1.5, height: 21), ink)
    }
}

/// Figma: the file's pages and layers, the pricing page on the canvas, and
/// the design panel.
@MainActor
struct FigmaScreen {
    let spec: DemoScreenSpec
    let canvas: Canvas

    func draw() {
        let c = canvas
        let meta = spec.meta
        let size = c.size
        let ink = hex(0x111111)
        c.fill(c.bounds, hex(0xF5F5F5))
        // Toolbar.
        c.fill(CGRect(x: 0, y: 0, width: size.width, height: 48), hex(0x2C2C2C))
        c.trafficLights(14, 18)
        for (index, name) in ["cursorarrow", "number", "square", "pencil", "textformat", "bubble.left"].enumerated() {
            let x = 100 + CGFloat(index) * 44
            if index == 0 { c.round(CGRect(x: x - 8, y: 8, width: 36, height: 32), 6, hex(0x0D99FF)) }
            c.symbol(name, CGRect(x: x, y: 15, width: 20, height: 18), .white)
        }
        let file = meta["file"]?.text ?? spec.title
        c.text("Pebblewick  /  ", size.width / 2 - 120, 15, Face.ui(13), hex(0xB3B3B3))
        c.text(file, size.width / 2 - 120 + Canvas.width("Pebblewick  /  ", Face.ui(13)), 15, Face.ui(13, .semibold), .white)
        c.avatar("Theo Brandt", CGRect(x: size.width - 260, y: 12, width: 24, height: 24), avatarColor("Theo Brandt"),
                 font: Face.ui(10, .semibold))
        c.avatar("Ren Alder", CGRect(x: size.width - 240, y: 12, width: 24, height: 24), hex(0x2E9E8F), font: Face.ui(10, .semibold))
        c.round(CGRect(x: size.width - 196, y: 10, width: 70, height: 28), 6, hex(0x0D99FF))
        c.text("Share", size.width - 179, 15.5, Face.ui(13, .semibold), .white)
        c.symbol("play", CGRect(x: size.width - 108, y: 16, width: 14, height: 16), .white)
        c.text("100%", size.width - 76, 15, Face.ui(13), .white)
        // Layers.
        let left = CGRect(x: 0, y: 48, width: 240, height: size.height - 48)
        c.fill(left, .white)
        c.vline(left.maxX, left.minY, left.height, hex(0xE6E6E6))
        c.text("Pages", 16, 64, Face.ui(12, .semibold), ink)
        var y: CGFloat = 92
        for (index, pageName) in (meta["pages"]?.texts ?? []).enumerated() {
            if index == 0 { c.fill(CGRect(x: 0, y: y - 5, width: left.width, height: 26), hex(0xE5F4FF)) }
            c.text(pageName, 30, y, Face.ui(12.5), ink)
            y += 26
        }
        c.hline(0, y + 8, left.width, hex(0xE6E6E6))
        y += 24
        c.text("Layers", 16, y, Face.ui(12, .semibold), ink)
        y += 28
        let highlight = meta["highlight"]?.int ?? 1
        let plans = meta["plans"]?.rows ?? []
        let selectedLayer = plans.indices.contains(highlight) ? plans[highlight].first : nil
        for layer in meta["layers"]?.texts ?? [] {
            let isPlan = plans.contains { $0.first == layer }
            if layer == selectedLayer { c.fill(CGRect(x: 0, y: y - 5, width: left.width, height: 26), hex(0xE5F4FF)) }
            c.symbol(isPlan ? "square.dashed" : "number", CGRect(x: isPlan ? 36 : 18, y: y, width: 12, height: 12), hex(0x7A7A7A))
            c.text(layer, isPlan ? 56 : 38, y - 1, Face.ui(12.5), ink)
            y += 26
        }
        // Properties.
        let right = CGRect(x: size.width - 240, y: 48, width: 240, height: size.height - 48)
        c.fill(right, .white)
        c.vline(right.minX, right.minY, right.height, hex(0xE6E6E6))
        c.text("Design", right.minX + 16, 64, Face.ui(12, .semibold), ink)
        c.text("Prototype", right.minX + 76, 64, Face.ui(12), hex(0x7A7A7A))
        let fields = [("Frame", [("W", "296"), ("H", "400"), ("X", "448"), ("Y", "222")]),
                      ("Auto layout", [("Gap", "16"), ("Pad", "24")]),
                      ("Fill", [("", "F4F1FF")]), ("Stroke", [("", "6C4DF6 \u{00B7} 2")])]
        y = 100
        for (title, values) in fields {
            c.text(title, right.minX + 16, y, Face.ui(12, .semibold), ink)
            y += 24
            for (index, value) in values.enumerated() {
                let x = right.minX + 16 + CGFloat(index % 2) * 106
                if index % 2 == 0 && index > 0 { y += 32 }
                let field = CGRect(x: x, y: y, width: values.count == 1 ? 208 : 100, height: 26)
                c.round(field, 4, hex(0xF5F5F5))
                c.text(value.0.isEmpty ? value.1 : "\(value.0)  \(value.1)", field.minX + 8, field.minY + 5, Face.ui(12), ink)
            }
            y += 46
        }
        // The frame on the canvas.
        let frame = CGRect(x: left.maxX + 60, y: 112, width: right.minX - left.maxX - 120, height: 700)
        c.text("Pricing \u{00B7} Desktop", frame.minX, frame.minY - 22, Face.ui(12), hex(0x7A7A7A))
        c.fill(frame, .white)
        c.stroke(frame, 0, hex(0xE0E0E0))
        let purple = hex(0x6C4DF6)
        c.round(CGRect(x: frame.minX + 40, y: frame.minY + 32, width: 22, height: 22), 6, hex(0x2E9E8F))
        c.text("Pebblewick", frame.minX + 70, frame.minY + 32, Face.ui(17, .bold), ink)
        for (index, item) in ["Features", "Studios", "Pricing", "Log in"].enumerated() {
            c.text(item, frame.maxX - 330 + CGFloat(index) * 76, frame.minY + 35, Face.ui(13), hex(0x3D3D3D))
        }
        c.centered(meta["headline"]?.text ?? "", frame.minX, frame.width, frame.minY + 100, Face.ui(34, .bold), ink)
        let toggle = meta["toggle"]?.texts ?? ["Monthly", "Yearly"]
        let toggleRect = CGRect(x: frame.midX - 150, y: frame.minY + 160, width: 300, height: 36)
        c.round(toggleRect, 18, hex(0xF1EFF9))
        c.round(CGRect(x: toggleRect.midX, y: toggleRect.minY + 3, width: 147, height: 30), 15, .white)
        c.centered(toggle.first ?? "", toggleRect.minX, 150, toggleRect.minY + 9, Face.ui(13, .medium), hex(0x555555))
        c.centered(toggle.last ?? "", toggleRect.midX, 150, toggleRect.minY + 9, Face.ui(13, .semibold), purple)
        let cardWidth = (frame.width - 80 - 32) / 3
        for (index, plan) in plans.enumerated() where plan.count >= 4 {
            let x = frame.minX + 40 + CGFloat(index) * (cardWidth + 16)
            let isHighlight = index == highlight
            let card = CGRect(x: x, y: frame.minY + (isHighlight ? 222 : 236), width: cardWidth, height: isHighlight ? 400 : 372)
            c.round(card, 14, isHighlight ? hex(0xF4F1FF) : .white)
            c.stroke(card, 14, isHighlight ? purple : hex(0xE3E3E3), width: isHighlight ? 2 : 1)
            if isHighlight {
                let badge = CGRect(x: card.midX - 52, y: card.minY - 12, width: 104, height: 24)
                c.round(badge, 12, purple)
                c.centered("Most studios", badge.minX, badge.width, badge.minY + 4, Face.ui(12, .semibold), .white)
            }
            c.text(plan[0], x + 22, card.minY + 30, Face.ui(18, .semibold), ink)
            let priceWidth = c.text(plan[1], x + 22, card.minY + 62, Face.ui(34, .bold), ink)
            c.text(plan[2], x + 28 + priceWidth, card.minY + 80, Face.ui(13), hex(0x6B6B6B))
            c.paragraph(plan[3], CGRect(x: x + 22, y: card.minY + 124, width: cardWidth - 44, height: 60), Face.ui(13.5), hex(0x3D3D3D))
            let features = meta["features"]?.items.dropFirst(index).first?.texts ?? []
            for (row, feature) in features.enumerated() {
                let fy = card.minY + 180 + CGFloat(row) * 26
                c.symbol("checkmark", CGRect(x: x + 22, y: fy + 2, width: 12, height: 11), isHighlight ? purple : hex(0x3F8F5F),
                         weight: .bold)
                c.text(feature, x + 42, fy, Face.ui(13), hex(0x3D3D3D), maxWidth: cardWidth - 64)
            }
            let button = CGRect(x: x + 22, y: card.maxY - 66, width: cardWidth - 44, height: 38)
            c.round(button, 9, isHighlight ? purple : hex(0xF1EFF9))
            c.centered(isHighlight ? "Start free" : "Choose \(plan[0])", button.minX, button.width, button.minY + 10,
                       Face.ui(14, .semibold), isHighlight ? .white : purple)
            if isHighlight {
                // Selected on the canvas.
                c.stroke(card.insetBy(dx: -6, dy: -6), 4, hex(0x0D99FF), width: 1.5)
                for corner in [CGPoint(x: card.minX - 6, y: card.minY - 6), CGPoint(x: card.maxX + 6, y: card.minY - 6),
                               CGPoint(x: card.minX - 6, y: card.maxY + 6), CGPoint(x: card.maxX + 6, y: card.maxY + 6)] {
                    c.fill(CGRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8), .white)
                    c.stroke(CGRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8), 0, hex(0x0D99FF), width: 1.5)
                }
                let size = CGRect(x: card.midX - 34, y: card.maxY + 12, width: 68, height: 20)
                c.round(size, 4, hex(0x0D99FF))
                c.centered("296 \u{00D7} 400", size.minX, size.width, size.minY + 3, Face.ui(11, .medium), .white)
            }
        }
        c.centered("Start free for 14 days. No card needed.", frame.minX, frame.width, frame.maxY - 34, Face.ui(13), hex(0x6B6B6B))
    }
}

/// Calendar, in week view: the week's meetings, and the time now.
@MainActor
struct CalendarScreen {
    let spec: DemoScreenSpec
    let canvas: Canvas

    func draw() {
        let c = canvas
        let meta = spec.meta
        let size = c.size
        let ink = hex(0x1D1D1F)
        c.fill(c.bounds, .white)
        // Toolbar.
        c.fill(CGRect(x: 0, y: 0, width: size.width, height: 52), hex(0xF6F6F6))
        c.hline(0, 52, size.width, hex(0xDCDCDC))
        c.trafficLights(16, 20)
        c.symbol("sidebar.left", CGRect(x: 92, y: 18, width: 20, height: 16), hex(0x6E6E73))
        c.symbol("plus", CGRect(x: 132, y: 18, width: 16, height: 16), hex(0x6E6E73))
        let segments = ["Day", "Week", "Month", "Year"]
        let segment = CGRect(x: size.width / 2 - 140, y: 13, width: 280, height: 26)
        c.round(segment, 7, hex(0xE3E3E3))
        for (index, name) in segments.enumerated() {
            let rect = CGRect(x: segment.minX + 2 + CGFloat(index) * 69, y: segment.minY + 2, width: 68, height: 22)
            if name == "Week" { c.round(rect, 6, .white) }
            c.centered(name, rect.minX, rect.width, rect.minY + 3, Face.ui(13, name == "Week" ? .semibold : .regular), ink)
        }
        let search = CGRect(x: size.width - 220, y: 13, width: 200, height: 26)
        c.round(search, 7, hex(0xE3E3E3))
        c.symbol("magnifyingglass", CGRect(x: search.minX + 10, y: search.minY + 6, width: 13, height: 13), hex(0x8E8E93))
        c.text("Search", search.minX + 30, search.minY + 5, Face.ui(13), hex(0x8E8E93))
        // The month and the days.
        c.text(meta["month_label"]?.text ?? "", 24, 70, Face.ui(28, .bold), ink)
        let todayLabel = CGRect(x: size.width - 172, y: 74, width: 64, height: 26)
        c.round(todayLabel, 6, hex(0xEFEFEF))
        c.centered("Today", todayLabel.minX, todayLabel.width, todayLabel.minY + 5, Face.ui(13), ink)
        c.symbol("chevron.left", CGRect(x: size.width - 98, y: 80, width: 10, height: 14), hex(0x6E6E73))
        c.symbol("chevron.right", CGRect(x: size.width - 66, y: 80, width: 10, height: 14), hex(0x6E6E73))
        let gutter: CGFloat = 70
        let gridTop: CGFloat = 158
        let dayWidth = (size.width - gutter - 10) / 7
        var todayIndex: Int?
        for (index, day) in (meta["days"]?.items ?? []).enumerated() {
            let label = day.items.first?.text ?? ""
            let isToday = day.items.dropFirst().first?.bool ?? false
            let x = gutter + CGFloat(index) * dayWidth
            let parts = label.split(separator: " ").map(String.init)
            let name = parts.first ?? label
            let number = parts.dropFirst().first ?? ""
            let nameWidth = c.text(name, x + 8, 124, Face.ui(15), isToday ? hex(0xFF3B30) : hex(0x6E6E73))
            if isToday {
                todayIndex = index
                let numberWidth = Canvas.width(number, Face.ui(15, .semibold))
                c.circle(CGPoint(x: x + 22 + nameWidth + numberWidth / 2, y: 133), max(13, numberWidth / 2 + 6), hex(0xFF3B30))
                c.text(number, x + 22 + nameWidth, 124, Face.ui(15, .semibold), .white)
            } else {
                c.text(number, x + 14 + nameWidth, 124, Face.ui(15), ink)
            }
            c.vline(x, 150, size.height - 150, hex(0xE5E5E5))
        }
        c.hline(0, 150, size.width, hex(0xDCDCDC))
        // Hours, 8 AM to 6 PM.
        let firstHour = 8
        let hourHeight = (size.height - gridTop - 20) / 10.5
        for hour in firstHour...18 {
            let y = gridTop + CGFloat(hour - firstHour) * hourHeight
            let label = hour == 12 ? "Noon" : "\(hour > 12 ? hour - 12 : hour) \(hour >= 12 ? "PM" : "AM")"
            c.textRight(label, gutter - 10, y - 8, Face.ui(12), hex(0x8E8E93))
            c.hline(gutter, y, size.width - gutter, hex(0xEBEBEB))
        }
        func yFor(_ minutes: Int) -> CGFloat {
            gridTop + CGFloat(minutes - firstHour * 60) / 60 * hourHeight
        }
        for event in meta["events"]?.items ?? [] {
            let values = event.items
            guard values.count >= 4, let day = values[0].int, let start = values[1].int, let end = values[2].int,
                  start >= firstHour * 60, end <= 19 * 60 else { continue }
            let title = values[3].text ?? ""
            let location = values.count > 4 ? values[4].text : nil
            let rect = CGRect(x: gutter + CGFloat(day) * dayWidth + 3, y: yFor(start) + 1, width: dayWidth - 8,
                              height: max(yFor(end) - yFor(start) - 2, 20))
            c.round(rect, 5, hex(0x1D7AF2, alpha: 0.16))
            c.fill(CGRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height), hex(0x1D7AF2))
            c.text(title, rect.minX + 9, rect.minY + 4, Face.ui(12.5, .semibold), hex(0x0B4F9E), maxWidth: rect.width - 14)
            if rect.height > 36 {
                let line = location.map { "\(Self.clock(start)) \u{00B7} \($0)" } ?? Self.clock(start)
                c.text(line, rect.minX + 9, rect.minY + 21, Face.ui(11.5), hex(0x1D7AF2), maxWidth: rect.width - 14)
            }
        }
        // Now.
        if let todayIndex, let now = meta["now_minutes"]?.int, now >= firstHour * 60, now <= 18 * 60 + 30 {
            let y = yFor(now)
            let x = gutter + CGFloat(todayIndex) * dayWidth
            c.circle(CGPoint(x: x, y: y), 5, hex(0xFF3B30))
            c.hline(x, y - 1, dayWidth, hex(0xFF3B30), thickness: 2)
        }
    }

    static func clock(_ minutes: Int) -> String {
        let hour = minutes / 60
        let shown = hour % 12 == 0 ? 12 : hour % 12
        return "\(shown):\(String(format: "%02d", minutes % 60)) \(hour < 12 ? "AM" : "PM")"
    }
}
