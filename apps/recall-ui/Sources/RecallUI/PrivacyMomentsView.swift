// PrivacyMomentsView.swift — opaque cards for cascade-suppressed events.
//
// Each card carries ONLY {appBundleId, ts, reason-string} per ADR-0017
// §5.1. NEVER the OCR'd text (it didn't reach OCR), NEVER the keyframe
// (it wasn't stored), NEVER the windowTitle/url (content-as-content
// invariant). The friendly-string map lives in ReasonStrings.

import SwiftUI
import RecallUIKit

struct PrivacyMomentsView: View {
    @StateObject var viewModel: PrivacyMomentsViewModel

    var body: some View {
        Group {
            if let err = viewModel.errorMessage {
                ContentUnavailableView(
                    "Privacy moments failed to load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(err)
                )
            } else if viewModel.isLoading && viewModel.moments.isEmpty {
                ProgressView("Loading privacy moments…")
            } else if viewModel.moments.isEmpty {
                ContentUnavailableView(
                    "No privacy moments yet",
                    systemImage: "eye.slash",
                    description: Text(
                        "MCI hasn't redacted anything for this brain yet."
                    )
                )
            } else {
                List(viewModel.moments) { moment in
                    PrivacyMomentCard(moment: moment)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .refreshable {
                    await viewModel.reload()
                }
            }
        }
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
                    .foregroundStyle(.secondary)
                Text("MCI redacted this")
                    .font(.headline)
                Spacer()
                Text(ReasonStrings.sectionTag(for: moment.reasonCode))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("App:").foregroundStyle(.secondary)
                    Text(moment.appBundleId ?? "(unknown)")
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Time:").foregroundStyle(.secondary)
                    Text(Formatters.tsString(usSinceEpoch: moment.tsUs))
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Reason:").foregroundStyle(.secondary)
                    Text(ReasonStrings.string(for: moment.reasonCode))
                }
            }
            Text("(no content captured)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.4), lineWidth: 0.5)
        )
        .padding(.vertical, 4)
    }
}
