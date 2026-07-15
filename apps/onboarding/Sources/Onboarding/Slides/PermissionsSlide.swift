import SwiftUI
import OnboardingKit

/// Cotypist peer-study P0 pattern #2 — deferred-permission choreography.
///
/// The slide preserves the PR #44 pre-flight overview at the top ("here's
/// the four TCC / FDA surfaces you'll be asked for") and then walks the
/// user through the sequence ONE surface at a time. Each sub-step renders:
///   1. A permission-specific title + plain-English "why" copy.
///   2. A prominent "Grant" button → fires the TCC probe.
///   3. A "Skip for now" button (always available — accessibility requirement).
///   4. An inline denial-recovery banner if the user denied, with a
///      "Continue" button that advances the sequence without blocking.
///
/// After every surface has an outcome the slide shows a compact summary
/// and the standard `OnboardingFlowView` "Next" affordance advances to
/// `.primaryHotkey`. `canAdvance` on the flow VM still gates on Screen
/// Recording being `.granted` (the only hard-required surface).
struct PermissionsSlide: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @State private var isResetting = false
    @State private var showResetFailedFallback = false
    /// SwiftUI timer polled every 1 s while this slide is on screen.
    /// Lets the slide auto-detect a Screen Recording / Accessibility
    /// grant made by the user in System Settings without requiring
    /// them to leave + re-enter the slide.
    private let pollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var screenRecording: any TCCPermission {
        flowVM.screenRecordingPermission
    }

    private var accessibility: any TCCPermission {
        flowVM.accessibilityPermission
    }

    var body: some View {
        SlideContainer {
            VStack(spacing: OnboardingDesign.Space.xl) {
                OnboardingTheme.title("macOS requires your permission")

                // The Cotypist "neither stored nor sent" moment — turn the
                // scariest ask (Screen Recording) into a reassurance. The
                // claim is exact: frames are OCR'd in memory and discarded;
                // only the extracted text is persisted, encrypted, locally.
                ReassuranceBanner(
                    systemImage: "eye.slash.fill",
                    message: "Screen frames are OCR'd in memory and instantly discarded — the picture is never saved or sent anywhere. Only the extracted text stays, encrypted, on this Mac.",
                    highlight: "never saved or sent anywhere"
                )

                // The Raycast "Ask anything" assurance strip — three short
                // promises with a popover that spells each one out.
                AssuranceRow(items: [
                    AssuranceItem(
                        icon: "desktopcomputer",
                        title: "On-device",
                        detail: "OCR and indexing run entirely on your Mac — no server ever sees your screen."
                    ),
                    AssuranceItem(
                        icon: "icloud.slash",
                        title: "No collection",
                        detail: "Nothing is uploaded. Hippocampus makes zero network calls with your captured content."
                    ),
                    AssuranceItem(
                        icon: "lock.fill",
                        title: "Encrypted",
                        detail: "The text index is sealed with a 256-bit key that never leaves this Mac."
                    ),
                ])

                // Pre-flight overview (PR #44) — kept at the top so the
                // user still sees the map of all upcoming asks before
                // the first OS dialog fires.
                TCCPreflightOverview(
                    screenRecordingStatus: screenRecording.status,
                    accessibilityStatus: accessibility.status,
                    automationStatus: flowVM.automationPermission.status,
                    fullDiskAccessStatus: flowVM.fullDiskAccessStatus
                )

                // The choreographed sub-step. Renders one surface at a
                // time; advances via `flowVM.recordPermissionOutcome`.
                if let surface = flowVM.currentPermissionSurface {
                    permissionCard(for: surface)
                } else {
                    choreographyCompleteSummary
                }

                Text("You can revoke any permission at any time in System Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            flowVM.refreshPermissions()
        }
        .task {
            await flowVM.refreshFullDiskAccessStatus()
        }
        .onReceive(pollTimer) { _ in
            // Cheap CGPreflightScreenCaptureAccess / AXIsProcessTrusted
            // checks. Also opportunistically syncs the choreography
            // outcome map when the user grants via System Settings.
            flowVM.refreshPermissions()
        }
    }

    // MARK: - Per-surface card (one at a time)

    @ViewBuilder
    private func permissionCard(for surface: PermissionSurface) -> some View {
        let copy = PermissionCopy.for(surface)
        let currentStatus = statusFor(surface)
        let outcome = flowVM.permissionResults[surface] ?? .pending

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: copy.icon)
                    .foregroundStyle(OnboardingDesign.Palette.accent)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text(copy.title)
                        .font(.system(size: 16, weight: .semibold))
                    Text(copy.requirementBadge)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Step \(flowVM.permissionSequenceIndex + 1) of \(OnboardingFlowViewModel.permissionSequence.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Text(copy.why)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Grant / skip row. Both buttons are always present — the
            // Skip affordance is an accessibility requirement (SetApp /
            // Alfred conflicts, corporate-managed Macs where TCC is
            // MDM-locked, etc. must never dead-end the user).
            if currentStatus != .granted && outcome != .denied {
                HStack(spacing: 12) {
                    Button {
                        grantCurrent(surface: surface)
                    } label: {
                        Label("Grant \(copy.shortName)", systemImage: "checkmark.shield")
                    }
                    .onboardingPrimary()

                    Button("Skip for now") {
                        flowVM.recordPermissionOutcome(surface, .skipped)
                    }
                    .onboardingSecondary()
                }
            }

            // Inline denial-recovery banner. Matches Cotypist pattern —
            // banner, not modal; "Continue" advances without blocking.
            // Screen Recording is the exception: it's hard-required, so
            // we surface the Reset & Retry affordance from PR #44
            // rather than a "Continue" that would silently drop the
            // user into a broken app.
            if outcome == .denied || (currentStatus == .denied && outcome == .pending) {
                denialRecoveryBanner(for: surface, copy: copy)
            }

            // Post-grant confirmation.
            if currentStatus == .granted {
                HStack(spacing: 8) {
                    Label("\(copy.shortName) granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Continue") {
                        flowVM.recordPermissionOutcome(surface, .granted)
                    }
                    .onboardingSecondary()
                }
            }
        }
        .glassCard(padding: OnboardingDesign.Space.lg)
        .frame(maxWidth: 520)
    }

    // MARK: - Denial recovery (inline, matches Cotypist)

    @ViewBuilder
    private func denialRecoveryBanner(for surface: PermissionSurface,
                                       copy: PermissionCopy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 14))
                Text("\(copy.shortName) was denied")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(copy.denialRecovery)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if surface == .screenRecording {
                    // Screen Recording is hard-required. Offer the
                    // Reset & Retry affordance (PR #44) rather than
                    // "Continue" — a "Continue" past denied SR would
                    // drop the user into a non-functional app.
                    Button {
                        Task { await performResetAndRetry(surface: surface) }
                    } label: {
                        if isResetting {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Resetting...")
                            }
                        } else {
                            Label("Reset & retry", systemImage: "arrow.clockwise")
                        }
                    }
                    .onboardingPrimary()
                    .disabled(isResetting)
                } else {
                    // AX / Automation / FDA are soft-fail — inline
                    // "Continue" advances the sequence, matching the
                    // Cotypist pattern.
                    Button("Continue") {
                        flowVM.recordPermissionOutcome(surface, .denied)
                    }
                    .onboardingPrimary()
                }

                Button("Open Privacy Settings") {
                    openSettingsFor(surface: surface)
                }
                .onboardingSecondary()
            }

            if showResetFailedFallback && surface == .screenRecording {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Still denied after reset.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                    // Cycle 8.54 copy audit — pared down the engineer-
                    // only "MCICaptureHelper" bundle-name leak; users
                    // still get the concrete fix path (Settings pane +
                    // relaunch) without the internal bundle jargon.
                    Text("Open System Settings → Privacy & Security → Screen Recording. Remove any duplicate Hippocampus entries whose path is not in /Applications, then quit Hippocampus and reopen it.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(OnboardingDesign.Space.md)
        .background(
            OnboardingDesign.Palette.attention.opacity(0.10),
            in: RoundedRectangle(cornerRadius: OnboardingDesign.Radius.card)
        )
    }

    // MARK: - Choreography-complete summary

    private var choreographyCompleteSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Permissions set")
                    .font(.system(size: 14, weight: .semibold))
            }
            ForEach(OnboardingFlowViewModel.permissionSequence, id: \.self) { surface in
                let outcome = flowVM.permissionResults[surface] ?? .pending
                if outcome != .notApplicable {
                    HStack(spacing: 8) {
                        Image(systemName: iconFor(outcome: outcome))
                            .foregroundStyle(colorFor(outcome: outcome))
                            .font(.system(size: 11))
                        Text(PermissionCopy.for(surface).shortName)
                            .font(.system(size: 12))
                        Spacer()
                        Text(labelFor(outcome: outcome))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .glassCard(padding: OnboardingDesign.Space.md)
        .frame(maxWidth: 520)
    }

    // MARK: - Actions

    private func grantCurrent(surface: PermissionSurface) {
        switch surface {
        case .screenRecording:
            screenRecording.requestOrOpenSettings()
        case .accessibility:
            accessibility.requestOrOpenSettings()
        case .automation:
            // No probe here — surprise-dialog #3 pattern. The Browser
            // Extension slide fires the real Automation probe on Safari
            // install click. For the choreography we just mark skipped
            // so the sequence advances; the user will see the OS dialog
            // in context on the Browser Extension slide.
            flowVM.recordPermissionOutcome(surface, .skipped)
        case .fullDiskAccess:
            // FDA is contextual — deferred to the Allowlist slide when
            // the user toggles a Messages / Mail deep-hook ON. Same
            // rationale as Automation.
            flowVM.recordPermissionOutcome(surface, .skipped)
        }
        flowVM.refreshPermissions()
    }

    private func openSettingsFor(surface: PermissionSurface) {
        switch surface {
        case .screenRecording: screenRecording.openPrivacySettings()
        case .accessibility:   accessibility.openPrivacySettings()
        case .automation:      flowVM.automationPermission.openPrivacySettings()
        case .fullDiskAccess:  break
        }
    }

    private func performResetAndRetry(surface: PermissionSurface) async {
        isResetting = true
        showResetFailedFallback = false
        let target: any TCCPermission = surface == .screenRecording
            ? screenRecording : accessibility
        let succeeded = await target.resetAndRetry()
        isResetting = false
        flowVM.refreshPermissions()
        if !succeeded {
            showResetFailedFallback = true
        }
    }

    // MARK: - Status readouts

    private func statusFor(_ surface: PermissionSurface) -> TCCStatus {
        switch surface {
        case .screenRecording: screenRecording.status
        case .accessibility:   accessibility.status
        case .automation:      flowVM.automationPermission.status
        case .fullDiskAccess:  .notRequested
        }
    }

    private func iconFor(outcome: PermissionOutcome) -> String {
        switch outcome {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .skipped: "forward.circle"
        case .pending, .notApplicable: "circle"
        }
    }

    private func colorFor(outcome: PermissionOutcome) -> Color {
        switch outcome {
        case .granted: .green
        case .denied: .red
        case .skipped: .orange
        case .pending, .notApplicable: .secondary
        }
    }

    private func labelFor(outcome: PermissionOutcome) -> String {
        switch outcome {
        case .granted: "Granted"
        case .denied: "Denied · will retry later"
        case .skipped: "Skipped"
        case .pending: "Pending"
        case .notApplicable: "N/A"
        }
    }
}

/// Load-bearing per-surface copy for the choreography. Kept as a Slide-
/// local view helper (not `OnboardingCopy`) so the marketing-facing
/// strings there stay focused on marketing / migrator copy and slide
/// copy stays with the slide.
private struct PermissionCopy {
    let title: String
    let shortName: String
    let icon: String
    let requirementBadge: String
    let why: String
    let denialRecovery: String

    static func `for`(_ surface: PermissionSurface) -> PermissionCopy {
        switch surface {
        case .screenRecording:
            return PermissionCopy(
                title: "Screen Recording",
                shortName: "Screen Recording",
                icon: "rectangle.inset.filled.and.person.filled",
                requirementBadge: "Required",
                why: "Lets Hippocampus see what's on your screen so we can OCR it in memory and index the text. Frames are discarded — only the extracted text is stored, and everything stays on your Mac.",
                denialRecovery: "Screen Recording is required for Hippocampus to work. macOS won't re-prompt automatically — use Reset & Retry to clear the old TCC entry and try again."
            )
        case .accessibility:
            return PermissionCopy(
                title: "Accessibility",
                shortName: "Accessibility",
                icon: "accessibility",
                requirementBadge: "Recommended",
                why: "Lets Hippocampus detect password fields so it knows NOT to capture them. Also improves recall accuracy on native macOS apps. Recommended but not required — you can still use Hippocampus without it.",
                denialRecovery: "That's OK — Hippocampus still works, but it won't be able to detect password fields automatically. You can grant Accessibility later from Settings if you change your mind."
            )
        case .automation:
            return PermissionCopy(
                title: "Automation (Safari)",
                shortName: "Automation",
                icon: "applescript",
                requirementBadge: "Optional · only if you use Safari",
                why: "Only if you plan to use the Safari extension — lets Hippocampus open Settings → Extensions with one click. If you use Chrome, Arc, or another browser, skip this step.",
                denialRecovery: "That's OK — you can still install the Safari extension manually from Settings → Extensions. Grant later in Privacy & Security → Automation if you want the one-click flow."
            )
        case .fullDiskAccess:
            return PermissionCopy(
                title: "Full Disk Access",
                shortName: "Full Disk Access",
                icon: "externaldrive",
                requirementBadge: "Optional · only for Messages / Mail",
                why: "Only if you want Hippocampus to remember Messages or Mail conversations. Skip this if you only want browser + app-window capture. You can enable per-app deep-hooks later on the Allowlist step.",
                denialRecovery: "That's OK — Hippocampus still remembers everything you see on screen. Messages / Mail deep-integration is off; you can toggle it later on the Allowlist step."
            )
        }
    }
}
