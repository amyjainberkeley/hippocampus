import AppKit
import RecallUIKit
import SwiftUI

struct PrivacyMomentsView: View {
    @StateObject var viewModel: PrivacyMomentsViewModel

    var body: some View {
        Group {
            if viewModel.errorMessage != nil {
                // Cycle 8.54 copy audit — plain-English memory-
                // unreachable copy (no raw error, no jargon).
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        UserFacingCopy.memoryUnreachableTitle,
                        systemImage: "exclamationmark.triangle.fill",
                        description: Text(UserFacingCopy.memoryUnreachableBody)
                    )
                    .foregroundStyle(Color.brandError)

                    Button(UserFacingCopy.openHippocampusAction) {
                        let appPath = NSHomeDirectory() + "/Applications/Hippocampus.app"
                        NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.brandMint)
                }
            } else if viewModel.isLoading && viewModel.moments.isEmpty {
                ShimmerLoadingView(isLoading: true)
            } else if viewModel.moments.isEmpty {
                // Cycle 8.49 polished empty state (audit-gap fix).
                MCIEmptyState.noPrivacyMoments()
            } else {
                List(viewModel.moments) { moment in
                    PrivacyMomentCard(moment: moment)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.brandBgPrimary)
                .refreshable {
                    await viewModel.reload()
                }
            }
        }
        .background(Color.brandBgPrimary)
        .task {
            await viewModel.reload()
        }
    }
}

struct PrivacyMomentCard: View {
    let moment: PrivacyMoment

    var body: some View {
        // MCIDesignSystem cycle 8.48: card rhythm on 8pt grid + Stripe
        // two-weight typography (.bodyStrong for the redaction headline).
        VStack(alignment: .leading, spacing: MCI.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "eye.slash.fill")
                    .foregroundStyle(Color.brandMintDim)
                Text("Hippocampus redacted this")
                    .mciFont(.bodyStrong)
                    .foregroundStyle(Color.brandFgPrimary)
                Spacer()
                Text(ReasonStrings.sectionTag(for: moment.reasonCode))
                    .font(MCI.Font.mono)
                    .foregroundStyle(Color.brandMintDim)
            }
            Grid(alignment: .leading, horizontalSpacing: MCI.Spacing.s, verticalSpacing: MCI.Spacing.xs) {
                GridRow {
                    Text("App:").foregroundStyle(Color.brandFgMuted)
                    Text(moment.appBundleId ?? "(unknown)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.brandFgSecondary)
                }
                GridRow {
                    Text("Time:").foregroundStyle(Color.brandFgMuted)
                    Text(Formatters.relativeTime(usSinceEpoch: moment.tsUs))
                        .font(.system(.body, design: .default))
                        .foregroundStyle(Color.brandFgSecondary)
                        .help(Formatters.tsString(usSinceEpoch: moment.tsUs))
                }
                GridRow {
                    Text("Reason:").foregroundStyle(Color.brandFgMuted)
                    Text(ReasonStrings.string(for: moment.reasonCode))
                        .foregroundStyle(Color.brandFgSecondary)
                }
            }
            Text("(no content captured)")
                .font(.caption)
                .foregroundStyle(Color.brandFgMuted)
        }
        .padding(MCI.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: MCI.Radius.m)
                .fill(Color.brandCardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MCI.Radius.m)
                .stroke(Color.brandCardBorder, lineWidth: 0.5)
        )
        .mciShadow(.card)
        .padding(.vertical, MCI.Spacing.xs)
    }
}
