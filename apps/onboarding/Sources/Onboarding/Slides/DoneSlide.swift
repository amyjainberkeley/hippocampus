import SwiftUI
import OnboardingKit

struct DoneSlide: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @EnvironmentObject var prepareBrainVM: PrepareBrainViewModel

    var body: some View {
        SlideContainer {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)

                OnboardingTheme.title("You're all set")

                Text("Hippocampus is now watching for activity. Look for the menu-bar icon.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)

                summaryChecklist

                shortcutsSection
            }
        }
    }

    private var summaryChecklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            checkRow(
                granted: flowVM.screenRecordingPermission.status == .granted,
                label: "Screen Recording"
            )
            checkRow(granted: true, label: "Encrypted")
            checkRow(granted: true, label: "Retention policy set")
            modelCheckRow
        }
        .padding(16)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 380)
    }

    private func checkRow(granted: Bool, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            Text(label)
                .font(.system(size: 14))
            Spacer()
        }
    }

    @ViewBuilder
    private var modelCheckRow: some View {
        if prepareBrainVM.modelDownloaded {
            checkRow(granted: true, label: "On-device LLM")
        } else {
            HStack(spacing: 10) {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("On-device LLM")
                        .font(.system(size: 14))
                    Text("Daily briefs disabled — enable in Settings")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            shortcutRow(keys: "\u{21E7}\u{2318}P", label: "Pause capture instantly")
            shortcutRow(keys: "\u{21E7}\u{2318}F", label: "Search what you've seen")
        }
        .padding(14)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 380)
    }

    private func shortcutRow(keys: String, label: String) -> some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 14))
        }
    }
}
