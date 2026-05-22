import SwiftUI
import OnboardingKit

struct PermissionStepView: View {
    let title: String
    let explanation: String
    let permissionKind: TCCPermissionKind

    @EnvironmentObject var flowVM: OnboardingFlowViewModel
    @State private var userConfirmedHelper = false

    private var permission: (any TCCPermission)? {
        switch permissionKind {
        case .screenRecording: return flowVM.screenRecordingPermission
        case .accessibility: return flowVM.accessibilityPermission
        case .automation: return flowVM.automationPermission
        }
    }

    private var isDualGrantStep: Bool {
        permissionKind == .screenRecording
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: iconName)
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text(title)
                .font(.title)
                .fontWeight(.semibold)

            Text(explanation)
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            if isDualGrantStep {
                dualGrantSection
            } else if let perm = permission {
                statusBadge(perm.status)

                Button("Open System Settings") {
                    perm.requestOrOpenSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Text("You can revoke this at any time in System Settings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var dualGrantSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Two binaries need Screen Recording permission:")
                .font(.callout)
                .fontWeight(.medium)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "menubar.rectangle")
                        .frame(width: 20)
                    VStack(alignment: .leading) {
                        Text("Hippocampus")
                            .font(.body.weight(.medium))
                        Text("The menu-bar app")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let perm = permission {
                        statusDot(perm.status)
                    }
                }

                HStack(spacing: 10) {
                    Image(systemName: "gearshape")
                        .frame(width: 20)
                    VStack(alignment: .leading) {
                        Text("MCICaptureHelper")
                            .font(.body.weight(.medium))
                        Text("The capture engine (child process)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusDot(userConfirmedHelper ? .granted : .notRequested)
                }
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 400)

            Text("macOS evaluates each binary separately. Both must be granted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }

        if let perm = permission {
            Button("Open Screen Recording Settings") {
                perm.requestOrOpenSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("If MCICaptureHelper isn't listed:")
                .font(.callout)
                .fontWeight(.medium)

            VStack(alignment: .leading, spacing: 4) {
                Label("Click the + button in System Settings", systemImage: "plus.circle")
                Label("Press Cmd+Shift+. to show hidden files", systemImage: "keyboard")
                Label("Navigate to:", systemImage: "folder")
                Text("~/Applications/Hippocampus.app/Contents/MacOS/MCICaptureHelper")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.leading, 28)
                    .textSelection(.enabled)
                Label("Select it and toggle on", systemImage: "checkmark.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 400)

        Toggle("I granted both binaries", isOn: $userConfirmedHelper)
            .toggleStyle(.checkbox)
    }

    @ViewBuilder
    private func statusDot(_ status: TCCStatus) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 8, height: 8)
    }

    private var iconName: String {
        switch permissionKind {
        case .screenRecording: return "rectangle.inset.filled.and.person.filled"
        case .accessibility: return "accessibility"
        case .automation: return "gearshape.2"
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: TCCStatus) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 8, height: 8)
            Text(statusLabel(status))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
    }

    private func statusColor(_ status: TCCStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .notRequested: return .orange
        }
    }

    private func statusLabel(_ status: TCCStatus) -> String {
        switch status {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notRequested: return "Not yet granted"
        }
    }
}
