// SPDX-License-Identifier: Apache-2.0
//
// CodeScreens.swift — VS Code with a TypeScript file open, and Terminal.

import AppKit

/// VS Code in its dark theme: the file, its project's files, the tabs and
/// the status bar.
@MainActor
struct EditorScreen {
    let spec: DemoScreenSpec
    let canvas: Canvas

    private var meta: DemoJSON { spec.meta }

    func draw() {
        let c = canvas
        let size = c.size
        c.fill(c.bounds, hex(0x1F1F1F))
        // Title bar, with the command center.
        c.fill(CGRect(x: 0, y: 0, width: size.width, height: 35), hex(0x181818))
        c.hline(0, 35, size.width, hex(0x2B2B2B))
        c.trafficLights(13, 11)
        let center = CGRect(x: size.width / 2 - 230, y: 6, width: 460, height: 23)
        c.round(center, 6, hex(0x2A2A2A))
        c.stroke(center, 6, hex(0x3C3C3C))
        c.symbol("magnifyingglass", CGRect(x: center.minX + 150, y: 11, width: 13, height: 13), hex(0x9D9D9D))
        let project = meta["project"]?.text ?? "project"
        c.text(project, center.minX + 170, 9.5, Face.ui(12.5), hex(0xCCCCCC))
        for (index, name) in ["sidebar.left", "rectangle.split.2x1", "sidebar.right"].enumerated() {
            c.symbol(name, CGRect(x: size.width - 92 + CGFloat(index) * 26, y: 10, width: 16, height: 15), hex(0xA0A0A0))
        }
        // Activity bar.
        let bodyTop: CGFloat = 36
        let statusTop = size.height - 22
        c.fill(CGRect(x: 0, y: bodyTop, width: 48, height: statusTop - bodyTop), hex(0x181818))
        c.vline(48, bodyTop, statusTop - bodyTop, hex(0x2B2B2B))
        let activity = ["doc.on.doc", "magnifyingglass", "arrow.triangle.branch", "play", "square.grid.2x2"]
        for (index, name) in activity.enumerated() {
            let y = bodyTop + 12 + CGFloat(index) * 48
            c.symbol(name, CGRect(x: 12, y: y, width: 24, height: 24), index == 0 ? hex(0xD7D7D7) : hex(0x868686))
            if index == 0 { c.fill(CGRect(x: 0, y: y - 6, width: 2, height: 36), hex(0x0078D4)) }
        }
        c.symbol("person.crop.circle", CGRect(x: 12, y: statusTop - 88, width: 24, height: 24), hex(0x868686))
        c.symbol("gearshape", CGRect(x: 12, y: statusTop - 44, width: 24, height: 24), hex(0x868686))
        drawExplorer(top: bodyTop, bottom: statusTop)
        drawTabs(top: bodyTop)
        drawCode(top: bodyTop + 58, bottom: statusTop)
        drawStatusBar(top: statusTop)
    }

