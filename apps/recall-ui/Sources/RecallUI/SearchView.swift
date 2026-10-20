import AppKit
import Combine
import RecallUIKit
import SwiftUI

struct SearchView: View {
    /// Ask owns the model, so matches and their selection survive a change
    /// of place (critique-recall-engineering finding 16).
    @ObservedObject var viewModel: SearchViewModel
    /// Injected so `DetailPaneView`'s related-hits flyout (cycle 8.37
    /// PR-3) can resolve linked event ids. Optional so previews / tests
    /// that stub the VM can omit it — the flyout button hides in that
    /// case.
    var reader: BrainReader? = nil
    /// The match mode and filters show when asked for, or while one is on.
    var showsFilters = false
    /// Ask decides when "Nothing matched" may show: never for a question
    /// that has not been asked (critique-recall-engineering finding 16).
    var showsNoMatches = true
    /// Over the matches while an answer shows.
    var heading: String? = nil

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let scope = viewModel.pageScope,
                   !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SearchScopeBar(scope: scope, isScoped: $viewModel.isScoped)
                    Divider().background(Color.brandCardBorder)
                }
                if showsFilters || viewModel.filters.anyActive {
                    filterBar
                    Divider().background(Color.brandCardBorder)
                }
                if let scope = viewModel.activeScope, !viewModel.hits.isEmpty {
                    Text(verbatim: LibraryCopy.Search.matches(viewModel.hits.count, in: scope.name))
                        .mciFont(.caption)
                        .foregroundStyle(Color.brandFgSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, MCI.Spacing.l)
                        .padding(.top, MCI.Spacing.m)
                }
                if let heading, !viewModel.hits.isEmpty {
                    Text(heading)
                        .mciFont(.caption)
                        .foregroundStyle(Color.brandFgSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, MCI.Spacing.l)
                        .padding(.top, MCI.Spacing.m)
                }
                content
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .background(Color.brandBgPrimary)
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) {
            _ in
            Task { await viewModel.refresh() }
        }
        .registerActionPanelCommands([
            .init(
                id: "search.clearQuery",
                title: UserFacingCopy.clearAction,
                shortcut: "\u{2318}\u{21E7}K",
                category: .search,
                isEnabled: { !viewModel.query.isEmpty || viewModel.filters.anyActive }
            ) {
                viewModel.clear()
            },
        ])
    }

    /// Exact words or meaning, then the date and app filters.
    private var filterBar: some View {
        HStack(spacing: MCI.Spacing.m) {
            Picker(UserFacingCopy.matchModeLabel, selection: $viewModel.mode) {
                Text(UserFacingCopy.matchModeExact).tag(SearchMode.text)
                Text(UserFacingCopy.matchModeMeaning).tag(SearchMode.related)
                    .selectionDisabled(viewModel.hasUnsupportedRelatedFilters)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .help(UserFacingCopy.matchModeHelp)
            ScrollView(.horizontal) {
                FilterPillsView(
                    filters: $viewModel.filters,
                    observedApps: viewModel.observedApps
                ) {
                    Task {
                        await viewModel.runSearch()
                        await viewModel.reloadObservedApps()
                    }
                }
            }
            .frame(height: 72)
        }
        .padding(.horizontal, MCI.Spacing.l)
        .task { await viewModel.reloadObservedApps() }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if let message = viewModel.filterLimitationMessage,
                viewModel.mode == .related,
                !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !viewModel.hasUnsupportedRelatedFilters {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.brandFgSecondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .help(message)
            }
            if viewModel.errorMessage != nil || viewModel.hits.isEmpty {
                EvidenceStateViewport {
                    searchStatus
                }
            } else {
                searchResults
            }
        }
    }

    @ViewBuilder
    private var searchStatus: some View {
        if viewModel.errorMessage != nil {
            // Cycle 8.54 copy audit — never leak raw `\(error)` to the
            // UI. The raw error stays in the view model for logging
            // (Console + crash reports); users see plain English + a
            // named next action.
            VStack(spacing: 16) {
                ContentUnavailableView(
                    UserFacingCopy.memoryUnreachableTitle,
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text(UserFacingCopy.memoryUnreachableBody)
                )
                .foregroundStyle(Color.brandError)

                Button(UserFacingCopy.openHippocampusAction) {
                    // The window runs inside Hippocampus.app, wherever it is.
                    NSWorkspace.shared.open(Bundle.main.bundleURL)
                }
                .buttonStyle(.bordered)
            }
        } else if let message = viewModel.filterLimitationMessage,
            viewModel.mode == .related,
            !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            viewModel.hasUnsupportedRelatedFilters {
            ContentUnavailableView(
                UserFacingCopy.meaningFiltersUnavailable,
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text(message)
            )
            .foregroundStyle(Color.brandFgSecondary)
        } else if viewModel.hits.isEmpty && !viewModel.isSearching && !showsNoMatches {
            // A question waiting to be asked, or one answered above: nothing to say.
            EmptyView()
        } else if viewModel.hits.isEmpty && !viewModel.isSearching, let scope = viewModel.activeScope {
            VStack(spacing: MCI.Spacing.m) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(MCI.Color.foregroundMuted)
                    .accessibilityHidden(true)
                Text(verbatim: LibraryCopy.Search.nothingIn(scope.name))
                    .font(MCI.Font.title2)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                    .multilineTextAlignment(.center)
                Button(LibraryCopy.Search.searchEverything) { viewModel.searchEverything() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, MCI.Spacing.xl)
            .padding(.top, MCI.Spacing.xxxl)
        } else if viewModel.hits.isEmpty && !viewModel.isSearching {
            // Keep the query in the search field so long input cannot size the heading.
            if viewModel.filters.anyActive {
                MCIEmptyState.filterTooNarrow {
                    viewModel.clear()
                }
            } else {
                ContentUnavailableView(
                    UserFacingCopy.nothingMatched,
                    systemImage: "magnifyingglass"
                )
                .foregroundStyle(Color.brandFgSecondary)
            }
        } else if viewModel.isSearching && viewModel.hits.isEmpty {
            ShimmerLoadingView(isLoading: true)
        }
    }

    private var searchResults: some View {
        AdaptiveEvidencePanes(
            showsDetail: viewModel.isDetailFocused && viewModel.selectedHit != nil,
            backLabel: UserFacingCopy.backToResults,
            onDismissDetail: { viewModel.dismissDetail() }
        ) {
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

        } detail: {
            if let hit = viewModel.selectedHit {
                DetailPaneView(hit: hit, reader: reader,
                               screenshotEventIDs: MCI.Workspace.screenshotMoments(from: viewModel.hits,
                                                                                   keeping: hit.id).map(\.id),
                               query: viewModel.query)
            }
        }
        .onChange(of: viewModel.selectedHitId) { _, newValue in
            if newValue != nil {
                viewModel.isDetailFocused = true
            }
        }
    }
}

/// The scope bar under the field while typing on a page that offers one,
/// Mail-style (SPEC 2.8): "Search: Everything | trailhead-shop".
struct SearchScopeBar: View {
    let scope: SearchScope
    @Binding var isScoped: Bool

    var body: some View {
        HStack(spacing: MCI.Spacing.xs) {
            Text(verbatim: LibraryCopy.Search.label)
                .foregroundStyle(MCI.Color.foregroundSecondary)
                .padding(.trailing, MCI.Spacing.xs)
            choice(LibraryCopy.Search.everything, on: !isScoped) { isScoped = false }
            choice(scope.name, on: isScoped) { isScoped = true }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, MCI.Spacing.l)
        .padding(.vertical, MCI.Spacing.xs + 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LibraryCopy.Search.label)
    }

    private func choice(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .fontWeight(on ? .semibold : .regular)
                .foregroundStyle(MCI.Color.foreground)
                .padding(.horizontal, MCI.Spacing.s + 2)
                .padding(.vertical, MCI.Spacing.xs)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(on ? MCI.Color.border.opacity(0.7) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
