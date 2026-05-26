import Foundation

@MainActor
public final class OnboardingFlowViewModel: ObservableObject {
    @Published public private(set) var currentStep: OnboardingStep = .welcome
    @Published public private(set) var permissionRefreshCount = 0

    public let screenRecordingPermission: any TCCPermission
    public let accessibilityPermission: any TCCPermission

    private let stateStore: any OnboardingStateStore

    public init(
        screenRecording: any TCCPermission,
        accessibility: any TCCPermission,
        stateStore: any OnboardingStateStore = FileOnboardingStateStore()
    ) {
        self.screenRecordingPermission = screenRecording
        self.accessibilityPermission = accessibility
        self.stateStore = stateStore

        // Resume where the user left off if we have a persisted step.
        // Falls back to `.welcome` on a fresh install or any
        // read/parse failure (CEO dogfood 2026-05-26 — quit + reopen
        // used to always restart at slide 0).
        if let resumed = stateStore.load() {
            self.currentStep = resumed
        }
    }

    public var canAdvance: Bool {
        if currentStep == .done { return false }
        if currentStep == .permissions {
            return screenRecordingPermission.status == .granted
        }
        return true
    }

    public func refreshPermissions() {
        _ = screenRecordingPermission.checkCurrent()
        _ = accessibilityPermission.checkCurrent()
        permissionRefreshCount += 1
    }

    public var canGoBack: Bool {
        currentStep != .welcome
    }

    public var progress: Double {
        Double(currentStep.rawValue) / Double(OnboardingStep.allCases.count - 1)
    }

    public func advance() {
        guard canAdvance,
              let next = OnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
        stateStore.save(next)
    }

    public func back() {
        guard canGoBack,
              let prev = OnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prev
        stateStore.save(prev)
    }

    public func goTo(_ step: OnboardingStep) {
        currentStep = step
        stateStore.save(step)
    }

    /// Called by the final "Get Started" tap. Removes the resume file
    /// so that a future re-launch (e.g. after a wipe that left the
    /// sentinel untouched, or future re-onboarding flows) starts at
    /// `.welcome` instead of stuck at `.done`. The
    /// `OnboardingSentinel` itself is the source of truth for "the
    /// user finished" and is written separately by the slide.
    public func clearResumeState() {
        stateStore.clear()
    }
}