    private func drawExplorer(top: CGFloat, bottom: CGFloat) {
        let c = canvas
        let left: CGFloat = 49
        let width: CGFloat = 251
        c.fill(CGRect(x: left, y: top, width: width, height: bottom - top), hex(0x181818))
        c.vline(left + width, top, bottom - top, hex(0x2B2B2B))
        c.text("EXPLORER", left + 20, top + 12, Face.ui(11, .medium), hex(0xCCCCCC), kern: 0.4)
        c.text("\u{2219}\u{2219}\u{2219}", left + width - 34, top + 8, Face.ui(14, .bold), hex(0x9D9D9D))
        let project = (meta["project"]?.text ?? "project").uppercased()
        c.text("\u{2304}", left + 10, top + 33, Face.ui(13, .semibold), hex(0xCCCCCC))
        c.text(project, left + 26, top + 38, Face.ui(11, .bold), hex(0xCCCCCC), kern: 0.3)
        let file = meta["file"]?.text ?? ""
        var y = top + 62
        for entry in meta["tree"]?.texts ?? [] {
            let isFolder = entry.hasPrefix("\u{25BE}") || entry.hasPrefix("\u{25B8}")
            let name = isFolder ? String(entry.dropFirst(2)) : entry
            let depth: CGFloat = isFolder ? 0 : (name.contains(".ts") ? 1 : 0)
            let x = left + 18 + depth * 16
            if name == file {
                c.fill(CGRect(x: left, y: y - 3, width: width, height: 22), hex(0x37373D))
                c.stroke(CGRect(x: left, y: y - 3, width: width, height: 22), 0, hex(0x0078D4))
            }
            if isFolder {
                c.text(entry.hasPrefix("\u{25BE}") ? "\u{2304}" : "\u{203A}", x - 4, y - 3,
                       Face.ui(13, .semibold), hex(0xCCCCCC))
                c.text(name, x + 12, y, Face.ui(13), hex(0xCCCCCC))
            } else {
                fileIcon(name, x + 6, y + 1)
                c.text(name, x + 26, y, Face.ui(13), name == file ? hex(0xFFFFFF) : hex(0xCCCCCC))
            }
            y += 22
        }
        for (index, section) in ["OUTLINE", "TIMELINE"].enumerated() {
            let sy = bottom - 54 + CGFloat(index) * 24
            c.hline(left, sy - 4, width, hex(0x2B2B2B))
            c.text("\u{203A}", left + 10, sy - 1, Face.ui(13, .semibold), hex(0xCCCCCC))
            c.text(section, left + 24, sy + 2, Face.ui(11, .bold), hex(0xCCCCCC), kern: 0.3)
        }
    }

    private func fileIcon(_ name: String, _ x: CGFloat, _ y: CGFloat) {
        let c = canvas
        if name.hasSuffix(".ts") {
            c.text("TS", x - 2, y + 1, Face.ui(9.5, .heavy), hex(0x3178C6))
        } else if name.hasSuffix(".json") {
            c.text("{}", x - 1, y - 1, Face.mono(12, .bold), hex(0xCBCB41))
        } else if name.hasSuffix(".md") {
            c.symbol("info.circle.fill", CGRect(x: x - 1, y: y, width: 13, height: 13), hex(0x519ABA))
        } else {
            c.symbol("doc", CGRect(x: x - 1, y: y, width: 12, height: 13), hex(0x9D9D9D))
        }
    }

    private func drawTabs(top: CGFloat) {
        let c = canvas
        let left: CGFloat = 301
        c.fill(CGRect(x: left, y: top, width: c.size.width - left, height: 35), hex(0x181818))
        c.hline(left, top + 35, c.size.width - left, hex(0x2B2B2B))
        let tabs = meta["tabs"]?.texts ?? []
        let active = meta["active_tab"]?.int ?? 0
        var x = left
        for (index, tab) in tabs.enumerated() {
            let width = Canvas.width(tab, Face.ui(13)) + 62
            let rect = CGRect(x: x, y: top, width: width, height: 35)
            if index == active {
                c.fill(rect, hex(0x1F1F1F))
                c.fill(CGRect(x: x, y: top, width: width, height: 1.5), hex(0x0078D4))
            }
            c.vline(x + width, top, 35, hex(0x2B2B2B))
            fileIcon(tab, x + 14, top + 11)
            c.text(tab, x + 34, top + 9.5, Face.ui(13), index == active ? hex(0xFFFFFF) : hex(0x9D9D9D))
            if index == active { c.text("\u{00D7}", x + width - 22, top + 7, Face.ui(15), hex(0xCCCCCC)) }
            x += width
        }
        // The path above the code.
        let file = meta["file"]?.text ?? ""
        let function = spec.mainLines.first { $0.contains("function ") }
            .flatMap { $0.components(separatedBy: "function ").last?.components(separatedBy: "(").first }
        let crumbs = ["src", file] + (function.map { [$0] } ?? [])
        var cx = left + 20
        for (index, crumb) in crumbs.enumerated() {
            cx += c.text(crumb, cx, top + 42, Face.ui(12), hex(0xA9A9A9))
            if index < crumbs.count - 1 {
                cx += c.text("  \u{203A}  ", cx, top + 41, Face.ui(12), hex(0x7A7A7A))
            }
        }
    }

