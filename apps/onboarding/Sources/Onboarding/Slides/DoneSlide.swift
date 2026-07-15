import SwiftUI
import OnboardingKit

struct DoneSlide: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @EnvironmentObject var prepareBrainVM: PrepareBrainViewModel

    var body: some View {
        SlideContainer {
            VStack(spacing: OnboardingDesign.Space.xl) {
                HeroHeader(
                    title: "You're all set",
                    subtitle: "Hippocampus is now watching for activity. Look for the menu-bar icon.",
                    titleStyle: .display
                ) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(OnboardingDesign.Palette.success)
                }

                summaryChecklist

                menuBarHint
            }
        }
    }

    private var summaryChecklist: some View {
        VStack(alignment: .leading, spacing: OnboardingDesign.Space.md) {
            checkRow(
                granted: flowVM.screenRecordingPermission.status == .granted,
                label: "Screen Recording"
            )
            checkRow(granted: true, label: "Encrypted")
            checkRow(granted: true, label: "Retention policy set")
            modelCheckRow
        }
        .frame(maxWidth: 380)
        .glassCard(padding: OnboardingDesign.Space.lg)
    }

    private func checkRow(granted: Bool, label: String) -> some View {
        HStack(spacing: OnboardingDesign.Space.md) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? OnboardingDesign.Palette.success : Color.secondary)
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
            HStack(spacing: OnboardingDesign.Space.md) {
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

    // Cycle 8.38 audit F5 — the previous "shortcutsSection" advertised
    // ⇧⌘P / ⇧⌘F as global hotkeys, neither of which is bound anywhere
    // in HippocampusApp. Rather than lie in the final slide, point the
    // user at the always-present menu-bar entry point. If the hotkeys
    // ship (recall-UI audit PR-5), restore a shortcuts row *then*.
    private var menuBarHint: some View {
        IconTextRow(
            icon: "menubar.arrow.up.rectangle",
            title: OnboardingCopy.doneMenuBarHint
        )
        .frame(maxWidth: 380)
        .glassCard(padding: OnboardingDesign.Space.lg)
    }
}
