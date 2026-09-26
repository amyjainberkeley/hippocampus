import SwiftUI

enum OnboardingTheme {
    static let accentBlue = Color(
        red: Double(0x0A) / 255,
        green: Double(0x66) / 255,
        blue: Double(0xD8) / 255
    )

    static let windowWidth: CGFloat = 1280
    static let windowHeight: CGFloat = 720
    static let contentMaxWidth: CGFloat = 600
    static let slidePadding: CGFloat = 48

    static func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 28, weight: .semibold))
    }

    static func subtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(.secondary)
    }
}
