import AppKit
import RecallUIKit
import SwiftUI

struct SearchView: View {
    @StateObject var viewModel: SearchViewModel
    var focusTrigger: Bool = false
    /// Injected so `DetailPaneView`'s related-hits flyout (cycle 8.37
    /// PR-3) can resolve linked event ids. Optional so previews / tests
    /// that stub the VM can omit it — the flyout button hides in that
    /// case.
    var reader: BrainReader? = nil
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            FilterPillsView(
                filters: $viewModel.filters,
                observedApps: viewModel.observedApps
            ) {
                Task {
                    await viewModel.runSearch()
                    await viewModel.reloadObservedApps()
                }
            }
            Divider().background(Color.brandCardBorder)
            content
        }
        .background(Color.brandBgPrimary)
        .task {
            await viewModel.reloadObservedApps()
        }
        .onChange(of: focusTrigger) { _, _ in
            isSearchFieldFocused = true
        }
        .registerActionPanelCommands([
            .init(
                id: "search.clearQuery",
                title: "Clear Query",
                shortcut: "⌘⇧K",
                category: .search,
                isEnabled: { !viewModel.query.isEmpty || viewModel.filters.anyActive }
            ) {
                viewModel.clear()
            }
        ])
    }

    private var searchBar: some View {
        // MCIDesignSystem cycle 8.48: 8pt grid + Stripe-tuned body font.
        HStack(spacing: MCI.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.brandFgMuted)
            TextField(
                "Search everything you've seen…",
                text: $viewModel.query
            )
            .textFieldStyle(.plain)
            .mciFont(.body)
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
        .padding(.horizontal, MCI.Spacing.m)
        .padding(.vertical, MCI.Spacing.m - 2)
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
            // Cycle 8.49 polished empty state (audit-gap fix). Two
            // variants: filter-only narrowed to nothing → "Clear
            // filters" action; text query with no hits → broaden-terms
            // + dictionary nudge.
            if viewModel.query.isEmpty && viewModel.filters.anyActive {
                MCIEmptyState.filterTooNarrow {
                    viewModel.clear()
                }
            } else {
                MCIEmptyState.noSearchHits(query: viewModel.query)
            }
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
}
