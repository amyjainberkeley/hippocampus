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
        // The theme holds the window's size and margins, and no colour.
        XCTAssertFalse(theme.contains("Color("), "no second accent")
        XCTAssertFalse(theme.contains("Palette."), "no second name for the accent")
        XCTAssertFalse(design.contains("Double(0x0A)"), "no second, hand-typed accent")
    }
}
