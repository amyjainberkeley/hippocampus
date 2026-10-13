import SwiftUI
import OnboardingKit
#if canImport(AppKit)
import AppKit
#endif

struct OnboardingFlowView: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @EnvironmentObject var prepareBrainVM: PrepareBrainViewModel
    @EnvironmentObject var retentionVM: RetentionViewModel
    @State private var completionError: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            slideContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(flowVM.currentStep)
                .transition(OnboardingDesign.Motion.entrance(reduceMotion: reduceMotion))

            navigationBar
        }
        .background(OnboardingMaterialBackdrop(intensity: backdropIntensity))
        .animation(
            OnboardingDesign.Motion.resolve(OnboardingDesign.Motion.standard, reduceMotion: reduceMotion),
            value: flowVM.currentStep
        )
        .alert("Setup could not finish", isPresented: Binding(get: { completionError != nil }, set: { if !$0 { completionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(completionError ?? "") }
    }

    /// The material stays quiet on working steps and slightly more translucent
    /// at the three bookends. There is no decorative color wash.
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
                        .disabled(!canFinish)
                } else {
                    navPrimaryButton
                }
            }
            .frame(width: 160, alignment: .trailing)
        }
        .padding(.horizontal, OnboardingDesign.Space.xxl)
        .padding(.vertical, OnboardingDesign.Space.lg)
        .background(
            reduceTransparency
                ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                : AnyShapeStyle(.ultraThinMaterial)
        )
        .overlay(alignment: .top) {
            Divider()
        }
    }

    /// Steps whose in-content action is the screen's real filled CTA (e.g.
    /// PrepareBrain's "Download"). There, the nav "Continue" steps down to a
    /// ghost so only one filled accent shows per screen (the one-CTA rule).
    private var navPrimaryIsGhost: Bool {
        flowVM.currentStep == .prepareBrain
    }

    @ViewBuilder
    private var navPrimaryButton: some View {
        if navPrimaryIsGhost {
            Button(primaryLabel) { advance() }
                .keyboardShortcut(.defaultAction)
                .onboardingSecondary()
                .disabled(!canUsePrimaryAction)
                .opacity(canUsePrimaryAction ? 1 : 0.5)
        } else {
            Button(primaryLabel) { advance() }
                .keyboardShortcut(.defaultAction)
                .onboardingPrimary()
                .disabled(!canUsePrimaryAction)
                .opacity(canUsePrimaryAction ? 1 : 0.5)
        }
    }

    private var canUsePrimaryAction: Bool {
        flowVM.canAdvance && !(flowVM.currentStep == .retention && retentionVM.isSaving)
            && (flowVM.currentStep != .prepareBrain || prepareBrainVM.canContinue)
    }

    private var canFinish: Bool {
        prepareBrainVM.canContinue
            && flowVM.screenRecordingPermission.status == .granted
            && flowVM.accessibilityPermission.status == .granted
            && !retentionVM.isSaving
    }

    /// Raycast labels its first step "Start Setup"; the rest are "Continue".
    private var primaryLabel: String {
        flowVM.currentStep == .welcome ? "Start Setup" : "Continue"
    }

    private func advance() {
        guard canUsePrimaryAction else { return }
        if flowVM.currentStep == .retention {
            Task { @MainActor in
                await retentionVM.saveThen { flowVM.advance() }
            }
            return
        }
        flowVM.advance()
    }

    private func finish() {
        Task { @MainActor in
            // The quick check never turns a permission off; this one does.
            await flowVM.refreshPermissionsAsync()
            guard canFinish else { return }
            do {
                // Cross-process sentinel so Hippocampus.app starts remembering
                // and skips its auto-spawn on the next launch. This flow has
                // no open-at-login checkbox, so it records no.
                try FileOnboardingConsentStore().give(openAtLogin: false)
            } catch {
                completionError = "Setup could not be saved. Check available disk space and try again."
                return
            }
            UserDefaults.standard.set(true, forKey: "MCIOnboardingCompleted")
            // Clear the resume-state file so a future re-launch (e.g. dev-tool
            // wipe that touches the sentinel but not the state file) starts at
            // `.welcome` instead of stuck at `.done`.
            flowVM.clearResumeState()
            #if canImport(AppKit)
            NSApplication.shared.terminate(nil)
            #endif
        }
    }
}
