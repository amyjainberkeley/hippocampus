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
        case .connectClaudeCode:
            ConnectClaudeCodeSlide()
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
                    // Cross-process sentinel so Hippocampus.app's
                    // auto-launch-onboarding check at next start
                    // sees "completed at least once" and skips the
                    // automatic spawn. See OnboardingSentinel in
                    // HippocampusKit — we duplicate the file path
                    // here rather than depending on HippocampusKit
                    // (per Package.swift's "Zero external
                    // dependencies" comment).
                    writeOnboardingCompleteSentinel()
                    // Clear the resume-state file so a future
                    // re-launch (e.g. dev-tool wipe that touches
                    // the sentinel but not the state file) starts
                    // at `.welcome` instead of stuck at `.done`.
                    flowVM.clearResumeState()
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

    /// Touch `~/Library/Application Support/MCI/.onboarding-complete`
    /// so Hippocampus.app skips its auto-spawn on next launch. Mirror
    /// of `HippocampusKit.OnboardingSentinel.markComplete()` —
    /// duplicated to avoid an OnboardingKit→HippocampusKit dep.
    private func writeOnboardingCompleteSentinel() {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/MCI/.onboarding-complete"
            )
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let stamp = ISO8601DateFormatter().string(from: Date())
        let body = "onboarding-completed-at \(stamp)\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }
}
