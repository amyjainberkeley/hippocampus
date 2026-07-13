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
    /// Cycle 8.48 — Raycast peer-study P0 pattern #1. Flipped to `true`
    /// when the user completes the ⇧⌘Space live-try on the
    /// `PrimaryHotkeySlide` (either by pressing the hotkey while the
    /// slide is frontmost, or by tapping "Skip" — the flag records "we
    /// showed them the moment, they engaged with it" for downstream
    /// telemetry-gap analysis, not "the hotkey actually works").
    @Published public private(set) var hotkeyPracticed: Bool = false

    public let screenRecordingPermission: any TCCPermission
    public let accessibilityPermission: any TCCPermission
    /// Automation TCC — wired in per audit gap G1 so `PermissionsSlide`
    /// can surface it in the pre-flight overview and
    /// `BrowserExtensionSlide` can render an inline warning + a
    /// `.denied` recovery path when Safari's osascript keystroke is
    /// blocked (previously the error was silently swallowed).
    public let automationPermission: any TCCPermission
    /// Full Disk Access status snapshot. Refreshed alongside TCC
    /// probes so the pre-flight overview can pill the FDA row without
    /// touching the actor on every render. Stays `.notRequested`
    /// until the user toggles a Messages / Mail deep-hook on the
    /// Allowlist slide (ADR-0032 §3(b)).
    @Published public private(set) var fullDiskAccessStatus: FullDiskAccessStatus = .notRequested

    private let stateStore: any OnboardingStateStore
    private let fdaPermission: (any FullDiskAccessPermission)?

    public init(
        screenRecording: any TCCPermission,
        accessibility: any TCCPermission,
        automation: (any TCCPermission)? = nil,
        fullDiskAccess: (any FullDiskAccessPermission)? = nil,
        stateStore: any OnboardingStateStore = FileOnboardingStateStore(),
        migrationSource: MigrationSource? = nil
    ) {
        // Default the Automation permission to a stub so pre-audit
        // callers (unit tests + any downstream) keep compiling without
        // having to construct one. Production callers in
        // `OnboardingApp.init` inject `RealAutomationPermission`.
        let automation = automation ?? StubTCCPermission(kind: .automation, status: .notRequested)
        self.screenRecordingPermission = screenRecording
        self.accessibilityPermission = accessibility
        self.automationPermission = automation
        self.fdaPermission = fullDiskAccess
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
        if currentStep == .primaryHotkey {
            // The slide's Continue button binds `.disabled(!canAdvance)`;
            // `hotkeyPracticed` is flipped by either the live-try monitor
            // or the Skip fallback. Either path unblocks — Skip is
            // REQUIRED for accessibility (SetApp/Alfred can grab ⇧⌘Space).
            return hotkeyPracticed
        }
        return true
    }

    /// Called by `PrimaryHotkeySlide` when the user either presses
    /// ⇧⌘Space while the slide is frontmost OR taps "Skip". Idempotent
    /// — a second call is a no-op. Persists nothing beyond the flow
    /// VM (the `.onboarding-state` file already records the step; a
    /// user who quits mid-hotkey-slide re-lands here and re-tries).
    public func markHotkeyPracticed() {
        guard !hotkeyPracticed else { return }
        hotkeyPracticed = true
    }

    public func refreshPermissions() {
        _ = screenRecordingPermission.checkCurrent()
        _ = accessibilityPermission.checkCurrent()
        // Automation: cheap probe (NSAppleScript against System Events).
        // Do NOT probe here on the Permissions slide poll if the user
        // hasn't yet reached the Browser Extension flow — probing pre-
        // grant would fire the OS Automation dialog silently, which is
        // exactly the "surprise dialog #3" pattern we're fixing.
        // Instead, only trust the last-known status; the Browser
        // Extension slide will do the real probe when the user clicks
        // the Safari install button.
        _ = automationPermission.status
        permissionRefreshCount += 1
    }

    /// Snapshot the Full Disk Access status from the actor into the
    /// synchronous `fullDiskAccessStatus` @Published so views can pill
    /// the row without awaiting on every render. Idempotent.
    public func refreshFullDiskAccessStatus() async {
        guard let fda = fdaPermission else { return }
        let s = await fda.status()
        if s != fullDiskAccessStatus {
            fullDiskAccessStatus = s
        }
    }

    /// Probe Automation TCC on demand — called by the Browser
    /// Extension slide just before the Safari click so the returned
    /// status reflects "did the user grant when they saw the dialog?"
    /// Distinct from `refreshPermissions()` (which deliberately doesn't
    /// probe Automation — see comment there).
    @discardableResult
    public func probeAutomation() -> TCCStatus {
        automationPermission.checkCurrent()
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
