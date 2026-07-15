import SwiftUI
import OnboardingKit
#if canImport(AppKit)
import AppKit
#endif

struct OnboardingFlowView: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @EnvironmentObject var prepareBrainVM: PrepareBrainViewModel
    @EnvironmentObject var retentionVM: RetentionViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            slideContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(flowVM.currentStep)
                .transition(OnboardingDesign.Motion.entrance(reduceMotion: reduceMotion))

            navigationBar
        }
        .background(
            // Hero steps get a fuller glow; working steps a calm wash.
            GradientBackdrop(intensity: backdropIntensity)
        )
        .animation(
            OnboardingDesign.Motion.resolve(OnboardingDesign.Motion.standard, reduceMotion: reduceMotion),
            value: flowVM.currentStep
        )
    }

    /// Welcome, the hotkey moment, and the finish line read as "moments" and
    /// earn a stronger backdrop; everything else stays quiet under content.
    private var backdropIntensity: Double {
        switch flowVM.currentStep {
        case .welcome, .primaryHotkey, .done: return 0.95
        default: return 0.4
        }
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
        case .primaryHotkey:
            PrimaryHotkeySlide()
        case .allowlist:
            AllowlistSlide()
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
        case .mcpServers:
            McpServersSlide()
        case .done:
            DoneSlide()
        }
    }

    // MARK: - Bottom navigation bar (Raycast/Cotypist layout)
    //
    // Back on the left, wayfinding dots in the center, the single accent
    // CTA on the right. The dots stay centered via the flanking spacers
    // even when Back is absent (Welcome).

    private var navigationBar: some View {
        HStack(spacing: OnboardingDesign.Space.lg) {
            // Left — Back (subtle ghost), or nothing on the first slide.
            ZStack {
                if flowVM.canGoBack {
                    Button("Back") { flowVM.back() }
                        .keyboardShortcut(.cancelAction)
                        .onboardingSecondary()
                }
            }
            .frame(width: 96, alignment: .leading)

            Spacer(minLength: 0)

            ProgressDots(currentStep: flowVM.currentStep)

            Spacer(minLength: 0)

            // Right — the one primary action for this screen.
            ZStack {
                if flowVM.currentStep == .done {
                    Button("Get Started") { finish() }
                        .keyboardShortcut(.defaultAction)
                        .onboardingPrimary()
                } else {
                    Button(primaryLabel) { advance() }
                        .keyboardShortcut(.defaultAction)
                        .onboardingPrimary()
                        .disabled(!flowVM.canAdvance)
                        .opacity(flowVM.canAdvance ? 1 : 0.5)
                }
            }
            .frame(width: 160, alignment: .trailing)
        }
        .padding(.horizontal, OnboardingDesign.Space.xxl)
        .padding(.vertical, OnboardingDesign.Space.lg)
    }

    /// Raycast labels its first step "Start Setup"; the rest are "Continue".
    private var primaryLabel: String {
        flowVM.currentStep == .welcome ? "Start Setup" : "Continue"
    }

    private func advance() {
        if flowVM.currentStep == .retention {
            Task { await retentionVM.save() }
        }
        flowVM.advance()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "MCIOnboardingCompleted")
        // Cross-process sentinel so Hippocampus.app's auto-launch-onboarding
        // check at next start sees "completed at least once" and skips the
        // automatic spawn. See OnboardingSentinel in HippocampusKit — we
        // duplicate the file path here rather than depending on
        // HippocampusKit (per Package.swift's "Zero external dependencies").
        writeOnboardingCompleteSentinel()
        // Clear the resume-state file so a future re-launch (e.g. dev-tool
        // wipe that touches the sentinel but not the state file) starts at
        // `.welcome` instead of stuck at `.done`.
        flowVM.clearResumeState()
        #if canImport(AppKit)
        NSApplication.shared.terminate(nil)
        #endif
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
