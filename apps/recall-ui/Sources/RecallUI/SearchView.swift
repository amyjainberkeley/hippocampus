import AppKit
import RecallUIKit
import SwiftUI

struct SearchView: View {
    @StateObject var viewModel: SearchViewModel
    var focusTrigger: Bool = false
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            FilterPillsView(filters: $viewModel.filters) {
                Task { await viewModel.runSearch() }
            }
            Divider().background(Color.brandCardBorder)
            content
        }
        .background(Color.brandBgPrimary)
        .onChange(of: focusTrigger) { _, _ in
            isSearchFieldFocused = true
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.brandFgMuted)
            TextField(
                "Search everything you've seen…",
                text: $viewModel.query
            )
            .textFieldStyle(.plain)
            .foregroundStyle(Color.brandFgPrimary)
            .focused($isSearchFieldFocused)
            .onSubmit {
                Task { await viewModel.runSearch() }
            }
            if viewModel.isSearching {
                ProgressView().controlSize(.small)
            }
            if !viewModel.query.isEmpty || viewModel.filters.anyActive {
                Button {
                    viewModel.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.brandFgMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.brandBgPrimary)
    }

    @ViewBuilder
    private var content: some View {
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
        } else if viewModel.query.isEmpty && !viewModel.filters.anyActive {
            ContentUnavailableView(
                "Type to search your brain",
                systemImage: "brain",
                description: Text(
                    "Lexical + semantic recall across everything Hippocampus has captured."
                )
            )
            .foregroundStyle(Color.brandFgSecondary)
        } else if viewModel.hits.isEmpty && !viewModel.isSearching {
            ContentUnavailableView(
                "No matches",
                systemImage: "tray",
                description: Text("Try different words or a broader query.")
            )
            .foregroundStyle(Color.brandFgSecondary)
        } else if viewModel.isSearching && viewModel.hits.isEmpty {
            ShimmerLoadingView(isLoading: true)
        } else {
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
}
