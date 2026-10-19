// SPDX-License-Identifier: Apache-2.0
//
// The hi mark, as setup draws it: at the top of Welcome on the app icon's
// tile, in the demo and on the Promise's legend. Setup shares no module with
// the menu-bar app, so the geometry and the Lab colours are a copy of
// `apps/hippocampus/Sources/HippocampusKit/Brand/HiMarkGeometry.swift`;
// `OnboardingHiMarkTests` holds the copy to that file.

import CoreGraphics
import Foundation

public enum OnboardingHiMark {
    /// The h: stem, then the arch. Fill with the non-zero rule.
    public static let hSVGPath = "M1.5 0H14Q15.5 0 15.5 1.5V98.5Q15.5 100 14 100H1.5Q0 100 0 98.5V1.5Q0 0 1.5 0ZM12.5 44L15.5 40C21 33.2 27.25 28 38.75 28C50.84 28 62 37.87 62 51.5V98.5Q62 100 60.5 100H48.7Q47.2 100 47.2 98.5V52.4C47.2 44.4 41.85 40.4 33.25 40.4C24.25 40.4 18.1 43 15.5 50.5L12.5 54.5Z"

    /// The stem of the i.
    public static let iStemSVGPath = "M77 29.2H89.5Q91 29.2 91 30.7V98.5Q91 100 89.5 100H77Q75.5 100 75.5 98.5V30.7Q75.5 29.2 77 29.2Z"

    /// The i's dot.
    public static let dotCenter = CGPoint(x: 83.25, y: 7.96)
    public static let dotRadius: CGFloat = 10.08

    /// The box the mark is centered in: the letters and the solid dot.
    public static let inkBounds = CGRect(x: 0, y: -2.12, width: 93.33, height: 102.12)

    /// The tile: an 824 squircle at (100, 100) on Apple's 1024 icon grid.
    public static let tileSVGPath = "M284.3 100H739.7C866.9 100 924 157.1 924 284.3V739.7C924 866.9 866.9 924 739.7 924H284.3C157.1 924 100 866.9 100 739.7V284.3C100 157.1 157.1 100 284.3 100Z"
    public static let iconTileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    /// Where the mark sits on the 1024 canvas: 56% of the tile wide, 62% tall.
    public static let iconMarkOrigin = CGPoint(x: 281.28, y: 258.46)
    public static let iconMarkScale: CGFloat = 5.1088

    /// The Lab colours (sRGB, 0xRRGGBB): the tile from white to a cool
    /// grey, the letters navy, the dot blue.
    public static let tileTopRGB: UInt32 = 0xFFFFFF
    public static let tileBottomRGB: UInt32 = 0xE9EEF6
    public static let lettersRGB: UInt32 = 0x0F1B3D
    public static let dotRGB: UInt32 = 0x2F6BFF

    /// Red, green and blue of a 0xRRGGBB colour, each 0 to 1.
    public static func components(_ rgb: UInt32) -> (red: Double, green: Double, blue: Double) {
        (Double((rgb >> 16) & 0xFF) / 255, Double((rgb >> 8) & 0xFF) / 255, Double(rgb & 0xFF) / 255)
    }

    /// The letters, h and i stem, as one path in mark units.
    public static func letters() -> CGPath {
        let path = CGMutablePath()
        for data in [hSVGPath, iStemSVGPath] {
            if let part = Self.path(svg: data) { path.addPath(part) }
        }
        return path
    }

    /// The solid dot, in mark units.
    public static func dot() -> CGPath {
        CGPath(
            ellipseIn: CGRect(x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius,
                              width: 2 * dotRadius, height: 2 * dotRadius),
            transform: nil
        )
    }

    /// The tile's squircle, in 1024-grid units.
    public static func tile() -> CGPath {
        path(svg: tileSVGPath) ?? CGPath(rect: iconTileRect, transform: nil)
    }

    /// Where the mark's units land inside the tile, as fractions of the
    /// tile's side: its origin and its scale.
    public static var markInTile: (origin: CGPoint, scale: CGFloat) {
        (CGPoint(x: (iconMarkOrigin.x - iconTileRect.minX) / iconTileRect.width,
                 y: (iconMarkOrigin.y - iconTileRect.minY) / iconTileRect.height),
         iconMarkScale / iconTileRect.width)
    }

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
}