    private func drawCode(top: CGFloat, bottom: CGFloat) {
        let c = canvas
        let left: CGFloat = 301
        let font = Face.mono(13.5)
        let cursor = meta["cursor_line"]?.int ?? 0
        let lineHeight: CGFloat = 21
        let lines = spec.mainLines
        for (index, line) in lines.enumerated() {
            let y = top + 8 + CGFloat(index) * lineHeight
            guard y + lineHeight < bottom - 10 else { break }
            let number = index + 1
            if number == cursor {
                c.fill(CGRect(x: left, y: y - 2, width: c.size.width - left - 100, height: lineHeight), hex(0x2A2D2E))
                c.stroke(CGRect(x: left, y: y - 2, width: c.size.width - left - 100, height: lineHeight), 0, hex(0x282828))
            }
            c.textRight("\(number)", left + 58, y, font, number == cursor ? hex(0xCCCCCC) : hex(0x6E7681))
            c.draw(TypeScriptColors.line(line, font: font), left + 80, y)
            if number == cursor {
                let caret = left + 80 + Canvas.width(String(line.prefix(22)), font)
                c.fill(CGRect(x: caret, y: y, width: 2, height: 18), hex(0xAEAFAD))
            }
        }
        // The minimap.
        let mapLeft = c.size.width - 96
        for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let indent = CGFloat(line.prefix { $0 == " " }.count) * 1.4
            let length = min(CGFloat(line.count) * 1.3, 70)
            c.fill(CGRect(x: mapLeft + indent, y: top + 6 + CGFloat(index) * 4, width: length - indent, height: 2),
                   index + 1 == cursor ? hex(0x4B6FA5) : hex(0x505050))
        }
        c.fill(CGRect(x: mapLeft - 4, y: top, width: 84, height: CGFloat(lines.count) * 4 + 12), hex(0xFFFFFF, alpha: 0.04))
    }

    private func drawStatusBar(top: CGFloat) {
        let c = canvas
        c.fill(CGRect(x: 0, y: top, width: c.size.width, height: 22), hex(0x007ACC))
        c.fill(CGRect(x: 0, y: top, width: 36, height: 22), hex(0x16825D))
        c.symbol("chevron.left.forwardslash.chevron.right", CGRect(x: 10, y: top + 5, width: 16, height: 12), .white)
        let branch = meta["branch"]?.text ?? "main"
        c.symbol("arrow.triangle.branch", CGRect(x: 46, y: top + 4, width: 13, height: 14), .white)
        var x: CGFloat = 64
        x += c.text(branch, x, top + 3.5, Face.ui(12), .white) + 14
        c.symbol("xmark.circle", CGRect(x: x, y: top + 5, width: 12, height: 12), .white)
        c.text("0", x + 16, top + 3.5, Face.ui(12), .white)
        c.symbol("exclamationmark.triangle", CGRect(x: x + 32, y: top + 5, width: 13, height: 12), .white)
        c.text("0", x + 49, top + 3.5, Face.ui(12), .white)
        let cursor = meta["cursor_line"]?.int ?? 1
        let language = meta["language"]?.text ?? "TypeScript"
        let right = "Ln \(cursor), Col 23    Spaces: 2    UTF-8    LF    {}  \(language)"
        c.textRight(right, c.size.width - 40, top + 3.5, Face.ui(12), .white)
        c.symbol("bell", CGRect(x: c.size.width - 28, y: top + 4, width: 13, height: 14), .white)
    }
}

