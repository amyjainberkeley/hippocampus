import SwiftUI
import OnboardingKit

struct RetentionPolicyView: View {
    @EnvironmentObject var retentionVM: RetentionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Retention Policy")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Choose how long Hippocampus keeps your memories. Deleted data is crypto-shredded — the encryption key for that segment is destroyed, making recovery impossible even from backups.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ForEach([RetentionPolicy.forever, .thirtyDays, .sevenDays], id: \.self) { policy in
                    presetCard(policy)
                }
            }

            if retentionVM.selectedPolicy == .custom {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keep for \(retentionVM.customDays) days")
                        .font(.callout)
                        .fontWeight(.medium)
                    Slider(
                        value: Binding(
                            get: { Double(retentionVM.customDays) },
                            set: { retentionVM.customDays = Int($0) }
                        ),
                        in: 1...365,
                        step: 1
                    )
                    HStack {
                        Text("1 day")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("365 days")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Button("Custom duration") {
                retentionVM.selectedPolicy = .custom
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .opacity(retentionVM.selectedPolicy == .custom ? 0 : 1)
        }
        .task { await retentionVM.load() }
    }

    private func presetCard(_ policy: RetentionPolicy) -> some View {
        Button {
            retentionVM.selectedPolicy = policy
        } label: {
            VStack(spacing: 8) {
                Text(policy.displayName)
                    .font(.headline)
                if policy == .forever {
                    Text("Default")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let d = policy.days {
                    Text("then forget")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let _ = d // suppress warning
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                retentionVM.selectedPolicy == policy
                    ? Color.accentColor.opacity(0.1)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        retentionVM.selectedPolicy == policy
                            ? Color.accentColor
                            : Color.secondary.opacity(0.3),
                        lineWidth: retentionVM.selectedPolicy == policy ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
