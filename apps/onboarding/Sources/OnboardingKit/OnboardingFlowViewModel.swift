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

/// Cotypist peer-study P0 pattern #2 — deferred-permission choreography.
///
/// The four macOS TCC / FDA surfaces the onboarding flow may need to ask
/// for. Split out from `TCCPermissionKind` (SR / AX / Automation) so the
/// Full Disk Access surface — which uses a distinct `FullDiskAccessPermission`
/// protocol, not `TCCPermission` — can participate in the same one-at-a-time
/// sequence exposed by `PermissionsSlide`. Order is meaningful: it's the
/// order the user is asked in.
public enum PermissionSurface: String, Sendable, Equatable, CaseIterable {
    case screenRecording
    case accessibility
    case automation
    case fullDiskAccess
}

/// Outcome recorded per `PermissionSurface` as the user walks the
/// choreographed sequence on `PermissionsSlide`. `.pending` means the
/// user has not yet acted on this surface; `.skipped` means they tapped
/// "Skip for now"; `.notApplicable` means the surface's precondition
/// doesn't hold (e.g. Automation is skipped when no Safari extension is
/// desired, FDA when no Messages/Mail deep-hook is desired). Callers
/// use this to decide whether the "Continue" affordance renders after
/// denial and to gate advance to the next onboarding slide.
public enum PermissionOutcome: String, Sendable, Equatable {
    case pending
    case granted
    case denied
    case skipped
    case notApplicable
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

    // MARK: - Cotypist P0 #2 — deferred-permission choreography

    /// The canonical order the Permissions slide asks the four surfaces
    /// in. Public so tests and slide code share ground truth (fewer
    /// hard-coded arrays, one source of drift). Screen Recording is
    /// first because it's the only *required* surface; Accessibility is
    /// second because it's recommended and universally applicable;
    /// Automation and Full Disk Access come last because their
    /// preconditions (Safari extension desired, deep-hook desired) may
    /// not hold — in which case they resolve to `.notApplicable` and
    /// the sequence skips past them without rendering a card.
    public static let permissionSequence: [PermissionSurface] = [
        .screenRecording, .accessibility, .automation, .fullDiskAccess,
    ]

    /// Index into `permissionSequence` for the surface currently being
    /// asked on `PermissionsSlide`. `0` at slide entry; incremented by
    /// `advancePermissionSequence()` after the user acts (grant, deny +
    /// continue, or skip). When `>= permissionSequence.count` the slide
    /// treats the choreography as complete and shows the "All set →
    /// Continue" affordance that advances to the next onboarding step.
    @Published public private(set) var permissionSequenceIndex: Int = 0

    /// Per-surface outcome recorded as the user walks the choreography.
    /// `.pending` for anything not yet reached; `.notApplicable` for
    /// Automation / FDA on cold-start (both are contextual, deferred
    /// to their respective later slides — see the class-level comments
    /// on `automationPermission` and `fullDiskAccessStatus`).
    @Published public private(set) var permissionResults: [PermissionSurface: PermissionOutcome] = [
        .screenRecording: .pending,
        .accessibility: .pending,
        .automation: .notApplicable,
        .fullDiskAccess: .notApplicable,
    ]

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

