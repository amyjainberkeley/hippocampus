import AppKit
import RecallUIKit
import SwiftUI

/// One of History's lenses (SPEC-DELTA 1): Documents, Code or Conversations.
/// History's own rows and detail, filtered by kind, under Apple Notes' day
/// headings, newest first, with the same menu, keys and Forget. Its title
/// and one line lead the list; Conversations adds its chips.
struct LibraryLensView: View {
    @ObservedObject var model: LibraryLensModel
    let reader: BrainReader
    var open: (RecallRoute) -> Void
    var calendar: Calendar
    var now: @Sendable () -> Date

    @Environment(\.forget) private var forget
    @Environment(\.forgottenMoments) private var forgotten
    @Environment(\.locale) private var locale
    @StateObject private var items: MomentItems
    @State private var quickLook: ScreenshotSelection?
    @State private var relatedRequests = 0

    init(model: LibraryLensModel, reader: BrainReader, work: (any WorkReader)? = nil,
         open: @escaping (RecallRoute) -> Void = { _ in }, calendar: Calendar = .current,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.model = model
        self.reader = reader
        self.open = open
        self.calendar = calendar
        self.now = now
        _items = StateObject(wrappedValue: MomentItems(reader: work))
    }

    private var lens: LibraryLens { model.lens }

    /// The lens's moments without those forgotten a moment ago.
    private var sections: [LibrarySection] {
        let hits = forgotten.isEmpty ? model.shownHits : model.shownHits.filter { !forgotten.contains($0.id) }
        return LibrarySections.group(hits, now: now(), calendar: calendar)
    }

    private var rows: [HistoryRow] { sections.flatMap(\.rows) }

    private var picked: MomentSelection { MomentSelection(picked: model.selection, in: rows) }

    var body: some View {
        Group {
            if let error = model.errorMessage, model.hits.isEmpty {
                page { unavailable(error) }
            } else if model.isLoading && model.hits.isEmpty {
                page { ShimmerLoadingView(isLoading: true) }
            } else if rows.isEmpty {
                page { empty }
            } else {
                content
            }
        }
        .background(MCI.Color.background)
        .task {
            if model.hits.isEmpty { await model.reload() } else { await model.refresh() }
        }
        .task(id: [model.hits.first?.id ?? 0, UInt64(model.hits.count)]) {
            await items.load(model.hits.map(\.id))
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) { _ in
            Task { await model.refresh() }
        }
        .onChange(of: forgotten) { _, hidden in
            let gone = model.selection.filter { hidden.contains($0) }
            if !gone.isEmpty { model.selection.subtract(gone) }
        }
        .onChange(of: model.selection) { _, picked in
            if !picked.isEmpty { model.isDetailFocused = true }
        }
        .sheet(item: $quickLook) { selection in
            ScreenshotViewer(selection: selection, reader: reader)
        }
    }

