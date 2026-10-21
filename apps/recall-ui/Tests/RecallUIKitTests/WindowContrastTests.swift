import XCTest
@testable import RecallUIKit

/// The window's frame reads in light and dark (SPEC 2.14): its words on the
/// sidebar, the field row, the banner and the page meet WCAG's contrast for
/// text, and the selection's symbol stands out from its fill. If a pair
/// failed, the window would stay light this release instead.
final class WindowContrastTests: XCTestCase {
    private func token(_ name: String) throws -> (light: UInt32, dark: UInt32) {
        let found = try XCTUnwrap(MCI.Color.allTokens.first { $0.name == name }, name)
        return (found.light, found.dark)
    }

    private func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
    }

    private func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testTheFramesWordsMeetTextContrastInLightAndDark() throws {
        // (words, ground, the least ratio): rows, headers and the footer on
        // the sidebar; the selected row (whose words are the primary colour,
        // Show All's too); the field, the banner and pages.
        let pairs: [(String, String, Double)] = [
            ("foreground", "sidebar", 4.5),
            ("sidebarSecondary", "sidebar", 4.5),
            ("foreground", "sidebarSelection", 4.5),
            ("foreground", "surface", 4.5),
            ("foregroundSecondary", "surface", 4.5),
            ("foreground", "background", 4.5),
            ("foregroundSecondary", "background", 4.5),
            ("accent", "surface", 4.5),
        ]
        for (words, ground, least) in pairs {
            let w = try token(words)
            let g = try token(ground)
            XCTAssertGreaterThanOrEqual(ratio(w.light, g.light), least, "\(words) on \(ground), light")
            XCTAssertGreaterThanOrEqual(ratio(w.dark, g.dark), least, "\(words) on \(ground), dark")
        }
    }

    /// Privacy's forget and delete buttons: their red words read at 4.5:1 on
    /// the bordered button's own fill, light and dark. The window's error
    /// red, on that dark grey, read at 2.7:1 (the demo window's Privacy).
    func testPrivacysRedButtonWordsReadOnTheirFill() throws {
        XCTAssertGreaterThanOrEqual(ratio(PrivacyButtonRed.light, PrivacyButtonRed.fillLight), 4.5, "light")
        XCTAssertGreaterThanOrEqual(ratio(PrivacyButtonRed.dark, PrivacyButtonRed.fillDark), 4.5, "dark")
        // Every dark fill the renders draw under them: Sam's page, the demo
        // window's page, and the lightest, beside a card.
        for fill: UInt32 in [0x515356, 0x606163, 0x656669] {
            XCTAssertGreaterThanOrEqual(ratio(PrivacyButtonRed.dark, fill), 4.5, String(fill, radix: 16))
        }
        let error = try token("error")
        XCTAssertLessThan(ratio(error.dark, 0x606163), 3, "why the page has a red of its own")
        XCTAssertEqual(error.light, PrivacyButtonRed.light, "light mode keeps the window's red")
        // Still a red: more red than green or blue.
        for hex in [PrivacyButtonRed.light, PrivacyButtonRed.dark] {
            let red = (hex >> 16) & 0xFF, green = (hex >> 8) & 0xFF, blue = hex & 0xFF
            XCTAssertTrue(red > green && red > blue, String(hex, radix: 16))
        }
    }

    func testTheSelectedRowsSymbolStandsOutFromItsFill() throws {
        let accent = try token("accent")
        let selection = try token("sidebarSelection")
        XCTAssertGreaterThanOrEqual(ratio(accent.light, selection.light), 3, "light")
        XCTAssertGreaterThanOrEqual(ratio(accent.dark, selection.dark), 3, "dark")
    }

    func testTheFramesHairlinesAreSeenButQuiet() throws {
        for name in ["hairline", "windowEdge"] {
            let line = try token(name)
            let surface = try token("surface")
            XCTAssertGreaterThan(ratio(line.light, surface.light), 1.1, name)
            XCTAssertLessThan(ratio(line.light, surface.light), 2.0, name)
        }
    }

    func testNoYellowInTheFrame() throws {
        for name in ["sidebar", "sidebarSelection", "hairline", "windowEdge", "placeholder"] {
            let value = try token(name)
            for hex in [value.light, value.dark] {
                let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
                XCTAssertFalse(r > 150 && g > 120 && b < 0.6 * min(r, g), "\(name) is not yellow")
            }
        }
    }
}
