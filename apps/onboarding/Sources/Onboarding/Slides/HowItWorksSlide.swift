import SwiftUI
import OnboardingKit

struct HowItWorksSlide: View {
    var body: some View {
        SlideContainer {
            VStack(spacing: OnboardingDesign.Space.xxl) {
                OnboardingDesign.TypeRamp.title("Hippocampus captures how you work")
                    .multilineTextAlignment(.center)

                HStack(spacing: OnboardingDesign.Space.lg) {
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

                VStack(alignment: .leading, spacing: OnboardingDesign.Space.md) {
                    IconTextRow(icon: "cpu", title: OnboardingCopy.howItWorksFootprint)
                    IconTextRow(
                        icon: "sparkles",
                        title: "Daily briefs (coming soon — on-device LLM, no cloud)."
                    )
                }
                .frame(maxWidth: 460)
                .glassCard(padding: OnboardingDesign.Space.lg)
            }
        }
    }

    private func pillar(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: OnboardingDesign.Space.md) {
            ZStack {
                Circle()
                    .fill(OnboardingDesign.Palette.accentSoft)
                    .frame(width: 52, height: 52)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(OnboardingDesign.Palette.accent)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .glassCard(padding: OnboardingDesign.Space.lg)
    }
}
