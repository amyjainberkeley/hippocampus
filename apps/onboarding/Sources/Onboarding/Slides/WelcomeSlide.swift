import SwiftUI
import OnboardingKit

struct WelcomeSlide: View {
    var body: some View {
        SlideContainer {
            VStack(spacing: 24) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 72))
                    .foregroundStyle(OnboardingTheme.accentBlue)

                VStack(spacing: 8) {
                    OnboardingTheme.title("Welcome to Hippocampus")
                    OnboardingTheme.subtitle("Your memory, on your machine.")
                }

                VStack(alignment: .leading, spacing: 14) {
                    bulletPoint(
                        icon: "lock.fill",
                        text: "Everything stays on this Mac — zero network, fully encrypted."
                    )
                    bulletPoint(
                        icon: "eye.slash.fill",
                        text: "Passwords, secure fields, and DRM content are blocked at capture — not after."
                    )
                    bulletPoint(
                        icon: "key.fill",
                        text: "Your brain is encrypted on disk. Only you hold the key."
                    )
                }
                .padding(.top, 8)
            }
        }
    }

    private func bulletPoint(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(OnboardingTheme.accentBlue)
            Text(text)
                .font(.system(size: 14))
        }
    }
}
