import AppKit
import RecallUIKit
import SwiftUI

/// History's list: one day's moments, newest first, under their clock hour,
/// with "Show Earlier" below the last row (RULINGS W8) and, at the oldest day
/// kept, how long moments are kept (SPEC 3.4). ⌘-click and ⇧-click pick
/// several rows; right-click acts on the clicked row, or on every picked row
/// when it is picked; Space opens the picked moment's screenshot; ⌘⌫ forgets
/// what is picked. The model belongs to Ask, so the rows and the pages
/// already read stay when a place changes.
struct TimelineView: View {
    @ObservedObject var viewModel: TimelineViewModel
    /// Injected so `DetailPaneView`'s related-hits flyout (cycle 8.37
    /// PR-3) can resolve linked event ids. Optional so previews / tests
    /// omit it.
    var reader: BrainReader?
    /// The day shown is today: its empty state says so.
    var isToday: Bool
    var calendar: Calendar
    /// Opens a Working On item from "Part of …".
    var open: (RecallRoute) -> Void
    /// How long moments are kept, read when the list reaches the oldest day.
    var retention: @Sendable () -> RetentionSetting?
    /// Opens Preferences › Privacy, where how long moments are kept is set.
    var changeRetention: () -> Void

    @Environment(\.forget) private var forget
    @Environment(\.forgottenMoments) private var forgotten
    @StateObject private var items: MomentItems
    @State private var kept: RetentionSetting?
    @State private var quickLook: ScreenshotSelection?
    @State private var relatedRequests = 0

    init(viewModel: TimelineViewModel, reader: BrainReader? = nil, isToday: Bool = true,
         calendar: Calendar = .current, work: (any WorkReader)? = nil,
         open: @escaping (RecallRoute) -> Void = { _ in },
         retention: @escaping @Sendable () -> RetentionSetting? = {
             RetentionSetting.read(from: RetentionSetting.defaultURL)
         },
         changeRetention: @escaping () -> Void = TimelineView.openRetentionPreferences) {
        self.viewModel = viewModel
        self.reader = reader
        self.isToday = isToday
        self.calendar = calendar
        self.open = open
        self.retention = retention
        self.changeRetention = changeRetention
        _items = StateObject(wrappedValue: MomentItems(reader: work))
    }

    nonisolated static func openRetentionPreferences() {
        Task { _ = await WorkspacePreferencesRouter.shared.open(.privacy, bundleURL: Bundle.main.bundleURL) }
    }

    /// The day's moments without those forgotten a moment ago: they stay
    /// hidden while their Undo note is up.
    private var shownHits: [Hit] {
        forgotten.isEmpty ? viewModel.hits : viewModel.hits.filter { !forgotten.contains($0.id) }
    }

