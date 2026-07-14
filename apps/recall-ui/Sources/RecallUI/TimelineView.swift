import AppKit
import RecallUIKit
import SwiftUI

struct TimelineView: View {
    @StateObject var viewModel: TimelineViewModel
    /// Injected so `DetailPaneView`'s related-hits flyout (cycle 8.37
    /// PR-3) can resolve linked event ids. Optional so previews / tests
    /// omit it.
    var reader: BrainReader? = nil

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
        // Cycle 8.49 polished empty state (audit-gap fix). Timeline with
        // no events = fresh brain — reassuring, informative.
        MCIEmptyState.noTimelineEvents()
    }

    private func errorView(_ err: String) -> some View {
        // Cycle 8.54 copy audit — `err` unused in the UI (raw SQLCipher
        // / FFI strings would leak jargon). Retained as a param so a
        // future OSLog hook can consume it without touching the View.
        _ = err
        return VStack(spacing: 16) {
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
                DetailPaneView(hit: hit, reader: reader)
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
