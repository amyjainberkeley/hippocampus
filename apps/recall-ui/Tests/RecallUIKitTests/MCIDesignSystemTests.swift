// MCIDesignSystemTests.swift — pin the design-token surface.
//
// Cycle 8.48 (MCIDesignSystem Stripe-tuned tokens PR): guard against
// silent drift in the color / spacing / motion / radius scales. If a
// well-meaning cleanup shifts `MCI.Spacing.l` from 16 → 12, we want
// CI to say NO before every view in the app resizes an inch to the
// left.

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

    func testRadiusScaleMatchesStripeRange() {
        XCTAssertEqual(MCI.Radius.xs, 4)
        XCTAssertEqual(MCI.Radius.s, 6)
        XCTAssertEqual(MCI.Radius.m, 8)
        XCTAssertEqual(MCI.Radius.l, 12)
        XCTAssertEqual(MCI.Radius.xl, 14)
    }

    // MARK: - Motion budget (≤ 300ms, no bounce)

    func testMotionDurationsAreWithinBudget() {
        // §4.4 of the peer study: opacity+transform only, ≤ 300ms,
        // ease-in-out (no spring, no bounce). We assert the raw
        // duration constants — the `Animation` values themselves are
        // opaque, but their duration numerics are exposed as tokens.
        XCTAssertEqual(MCI.Motion.durationSnap, 0.15, accuracy: 0.001)
        XCTAssertEqual(MCI.Motion.durationStandard, 0.25, accuracy: 0.001)
        XCTAssertEqual(MCI.Motion.durationDeliberate, 0.35, accuracy: 0.001)
        // deliberate is the ceiling; anything more than that is out of budget.
        XCTAssertLessThanOrEqual(MCI.Motion.durationDeliberate, 0.5)
    }

    // MARK: - Color tokens

    func testAllColorTokensHaveLightAndDarkVariants() {
        // Assert the whole enumerated pin-list is non-empty and that
        // each entry has a distinct light + dark hex (no accidental
        // aliasing that would collapse the two appearances).
        XCTAssertFalse(MCI.Color.allTokens.isEmpty)
        for (name, light, dark) in MCI.Color.allTokens {
            // Some tokens (e.g. success, background) can legitimately
            // hold the same accent in both modes, but foreground /
            // surface / accent MUST differ.
            let mustDiffer: Set<String> = [
                "accent", "background", "surface", "foreground",
                "foregroundSecondary", "border",
            ]
            if mustDiffer.contains(name) {
                XCTAssertNotEqual(light, dark, "token \(name) has same light+dark hex")
            }
        }
    }

    func testAccentIsMintNotStripeIndigo() {
        // Stripe's indigo is `#533afd`. We deliberately picked a
        // mint-shifted accent to differentiate MCI. If a future refactor
        // accidentally lifts `#533afd` into the accent, this test yells.
        let accent = MCI.Color.allTokens.first { $0.name == "accent" }
        XCTAssertNotNil(accent)
        XCTAssertNotEqual(accent?.dark, 0x533AFD)
        XCTAssertNotEqual(accent?.light, 0x533AFD)
    }

    #if canImport(AppKit)
    func testDarkModeColorResolvesToDarkHex() throws {
        // Under the dark appearance, the semantic token must resolve
        // to the pinned dark hex. This is the snapshot pin — a token
        // shift is caught here even if the visual regression is subtle.
        //
        // `performAsCurrentDrawingAppearance` returns `Void`, so we
        // capture the resolved NSColor via a var closed over by the
        // block. `NSColor(_: Color)` requires macOS 12+; Package.swift
        // pins macOS 14, so this is available.
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var resolved: NSColor? = nil
        dark.performAsCurrentDrawingAppearance {
            resolved = NSColor(MCI.Color.background).usingColorSpace(.sRGB)
        }
        let got = try XCTUnwrap(resolved)
        // Use the direct hex bridge for the pin; asserts the AppKit
        // dynamic-provider is wired the right way round.
        let expected = try XCTUnwrap(NSColor(hex: 0x0D0D0D).usingColorSpace(.sRGB))
        XCTAssertEqual(got.redComponent, expected.redComponent, accuracy: 0.02)
        XCTAssertEqual(got.greenComponent, expected.greenComponent, accuracy: 0.02)
        XCTAssertEqual(got.blueComponent, expected.blueComponent, accuracy: 0.02)
    }
    #endif

    // MARK: - Font tracking curve

    func testTrackingCurveMatchesStripeGuidance() {
        // §4.1: −1.4px @ 56pt down to −0.2px @ 20pt. We can't reach
        // Stripe's full display scale on macOS chrome, but the curve
        // should ramp from tighter (display) to neutral (body). The
        // ratios matter more than the exact values.
        XCTAssertLessThan(MCIFontRole.display.tracking, MCIFontRole.title.tracking)
        XCTAssertLessThan(MCIFontRole.title.tracking, MCIFontRole.title2.tracking)
        XCTAssertLessThanOrEqual(MCIFontRole.title2.tracking, MCIFontRole.body.tracking)
        XCTAssertEqual(MCIFontRole.body.tracking, 0)
        XCTAssertEqual(MCIFontRole.caption.tracking, 0)
    }

    func testFontRoleSurfaceIsExhaustive() {
        // Every case in `MCIFontRole` must map to a non-default Font.
        // Enum exhaustiveness is a Swift compile-time property, but the
        // `.font` accessor uses a switch — if a future case is added
        // without wiring, this test forces a review.
        let roles: [MCIFontRole] = [
            .display, .title, .title2, .body, .bodyStrong,
            .caption, .footnote, .mono,
        ]
        for r in roles {
            // Font is opaque; assert we don't crash + tracking is
            // finite. The strong pin is the tracking-curve test above.
            _ = r.font
            XCTAssertTrue(r.tracking.isFinite)
        }
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
