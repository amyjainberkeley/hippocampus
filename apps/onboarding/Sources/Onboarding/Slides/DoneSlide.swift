import SwiftUI
import OnboardingKit

struct DoneSlide: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @EnvironmentObject var prepareBrainVM: PrepareBrainViewModel

    var body: some View {
        SlideContainer {
            VStack(spacing: OnboardingDesign.Space.xl) {
                HeroHeader(
                    title: readyForCapture ? "You're all set" : "Finish preparing your memory",
                    subtitle: readyForCapture ? "Capture begins when you click Get Started. You can pause it any time from the menu bar." : "Go back to finish the unchecked setup steps before starting capture.",
                    titleStyle: .display
                ) {
                    Image(systemName: readyForCapture ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 60))
                        .foregroundStyle(OnboardingDesign.Palette.success)
                }

                summaryChecklist

                menuBarHint
            }
        }
        .task { await prepareBrainVM.generateKey(); flowVM.refreshPermissions() }
    }

    private var readyForCapture: Bool {
        prepareBrainVM.canContinue
            && flowVM.screenRecordingPermission.status == .granted
            && flowVM.accessibilityPermission.status == .granted
    }

    private var summaryChecklist: some View {
        VStack(alignment: .leading, spacing: OnboardingDesign.Space.md) {
            checkRow(
                granted: flowVM.screenRecordingPermission.status == .granted,
                label: "Screen Recording"
            )
            checkRow(
                granted: flowVM.accessibilityPermission.status == .granted,
                label: "Accessibility privacy checks"
            )
            checkRow(granted: prepareBrainVM.canContinue, label: "Encryption key ready")
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
            checkRow(granted: true, label: "Richer brief wording ready")
        } else {
            HStack(spacing: OnboardingDesign.Space.md) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(OnboardingDesign.Palette.success)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Evidence-cited briefs ready")
                        .font(.system(size: 14))
                    Text("Optional richer wording can be added later")
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
