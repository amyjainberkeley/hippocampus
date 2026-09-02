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
                        detail: "After you opt in, screen, focused-window, and active-tab context are sampled in the background."
                    )
                    pillar(
                        icon: "brain",
                        title: "Remember",
                        detail: "Raw frames are discarded. OCR text, metadata, and selected encrypted visual keyframes stay local."
                    )
                    pillar(
                        icon: "magnifyingglass",
                        title: "Recall",
                        detail: "Search by words or meaning, then inspect the source event behind each result."
                    )
                }

                VStack(alignment: .leading, spacing: OnboardingDesign.Space.md) {
                    IconTextRow(icon: "cpu", title: OnboardingCopy.howItWorksFootprint)
                    IconTextRow(
                        icon: "sparkles",
                        title: "Daily briefs run locally when the optional model is installed."
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
