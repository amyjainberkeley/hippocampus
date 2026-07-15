import SwiftUI
import OnboardingKit

struct RetentionSlide: View {
    @EnvironmentObject var retentionVM: RetentionViewModel
    @EnvironmentObject var trustVM: TrustPanelViewModel

    var body: some View {
        SlideContainer {
            VStack(spacing: OnboardingDesign.Space.xl) {
                VStack(spacing: OnboardingDesign.Space.md) {
                    SectionChip(text: "Retention")
                    OnboardingDesign.TypeRamp.title("Retention and privacy")
                        .multilineTextAlignment(.center)
                }

                OnboardingDesign.TypeRamp.body("Choose how long Hippocampus keeps your memories. Deleted data is crypto-shredded — the encryption key for that segment is destroyed.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: OnboardingDesign.Width.prose)

                retentionPicker

                blockedAppsPreview
            }
        }
        .task { await retentionVM.load() }
    }

    private var retentionPicker: some View {
        VStack(spacing: OnboardingDesign.Space.lg) {
            HStack(spacing: OnboardingDesign.Space.md) {
                retentionCard(.sevenDays)
                retentionCard(.thirtyDays)
                retentionCard(.forever)
            }

            if retentionVM.selectedPolicy == .custom {
                VStack(spacing: OnboardingDesign.Space.sm - 2) {
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
                    .tint(OnboardingDesign.Palette.accent)
                    HStack {
                        OnboardingDesign.TypeRamp.footnote("1 day").foregroundStyle(.tertiary)
                        Spacer()
                        OnboardingDesign.TypeRamp.footnote("365 days").foregroundStyle(.tertiary)
                    }
                }
            }

            Button("Custom duration") {
                retentionVM.selectedPolicy = .custom
            }
            .onboardingText(color: OnboardingDesign.Palette.accent)
            .opacity(retentionVM.selectedPolicy == .custom ? 0 : 1)
        }
        .frame(maxWidth: 420)
    }

    private func retentionCard(_ policy: RetentionPolicy) -> some View {
        let selected = retentionVM.selectedPolicy == policy
        return Button {
            retentionVM.selectedPolicy = policy
        } label: {
            VStack(spacing: OnboardingDesign.Space.sm - 2) {
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
            .padding(OnboardingDesign.Space.lg - 2)
            .background(
                selected ? OnboardingDesign.Palette.accentSoft : Color.clear,
                in: RoundedRectangle(cornerRadius: OnboardingDesign.Radius.control, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OnboardingDesign.Radius.control, style: .continuous)
                    .stroke(
                        selected ? OnboardingDesign.Palette.accent : OnboardingDesign.Palette.hairline,
                        lineWidth: selected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var blockedAppsPreview: some View {
        VStack(alignment: .leading, spacing: OnboardingDesign.Space.sm) {
            Text("Always blocked")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            let deniedApps = trustVM.denylistEntries.prefix(5)
            if deniedApps.isEmpty {
                defaultBlockedList
            } else {
                ForEach(Array(deniedApps)) { entry in
                    HStack(spacing: OnboardingDesign.Space.sm) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(OnboardingDesign.Palette.excluded)
                            .font(.system(size: 12))
                        OnboardingDesign.TypeRamp.mono(entry.value)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: OnboardingDesign.Space.md)
        .frame(maxWidth: 420)
    }

    private var defaultBlockedList: some View {
        VStack(alignment: .leading, spacing: OnboardingDesign.Space.xs) {
            blockedRow("1Password")
            blockedRow("Chase Banking")
            blockedRow("Messages")
            blockedRow("FaceTime")
            blockedRow("Safari Private Browsing")
        }
    }

    private func blockedRow(_ name: String) -> some View {
        HStack(spacing: OnboardingDesign.Space.sm) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(OnboardingDesign.Palette.excluded)
                .font(.system(size: 12))
            Text(name)
                .font(.system(size: 12))
        }
    }
}
