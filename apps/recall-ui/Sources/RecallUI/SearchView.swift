import AppKit
import Combine
import RecallUIKit
import SwiftUI

struct SearchView: View {
    @StateObject var viewModel: SearchViewModel
    var focusTrigger: Bool = false
    var focusRequest: RecallFocusRequest? = nil
    /// Injected so `DetailPaneView`'s related-hits flyout (cycle 8.37
    /// PR-3) can resolve linked event ids. Optional so previews / tests
    /// that stub the VM can omit it — the flyout button hides in that
    /// case.
    var reader: BrainReader? = nil
    var contextExporter: @Sendable (String) async throws -> String = { try await ContextHandoffExporter.export(focus: $0) }
    @FocusState private var isSearchFieldFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isRegistryRefreshing = false
    @State private var isExportingContext = false
    @State private var showsContextHandoffError = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                searchBar
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
                Divider().background(Color.brandCardBorder)
                content
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .background(Color.brandBgPrimary)
        // Detail command registration must not invalidate the search layout.
        .onReceive(
            ActionPanelRegistry.shared.$isRefreshing
                .removeDuplicates()
                .receive(on: RunLoop.main)
        ) { isRefreshing in
            if isRegistryRefreshing != isRefreshing {
                isRegistryRefreshing = isRefreshing
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) {
            _ in
            Task { await viewModel.refresh() }
        }
        .task(id: focusRequest) {
            if let focusRequest {
                await viewModel.focusEvent(id: focusRequest.eventId)
                await viewModel.reloadObservedApps()
            } else {
                isSearchFieldFocused = true
                await viewModel.refresh()
            }
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
            },
            .init(
                id: "search.copyAgentContext",
                title: "Copy Agent Context",
                shortcut: "",
                category: .search,
                description: "Copy a bounded, cited packet for the current task.",
                isEnabled: { !isExportingContext }
            ) {
                copyAgentContext()
            }
        ])
        .alert("Couldn’t copy agent context", isPresented: $showsContextHandoffError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Open Hippocampus and try again.")
        }
    }

    private var searchBar: some View {
        // MCIDesignSystem cycle 8.48: 8pt grid + Stripe-tuned body font.
        HStack(spacing: MCI.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.brandFgMuted)
            TextField(
                "Search captured text…",
                text: $viewModel.query
            )
            .textFieldStyle(.plain)
            .mciFont(.body)
            .foregroundStyle(Color.brandFgPrimary)
            .focused($isSearchFieldFocused)
            .frame(minWidth: 0, maxWidth: .infinity)
            .onSubmit {
                Task { await viewModel.runSearch() }
            }
            Picker("Search mode", selection: $viewModel.mode) {
                Text("Text").tag(SearchMode.text)
                Text("Related").tag(SearchMode.related)
                    .selectionDisabled(viewModel.hasUnsupportedRelatedFilters)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 142)
            .help("Text finds indexed words. Related also retrieves unverified semantic context.")
            if viewModel.isSearching || isRegistryRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                copyAgentContext()
            } label: {
                Group {
                    if isExportingContext {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "doc.on.clipboard")
                    }
                }
                .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(isExportingContext)
            .help("Copy a bounded, cited context packet for an agent")
            .accessibilityLabel("Copy agent context")
            .accessibilityHint("Copies memory related to this search with source citations")
            if !viewModel.query.isEmpty || viewModel.filters.anyActive {
                Button {
                    viewModel.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.brandFgMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityHint("Clears the query and any active filters")
            }
        }
        .padding(.horizontal, MCI.Spacing.xl)
        .padding(.vertical, MCI.Spacing.m)
        .background(
            reduceTransparency
                ? AnyShapeStyle(Color.brandBgSecondary)
                : AnyShapeStyle(.ultraThinMaterial)
        )
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
                    let appPath = NSHomeDirectory() + "/Applications/Hippocampus.app"
                    NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
                }
                .buttonStyle(.bordered)
                .tint(Color.brandMint)
            }
        } else if let message = viewModel.filterLimitationMessage,
            viewModel.mode == .related,
            !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            viewModel.hasUnsupportedRelatedFilters {
            ContentUnavailableView(
                "Related search unavailable",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text(message)
            )
            .foregroundStyle(Color.brandFgSecondary)
        } else if viewModel.hits.isEmpty
            && viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "Search your memory",
                systemImage: "magnifyingglass"
            )
            .foregroundStyle(Color.brandFgSecondary)
        } else if viewModel.hits.isEmpty && !viewModel.isSearching {
            // Keep the query in the search field so long input cannot size the heading.
            if viewModel.filters.anyActive {
                MCIEmptyState.filterTooNarrow {
                    viewModel.clear()
                }
            } else {
                ContentUnavailableView(
                    "No matching memories",
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
            backLabel: "Back to results",
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
                DetailPaneView(hit: hit, reader: reader, screenshotEventIDs: MCI.Workspace.recentKeyframes(from: viewModel.hits).map(\.id))
            }
        }
        .onChange(of: viewModel.selectedHitId) { _, newValue in
            if newValue != nil {
                viewModel.isDetailFocused = true
            }
        }
    }

    private func copyAgentContext() {
        guard !isExportingContext else { return }
        isExportingContext = true
        let focus = viewModel.query
        Task {
            defer { isExportingContext = false }
            do {
                let packet = try await contextExporter(focus)
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(packet, forType: .string) else {
                    showsContextHandoffError = true
                    return
                }
                ToastNotifier.shared.notify("Agent context copied")
            } catch {
                showsContextHandoffError = true
            }
        }
    }
}
