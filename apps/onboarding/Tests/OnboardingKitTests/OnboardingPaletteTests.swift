import XCTest
@testable import OnboardingKit

final class OnboardingPaletteTests: XCTestCase {
    func testTheBrandColoursAreTheRulingsValues() {
        XCTAssertEqual(OnboardingPalette.accent, 0x2F6BFF)
        XCTAssertEqual(OnboardingPalette.accentText, 0x0A66D8)
        XCTAssertEqual(OnboardingPalette.ink, 0x0F1B3D)
        let accent = OnboardingPalette.components(0x2F6BFF)
        XCTAssertEqual(accent.red, 47.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(accent.green, 107.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(accent.blue, 1, accuracy: 0.0001)
    }

    func testSmallTextKeepsAtLeastFourAndAHalfToOneOnEverySurface() {
        // Grey text is the window's own secondary grey, not macOS's
        // secondary label, which renders near #7B7B7C there: under 4:1.
        XCTAssertEqual(OnboardingPalette.secondaryText, 0x6E6E73)
        XCTAssertLessThan(OnboardingPalette.contrast(0x7B7B7C, OnboardingPalette.windowSurface), 4.5)
        for surface in [OnboardingPalette.cardSurface, OnboardingPalette.windowSurface] {
            for text in [OnboardingPalette.secondaryText, OnboardingPalette.accentText] {
                XCTAssertGreaterThanOrEqual(OnboardingPalette.contrast(text, surface), 4.5,
                                            String(format: "%06X on %06X", text, surface))
            }
            XCTAssertGreaterThanOrEqual(OnboardingPalette.contrast(OnboardingPalette.ink, surface), 7)
        }
        XCTAssertEqual(OnboardingPalette.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(OnboardingPalette.contrast(0xFFFFFF, 0xFFFFFF), 1, accuracy: 0.0001)
    }

    func testTheSwiftUITokensComeFromThePalette() throws {
        let design = try String(
            contentsOf: onboardingPackageRoot.appendingPathComponent("Sources/Onboarding/SharedComponents/OnboardingDesign.swift"),
            encoding: .utf8
        )
        let theme = try String(
            contentsOf: onboardingPackageRoot.appendingPathComponent("Sources/Onboarding/SharedComponents/OnboardingTheme.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(design.contains("static let accent = color(OnboardingPalette.accent)"))
        XCTAssertTrue(design.contains("static let accentText = color(OnboardingPalette.accentText)"))
        XCTAssertTrue(design.contains("static let ink = color(OnboardingPalette.ink)"))
        XCTAssertTrue(design.contains("static let secondaryText = color(OnboardingPalette.secondaryText)"))
        XCTAssertTrue(design.contains("static let windowSolid = color(OnboardingPalette.windowSurface)"))
        // The theme holds the window's size and margins, and no colour.
        XCTAssertFalse(theme.contains("Color("), "no second accent")
        XCTAssertFalse(theme.contains("Palette."), "no second name for the accent")
        XCTAssertFalse(design.contains("Double(0x0A)"), "no second, hand-typed accent")
    }
}
