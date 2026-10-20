import AppKit
import RecallUIKit
import SwiftUI

/// Web Pages (SPEC 3.5): pages read in a browser, one row per page across
/// days, newest first, under Apple Notes' date sections, with a browser
/// filter. A lens over History: each row is its newest moment drawn as
/// History draws it, with the page's title and site; its detail is
/// History's, with when it was read and the page's own actions.
struct WebPagesPlace: View {
    let work: any WorkReader
    let reader: BrainReader
    let open: (RecallRoute) -> Void

    @StateObject private var model: WebPagesModel
    /// The Working On item each page's newest moment is part of, for
    /// "Part of trailhead-shop ›" under the detail's header (SPEC 3.4).
    @StateObject private var items: MomentItems
    @Environment(\.workNow) private var now
    @Environment(\.workDisplayCalendar) private var calendar
    @Environment(\.lensForget) private var lensForget
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview

    init(work: any WorkReader, reader: BrainReader, open: @escaping (RecallRoute) -> Void,
         model: WebPagesModel? = nil) {
        self.work = work
        self.reader = reader
        self.open = open
        _model = StateObject(wrappedValue: model ?? WebPagesModel(work: work, reader: reader))
        _items = StateObject(wrappedValue: MomentItems(reader: work))
    }

    var body: some View {
        AdaptiveEvidencePanes(showsDetail: model.selected?.newest != nil, backLabel: NavigationCopy.webPages,
                              onDismissDetail: { Task { await model.select(nil) } }) {
            list
        } detail: {
            if let row = model.selected, let hit = row.newest {
                detail(row, hit: hit)
            }
        }
        .background(MCI.Color.background)
        .task {
            await model.reload()
        }
        .task(id: model.selected?.newest?.id) {
            if let id = model.selected?.newest?.id { await items.load([id]) }
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryDeletionSignal.notification)) { _ in
            items.clear()
            Task { await model.reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryRefreshSignal.notification)) { _ in
            Task { await model.reload() }
        }
    }

    // MARK: The list

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                header
                switch model.state {
                case .loading where model.rows.isEmpty:
                    ForEach(0..<4, id: \.self) { _ in LoadingRow().padding(.horizontal, 18) }
                case .failed:
                    WorkEmptyState(symbol: "exclamationmark.triangle", title: WorkCopy.loadFailed,
                                   actionTitle: WorkCopy.tryAgain) { Task { await model.reload() } }
                default:
                    if model.shownRows.isEmpty {
                        WorkEmptyState(symbol: "globe",
                                       title: model.browser.map { WorkCopy.noPagesFrom(Formatters.appDisplayName($0)) }
                                           ?? WorkCopy.webPagesEmptyTitle,
                                       message: model.browser == nil ? WorkCopy.webPagesEmptyBody : nil)
                    } else {
                        ForEach(model.sections, id: \.title) { section in
                            Section {
                                ForEach(section.rows) { row in
                                    rowView(row, last: row.id == section.rows.last?.id)
                                }
                            } header: {
                                sectionHeader(section.title, first: section.title == model.sections.first?.title)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 28)
        }
        .background(MCI.Color.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                Text(NavigationCopy.webPages)
                    .mciFont(.title)
                    .foregroundStyle(MCI.Color.foreground)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if !model.rows.isEmpty {
                    browserMenu
                }
            }
            Text(WorkCopy.webPagesLead)
                .font(.system(size: 13))
                .foregroundStyle(MCI.Color.foregroundSecondary)
            if model.hasNoAddresses {
                HStack(spacing: 10) {
                    Text(WorkCopy.noAddressesNote)
                        .font(.system(size: 12))
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                    Spacer(minLength: 0)
                    Button(WorkCopy.addBrowserExtension) {
                        guard !isSyntheticPreview else { return }
                        Task { _ = await WorkspacePreferencesRouter.shared.open(.sources, bundleURL: Bundle.main.bundleURL) }
                    }
                    .buttonStyle(WorkButtonStyle(small: true))
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 6)
    }

    private var browserMenu: some View {
        Menu {
            Button(WorkCopy.allBrowsers) { model.browser = nil }
            Divider()
            ForEach(model.browsers, id: \.self) { browser in
                Button(Formatters.appDisplayName(browser)) { model.browser = browser }
            }
        } label: {
            Text(model.browser.map(Formatters.appDisplayName) ?? WorkCopy.allBrowsers)
                .font(.system(size: 13))
        }
        .menuStyle(.button)
        .fixedSize()
    }

    private func sectionHeader(_ title: String, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(verbatim: title)
                .font(.system(size: 12))
                .foregroundStyle(MCI.Color.foregroundSecondary)
            Rectangle().fill(MCI.Color.borderStrong).frame(height: 1)
        }
        .padding(.horizontal, 18)
        .padding(.top, first ? 14 : 32)
        .background(MCI.Color.background)
        .accessibilityAddTraits(.isHeader)
    }

    private func rowView(_ row: WebPageRow, last: Bool) -> some View {
        let origin = WebPagesModel.origin(row)
        let selected = model.selectedId == row.id
        return Button {
            Task { await model.select(row.id) }
        } label: {
            LensRow(hit: row.newest, headline: row.page.title, place: origin.place, extra: origin.days,
                    when: WorkFormat.rowTime(us: row.lastUs, now: now(), calendar: calendar),
                    appBundleId: row.page.app)
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
            if let url = WebPagesModel.link(row) {
                Button(WorkCopy.openLink) {
                    guard !isSyntheticPreview else { return }
                    NSWorkspace.shared.open(url)
                }
                Button(WorkCopy.copyLink) { copy(url) }
            }
            AskAIMenu(source: .moments(Array(row.page.moments.prefix(WebPagesModel.askMoments))))
            if let forget = lensForget.forget {
                Divider()
                Button(WorkCopy.forgetThisPage) { forget(row.page.moments, row.page.title, .page) }
            }
        }
    }

    // MARK: The detail

    private func detail(_ row: WebPageRow, hit: Hit) -> some View {
        // History's own detail, with the page's "Read 2 times today" under
        // its date and the page's actions in place of a moment's (SPEC 3.5).
        DetailPaneView(hit: hit, reader: reader, partOf: items.partOf(hit),
                       openItem: { open(RecallRoute(workItem: $0.id)) }, underDate: readOnLine(row),
                       actions: AnyView(actions(row)))
            .id(hit.id)
    }

    /// "Read 2 times today:" and each time, which opens it in History.
    private func readOnLine(_ row: WebPageRow) -> AnyView? {
        guard let readOn = model.readOn(row) else { return nil }
        return AnyView(
            HStack(spacing: 6) {
                Text(readOn.lead)
                    .font(.system(size: 12))
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                ForEach(readOn.moments, id: \.id) { moment in
                    Button {
                        open(RecallRoute(place: .ask, clearsField: true, focusEventId: moment.id))
                    } label: {
                        Text(verbatim: WorkFormat.whenShort(us: moment.tsUs, now: now(), calendar: calendar))
                            .font(.system(size: 11.5))
                            .foregroundStyle(MCI.Color.foreground)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(MCI.Color.surface))
                            .overlay(Capsule().strokeBorder(MCI.Color.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        )
    }

    /// Open Link, Copy Link, Ask and, at the far right, Forget This Page.
    private func actions(_ row: WebPageRow) -> some View {
        HStack(spacing: 8) {
            if let url = WebPagesModel.link(row) {
                Button(WorkCopy.openLink) {
                    guard !isSyntheticPreview else { return }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(WorkCopy.copyLink) { copy(url) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            // Ask is given the page's newest moments (SPEC 5.3.1).
            AskAIButton(source: .moments(Array(row.page.moments.prefix(WebPagesModel.askMoments))),
                        reader: reader, handlesCommandReturn: true)
                .controlSize(.small)
            Spacer(minLength: 0)
            if let forget = lensForget.forget {
                TrashButton(help: WorkCopy.forgetThisPage, label: WorkCopy.forgetThisPage) {
                    forget(row.page.moments, row.page.title, .page)
                }
            }
        }
    }

    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}
