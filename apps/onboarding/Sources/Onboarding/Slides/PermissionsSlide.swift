import SwiftUI
import OnboardingKit

struct PermissionsSlide: View {
    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @State private var userConfirmedHelper = false
    @State private var isResetting = false
    @State private var showResetFailedFallback = false

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
            _ = screenRecording.checkCurrent()
            _ = accessibility.checkCurrent()
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

            if !screenRecordingDenied {
                Button("Open Screen Recording Settings") {
                    screenRecording.requestOrOpenSettings()
                }
                .buttonStyle(.borderedProminent)
                .tint(OnboardingTheme.accentBlue)
                .controlSize(.regular)
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
                        Task { await accessibility.resetAndRetry() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Grant") {
                        accessibility.requestOrOpenSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
