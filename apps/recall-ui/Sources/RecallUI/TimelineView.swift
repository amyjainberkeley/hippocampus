import AppKit
import RecallUIKit
import SwiftUI

/// History's list: one day's moments, newest first, under their clock hour,
/// with "Show Earlier" below the last row (RULINGS W8). The model belongs to
/// Ask, so the rows and the pages already read stay when a place changes.
struct TimelineView: View {
    @ObservedObject var viewModel: TimelineViewModel
    /// Injected so `DetailPaneView`'s related-hits flyout (cycle 8.37
    /// PR-3) can resolve linked event ids. Optional so previews / tests
    /// omit it.
    var reader: BrainReader? = nil
    /// The day shown is today: its empty state says so.
    var isToday = true
    var calendar: Calendar = .current

    var body: some View {
        Group {
            if let err = viewModel.errorMessage {
                EvidenceStateViewport { errorView(err) }
            } else if viewModel.isLoading && viewModel.hits.isEmpty {
                EvidenceStateViewport { ShimmerLoadingView(isLoading: true) }
            } else if viewModel.hits.isEmpty {
                EvidenceStateViewport { emptyView }
            } else {
                contentView
            }
        }
        .background(Color.brandBgPrimary)
        .task {
            // The rows already read stay when Ask comes back on screen.
            if viewModel.hits.isEmpty {
                await viewModel.reload()
            } else {
                await viewModel.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) {
            _ in
            // Reads again only when something newer was saved; a delete
            // reads again by itself (critique-recall-engineering finding 7).
            Task { await viewModel.refresh() }
        }
    }

    private var emptyView: some View {
        ContentUnavailableView(
            isToday ? UserFacingCopy.historyEmptyToday : UserFacingCopy.historyEmptyPastDay,
            systemImage: "clock"
        )
        .foregroundStyle(Color.brandFgSecondary)
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
                // The window runs inside Hippocampus.app, wherever it is.
                NSWorkspace.shared.open(Bundle.main.bundleURL)
            }
            .buttonStyle(.bordered)
        }
    }

    private var sections: [HistorySection] {
        HistorySections.group(hits: viewModel.hits, sessions: [], calendar: calendar)
    }

    private func heading(_ section: HistorySection) -> String {
        switch section.owner {
        case let .hour(startUs):
            Formatters.clockHour(us: startUs, timeZone: calendar.timeZone)
        case let .session(block):
            block.title
        }
    }

    private var contentView: some View {
        AdaptiveEvidencePanes(
            showsDetail: viewModel.isDetailFocused && viewModel.selectedHit != nil,
            backLabel: UserFacingCopy.backToHistory,
            onDismissDetail: { viewModel.dismissDetail() }
        ) {
            List(selection: $viewModel.selectedHitId) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            HitRow(hit: row.hit, showsClockTime: true, count: row.count)
                                .tag(row.hit.id)
                                .listRowBackground(
                                    viewModel.selectedHitId == row.hit.id
                                        ? Color.brandMintSubtle : Color.clear
                                )
                        }
                    } header: {
                        Text(verbatim: heading(section))
                            .mciFont(.caption)
                            .foregroundStyle(Color.brandFgSecondary)
                    }
                }
                if viewModel.canLoadEarlier || viewModel.isLoadingEarlier {
                    HStack {
                        Spacer()
                        if viewModel.isLoadingEarlier {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(UserFacingCopy.showEarlier) {
                                Task { await viewModel.loadEarlier() }
                            }
                            .buttonStyle(.bordered)
                        }
                        Spacer()
                    }
                    .padding(.vertical, MCI.Spacing.s)
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
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
                    return .handled
                }
                if viewModel.selectedHitId != nil {
                    viewModel.selectedHitId = nil
                    return .handled
                }
                return .ignored
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
}
