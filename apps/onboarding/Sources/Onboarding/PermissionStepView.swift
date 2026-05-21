import SwiftUI
import OnboardingKit

struct PermissionStepView: View {
    let title: String
    let explanation: String
    let permissionKind: TCCPermissionKind

    @EnvironmentObject var flowVM: OnboardingFlowViewModel

    private var permission: (any TCCPermission)? {
        switch permissionKind {
        case .screenRecording: return flowVM.screenRecordingPermission
        case .accessibility: return flowVM.accessibilityPermission
        case .automation: return flowVM.automationPermission
        }
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

            if let perm = permission {
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
