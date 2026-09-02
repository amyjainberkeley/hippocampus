import SwiftUI
import OnboardingKit

struct PrepareBrainSlide: View {
    @EnvironmentObject var prepareBrainVM: PrepareBrainViewModel

    var body: some View {
        SlideContainer {
            VStack(spacing: OnboardingDesign.Space.xl) {
                OnboardingDesign.TypeRamp.title("Preparing your brain")
                    .multilineTextAlignment(.center)

                keyGenerationSection

                briefReadinessSection
                    .glassCard(padding: OnboardingDesign.Space.lg)
                    .frame(maxWidth: 460)
            }
        }
        .task {
            await prepareBrainVM.generateKey()
            await prepareBrainVM.checkModelAvailability()
        }
    }

    private var keyGenerationSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                keyStatusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(keyStatusText)
                        .font(.system(size: 14, weight: .medium))
                    Text("Your data is encrypted with a unique key on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .glassCard(padding: OnboardingDesign.Space.md)
            .frame(maxWidth: 460)
        }
    }

    @ViewBuilder
    private var keyStatusIcon: some View {
        switch prepareBrainVM.keyState {
        case .checking, .generating:
            ProgressView()
                .controlSize(.small)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 18))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 18))
        }
    }

    private var keyStatusText: String {
        switch prepareBrainVM.keyState {
        case .checking: "Checking encryption key..."
        case .generating: "Generating local encryption key..."
        case .ready: "Encryption key ready"
        case .failed(let msg): "Key generation failed: \(msg)"
        }
    }

    private var briefReadinessSection: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(OnboardingDesign.Palette.accent)

            VStack(spacing: 4) {
                Text("Daily brief ready")
                    .font(.system(size: 15, weight: .semibold))
                Text("Evidence-cited briefs are ready. No model download or account is required.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            if prepareBrainVM.modelDownloaded {
                Label("Richer local wording is also installed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingDesign.Palette.success)
            }
        }
    }
}
