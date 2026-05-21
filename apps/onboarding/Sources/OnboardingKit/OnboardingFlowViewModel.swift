import Foundation

@MainActor
public final class OnboardingFlowViewModel: ObservableObject {
    @Published public private(set) var currentStep: OnboardingStep = .welcome
    @Published public var isTrustPanelPresented: Bool = false

    public let screenRecordingPermission: any TCCPermission
    public let accessibilityPermission: any TCCPermission
    public let automationPermission: any TCCPermission

    public init(
        screenRecording: any TCCPermission,
        accessibility: any TCCPermission,
        automation: any TCCPermission
    ) {
        self.screenRecordingPermission = screenRecording
        self.accessibilityPermission = accessibility
        self.automationPermission = automation
    }

    public var canAdvance: Bool {
        currentStep != .done
    }

    public var canGoBack: Bool {
        currentStep != .welcome
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

    public func permissionForCurrentStep() -> (any TCCPermission)? {
        switch currentStep {
        case .screenRecording: return screenRecordingPermission
        case .accessibility: return accessibilityPermission
        case .automation: return automationPermission
        default: return nil
        }
    }
}
