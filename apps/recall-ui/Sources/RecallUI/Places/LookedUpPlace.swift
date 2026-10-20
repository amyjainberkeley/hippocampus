import AppKit
import RecallUIKit
import SwiftUI

/// Looked Up (SPEC 3.6): searches made on the sites the agent reads, newest
/// first, by day; the same query on one day is one row. A lens over
/// History: each row is its results page; its detail is the search, the
/// pages opened next in the same browser, then what the results page showed.
struct LookedUpPlace: View {
    let understanding: UnderstandingReader
    let reader: BrainReader
    let open: (RecallRoute) -> Void
    /// Where searches come from; nil reads the bundled agent in the app and
    /// nothing in the synthetic preview.
    var searches: (any SearchesReading)?

    @Environment(\.isSyntheticPreview) private var isSyntheticPreview

    var body: some View {
        LookedUpList(reader: reader, open: open,
                     model: LookedUpModel(searches: searches ?? (isSyntheticPreview
                                                                    ? PreviewSearchesReader()
                                                                    : AgentWorkReader.shared),
                                          reader: reader))
    }
}

/// Looked Up's list and detail, over a model.
struct LookedUpList: View {
    let reader: BrainReader
    let open: (RecallRoute) -> Void

    @StateObject private var model: LookedUpModel
    @Environment(\.workNow) private var now
    @Environment(\.workDisplayCalendar) private var calendar
    @Environment(\.lensForget) private var lensForget
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview

