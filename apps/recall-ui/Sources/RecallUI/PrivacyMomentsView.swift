import AppKit
import RecallUIKit
import SwiftUI

struct PrivacyMomentsView: View {
    @StateObject var viewModel: PrivacyMomentsViewModel

    var body: some View {
        Group {
            if let err = viewModel.errorMessage {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Couldn't open your brain",
                        systemImage: "exclamationmark.triangle.fill",
                        description: Text("Check that the helper is running.\n\(err)")
                    )
                    .foregroundStyle(Color.brandError)

                    Button("Open Hippocampus.app") {
                        let appPath = NSHomeDirectory() + "/Applications/MCICaptureHelper.app"
                        NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.brandMint)
                }
            } else if viewModel.isLoading && viewModel.moments.isEmpty {
                ShimmerLoadingView(isLoading: true)
            } else if viewModel.moments.isEmpty {
                ContentUnavailableView(
                    "No privacy moments yet",
                    systemImage: "eye.slash",
                    description: Text(
                        "Hippocampus hasn't redacted anything for this brain yet."
                    )
                )
                .foregroundStyle(Color.brandFgSecondary)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "eye.slash.fill")
                    .foregroundStyle(Color.brandMintDim)
                Text("Hippocampus redacted this")
                    .font(.headline)
                    .foregroundStyle(Color.brandFgPrimary)
                Spacer()
                Text(ReasonStrings.sectionTag(for: moment.reasonCode))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.brandMintDim)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
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
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.brandCardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.brandCardBorder, lineWidth: 0.5)
        )
        .padding(.vertical, 4)
    }
}