/// TypeScript in VS Code's dark colours.
enum TypeScriptColors {
    private static let control: Set<String> = ["import", "export", "from", "return", "await", "if", "else", "as",
                                                "for", "of", "throw", "try", "catch"]
    private static let keywords: Set<String> = ["const", "let", "var", "function", "async", "new", "type",
                                                 "interface", "true", "false", "null", "undefined", "typeof",
                                                 "class", "extends", "this"]

    static func line(_ line: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func add(_ text: String, _ color: UInt32) {
            result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: hex(color)]))
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") {
            add(line, 0x6A9955)
            return result
        }
        var word = ""
        var string: Character?
        var buffer = ""
        let characters = Array(line)
        func flush(next: Character?) {
            guard !word.isEmpty else { return }
            let color: UInt32 = if control.contains(word) {
                0xC586C0
            } else if keywords.contains(word) {
                0x569CD6
            } else if word.first?.isNumber == true {
                0xB5CEA8
            } else if next == "(" {
                0xDCDCAA
            } else if word.first?.isUppercase == true {
                0x4EC9B0
            } else {
                0x9CDCFE
            }
            add(word, color)
            word = ""
        }
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let quote = string {
                buffer.append(character)
                if character == quote {
                    add(buffer, 0xCE9178)
                    buffer = ""
                    string = nil
                }
            } else if character == "\"" || character == "'" || character == "`" {
                flush(next: character)
                string = character
                buffer = String(character)
            } else if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                flush(next: nil)
                add(String(characters[index...]), 0x6A9955)
                return result
            } else if character.isLetter || character.isNumber || character == "_" || character == "$" {
                word.append(character)
            } else {
                flush(next: character)
                let punctuation: UInt32 = "{}()[]".contains(character) ? 0xFFD700 : 0xD4D4D4
                add(String(character), "{}".contains(character) ? 0xDA70D6 : punctuation)
            }
            index += 1
        }
        flush(next: nil)
        if !buffer.isEmpty { add(buffer, 0xCE9178) }
        return result
    }
}

/// Terminal in a dark profile: the commands and what they printed.
@MainActor
struct TerminalScreen {
    let spec: DemoScreenSpec
    let canvas: Canvas

    func draw() {
        let c = canvas
        let size = c.size
        c.fill(c.bounds, hex(0x1C1C1E))
        c.fill(CGRect(x: 0, y: 0, width: size.width, height: 28), hex(0x2C2C2E))
        c.hline(0, 28, size.width, hex(0x000000))
        c.trafficLights(12, 8)
        c.centered(spec.title, 0, size.width, 6, Face.ui(13, .medium), hex(0xA1A1A6))
        let prompt = spec.meta["prompt"]?.text ?? "% "
        let font = Face.mono(14)
        let lines = spec.mainLines
        for (index, line) in lines.enumerated() {
            let y = 42 + CGFloat(index) * 21
            var x: CGFloat = 14
            if line.hasPrefix(prompt) || line == prompt.trimmingCharacters(in: .whitespaces) {
                x += c.text(prompt, x, y, font, hex(0x64D2FF))
                let command = line.count > prompt.count ? String(line.dropFirst(prompt.count)) : ""
                x += c.text(command, x, y, font, hex(0xF2F2F7))
                if index == lines.count - 1 {
                    c.fill(CGRect(x: x + 1, y: y + 1, width: 9, height: 18), hex(0xE5E5E7))
                }
                continue
            }
            c.text(line, x, y, font, color(of: line))
        }
    }

    private func color(of line: String) -> NSColor {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\u{2713}") || trimmed.contains("passed") && !trimmed.contains("failed") {
            return hex(0x32D74B)
        }
        if trimmed.hasPrefix("\u{00D7}") || trimmed.hasPrefix("\u{2192}") || trimmed.contains("failed") {
            return hex(0xFF6961)
        }
        if trimmed.hasPrefix("RUN") || trimmed.hasPrefix("\u{276F}") { return hex(0x64D2FF) }
        if trimmed.hasPrefix("*") || trimmed.hasPrefix("To ") { return hex(0xC7C7CC) }
        return hex(0xE5E5E7)
    }
}
