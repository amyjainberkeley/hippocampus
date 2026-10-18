// The hi mark at the top of the window's sidebar (RULINGS W10, B3). The window
// shares no module with the menu-bar app, so the path data is a copy of
// `apps/hippocampus/Sources/HippocampusKit/Brand/HiMarkGeometry.swift`;
// `WindowHiMarkTests` holds the copy to that file.

import CoreGraphics
import SwiftUI

public enum WindowHiMark {
    /// The h: stem, then the arch. Fill with the non-zero rule.
    public static let hSVGPath = "M1.5 0H14Q15.5 0 15.5 1.5V98.5Q15.5 100 14 100H1.5Q0 100 0 98.5V1.5Q0 0 1.5 0ZM12.5 44L15.5 40C21 33.2 27.25 28 38.75 28C50.84 28 62 37.87 62 51.5V98.5Q62 100 60.5 100H48.7Q47.2 100 47.2 98.5V52.4C47.2 44.4 41.85 40.4 33.25 40.4C24.25 40.4 18.1 43 15.5 50.5L12.5 54.5Z"

    /// The stem of the i.
    public static let iStemSVGPath = "M77 29.2H89.5Q91 29.2 91 30.7V98.5Q91 100 89.5 100H77Q75.5 100 75.5 98.5V30.7Q75.5 29.2 77 29.2Z"

    /// The i's dot.
    public static let dotCenter = CGPoint(x: 83.25, y: 7.96)
    public static let dotRadius: CGFloat = 10.08

    /// The box the mark is centered in: the letters and the solid dot.
    public static let inkBounds = CGRect(x: 0, y: -2.12, width: 93.33, height: 102.12)

    /// Letters navy, dot blue (RULINGS G2).
    public static let lettersRGB: UInt32 = 0x0F1B3D
    public static let dotRGB: UInt32 = 0x2F6BFF
    /// The icon's tile, top to bottom: the Lab colours.
    public static let tileTopRGB: UInt32 = 0xFFFFFF
    public static let tileBottomRGB: UInt32 = 0xE9EEF6

    /// Parses SVG path data with absolute M, L, H, V, C, Q and Z commands, one
    /// set of numbers each, as the app's parser does. Nil for anything else.
    public static func path(svg data: String) -> CGPath? {
        var commands: [(letter: Character, numbers: [CGFloat])] = []
        var token = ""
        func flush() -> Bool {
            guard !token.isEmpty else { return true }
            guard let value = Double(token), !commands.isEmpty else { return false }
            commands[commands.count - 1].numbers.append(CGFloat(value))
            token = ""
            return true
        }
        for character in data {
            switch character {
            case "M", "L", "H", "V", "C", "Q", "Z":
                guard flush() else { return nil }
                commands.append((character, []))
            case "0"..."9", ".":
                token.append(character)
            case "-":
                guard flush() else { return nil }
                token = "-"
            case " ", ",", "\n", "\t":
                guard flush() else { return nil }
            default:
                return nil
            }
        }
        guard flush(), commands.first?.letter == "M" else { return nil }

        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        for (letter, n) in commands {
            let expected: Int
            switch letter {
            case "M", "L": expected = 2
            case "H", "V": expected = 1
            case "C": expected = 6
            case "Q": expected = 4
            default: expected = 0
            }
            guard n.count == expected else { return nil }
            switch letter {
            case "M":
                current = CGPoint(x: n[0], y: n[1])
                start = current
                path.move(to: current)
            case "L":
                current = CGPoint(x: n[0], y: n[1])
                path.addLine(to: current)
            case "H":
                current.x = n[0]
                path.addLine(to: current)
            case "V":
                current.y = n[0]
                path.addLine(to: current)
            case "C":
                current = CGPoint(x: n[4], y: n[5])
                path.addCurve(to: current, control1: CGPoint(x: n[0], y: n[1]), control2: CGPoint(x: n[2], y: n[3]))
            case "Q":
                current = CGPoint(x: n[2], y: n[3])
                path.addQuadCurve(to: current, control: CGPoint(x: n[0], y: n[1]))
            default:
                path.closeSubpath()
                current = start
            }
        }
        return path
    }

    static func color(_ rgb: UInt32) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255)
    }
}

/// The hi mark, letters in the primary colour and the dot blue while
/// Hippocampus is remembering; with `remembering` false the dot goes and the
/// letters dim, as the menu bar's off picture does (RULINGS B1, B3).
public struct WindowHiMarkView: View {
    public let remembering: Bool

    public init(remembering: Bool = true) {
        self.remembering = remembering
    }

    public var body: some View {
        ZStack {
            WindowHiMarkShape(part: .letters)
                .fill(Color.primary.opacity(remembering ? 1 : 0.55))
            if remembering {
                WindowHiMarkShape(part: .dot).fill(WindowHiMark.color(WindowHiMark.dotRGB))
            }
        }
        .aspectRatio(WindowHiMark.inkBounds.width / WindowHiMark.inkBounds.height, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The hi mark on its tile, as the app's icon draws it (`AppIcon.svg`): the
/// Lab colours, tile #FFFFFF to #E9EEF6, letters #0F1B3D, dot #2F6BFF, a
/// hairline edge and continuous corners. An icon, so the same in dark mode.
/// The dot means remembering, as everywhere: with `remembering` false it
/// goes and the letters dim, as the menu bar's off picture does (RULINGS B1).
public struct HiTileView: View {
    public let size: CGFloat
    public let remembering: Bool

    public init(size: CGFloat, remembering: Bool = true) {
        self.size = size
        self.remembering = remembering
    }

    public var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        ZStack {
            tile.fill(LinearGradient(colors: [WindowHiMark.color(WindowHiMark.tileTopRGB),
                                              WindowHiMark.color(WindowHiMark.tileBottomRGB)],
                                     startPoint: .top, endPoint: .bottom))
            tile.strokeBorder(Color.black.opacity(0.1), lineWidth: max(0.5, size * 0.006))
            ZStack {
                WindowHiMarkShape(part: .letters)
                    .fill(WindowHiMark.color(WindowHiMark.lettersRGB).opacity(remembering ? 1 : 0.55))
                if remembering {
                    WindowHiMarkShape(part: .dot).fill(WindowHiMark.color(WindowHiMark.dotRGB))
                }
            }
            // The icon's proportions: the mark is 58% of the tile wide.
            .frame(width: size * 0.58, height: size * 0.635)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One part of the mark, with `inkBounds` fitted into the frame and centred,
/// so the letters never move when the dot comes and goes.
struct WindowHiMarkShape: Shape {
    enum Part { case letters, dot }
    let part: Part

    func path(in rect: CGRect) -> Path {
        let box = WindowHiMark.inkBounds
        let scale = min(rect.width / box.width, rect.height / box.height)
        var transform = CGAffineTransform(
            translationX: rect.midX - box.midX * scale,
            y: rect.midY - box.midY * scale
        ).scaledBy(x: scale, y: scale)
        let source: CGPath
        switch part {
        case .letters:
            let letters = CGMutablePath()
            for data in [WindowHiMark.hSVGPath, WindowHiMark.iStemSVGPath] {
                if let path = WindowHiMark.path(svg: data) { letters.addPath(path) }
            }
            source = letters
        case .dot:
            let r = WindowHiMark.dotRadius
            let c = WindowHiMark.dotCenter
            source = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
        }
        return Path(source.copy(using: &transform) ?? source)
    }
}
