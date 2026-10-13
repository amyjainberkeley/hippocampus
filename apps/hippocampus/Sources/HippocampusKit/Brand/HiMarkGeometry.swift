// SPDX-License-Identifier: TBD-private
//
// The hi mark: a lowercase h and i side by side. One geometry serves the
// menu bar, Ask, and the asset generator in scripts/brand. Units: the
// ascender top is y = 0 and the baseline y = 100, with y growing downward.

import CoreGraphics

public enum HiMark {

    /// The four pictures the mark can show.
    public enum State: CaseIterable, Sendable {
        /// hi with a solid dot: remembering, or about to.
        case remembering
        /// hi with a hollow dot: on, but skipping this window.
        case skipping
        /// h and a dotless i, dimmed: paused or off.
        case off
        /// h!: something needs the person.
        case needsYou
    }

    /// The shapes a picture is built from.
    public enum Part: CaseIterable, Sendable {
        case h, iStem, dot, ring, bangStem, bangDot
    }

    /// What each picture draws. Only `.off` dims its letters.
    public static func parts(for state: State) -> [Part] {
        switch state {
        case .remembering: return [.h, .iStem, .dot]
        case .skipping: return [.h, .iStem, .ring]
        case .off: return [.h, .iStem]
        case .needsYou: return [.h, .bangStem, .bangDot]
        }
    }

    /// Letter opacity for a picture.
    public static func letterStrength(for state: State) -> CGFloat {
        state == .off ? 0.55 : 1
    }

    // MARK: - Geometry

    /// The h: stem, then the arch. The arch overlaps the stem between
    /// x = 12.5 and 15.5, so fill with the non-zero rule.
    public static let hSVGPath = "M1.5 0H14Q15.5 0 15.5 1.5V98.5Q15.5 100 14 100H1.5Q0 100 0 98.5V1.5Q0 0 1.5 0ZM12.5 44L15.5 40C21 33.2 27.25 28 38.75 28C50.84 28 62 37.87 62 51.5V98.5Q62 100 60.5 100H48.7Q47.2 100 47.2 98.5V52.4C47.2 44.4 41.85 40.4 33.25 40.4C24.25 40.4 18.1 43 15.5 50.5L12.5 54.5Z"

    /// The stem of the i, from just above the x-height to the baseline.
    public static let iStemSVGPath = "M77 29.2H89.5Q91 29.2 91 30.7V98.5Q91 100 89.5 100H77Q75.5 100 75.5 98.5V30.7Q75.5 29.2 77 29.2Z"

    /// The stem of the "!": the i mirrored top to bottom about y = 50.
    public static let bangStemSVGPath = "M77 0H89.5Q91 0 91 1.5V69.3Q91 70.8 89.5 70.8H77Q75.5 70.8 75.5 69.3V1.5Q75.5 0 77 0Z"

    /// The h and the i stem, as the SVG files carry them.
    public static var lettersSVGPath: String { hSVGPath + iStemSVGPath }

    /// Stem width; the h stem, the i and the "!" share it.
    public static let stemWidth: CGFloat = 15.5
    /// Left edge of the i stem and of the "!" stem.
    public static let iStemLeft: CGFloat = 75.5
    public static let baseline: CGFloat = 100

    /// The i's dot: 1.3 stems wide, 0.72 stems above the i.
    public static let dotCenter = CGPoint(x: 83.25, y: 7.96)
    public static let dotRadius: CGFloat = 10.08

    /// The hollow dot: its bottom rests where the solid dot's does.
    public static let ringCenter = CGPoint(x: 83.25, y: 4.48)
    public static let ringOuterRadius: CGFloat = 13.565
    public static let ringInnerRadius: CGFloat = 5.815

    /// The "!" dot, below its stem.
    public static let bangDotCenter = CGPoint(x: 83.25, y: 92.04)

    /// The box the mark is centered in: the letters and the solid dot.
    public static let inkBounds = CGRect(x: 0, y: -2.12, width: 93.33, height: 102.12)

    // MARK: - Colors (sRGB, 0xRRGGBB)

    public static let tileTopRGB: UInt32 = 0xFFFFFF
    public static let tileBottomRGB: UInt32 = 0xE9EEF6
    public static let lettersRGB: UInt32 = 0x0F1B3D
    public static let dotRGB: UInt32 = 0x2F6BFF

    /// Red, green and blue of a 0xRRGGBB color, each 0 to 1.
    public static func components(_ rgb: UInt32) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        (CGFloat((rgb >> 16) & 0xFF) / 255, CGFloat((rgb >> 8) & 0xFF) / 255, CGFloat(rgb & 0xFF) / 255)
    }

    // MARK: - App icon, on Apple's 1024 grid

    /// The tile: an 824 squircle at (100, 100), corner 184.3.
    public static let tileSVGPath = "M284.3 100H739.7C866.9 100 924 157.1 924 284.3V739.7C924 866.9 866.9 924 739.7 924H284.3C157.1 924 100 866.9 100 739.7V284.3C100 157.1 157.1 100 284.3 100Z"
    public static let iconTileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    /// Where the mark sits on the 1024 canvas: 56% of the tile wide, 62% tall.
    public static let iconMarkOrigin = CGPoint(x: 281.28, y: 258.46)
    public static let iconMarkScale: CGFloat = 5.1088

    // MARK: - Paths

    public static func letters() -> CGPath { parsed(lettersSVGPath) }
    public static func hOnly() -> CGPath { parsed(hSVGPath) }
    public static func iStem() -> CGPath { parsed(iStemSVGPath) }
    public static func bangStem() -> CGPath { parsed(bangStemSVGPath) }
    public static func dot() -> CGPath { circle(dotCenter, dotRadius) }
    public static func bangDot() -> CGPath { circle(bangDotCenter, dotRadius) }

    /// The hollow dot as one fillable shape: the inner circle runs the other
    /// way, so the non-zero rule leaves it empty.
    public static func ring() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: ringCenter.x + ringOuterRadius, y: ringCenter.y))
        path.addRelativeArc(center: ringCenter, radius: ringOuterRadius, startAngle: 0, delta: 2 * .pi)
        path.closeSubpath()
        path.move(to: CGPoint(x: ringCenter.x + ringInnerRadius, y: ringCenter.y))
        path.addRelativeArc(center: ringCenter, radius: ringInnerRadius, startAngle: 0, delta: -2 * .pi)
        path.closeSubpath()
        return path
    }

    public static func path(for part: Part) -> CGPath {
        switch part {
        case .h: return hOnly()
        case .iStem: return iStem()
        case .dot: return dot()
        case .ring: return ring()
        case .bangStem: return bangStem()
        case .bangDot: return bangDot()
        }
    }

    /// The tile scaled to a `side` × `side` square at the origin.
    public static func tile(side: CGFloat) -> CGPath {
        var transform = CGAffineTransform(scaleX: side / iconTileRect.width, y: side / iconTileRect.height)
            .translatedBy(x: -iconTileRect.minX, y: -iconTileRect.minY)
        return parsed(tileSVGPath).copy(using: &transform) ?? parsed(tileSVGPath)
    }

    // MARK: - Path data

    /// Parses SVG path data with absolute M, L, H, V, C, Q and Z commands,
    /// one set of numbers each. Returns nil for anything else.
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

    private static func parsed(_ data: String) -> CGPath {
        guard let path = path(svg: data) else { preconditionFailure("HiMark path data must parse") }
        return path
    }

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius), transform: nil)
    }
}
