import SwiftUI
import OnboardingKit

struct RetentionSlide: View {
    @EnvironmentObject var retentionVM: RetentionViewModel
    @EnvironmentObject var trustVM: TrustPanelViewModel

    var body: some View {
        SlideContainer {
            VStack(spacing: 24) {
                OnboardingTheme.title("Retention and privacy")

                Text("Choose how long Hippocampus keeps your memories. Deleted data is crypto-shredded — the encryption key for that segment is destroyed.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)

                retentionPicker

                blockedAppsPreview
            }
        }
        .task { await retentionVM.load() }
    }

    private var retentionPicker: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                retentionCard(.sevenDays)
                retentionCard(.thirtyDays)
                retentionCard(.forever)
            }

            if retentionVM.selectedPolicy == .custom {
                VStack(spacing: 6) {
                    Text("Keep for \(retentionVM.customDays) days")
                        .font(.system(size: 14, weight: .medium))
                    Slider(
                        value: Binding(
                            get: { Double(retentionVM.customDays) },
                            set: { retentionVM.customDays = Int($0) }
                        ),
                        in: 1...365,
                        step: 1
                    )
                    .tint(OnboardingTheme.accentBlue)
                    HStack {
                        Text("1 day").font(.system(size: 11)).foregroundStyle(.tertiary)
                        Spacer()
                        Text("365 days").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }

            Button("Custom duration") {
                retentionVM.selectedPolicy = .custom
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(OnboardingTheme.accentBlue)
            .opacity(retentionVM.selectedPolicy == .custom ? 0 : 1)
        }
        .frame(maxWidth: 420)
    }

    private func retentionCard(_ policy: RetentionPolicy) -> some View {
        let selected = retentionVM.selectedPolicy == policy
        return Button {
            retentionVM.selectedPolicy = policy
        } label: {
            VStack(spacing: 6) {
                Text(policy.displayName)
                    .font(.system(size: 15, weight: .semibold))
                if policy == .forever {
                    Text("Default")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("then forget")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(
                selected ? OnboardingTheme.accentBlue.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        selected ? OnboardingTheme.accentBlue : Color.secondary.opacity(0.25),
                        lineWidth: selected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var blockedAppsPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Always blocked")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            let deniedApps = trustVM.denylistEntries.prefix(5)
            if deniedApps.isEmpty {
                defaultBlockedList
            } else {
                ForEach(Array(deniedApps)) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 12))
                        Text(entry.value)
                            .font(.system(size: 12, design: .monospaced))
                        Spacer()
                        if entry.source == .csoRatified {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 420)
    }

    private var defaultBlockedList: some View {
        VStack(alignment: .leading, spacing: 4) {
            blockedRow("1Password")
            blockedRow("Chase Banking")
            blockedRow("Messages")
            blockedRow("FaceTime")
            blockedRow("Safari Private Browsing")
        }
    }

    private func blockedRow(_ name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 12))
            Text(name)
                .font(.system(size: 12))
        }
    }
}
