// SPDX-License-Identifier: Apache-2.0
//
// The colours setup draws with (RULINGS B4 and G2), as 0xRRGGBB. The
// SwiftUI tokens in `OnboardingDesign.Palette` are built from these, so a
// test can hold the values.

import Foundation

public enum OnboardingPalette {
    /// Fills, selection and dots: the mark's blue dot.
    public static let accent: UInt32 = 0x2F6BFF
    /// Blue text on white keeps the darker blue, which reads better.
    public static let accentText: UInt32 = 0x0A66D8
    /// Titles: the mark's letters.
    public static let ink: UInt32 = 0x0F1B3D
    /// Grey text under titles and on cards: the window's own secondary
    /// grey (`MCI.Color.secondary`). macOS's secondary label renders near
    /// #7B7B7C on setup's surfaces, under 4:1; this keeps small grey text
    /// at 4.5:1 or better on white and on the window's grey.
    public static let secondaryText: UInt32 = 0x6E6E73
    /// The surfaces text sits on: cards, and the window behind them.
    public static let cardSurface: UInt32 = 0xFFFFFF
    public static let windowSurface: UInt32 = 0xF6F6F8

    /// Red, green and blue from 0 to 1.
    public static func components(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
        (
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255
        )
    }

    /// The WCAG contrast ratio of two opaque colours, 1 to 21.
    public static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            let rgb = components(hex)
            func linear(_ value: Double) -> Double {
                value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
        }
        let (light, dark) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (light + 0.05) / (dark + 0.05)
    }
}
