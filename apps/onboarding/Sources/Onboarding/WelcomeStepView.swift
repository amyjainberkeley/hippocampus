import SwiftUI
import OnboardingKit

struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text("Welcome to Hippocampus")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Your private context memory")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                bulletPoint(icon: "lock.fill",
                            text: "Everything stays on this Mac — zero network, fully encrypted.")
                bulletPoint(icon: "eye.slash.fill",
                            text: "Passwords, secure fields, and DRM content are blocked at capture — not after.")
                bulletPoint(icon: "key.fill",
                            text: "Your brain is encrypted on disk. Only you hold the key.")
            }
            .padding(.top, 8)
        }
    }

    private func bulletPoint(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.tint)
            Text(text)
                .font(.body)
        }
    }
}
