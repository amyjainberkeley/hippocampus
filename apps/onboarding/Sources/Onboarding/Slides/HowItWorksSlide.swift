import SwiftUI
import OnboardingKit

struct HowItWorksSlide: View {
    var body: some View {
        SlideContainer {
            VStack(spacing: 28) {
                OnboardingTheme.title("Hippocampus captures how you work")

                HStack(spacing: 32) {
                    pillar(
                        icon: "camera.fill",
                        title: "Capture",
                        detail: "Screen, focused window, active tab — captured continuously in the background."
                    )
                    pillar(
                        icon: "brain",
                        title: "Remember",
                        detail: "Frames are OCR'd in memory and discarded. Only text and metadata are stored."
                    )
                    pillar(
                        icon: "magnifyingglass",
                        title: "Recall",
                        detail: "Search what you've seen in natural language. Find anything, instantly."
                    )
                }

                Divider()
                    .padding(.horizontal, 40)

                VStack(spacing: 12) {
                    featureRow(
                        icon: "cpu",
                        text: OnboardingCopy.howItWorksFootprint
                    )
                    featureRow(
                        icon: "sparkles",
                        text: "Daily briefs (coming soon — on-device LLM, no cloud)."
                    )
                }
            }
        }
    }

    private func pillar(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(OnboardingTheme.accentBlue)
                .frame(height: 36)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 160)
        }
        .frame(maxWidth: .infinity)
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(OnboardingTheme.accentBlue)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }
}
