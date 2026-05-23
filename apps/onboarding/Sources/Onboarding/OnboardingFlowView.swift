import SwiftUI
import OnboardingKit

struct OnboardingFlowView: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @EnvironmentObject var prepareBrainVM: PrepareBrainViewModel
    @EnvironmentObject var retentionVM: RetentionViewModel

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgressBar(currentStep: flowVM.currentStep)

            Divider()

            slideContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            navigationBar
        }
        .background(.background)
    }

    @ViewBuilder
    private var slideContent: some View {
        switch flowVM.currentStep {
        case .welcome:
            WelcomeSlide()
        case .howItWorks:
            HowItWorksSlide()
        case .trust:
            TrustSlide()
        case .permissions:
            PermissionsSlide()
        case .browserExtension:
            BrowserExtensionSlide()
        case .livePreview:
            LivePreviewSlide()
        case .retention:
            RetentionSlide()
        case .prepareBrain:
            PrepareBrainSlide()
        case .done:
            DoneSlide()
        }
    }

    private var navigationBar: some View {
        HStack {
            if flowVM.canGoBack {
                Button("Back") { flowVM.back() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if flowVM.currentStep == .done {
                Button("Get Started") {
                    UserDefaults.standard.set(true, forKey: "MCIOnboardingCompleted")
                    #if canImport(AppKit)
                    NSApplication.shared.terminate(nil)
                    #endif
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(OnboardingTheme.accentBlue)
                .controlSize(.regular)
            } else {
                Button("Continue") {
                    if flowVM.currentStep == .retention {
                        Task { await retentionVM.save() }
                    }
                    flowVM.advance()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(OnboardingTheme.accentBlue)
                .controlSize(.regular)
                .disabled(!flowVM.canAdvance)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 14)
    }
}
