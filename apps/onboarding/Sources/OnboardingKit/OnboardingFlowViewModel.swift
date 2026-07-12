import Foundation

/// Where the user came from, for calibrating onboarding copy.
///
/// Populated by `OnboardingApp` from a `onboarding://start?migration=<x>`
/// deep-link; nil for a normal cold-start install. Read by `WelcomeSlide`
/// to render a migration-specific sub-header (e.g. Rewind sunset cohort,
/// cycle 8.37 `/rewind` landing lane, PR #30). Kept in the flow VM so it
/// is testable at the Kit layer without touching SwiftUI.
public enum MigrationSource: String, Sendable, Equatable, CaseIterable {
    case rewind
}

@MainActor
public final class OnboardingFlowViewModel: ObservableObject {
    @Published public private(set) var currentStep: OnboardingStep = .welcome
    @Published public private(set) var permissionRefreshCount = 0
    /// Set by `OnboardingApp` from the launch URL (or by tests). `nil` for
    /// normal cold-start. Currently only `.rewind` is honored — surfaces
    /// a WelcomeSlide sub-header re-using the `/rewind` landing lane copy.
    @Published public var migrationSource: MigrationSource?

    public let screenRecordingPermission: any TCCPermission
    public let accessibilityPermission: any TCCPermission

    private let stateStore: any OnboardingStateStore

    public init(
        screenRecording: any TCCPermission,
        accessibility: any TCCPermission,
        stateStore: any OnboardingStateStore = FileOnboardingStateStore(),
        migrationSource: MigrationSource? = nil
    ) {
        self.screenRecordingPermission = screenRecording
        self.accessibilityPermission = accessibility
        self.stateStore = stateStore
        self.migrationSource = migrationSource

        // Resume where the user left off if we have a persisted step.
        // Falls back to `.welcome` on a fresh install or any
        // read/parse failure (CEO dogfood 2026-05-26 — quit + reopen
        // used to always restart at slide 0).
        if let resumed = stateStore.load() {
            self.currentStep = resumed
        }
    }

    /// Parse a launch URL like `onboarding://start?migration=rewind` and
    /// apply the migration source if recognized. Unknown values are
    /// ignored (no throw) so a stale deep-link never breaks first-run.
    /// Returns `true` iff a known migration source was applied.
    @discardableResult
    public func applyLaunchURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let migrationRaw = components.queryItems?.first(where: { $0.name == "migration" })?.value,
              let source = MigrationSource(rawValue: migrationRaw) else {
            return false
        }
        migrationSource = source
        return true
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
