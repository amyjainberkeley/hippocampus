import AppKit
import RecallUIKit
import SwiftUI

struct TimelineView: View {
    @StateObject var viewModel: TimelineViewModel

    var body: some View {
        Group {
            if let err = viewModel.errorMessage {
                errorView(err)
            } else if viewModel.isLoading && viewModel.hits.isEmpty {
                ShimmerLoadingView(isLoading: true)
            } else if viewModel.hits.isEmpty {
                emptyView
            } else {
                contentView
            }
        }
        .background(Color.brandBgPrimary)
        .task {
            await viewModel.reload()
        }
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "No events yet",
            systemImage: "clock",
            description: Text(
                "Start using your Mac normally — Hippocampus is recording in the background."
            )
        )
        .foregroundStyle(Color.brandFgSecondary)
    }

    private func errorView(_ err: String) -> some View {
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
    }

    private var contentView: some View {
        HStack(spacing: 0) {
            List(selection: $viewModel.selectedHitId) {
                ForEach(viewModel.hits) { hit in
                    HitRow(hit: hit)
                        .tag(hit.id)
                        .listRowBackground(
                            viewModel.selectedHitId == hit.id
                                ? Color.brandMintSubtle : Color.clear
                        )
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Color.brandBgPrimary)
            .frame(minWidth: 300)
            .refreshable { await viewModel.reload() }
            .onKeyPress(.return, phases: .down) { _ in
                viewModel.focusDetail()
                return viewModel.selectedHitId != nil ? .handled : .ignored
            }
            .onKeyPress(.escape, phases: .down) { _ in
                if viewModel.isDetailFocused {
                    viewModel.dismissDetail()
                } else {
                    viewModel.selectedHitId = nil
                }
                return .handled
            }

            if viewModel.isDetailFocused, let hit = viewModel.selectedHit {
                Divider().background(Color.brandCardBorder)
                DetailPaneView(hit: hit)
                    .frame(minWidth: 300, idealWidth: 400)
            }
        }
        .onChange(of: viewModel.selectedHitId) { _, newValue in
            if newValue != nil {
                viewModel.isDetailFocused = true
            }
        }
    }
}
