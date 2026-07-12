import SwiftUI
import OnboardingKit

struct PermissionsSlide: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @State private var userConfirmedHelper = false
    @State private var isResetting = false
    @State private var showResetFailedFallback = false
    /// SwiftUI timer polled every 1 s while this slide is on screen.
    /// Lets the slide auto-detect a Screen Recording / Accessibility
    /// grant made by the user in System Settings without requiring
    /// them to leave + re-enter the slide. Combined with the
    /// `RealTCCPermission.requestOrOpenSettings` change to deep-link
    /// instead of calling `CGRequestScreenCaptureAccess` (which
    /// terminates the app on grant), the user never sees the
    /// onboarding window disappear under them.
    private let pollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var screenRecording: any TCCPermission {
        flowVM.screenRecordingPermission
    }

    private var accessibility: any TCCPermission {
        flowVM.accessibilityPermission
    }

    private var screenRecordingDenied: Bool {
        screenRecording.status == .denied
    }

    var body: some View {
        SlideContainer {
            VStack(spacing: 24) {
                OnboardingTheme.title("macOS requires your permission")

                Text("Frames are OCR'd in memory and discarded — only the extracted text and structured event metadata are stored.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)

                // Pre-flight overview: shows ALL 4 upcoming TCC asks
                // before the first OS dialog fires. Kills the Rewind
                // bad pattern (surprise dialog #3 on the Browser
                // Extension slide + surprise FDA on Allowlist).
                // Renders above the per-permission grant sections so
                // the user sees the map first, then the actions.
                TCCPreflightOverview(
                    screenRecordingStatus: screenRecording.status,
                    accessibilityStatus: accessibility.status,
                    automationStatus: flowVM.automationPermission.status,
                    fullDiskAccessStatus: flowVM.fullDiskAccessStatus
                )

                if screenRecordingDenied {
                    denialRecoveryBanner
                }

                screenRecordingSection

                accessibilitySection

                Text("You can revoke any permission at any time in System Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            flowVM.refreshPermissions()
        }
        .task {
            // Snapshot FDA status into the flow VM so the pre-flight
            // overview pill reflects any prior grant (e.g. user came
            // back to Permissions from the Allowlist slide).
            await flowVM.refreshFullDiskAccessStatus()
        }
        .onReceive(pollTimer) { _ in
            // Cheap CGPreflightScreenCaptureAccess / AXIsProcessTrusted
            // checks (both ~µs). Only fires while the slide is on
            // screen; the OnboardingFlowView's `switch flowVM.currentStep`
            // tears the view down when the user advances, which stops
            // the timer subscription via .autoconnect's lifecycle.
            flowVM.refreshPermissions()
        }
    }

    private var denialRecoveryBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 16))
                Text("Screen Recording was denied")
                    .font(.system(size: 14, weight: .semibold))
            }

            Text("macOS will not re-prompt until you reset the permission. Use the button below to clear the old entry and try again.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    Task { await performResetAndRetry() }
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
                .buttonStyle(.borderedProminent)
                .tint(OnboardingTheme.accentBlue)
                .controlSize(.regular)
                .disabled(isResetting)

                Button("Open Privacy Settings") {
                    screenRecording.openPrivacySettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            if showResetFailedFallback {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Still denied after reset.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.red)
                    Text("Open System Settings → Privacy & Security → Screen Recording. Remove any entries titled \"MCICaptureHelper\" with a path that does NOT start with /Applications/Hippocampus.app/. Then quit Hippocampus and reopen it.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func performResetAndRetry() async {
        isResetting = true
        showResetFailedFallback = false

        let succeeded = await screenRecording.resetAndRetry()

        isResetting = false
        flowVM.refreshPermissions()

        if !succeeded {
            showResetFailedFallback = true
        }
    }

    private var screenRecordingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Screen Recording", systemImage: "rectangle.inset.filled.and.person.filled")
                .font(.system(size: 15, weight: .semibold))

            Text("macOS evaluates permissions for two binaries separately: Hippocampus.app and MCICaptureHelper.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                binaryRow(
                    icon: "menubar.rectangle",
                    name: "Hippocampus",
                    detail: "The menu-bar app",
                    status: screenRecording.status
                )
                binaryRow(
                    icon: "gearshape",
                    name: "MCICaptureHelper",
                    detail: "The capture engine (child process)",
                    status: userConfirmedHelper ? .granted : .notRequested
                )
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            if screenRecording.status == .notRequested {
                Button("Open Screen Recording Settings") {
                    screenRecording.requestOrOpenSettings()
                    flowVM.refreshPermissions()
                }
                .buttonStyle(.borderedProminent)
                .tint(OnboardingTheme.accentBlue)
                .controlSize(.regular)
            } else if screenRecording.status == .granted {
                Label("Screen Recording granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13, weight: .medium))
            }

            helperInstructions

            Toggle("I granted both binaries", isOn: $userConfirmedHelper)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
        }
        .padding(16)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var accessibilitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Accessibility (optional)", systemImage: "accessibility")
                .font(.system(size: 15, weight: .semibold))

            Text("Lets Hippocampus detect password fields so it knows NOT to capture them. Recommended but not required.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                statusDot(accessibility.status)
                Text(statusLabel(accessibility.status))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()

                if accessibility.status == .denied {
                    Button("Reset & retry") {
                        Task {
                            _ = await accessibility.resetAndRetry()
                            flowVM.refreshPermissions()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if accessibility.status != .granted {
                    Button("Grant") {
                        accessibility.requestOrOpenSettings()
                        flowVM.refreshPermissions()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 14))
                }
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var helperInstructions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("If MCICaptureHelper isn't listed:")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Group {
                Label("Click + in System Settings", systemImage: "plus.circle")
                Label("Press Cmd+Shift+. to show hidden files", systemImage: "keyboard")
                Label("Navigate to Hippocampus.app → Contents → MacOS → MCICaptureHelper",
                      systemImage: "folder")
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
    }

    private func binaryRow(icon: String, name: String, detail: String,
                           status: TCCStatus) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            statusDot(status)
        }
    }

    private func statusDot(_ status: TCCStatus) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 8, height: 8)
    }

    private func statusColor(_ status: TCCStatus) -> Color {
        switch status {
        case .granted: .green
        case .denied: .red
        case .notRequested: .orange
        }
    }

    private func statusLabel(_ status: TCCStatus) -> String {
        switch status {
        case .granted: "Granted"
        case .denied: "Denied"
        case .notRequested: "Not yet granted"
        }
    }
}
