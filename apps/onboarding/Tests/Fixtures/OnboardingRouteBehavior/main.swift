import OnboardingKit

@main
struct OnboardingRouteBehavior {
    @MainActor
    static func main() {
        precondition(OnboardingStep(launchRoute: "allowlist") == .allowlist)
        precondition(OnboardingStep(launchRoute: "trust") == .trust)
        precondition(OnboardingStep(launchRoute: "unknown") == nil)

        let stateStore = InMemoryOnboardingStateStore(initial: .retention)
        let viewModel = OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
            stateStore: stateStore,
            initialStep: .allowlist
        )
        precondition(viewModel.currentStep == .allowlist)
    }
}
