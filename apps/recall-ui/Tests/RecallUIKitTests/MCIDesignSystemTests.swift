// MCIDesignSystemTests.swift — pin the design-token surface.

import SwiftUI
import XCTest

#if canImport(AppKit)
import AppKit
#endif

@testable import RecallUIKit

final class MCIDesignSystemTests: XCTestCase {

    // MARK: - Spacing scale (8pt grid)

    func testSpacingScaleIsOn8ptGrid() {
        // Each token must be either on the 4-multiple grid or one of
        // the two "off-grid" exceptions the design allows (2pt / 12pt).
        // Anything else would break vertical rhythm in a mixed layout.
        let scale: [CGFloat] = [
            MCI.Spacing.xxs, MCI.Spacing.xs, MCI.Spacing.s, MCI.Spacing.m,
            MCI.Spacing.l, MCI.Spacing.xl, MCI.Spacing.xxl, MCI.Spacing.xxxl,
            MCI.Spacing.hero,
        ]
        let expected: [CGFloat] = [2, 4, 8, 12, 16, 24, 32, 48, 64]
        XCTAssertEqual(scale, expected)
    }

    // MARK: - Radius scale

    func testRadiusScaleMatchesNativeControlRange() {
        XCTAssertEqual(MCI.Radius.xs, 4)
        XCTAssertEqual(MCI.Radius.s, 6)
        XCTAssertEqual(MCI.Radius.m, 8)
        XCTAssertEqual(MCI.Radius.l, 12)
        XCTAssertEqual(MCI.Radius.xl, 14)
    }

    // MARK: - Motion budget (≤ 300ms, no bounce)

    func testMotionDurationsAreWithinBudget() {
        XCTAssertEqual(MCI.Motion.durationSnap, 0.15, accuracy: 0.001)
        XCTAssertEqual(MCI.Motion.durationStandard, 0.25, accuracy: 0.001)
        XCTAssertEqual(MCI.Motion.durationDeliberate, 0.30, accuracy: 0.001)
        XCTAssertLessThanOrEqual(MCI.Motion.durationDeliberate, 0.3)
    }

    // MARK: - Color tokens

    func testApprovedMemoryPaletteIsPinned() {
        let palette = MCI.Color.approvedPalette
        XCTAssertEqual(palette.snowCanvas, 0xF6F8FB)
        XCTAssertEqual(palette.clearSurface, 0xFFFFFF)
        XCTAssertEqual(palette.ink, 0x18212B)
        XCTAssertEqual(palette.graphite, 0x5F6975)
        XCTAssertEqual(palette.cobaltAction, 0x3568D4)
        XCTAssertEqual(palette.coralChangeMarker, 0xD96C5F)
    }

    func testSemanticTokensUseApprovedPaletteInLightAppearance() {
        let tokens = Dictionary(uniqueKeysWithValues: MCI.Color.allTokens.map {
            ($0.name, $0.light)
        })
        XCTAssertEqual(tokens["background"], 0xF6F8FB)
        XCTAssertEqual(tokens["surface"], 0xFFFFFF)
        XCTAssertEqual(tokens["surfaceElevated"], 0xFFFFFF)
        XCTAssertEqual(tokens["foreground"], 0x18212B)
        XCTAssertEqual(tokens["foregroundSecondary"], 0x5F6975)
        XCTAssertEqual(tokens["accent"], 0x3568D4)
        XCTAssertEqual(tokens["change"], 0xD96C5F)
        XCTAssertFalse(tokens.values.contains(0x7AFFC1))
        XCTAssertFalse(tokens.values.contains(0x3AFDC8))
    }

    func testAllSemanticTokensAdaptAcrossLightAndDark() {
        XCTAssertFalse(MCI.Color.allTokens.isEmpty)
        for (name, light, dark) in MCI.Color.allTokens {
            XCTAssertNotEqual(light, dark, "token \(name) has same light+dark hex")
        }
    }

    #if canImport(AppKit)
    func testDarkModeColorResolvesToDarkHex() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var resolved: NSColor? = nil
        dark.performAsCurrentDrawingAppearance {
            resolved = NSColor(MCI.Color.background).usingColorSpace(.sRGB)
        }
        let got = try XCTUnwrap(resolved)
        let expected = try XCTUnwrap(NSColor(hex: 0x10151B).usingColorSpace(.sRGB))
        XCTAssertEqual(got.redComponent, expected.redComponent, accuracy: 0.02)
        XCTAssertEqual(got.greenComponent, expected.greenComponent, accuracy: 0.02)
        XCTAssertEqual(got.blueComponent, expected.blueComponent, accuracy: 0.02)
    }
    #endif

    // MARK: - Font tracking curve

    func testEveryFontRoleUsesZeroLetterSpacing() {
        for role in MCIFontRole.allCases {
            XCTAssertEqual(role.tracking, 0, "role \(role) must not alter native letter spacing")
        }
    }

    func testFontRoleSurfaceIsExhaustive() {
        for r in MCIFontRole.allCases {
            _ = r.font
            XCTAssertTrue(r.tracking.isFinite)
        }
    }

    // MARK: - Icon source

    func testIconSourceIsNeutralAndNonMint() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iconURL = root.appendingPathComponent("assets/branding/AppIcon.svg")
        let templateURL = root.appendingPathComponent("assets/branding/AppIcon-template.svg")
        let icon = try String(contentsOf: iconURL, encoding: .utf8)
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        for forbidden in ["#7AFFC1", "#3AFDC8", "face", "brain", "squiggle"] {
            XCTAssertFalse(icon.localizedCaseInsensitiveContains(forbidden))
            XCTAssertFalse(template.localizedCaseInsensitiveContains(forbidden))
        }
        XCTAssertTrue(icon.localizedCaseInsensitiveContains("layered memory mark"))
        XCTAssertTrue(template.localizedCaseInsensitiveContains("layered memory mark"))
    }

    // MARK: - Shadow presets

    func testShadowPresetsHaveExpectedDepth() {
        // `none` must be genuinely no-op.
        XCTAssertEqual(MCI.Shadow.none.radius, 0)
        XCTAssertEqual(MCI.Shadow.none.y, 0)
        // Card shadow is subtle — Stripe explicitly deprecates the
        // MacOS-pillow drop shadow.
        XCTAssertLessThan(MCI.Shadow.card.radius, 8)
        XCTAssertLessThan(MCI.Shadow.card.y, 4)
        // Modal shadow is larger but still bounded. If it ever climbs
        // above 40pt radius that's a "we've forgotten the design
        // language" smell.
        XCTAssertLessThan(MCI.Shadow.modal.radius, 40)
    }
}
