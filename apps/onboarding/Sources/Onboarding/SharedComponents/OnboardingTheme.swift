import SwiftUI

enum OnboardingTheme {
    /// The same accent as `OnboardingDesign.Palette.accent`; one source.
    static let accentBlue = OnboardingDesign.Palette.accent

    static let windowWidth: CGFloat = 760
    static let windowHeight: CGFloat = 560
    /// The text column: 760 less 48 on each side.
    static let contentMaxWidth: CGFloat = 664
    static let slidePadding: CGFloat = 48
    /// The title bar is hidden, so the window's buttons sit over the
    /// content. Nothing is drawn above this line.
    static let titleBarInset: CGFloat = 28

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
