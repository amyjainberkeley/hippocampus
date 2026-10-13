import SwiftUI

enum OnboardingTheme {
    /// The same accent as `OnboardingDesign.Palette.accent`; one source.
    static let accentBlue = OnboardingDesign.Palette.accent

    static let windowWidth: CGFloat = 1280
    static let windowHeight: CGFloat = 720
    static let contentMaxWidth: CGFloat = 600
    static let slidePadding: CGFloat = 48

    static func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(OnboardingDesign.Palette.ink)
    }

    static func subtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(.secondary)
    }
}