    init(reader: BrainReader, open: @escaping (RecallRoute) -> Void, model: LookedUpModel) {
        self.reader = reader
        self.open = open
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        AdaptiveEvidencePanes(showsDetail: model.selected?.page != nil, backLabel: NavigationCopy.lookedUp,
                              onDismissDetail: { Task { await model.select(nil) } }) {
            list
        } detail: {
            if let row = model.selected, let page = row.page {
                SearchDetail(row: row, page: page, openedNext: model.openedNext, reader: reader, open: open)
                    .id(row.id)
            }
        }
        .background(MCI.Color.background)
        .task { await model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: MemoryDeletionSignal.notification)) { _ in
            Task { await model.reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) { _ in
            Task { await model.reload() }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NavigationCopy.lookedUp)
                        .mciFont(.title)
                        .foregroundStyle(MCI.Color.foreground)
                        .accessibilityAddTraits(.isHeader)
                    Text(WorkCopy.lookedUpLead)
                        .font(.system(size: 13))
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                }
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 6)
                switch model.state {
                case .loading where model.rows.isEmpty:
                    ForEach(0..<4, id: \.self) { _ in LoadingRow().padding(.horizontal, 18) }
                case .failed:
                    WorkEmptyState(symbol: "exclamationmark.triangle", title: WorkCopy.loadFailed,
                                   actionTitle: WorkCopy.tryAgain) { Task { await model.reload() } }
                default:
                    if model.rows.isEmpty {
                        WorkEmptyState(symbol: "text.magnifyingglass", title: WorkCopy.lookedUpEmptyTitle,
                                       message: WorkCopy.lookedUpEmptyBody, actionTitle: WorkCopy.addBrowserExtension) {
                            guard !isSyntheticPreview else { return }
                            Task {
                                _ = await WorkspacePreferencesRouter.shared.open(.sources, bundleURL: Bundle.main.bundleURL)
                            }
                        }
                    } else {
                        ForEach(model.sections, id: \.title) { section in
                            Section {
                                ForEach(section.rows) { row in
                                    rowView(row, last: row.id == section.rows.last?.id)
                                }
                            } header: {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(verbatim: section.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(MCI.Color.foregroundSecondary)
                                    Rectangle().fill(MCI.Color.borderStrong).frame(height: 1)
                                }
                                .padding(.horizontal, 18)
                                .padding(.top, section.title == model.sections.first?.title ? 14 : 32)
                                .background(MCI.Color.background)
                                .accessibilityAddTraits(.isHeader)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 28)
        }
    }

    private func rowView(_ row: LookedUpRow, last: Bool) -> some View {
        let selected = model.selectedId == row.id
        return Button {
            Task { await model.select(row.id) }
        } label: {
            LensRow(hit: row.page, headline: "\u{201C}\(row.record.query)\u{201D}", place: row.origin,
                    extra: row.times > 1 ? WorkCopy.searchedTimes(row.times) : nil,
                    when: WorkFormat.rowTime(us: row.record.tsUs, now: now(), calendar: calendar),
                    picture: AnyView(EngineTile(engine: row.engine)))
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .background(selected ? MCI.Color.accentSubtle : Color.clear)
                .overlay(alignment: .bottom) {
                    if !last && !selected {
                        Rectangle().fill(MCI.Color.border).frame(height: 1).padding(.leading, 18 + 96 + 10)
                            .padding(.trailing, 18)
                    }
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let url = LookedUpModel.searchAgainURL(row) {
                Button(WorkCopy.searchAgain) {
                    guard !isSyntheticPreview else { return }
                    NSWorkspace.shared.open(url)
                }
            }
            if let forget = lensForget.forget {
                Divider()
                Button(WorkCopy.forgetThisSearch) { forget(row.eventIds, row.record.query, .search) }
            }
        }
    }
}

/// A search's detail (SPEC 3.6), in History's detail's shape: the query in
/// quotes, the site and browser, when; Search Again, Ask and Forget; the
/// pages opened next; then what the results page showed.
struct SearchDetail: View {
    let row: LookedUpRow
    let page: Hit
    let openedNext: [Hit]
    let reader: BrainReader
    let open: (RecallRoute) -> Void

    @Environment(\.workDisplayCalendar) private var calendar
    @Environment(\.lensForget) private var lensForget
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview
    @State private var reading: EventReading?
    @State private var readingDone = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MCI.Spacing.l) {
                header
                next
                Divider().background(Color.brandCardBorder)
                results
            }
            .padding(MCI.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.thinMaterial)
        .task(id: page.id) {
            let read = try? await reader.eventReading(eventId: page.id)
            reading = read.flatMap { $0 }.flatMap { $0.matches(page) ? $0 : nil }
            readingDone = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MCI.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "\u{201C}\(row.record.query)\u{201D}")
                    .mciFont(.title2)
                    .foregroundStyle(Color.brandFgPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer()
                Text(MemorySourceKind.label(page.sourceKind))
                    .mciFont(.caption)
                    .padding(.horizontal, MCI.Spacing.s - 2)
                    .padding(.vertical, MCI.Spacing.xxs)
                    .background(RoundedRectangle(cornerRadius: MCI.Radius.xs)
                        .stroke(Color.brandFgMuted.opacity(0.5), lineWidth: 0.5))
                    .foregroundStyle(Color.brandFgSecondary)
            }
            Text(verbatim: row.times > 1 ? "\(row.origin) \u{00B7} \(WorkCopy.searchedTimes(row.times))" : row.origin)
                .font(.system(.body, design: .default))
                .foregroundStyle(Color.brandFgSecondary)
            Text(Formatters.dayAndTime(us: row.record.tsUs))
                .font(.system(.caption, design: .default))
                .foregroundStyle(Color.brandFgSecondary)
            HStack(spacing: 8) {
                if let url = LookedUpModel.searchAgainURL(row) {
                    Button(WorkCopy.searchAgain) {
                        guard !isSyntheticPreview else { return }
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.bordered)
                    .help(url.host() ?? WorkCopy.searchAgain)
                }
                AskAIButton(source: .moments(row.eventIds), reader: reader, handlesCommandReturn: true)
                Spacer(minLength: 0)
                if let forget = lensForget.forget {
                    Button {
                        forget(row.eventIds, row.record.query, .search)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                    .help(WorkCopy.forgetThisSearch)
                    .accessibilityLabel(WorkCopy.forgetThisSearch)
                }
            }
            .padding(.top, 2)
        }
    }

    /// Up to five pages opened in the same browser in the five minutes after.
    private var next: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(WorkCopy.openedNext)
                .font(.system(.caption, design: .default).weight(.semibold))
                .foregroundStyle(Color.brandFgMuted)
                .accessibilityAddTraits(.isHeader)
            if openedNext.isEmpty {
                Text(WorkCopy.nothingOpenedNext)
                    .font(.system(size: 12))
                    .foregroundStyle(MCI.Color.foregroundSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(openedNext, id: \.id) { next in
                        NearRowView(title: MomentRowText.windowName(next), detail: Self.place(next, calendar: calendar)) {
                            open(RecallRoute(place: .ask, clearsField: true, focusEventId: next.id))
                        }
                    }
                }
            }
        }
    }

    /// What the results page showed: its reading, or the row's excerpt.
    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(UserFacingCopy.momentTextHeading(sourceKind: page.sourceKind))
                .font(.system(.caption, design: .default).weight(.semibold))
                .foregroundStyle(Color.brandFgMuted)
                .accessibilityAddTraits(.isHeader)
            let text = reading?.main ?? page.ocrTextSnippet
            if !readingDone {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(UserFacingCopy.momentTextLoading).font(.caption).foregroundStyle(.secondary)
                }
            } else if text.isEmpty {
                Text(UserFacingCopy.momentTextEmpty).font(.body).foregroundStyle(.secondary)
            } else {
                FormattedReadingView(text: text, reading: reading)
            }
        }
    }

    /// "pricingnotes.example · 2:07 PM".
    static func place(_ hit: Hit, calendar: Calendar) -> String {
        let host = hit.url.flatMap { URL(string: $0)?.host() }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        let time = WorkFormat.clock(Date(timeIntervalSince1970: Double(hit.tsUs) / 1_000_000), calendar: calendar)
        return [host, time].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}
