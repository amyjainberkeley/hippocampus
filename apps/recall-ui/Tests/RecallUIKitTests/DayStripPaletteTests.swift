import Foundation
import XCTest
@testable import RecallUIKit

/// The day strip's six kinds and colours (SPEC 2.14): the sidebar's words,
/// and no amber, no planning red, no design green, nothing yellow.
final class DayStripPaletteTests: XCTestCase {
    func testTheLegendUsesTheSidebarsWords() {
        XCTAssertEqual(StripKind.allCases.map(\.title),
                       ["Code", "Documents", "Conversations", "Web Pages", "Calls", "Other"])
        let folds: [WorkKind: StripKind] = [
            .code: .code, .writing: .documents, .design: .documents, .planning: .documents,
            .communication: .conversations, .ai: .conversations, .research: .webPages, .meetings: .calls,
            .media: .other, .other: .other,
        ]
        for (kind, strip) in folds {
            XCTAssertEqual(StripKind(kind), strip, "\(kind)")
        }
    }

    func testTheSixSwatchesAreTheSpecsAndNoneIsYellowOrTheOldRedOrGreen() {
        let expected: [StripKind: (UInt32, UInt32)] = [
            .code: (0x2A78D6, 0x3987E5), .documents: (0xEB6834, 0xD95926), .conversations: (0x1BAF7A, 0x199E70),
            .webPages: (0x6250D6, 0x9085E9), .calls: (0xE87BA4, 0xD55181), .other: (0xA1A5AC, 0x6B7078),
        ]
        for kind in StripKind.allCases {
            let swatch = DayStripPalette.swatch(for: kind)
            XCTAssertEqual(swatch.light, expected[kind]?.0, "\(kind) light")
            XCTAssertEqual(swatch.dark, expected[kind]?.1, "\(kind) dark")
        }
        let gone: Set<UInt32> = [0xEDA100, 0xC98500, 0xE34948, 0xE66767, 0x008300]
        for kind in WorkKind.allCases {
            let swatch = DayStripPalette.swatch(for: kind)
            XCTAssertFalse(gone.contains(swatch.light), "\(kind)")
            XCTAssertFalse(gone.contains(swatch.dark), "\(kind)")
            for value in [swatch.light, swatch.dark] {
                XCTAssertFalse(Self.isYellow(value), String(value, radix: 16))
            }
        }
    }

    /// Every pair of the six is far apart for most eyes, on both window
    /// backgrounds (CIE76 ΔE of at least 15), and each stands apart from the
    /// strip it sits on. Their words are always beside them, so colour is
    /// never the only signal.
    func testTheSixStayApartInLightAndDark() {
        for dark in [false, true] {
            let colours = StripKind.allCases.map { kind -> UInt32 in
                let swatch = DayStripPalette.swatch(for: kind)
                return dark ? swatch.dark : swatch.light
            }
            for i in colours.indices {
                for j in colours.indices where j > i {
                    XCTAssertGreaterThanOrEqual(Self.deltaE(colours[i], colours[j]), 15,
                                                "\(StripKind.allCases[i]) and \(StripKind.allCases[j]), dark \(dark)")
                }
                let background: UInt32 = dark ? 0x17191D : 0xF7F8FA
                XCTAssertGreaterThanOrEqual(Self.deltaE(colours[i], background), 20,
                                            "\(StripKind.allCases[i]) on the window, dark \(dark)")
            }
        }
    }

    // MARK: Colour arithmetic

    private static func isYellow(_ value: UInt32) -> Bool {
        let lab = lab(value)
        let hue = atan2(lab.b, lab.a) * 180 / .pi
        let chroma = (lab.a * lab.a + lab.b * lab.b).squareRoot()
        return chroma > 40 && hue > 70 && hue < 100
    }

    static func deltaE(_ x: UInt32, _ y: UInt32) -> Double {
        let a = lab(x), b = lab(y)
        return ((a.l - b.l) * (a.l - b.l) + (a.a - b.a) * (a.a - b.a) + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }

    private static func lab(_ value: UInt32) -> (l: Double, a: Double, b: Double) {
        func linear(_ channel: UInt32) -> Double {
            let c = Double(channel) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear((value >> 16) & 0xFF), g = linear((value >> 8) & 0xFF), bl = linear(value & 0xFF)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * bl
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }
}
