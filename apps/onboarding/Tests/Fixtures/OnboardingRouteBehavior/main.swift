import OnboardingKit

/// The routes the app passes in `MCI_ONBOARDING_STEP` open what the
/// contract says, and a panel never moves where setup resumes.
@main
struct OnboardingRouteBehavior {
    @MainActor
    static func main() {
        precondition(OnboardingLaunch.parse("app-access") == .panel(.appAccess))
        precondition(OnboardingLaunch.parse("allowlist") == .panel(.appAccess))
        precondition(OnboardingLaunch.parse("trust") == .panel(.neverRead))
        precondition(OnboardingLaunch.parse("permissions") == .flow(.permissions))
        precondition(OnboardingLaunch.parse("unknown") == .flow(nil))
        precondition(OnboardingLaunch.parse("app-access").resolved(consentGiven: false) == .flow(nil))
        precondition(!OnboardingLaunch.panel(.appAccess).usesResumeFile)

        let stateStore = InMemoryOnboardingStateStore(route: "permissions")
        let viewModel = OnboardingFlowViewModel(
            screenRecording: StubTCCPermission(kind: .screenRecording, status: .granted),
            accessibility: StubTCCPermission(kind: .accessibility, status: .granted),
            stateStore: stateStore,
            initialScreen: .promise
        )
        precondition(viewModel.screen == .promise)
        // Without consent, Try it falls back to Promise.
        viewModel.goTo(.tryIt)
        precondition(viewModel.screen == .promise)
        precondition(stateStore.loadRoute() == "promise")
    }
}
