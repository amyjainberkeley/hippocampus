import SwiftUI
import OnboardingKit

struct PrepareBrainSlide: View {
    @EnvironmentObject var prepareBrainVM: PrepareBrainViewModel

    var body: some View {
        SlideContainer {
            VStack(spacing: 28) {
                OnboardingTheme.title("Preparing your brain")

                keyGenerationSection

                Divider()
                    .padding(.horizontal, 40)

                modelDownloadSection
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
            .padding(14)
            .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
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

    private var modelDownloadSection: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("On-device AI Model")
                    .font(.system(size: 15, weight: .semibold))
                Text("Download \(prepareBrainVM.modelDisplayName) for daily briefs. Runs entirely on your Mac — no data leaves your device.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            modelStateView

            if case .notStarted = prepareBrainVM.downloadState {
                HStack(spacing: 8) {
                    Label(prepareBrainVM.modelSizeDescription, systemImage: "arrow.down.circle")
                    Label("On-device only", systemImage: "lock.shield")
                }
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var modelStateView: some View {
        switch prepareBrainVM.downloadState {
        case .notStarted:
            // Qwen3 model is live (PR #192) but downloading 2.5 GB
            // mid-onboarding is a worse experience than letting the
            // user finish setup in <30 s and grab the model on demand
            // from the menu-bar Daily Briefs item. Pre-skip so the
            // flow's `canAdvance` stays true and the user is never
            // blocked here; the StatusMenuView download flow is fully
            // wired and SHA-verifies against the same manifest.
            VStack(spacing: 8) {
                Label("Daily briefs are opt-in", systemImage: "doc.text")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13, weight: .medium))
                Text("To keep setup quick, the 2.5 GB Qwen3 brief model is downloaded on demand. Click the Hippocampus icon in your menu bar later → \"Daily Briefs: Off — Download Model…\" to enable.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .onAppear {
                prepareBrainVM.skipDownload()
            }

        case .downloading:
            VStack(spacing: 6) {
                ProgressView(value: prepareBrainVM.downloadProgress)
                    .tint(OnboardingTheme.accentBlue)
                    .frame(maxWidth: 300)
                HStack {
                    Text("\(Int(prepareBrainVM.downloadProgress * 100))%")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        prepareBrainVM.cancelDownload()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 300)
            }

        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Verifying integrity...")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

        case .ready:
            Label("Model ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 14, weight: .medium))

        case .failed(let msg):
            VStack(spacing: 8) {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
                Button("Retry") {
                    prepareBrainVM.startDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

        case .skipped:
            VStack(spacing: 4) {
                Label("Download skipped", systemImage: "arrow.right.circle")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                Text("Daily briefs disabled — enable in Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
