// TimelineView.swift — chronological list of recent events (no query).
// First load fires on appear; pull-to-refresh re-loads.

import SwiftUI
import RecallUIKit

struct TimelineView: View {
    @StateObject var viewModel: TimelineViewModel

    var body: some View {
        Group {
            if let err = viewModel.errorMessage {
                ContentUnavailableView(
                    "Timeline failed to load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(err)
                )
            } else if viewModel.isLoading && viewModel.hits.isEmpty {
                ProgressView("Loading timeline…")
            } else if viewModel.hits.isEmpty {
                ContentUnavailableView(
                    "No events yet",
                    systemImage: "clock",
                    description: Text(
                        "MCI hasn't recorded anything for this brain yet."
                    )
                )
            } else {
                List(viewModel.hits) { hit in
                    HitRow(hit: hit)
                }
                .listStyle(.inset)
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
