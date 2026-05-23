import Foundation

@MainActor
public final class OnboardingFlowViewModel: ObservableObject {
    @Published public private(set) var currentStep: OnboardingStep = .welcome

    public let screenRecordingPermission: any TCCPermission
    public let accessibilityPermission: any TCCPermission

    public init(
        screenRecording: any TCCPermission,
        accessibility: any TCCPermission
    ) {
        self.screenRecordingPermission = screenRecording
        self.accessibilityPermission = accessibility
    }

    public var canAdvance: Bool {
        if currentStep == .done { return false }
        if currentStep == .permissions {
            return screenRecordingPermission.status != .denied
        }
        return true
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
    }

    public func back() {
        guard canGoBack,
              let prev = OnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prev
    }

    public func goTo(_ step: OnboardingStep) {
        currentStep = step
    }
}
