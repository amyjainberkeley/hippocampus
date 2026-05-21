import SwiftUI
import OnboardingKit

struct TrustPanelView: View {
    @EnvironmentObject var trustVM: TrustPanelViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    cascadeSection
                    allowlistSection
                    denylistSection
                    readOnlyNotice
                }
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .task { await trustVM.load() }
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 4) {
            Text("What Hippocampus Sees")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Seven layers of protection, applied in order before anything is stored.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    @ViewBuilder
    private var cascadeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Privacy Cascade")
                .font(.headline)
            ForEach(trustVM.cascadeSteps) { step in
                HStack(alignment: .top, spacing: 10) {
                    Text("§\(step.section)")
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.bold)
                        .frame(width: 24)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.label)
                            .font(.callout)
                            .fontWeight(.medium)
                        Text(step.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var allowlistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allowed Apps")
                .font(.headline)
            Text("These apps are cleared for capture. The list is managed by Hippocampus security review.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if trustVM.isLoading {
                ProgressView()
            } else {
                ForEach(trustVM.allowlistEntries) { entry in
                    HStack {
                        Text(entry.bundleId)
                            .font(.system(.callout, design: .monospaced))
                        Spacer()
                        Text(entry.rationale)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var denylistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Denylist Categories")
                .font(.headline)
            Text("You can tell Hippocampus to ignore specific apps, URLs, or window titles. These are strictly additive — they only block, never allow.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(trustVM.denylistCategories) { cat in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cat.name)
                            .font(.callout)
                            .fontWeight(.medium)
                        Text(cat.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var readOnlyNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
            Text("Read-only — managed by Hippocampus security review. You cannot add or remove allowed apps in this version.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