    /// The lens's title and line over a state that fills the page.
    private func page(@ViewBuilder _ state: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MCI.Spacing.xl) {
                header
                state()
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, MCI.Spacing.l + 2)
            .padding(.top, MCI.Spacing.l + 4)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MCI.Spacing.xs) {
            Text(verbatim: lens.title)
                .font(MCI.Font.title)
                .foregroundStyle(MCI.Color.foreground)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: LibraryCopy.lead(lens))
                .font(.system(size: 13))
                .foregroundStyle(MCI.Color.foregroundSecondary)
            if lens == .conversations {
                ConversationChips(filter: $model.filter)
                    .padding(.top, MCI.Spacing.s)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var empty: some View {
        if lens == .conversations, model.filter != .all, !model.hits.isEmpty {
            ContentUnavailableView(LibraryCopy.emptyConversations(model.filter), systemImage: lens.symbol)
        } else {
            let words = LibraryCopy.empty(lens)
            ContentUnavailableView(words.title, systemImage: lens.symbol, description: Text(words.body))
        }
    }

    private func unavailable(_ error: String) -> some View {
        _ = error
        return ContentUnavailableView {
            Label(UserFacingCopy.memoryUnreachableTitle, systemImage: "exclamationmark.triangle")
        } description: {
            Text(UserFacingCopy.memoryUnreachableBody)
        } actions: {
            Button(UserFacingCopy.Overview.tryAgain) { Task { await model.reload() } }
        }
    }

    private var content: some View {
        AdaptiveEvidencePanes(
            showsDetail: model.isDetailFocused && !picked.isEmpty,
            backLabel: lens.title,
            onDismissDetail: { model.dismissDetail() }
        ) {
            List(selection: $model.selection) {
                header
                    .padding(.top, MCI.Spacing.s)
                    .padding(.bottom, MCI.Spacing.xs)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
                ForEach(sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            HitRow(hit: row.hit, count: row.count, screenshot: row.screenshot,
                                   time: section.time(of: row.hit, calendar: calendar, locale: locale))
                                .tag(row.hit.id)
                                .listRowBackground(model.selection.contains(row.hit.id)
                                    ? Color.brandMintSubtle : Color.clear)
                        }
                    } header: {
                        Text(verbatim: section.title(now: now(), calendar: calendar, locale: locale))
                            .mciFont(.caption)
                            .foregroundStyle(Color.brandFgSecondary)
                    }
                }
                if model.canLoadEarlier || model.isLoadingEarlier {
                    HStack {
                        Spacer()
                        if model.isLoadingEarlier {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(LibraryCopy.showEarlier) { Task { await model.loadEarlier() } }
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
            .background(MCI.Color.background)
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
                model.focusDetail()
                return model.selection.isEmpty ? .ignored : .handled
            }
            .onKeyPress(.space, phases: .down) { _ in
                guard picked.rows.count == 1, let shot = picked.rows[0].screenshot else { return .ignored }
                openScreenshot(shot)
                return .handled
            }
            .onKeyPress(.delete, phases: .down) { press in
                guard press.modifiers == .command, let forget, !picked.isEmpty else { return .ignored }
                forget(.moments(picked.momentIds))
                return .handled
            }
            .onKeyPress(.escape, phases: .down) { _ in
                if model.isDetailFocused {
                    model.dismissDetail()
                    return .handled
                }
                if !model.selection.isEmpty {
                    model.selection = []
                    return .handled
                }
                return .ignored
            }
        } detail: {
            if picked.rows.count > 1 {
                MultiMomentDetail(selection: picked, reader: reader)
            } else if let row = picked.rows.first {
                let hit = row.hit
                DetailPaneView(hit: hit, reader: reader,
                               screenshotEventIDs: MCI.Workspace.screenshotMoments(from: model.hits,
                                                                                   keeping: hit.id).map(\.id),
                               rowScreenshot: row.screenshot,
                               run: row.hits.map(\.id),
                               partOf: items.partOf(hit),
                               openItem: { open(RecallRoute(workItem: $0.id)) },
                               relatedRequests: relatedRequests)
            }
        }
    }

    private func show(_ ids: Set<UInt64>) {
        guard !ids.isEmpty else { return }
        model.selection = ids
        model.focusDetail()
    }

    private func openScreenshot(_ shot: Hit) {
        let ids = MCI.Workspace.screenshotMoments(from: model.hits, keeping: shot.id).map(\.id)
        quickLook = ScreenshotSelection(eventIDs: ids.contains(shot.id) ? ids : [shot.id], initialID: shot.id)
    }
}

/// Conversations' chips: All, Chat, Email and AI.
struct ConversationChips: View {
    @Binding var filter: ConversationFilter

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ConversationFilter.allCases, id: \.self) { chip in
                let isOn = chip == filter
                Button { filter = chip } label: {
                    Text(verbatim: chip.title)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(isOn ? MCI.Color.accent : MCI.Color.foreground)
                        .background(Capsule().fill(isOn ? MCI.Color.accentSubtle : MCI.Color.background))
                        .overlay(Capsule().strokeBorder(isOn ? MCI.Color.accent.opacity(0.35) : MCI.Color.border,
                                                        lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
        // The outer chips' edges stay whole inside a list row.
        .padding(.horizontal, 1)
        .padding(.vertical, 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LibraryCopy.Conversations.filterLabel)
    }
}

extension LibraryLens {
    /// The lens's symbol, as its row in the sidebar shows it.
    var symbol: String {
        switch self {
        case .documents: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .conversations: "bubble.left.and.bubble.right"
        }
    }
}

/// A lens as its place: the model lives as long as the place is shown.
struct LibraryLensPlace: View {
    @StateObject private var model: LibraryLensModel
    let reader: BrainReader
    let work: (any WorkReader)?
    let open: (RecallRoute) -> Void
    let calendar: Calendar
    let now: @Sendable () -> Date

    init(lens: LibraryLens, reader: BrainReader, work: (any WorkReader)?, open: @escaping (RecallRoute) -> Void,
         calendar: Calendar, now: @escaping @Sendable () -> Date) {
        _model = StateObject(wrappedValue: LibraryLensModel(lens: lens, reader: reader))
        self.reader = reader
        self.work = work
        self.open = open
        self.calendar = calendar
        self.now = now
    }

    var body: some View {
        LibraryLensView(model: model, reader: reader, work: work, open: open, calendar: calendar, now: now)
    }
}
