import SwiftUI
import AppKit
import OnboardingKit

/// Setup in five screens: Welcome, What you get, Permissions, Promise, Try
/// it. Back on What you get, Permissions and Promise only, five dots, one
/// primary button. Start Remembering on Promise is the only thing that
/// records consent.
///
/// Moving between screens (SPEC 7.1): the old screen fades out and drifts
/// 12 pt the way setup goes while the new one fades in from the other side,
/// 280 ms, overlapping; a 200 ms crossfade under Reduce Motion. The window
/// never resizes, and the bar below never moves.
struct OnboardingFlowView: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @EnvironmentObject var prepareBrainVM: PrepareBrainViewModel
    /// How long text and screenshots are kept, for the Promise. A missing
    /// retention file means 90 days; the real file is read at launch.
    @State private var kept = OnboardingCopy.kept(policy: .ninetyDays, customDays: nil, needsReview: false)
    /// The screen on display. It follows the flow one step behind, so the
    /// screen that leaves knows which way it goes before it goes.
    @State private var shown: OnboardingScreen?
    @State private var move: ScreenMove = .forward

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingWindow {
            ZStack {
                screen(shown ?? flowVM.screen)
                    .id(shown ?? flowVM.screen)
                    .transition(OnboardingDesign.Motion.screen(move, reduceMotion: reduceMotion))
            }
        } bar: {
            BottomBar(
                screen: flowVM.screen,
                back: flowVM.canGoBack ? { flowVM.back() } : nil,
                primaryLabel: primaryLabel,
                primaryLabels: OnboardingCopy.primaryLabels(for: flowVM.screen, isReview: flowVM.isReview),
                primaryEnabled: primaryEnabled,
                primaryDisabledReason: primaryDisabledReason,
                primary: primary
            )
        }
        .onAppear { shown = flowVM.screen }
        .onChange(of: flowVM.screen) { old, new in
            // First the leaving screen takes the move's direction, then the
            // new one replaces it, so Back drifts the other way.
            move = ScreenMove(from: old, to: new)
            DispatchQueue.main.async {
                withAnimation(OnboardingDesign.Motion.screenAnimation(reduceMotion: reduceMotion)) {
                    shown = flowVM.screen
                }
            }
        }
        .alert(OnboardingCopy.consentFailedTitle, isPresented: consentFailed) {
            Button("OK", role: .cancel) { flowVM.dismissConsentFailure() }
        } message: {
            Text(OnboardingCopy.consentFailedMessage)
        }
        .task {
            kept = await OnboardingCopy.kept(from: DiskRetentionStore())
        }
    }

    @ViewBuilder
    private func screen(_ screen: OnboardingScreen) -> some View {
        switch screen {
        case .welcome:
            WelcomeSlide()
        case .whatYouGet:
            WhatYouGetSlide()
        case .permissions:
            PermissionsSlide()
        case .promise:
            PromiseSlide(kept: kept)
        case .tryIt:
            TryItSlide(
                consentGivenAtUs: flowVM.consentGivenAtUs,
                // A first run is on: its consent started remembering.
                remembering: flowVM.rememberingForTryIt(environment: ProcessInfo.processInfo.environment),
                // Checked when nothing was read, not taken from consent.
                permissionsOn: { [flowVM] in await flowVM.permissionsStillOn() },
                openSettings: { [flowVM] in flowVM.openSettings($0) }
            )
        }
    }

    private var primaryLabel: String {
        switch flowVM.screen {
        case .welcome: OnboardingCopy.getStarted
        case .whatYouGet, .permissions: OnboardingCopy.continueLabel
        case .promise: OnboardingCopy.promisePrimary(isReview: flowVM.isReview, keyState: prepareBrainVM.keyState)
        case .tryIt: OnboardingCopy.done
        }
    }

    /// Start Remembering needs both permissions and the encryption key, and
    /// is off while a click is being checked.
    private var canStart: Bool {
        prepareBrainVM.canContinue && flowVM.bothGranted && !flowVM.isStartingRemembering
    }

    private var primaryEnabled: Bool {
        switch flowVM.screen {
        case .welcome, .whatYouGet, .tryIt: true
        case .permissions: flowVM.canAdvance
        case .promise: flowVM.isReview ? flowVM.canAdvance : canStart
        }
    }

    /// What VoiceOver says about an off primary button (SPEC 7.7). While the
    /// key is set up, the label itself says so.
    private var primaryDisabledReason: String? {
        guard !primaryEnabled else { return nil }
        switch flowVM.screen {
        case .permissions, .promise: return flowVM.bothGranted ? nil : OnboardingCopy.turnOnBothFirst
        case .welcome, .whatYouGet, .tryIt: return nil
        }
    }

    private func primary() {
        switch flowVM.screen {
        case .welcome, .whatYouGet, .permissions:
            flowVM.advance()
        case .promise where flowVM.isReview:
            flowVM.advance()
        case .promise:
            // Consent: the one click that records it.
            Task { await flowVM.startRemembering(keyReady: prepareBrainVM.canContinue) }
        case .tryIt:
            // Setup is done; a later run starts fresh. It fades out, then
            // the app opens the window on Today (SPEC 7.4).
            flowVM.clearResumeState()
            SetupWindow.fadeOutAndQuit()
        }
    }

    private var consentFailed: Binding<Bool> {
        Binding(
            get: { flowVM.consentFailure != nil },
            set: { if !$0 { flowVM.dismissConsentFailure() } }
        )
    }
}