        // Cotypist P0 #2 — seed the choreography outcome map from the
        // TCC probes' current status so a re-launch (or a test fixture
        // that hands us already-granted permissions) doesn't re-ask
        // for surfaces the user already granted. `.notRequested` stays
        // `.pending` so the sub-step still renders; `.granted` /
        // `.denied` transition to their terminal outcomes and the
        // sequence auto-advances past them below.
        seedChoreographyFromInitialStatus()
    }

    private func seedChoreographyFromInitialStatus() {
        let srStatus = screenRecordingPermission.status
        let axStatus = accessibilityPermission.status
        if srStatus == .granted { permissionResults[.screenRecording] = .granted }
        if srStatus == .denied  { permissionResults[.screenRecording] = .denied  }
        if axStatus == .granted { permissionResults[.accessibility]  = .granted }
        if axStatus == .denied  { permissionResults[.accessibility]  = .denied  }
        // Advance the sequence index past any terminal outcomes at head.
        // Repeat while the head surface is non-pending; caps at end.
        while permissionSequenceIndex < Self.permissionSequence.count {
            let surface = Self.permissionSequence[permissionSequenceIndex]
            let outcome = permissionResults[surface] ?? .pending
            if outcome == .pending { break }
            permissionSequenceIndex += 1
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
            // Cotypist P0 #2 preserves the PR #44 invariant: advance
            // out of `.permissions` requires Screen Recording granted
            // (the only hard-required surface). The choreography's
            // per-sub-step gating is a slide-level UX concern; the flow
            // VM only enforces the load-bearing invariant here so a
            // partially-walked user with SR granted can still exit via
            // the nav-bar Continue if they choose to (matches Cotypist
            // "skip and re-enable later from Settings" affordance).
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

    /// The surface currently being asked on `PermissionsSlide`, or `nil`
    /// when the choreography is complete (index past the end). Slides
    /// bind their sub-step title / rationale / grant-button to this.
    public var currentPermissionSurface: PermissionSurface? {
        guard permissionSequenceIndex >= 0,
              permissionSequenceIndex < Self.permissionSequence.count else {
            return nil
        }
        return Self.permissionSequence[permissionSequenceIndex]
    }

    /// True iff every surface in `permissionSequence` has an outcome
    /// that is NOT `.pending`. Slide binds its "All set — Continue"
    /// affordance to this; `canAdvance` at `.permissions` still enforces
    /// that Screen Recording specifically is `.granted` (SR is the only
    /// hard-required surface — AX, Automation, FDA are all soft-fails).
    public var permissionChoreographyComplete: Bool {
        for surface in Self.permissionSequence {
            if permissionResults[surface] == .pending { return false }
        }
        return true
    }

    /// Called by `PermissionsSlide` after the user acts on the current
    /// sub-step (grant landed, denial acknowledged with "Continue", or
    /// "Skip for now" tapped). Records the outcome for that surface and
    /// advances the sequence index past any surfaces whose precondition
    /// does NOT hold (`.notApplicable`) — so cold-start users who don't
    /// desire Safari + deep-hooks walk exactly the SR + AX sub-steps and
    /// see the completion affordance immediately after AX.
    ///
    /// Idempotent past the end: extra calls once
    /// `permissionSequenceIndex >= permissionSequence.count` are no-ops.
    public func recordPermissionOutcome(_ surface: PermissionSurface,
                                        _ outcome: PermissionOutcome) {
        permissionResults[surface] = outcome
        advancePermissionSequence()
    }

    /// Move to the next surface in `permissionSequence`, skipping past
    /// anything already resolved (`.granted`, `.denied`, `.skipped`, or
    /// `.notApplicable`). Called by `recordPermissionOutcome` and can
    /// also be called directly by tests / slide back-buttons to re-sync
    /// after out-of-band status changes (e.g. user granted SR from
    /// System Settings while parked on the AX sub-step, then hits Back
    /// then Next).
    public func advancePermissionSequence() {
        var idx = permissionSequenceIndex + 1
        while idx < Self.permissionSequence.count {
            let surface = Self.permissionSequence[idx]
            let outcome = permissionResults[surface] ?? .pending
            if outcome == .pending { break }
            idx += 1
        }
        permissionSequenceIndex = min(idx, Self.permissionSequence.count)
    }

    /// Mark Automation and/or FDA as *applicable* — flips the surface's
    /// outcome from `.notApplicable` to `.pending` so the choreography
    /// will render a card for it. Callers: `BrowserExtensionSlide`
    /// (Safari detected → `.automation`), `AllowlistSlide` (deep-hook
    /// toggled ON → `.fullDiskAccess`). Idempotent — flipping an
    /// already-applicable surface is a no-op. Wiring the actual triggers
    /// is deferred to a follow-up PR; this API lets tests exercise the
    /// applicable path today.
    public func markPermissionApplicable(_ surface: PermissionSurface) {
        if permissionResults[surface] == .notApplicable {
            permissionResults[surface] = .pending
        }
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
        // Cotypist P0 #2 — auto-sync the choreography outcomes for any
        // surface that landed a grant while the slide's poll timer was
        // ticking (user went to Settings and toggled ON). Only overwrite
        // `.pending` — never clobber an explicit `.skipped` or `.denied`
        // that the user has already acknowledged; that would replay the
        // deny-recovery banner surprise.
        syncChoreographyFromTCC(surface: .screenRecording,
                                 status: screenRecordingPermission.status)
        syncChoreographyFromTCC(surface: .accessibility,
                                 status: accessibilityPermission.status)
        permissionRefreshCount += 1
    }

    /// Overlay a fresh TCC status onto the choreography outcome for a
    /// surface, but only when it advances the state — never regress a
    /// user-acknowledged terminal outcome. Called from `refreshPermissions()`.
    private func syncChoreographyFromTCC(surface: PermissionSurface,
                                          status: TCCStatus) {
        let existing = permissionResults[surface] ?? .pending
        switch (existing, status) {
        case (.pending, .granted):
            permissionResults[surface] = .granted
            if let idx = Self.permissionSequence.firstIndex(of: surface),
               idx == permissionSequenceIndex {
                advancePermissionSequence()
            }
        default:
            break
        }
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
