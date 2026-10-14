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

    /// Red, green and blue from 0 to 1.
    public static func components(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
        (
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255
        )
    }
}