    var body: some View {
        Group {
            if let err = viewModel.errorMessage {
                EvidenceStateViewport { errorView(err) }
            } else if viewModel.isLoading && viewModel.hits.isEmpty {
                EvidenceStateViewport { ShimmerLoadingView(isLoading: true) }
            } else if shownHits.isEmpty {
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
        .task(id: [viewModel.hits.first?.id ?? 0, UInt64(viewModel.hits.count)]) {
            await items.load(viewModel.hits.map(\.id))
        }
        .task(id: viewModel.isOldestDay) {
            guard viewModel.isOldestDay else { return }
            let read = retention
            kept = await Task.detached { read() }.value
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) {
            _ in
            // Reads again only when something newer was saved; a delete
            // reads again by itself (critique-recall-engineering finding 7).
            Task { await viewModel.refresh() }
        }
        .onChange(of: forgotten) { _, hidden in
            // A row forgotten while picked is no longer picked.
            let gone = viewModel.selection.filter { hidden.contains($0) }
            if !gone.isEmpty { viewModel.selection.subtract(gone) }
        }
        .sheet(item: $quickLook) { selection in
            if let reader {
                ScreenshotViewer(selection: selection, reader: reader)
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: MCI.Spacing.l) {
            if isToday {
                ContentUnavailableView(LibraryCopy.History.emptyTodayTitle, systemImage: "clock",
                                       description: Text(LibraryCopy.History.emptyTodayBody))
            } else {
                ContentUnavailableView(LibraryCopy.History.emptyPastDay, systemImage: "clock")
            }
            // An empty day before today can be the oldest kept; today is just new.
            if !isToday, viewModel.isOldestDay, let days = kept?.days {
                RetentionLine(days: days, change: changeRetention)
            }
        }
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
        HistorySections.group(hits: shownHits, sessions: [], calendar: calendar)
    }

    private var rows: [HistoryRow] {
        sections.flatMap(\.rows)
    }

    /// The rows picked, as the detail and ⌘⌫ see them.
    private var picked: MomentSelection {
        MomentSelection(picked: viewModel.selection, in: rows)
    }

    private func heading(_ section: HistorySection) -> String {
        switch section.owner {
        case let .hour(startUs):
            Formatters.clockHour(us: startUs, timeZone: calendar.timeZone)
        case let .session(block):
            block.title
        }
    }

    /// "2 PM to 3 PM", and the hour it stands for, for an hour heading's menu.
    private func hour(_ section: HistorySection) -> (label: String, range: ClosedRange<Int64>)? {
        guard case let .hour(startUs) = section.owner else { return nil }
        let range = HistorySections.hour(startingAt: startUs, calendar: calendar)
        let end = Formatters.clockHour(us: range.upperBound + 1, timeZone: calendar.timeZone)
        let start = Formatters.clockHour(us: startUs, timeZone: calendar.timeZone)
        return (LibraryCopy.History.hourRange(start, end), range)
    }

    /// Forgets the hour under `section`'s heading, when forgetting is offered.
    private func hourForget(_ section: HistorySection) -> (() -> Void)? {
        guard let forget, let hour = hour(section) else { return nil }
        return { forget(.range(hour.range, label: hour.label)) }
    }

    private var contentView: some View {
        AdaptiveEvidencePanes(
            showsDetail: viewModel.isDetailFocused && !picked.isEmpty,
            backLabel: UserFacingCopy.backToHistory,
            onDismissDetail: { viewModel.dismissDetail() }
        ) {
            List(selection: $viewModel.selection) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            HitRow(hit: row.hit, showsClockTime: true, count: row.count,
                                   screenshot: row.screenshot)
                                .tag(row.hit.id)
                                .listRowBackground(
                                    viewModel.selection.contains(row.hit.id)
                                        ? Color.brandMintSubtle : Color.clear
                                )
                        }
                    } header: {
                        HourHeading(title: heading(section),
                                    forgetTitle: hour(section).map { LibraryCopy.History.forgetHour($0.label) },
                                    forgetHour: hourForget(section))
                    }
                }
                listEnd
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Color.brandBgPrimary)
            .contextMenu(forSelectionType: UInt64.self) { ids in
                MomentMenu(picked: MomentSelection(picked: ids, in: rows), reader: reader,
                           open: { show(ids) },
                           openScreenshot: { openScreenshot($0) },
                           showRelated: { hit in
                               show([hit.id])
                               relatedRequests += 1
                           })
            } primaryAction: { ids in
                show(ids)
            }
            .onKeyPress(.return, phases: .down) { _ in
                viewModel.focusDetail()
                return viewModel.selection.isEmpty ? .ignored : .handled
            }
            .onKeyPress(.space, phases: .down) { _ in
                guard picked.rows.count == 1, let shot = picked.rows[0].screenshot else { return .ignored }
                openScreenshot(shot)
                return .handled
            }
            .onKeyPress(.delete, phases: .down) { press in
                // ⌘⌫ forgets what is picked; plain ⌫ does nothing in a list.
                guard press.modifiers == .command, let forget, !picked.isEmpty else { return .ignored }
                forget(.moments(picked.momentIds))
                return .handled
            }
            .onKeyPress(.escape, phases: .down) { _ in
                if viewModel.isDetailFocused {
                    viewModel.dismissDetail()
                    return .handled
                }
                if !viewModel.selection.isEmpty {
                    viewModel.selection = []
                    return .handled
                }
                return .ignored
            }

        } detail: {
            if picked.rows.count > 1 {
                MultiMomentDetail(selection: picked, reader: reader)
            } else if let hit = viewModel.selectedHit {
                let row = rows.first { $0.hit.id == hit.id }
                DetailPaneView(hit: hit, reader: reader,
                               screenshotEventIDs: MCI.Workspace.screenshotMoments(from: viewModel.hits,
                                                                                   keeping: hit.id).map(\.id),
                               rowScreenshot: row?.screenshot,
                               run: row?.hits.map(\.id) ?? [hit.id],
                               partOf: items.partOf(hit),
                               openItem: { open(RecallRoute(workItem: $0.id)) },
                               relatedRequests: relatedRequests)
            }
        }
        .onChange(of: viewModel.selection) { _, newValue in
            if !newValue.isEmpty {
                viewModel.isDetailFocused = true
            }
        }
    }

    /// "Show Earlier" below the last row, or, at the oldest day kept, how long
    /// moments are kept.
    @ViewBuilder
    private var listEnd: some View {
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
        } else if viewModel.isOldestDay, let days = kept?.days {
            RetentionLine(days: days, change: changeRetention)
                .listRowBackground(Color.clear)
                .selectionDisabled()
        }
    }

    /// Picks `ids` and opens their detail.
    private func show(_ ids: Set<UInt64>) {
        guard !ids.isEmpty else { return }
        viewModel.selection = ids
        viewModel.focusDetail()
    }

    /// The screenshot full size, with the day's other screenshots beside it.
    private func openScreenshot(_ shot: Hit) {
        guard reader != nil else { return }
        let ids = MCI.Workspace.screenshotMoments(from: viewModel.hits, keeping: shot.id).map(\.id)
        quickLook = ScreenshotSelection(eventIDs: ids.contains(shot.id) ? ids : [shot.id], initialID: shot.id)
    }
}
