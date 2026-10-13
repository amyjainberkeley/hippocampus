import SwiftUI
import AppKit
import OnboardingKit

/// Setup in four screens: Welcome, Permissions, Promise, Try it. Back on
/// Permissions and Promise only, four dots, one primary button. Start
/// Remembering on Promise is the only thing that records consent.
struct OnboardingFlowView: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @EnvironmentObject var prepareBrainVM: PrepareBrainViewModel
    /// How long text and screenshots are kept, for the Promise. A missing
    /// retention file means 90 days; the real file is read at launch.
    @State private var kept = OnboardingCopy.kept(policy: .ninetyDays, customDays: nil, needsReview: false)
    /// A panel opened from Try it ("Add Extension"), shown in this window
    /// until its Done.
    @State private var panel: OnboardingPanel?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            OnboardingWindow {
                screen
                    .id(flowVM.screen)
                    .transition(OnboardingDesign.Motion.entrance(reduceMotion: reduceMotion))
            } bar: {
                BottomBar(
                    screen: flowVM.screen,
                    back: flowVM.canGoBack ? { flowVM.back() } : nil,
                    primaryLabel: primaryLabel,
                    primaryEnabled: primaryEnabled,
                    primary: primary
                )
            }
            // A panel covers the flow without ending it: Try it keeps
            // reading underneath and is as it was after Done.
            .opacity(panel == nil ? 1 : 0)
            .disabled(panel != nil)
            .accessibilityHidden(panel != nil)

            if let panel {
                OnboardingPanelView(panel: panel) { self.panel = nil }
            }
        }
        .animation(
            OnboardingDesign.Motion.resolve(OnboardingDesign.Motion.standard, reduceMotion: reduceMotion),
            value: flowVM.screen
        )
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
    private var screen: some View {
        switch flowVM.screen {
        case .welcome:
            WelcomeSlide()
        case .permissions:
            PermissionsSlide()
        case .promise:
            PromiseSlide(kept: kept)
        case .tryIt:
            TryItSlide(
                consentGivenAtUs: flowVM.consentGivenAtUs,
                remembering: RememberingState(environment: ProcessInfo.processInfo.environment),
                permissionsOn: { [flowVM] in
                    (flowVM.screenRecordingPermission.status == .granted,
                     flowVM.accessibilityPermission.status == .granted)
                },
                openSettings: { [flowVM] in flowVM.openSettings($0) },
                openPanel: { panel = $0 }
            )
        }
    }

    private var primaryLabel: String {
        switch flowVM.screen {
        case .welcome: OnboardingCopy.getStarted
        case .permissions: OnboardingCopy.continueLabel
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
        case .welcome, .tryIt: true
        case .permissions: flowVM.canAdvance
        case .promise: flowVM.isReview ? flowVM.canAdvance : canStart
        }
    }

    private func primary() {
        switch flowVM.screen {
        case .welcome, .permissions:
            flowVM.advance()
        case .promise where flowVM.isReview:
            flowVM.advance()
        case .promise:
            // Consent: the one click that records it.
            Task { await flowVM.startRemembering(keyReady: prepareBrainVM.canContinue) }
        case .tryIt:
            // Setup is done; a later run starts fresh.
            flowVM.clearResumeState()
            NSApplication.shared.terminate(nil)
        }
    }

    private var consentFailed: Binding<Bool> {
        Binding(
            get: { flowVM.consentFailure != nil },
            set: { if !$0 { flowVM.dismissConsentFailure() } }
        )
    }
}
