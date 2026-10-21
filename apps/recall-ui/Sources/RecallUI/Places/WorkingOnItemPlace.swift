import AppKit
import RecallUIKit
import SwiftUI

/// A Working On page (SPEC 3.2, SPEC-DELTA 3 and 4): everything about one
/// project or document. Its header with Resume, where you left off with its
/// screenshot, its files, the pages, searches and AI chats seen alongside,
/// its conversations by name, the meetings that overlapped its sessions,
/// and its own History by day: History's rows and detail for this item only.
struct WorkingOnItemPlace: View {
    let itemId: String
    let work: any WorkReader
    let reader: BrainReader
    let open: (RecallRoute) -> Void
    /// The item's name when the shell knows it, for "Nothing left from …".
    var name: String?
    /// Read again every two minutes while shown.
    var refreshEvery: Duration = .seconds(120)

    @StateObject private var model: WorkingOnItemModel
    @State private var selected: Hit?
    /// Context for This Folder…, open in the item's folder.
    @State private var folderSheet: FolderSheet?
    @Environment(\.workItemHides) private var hides
    @Environment(\.claudeCodeStartsSessions) private var claudeCodeStarts
    @Environment(\.workNow) private var now
    @Environment(\.workDisplayCalendar) private var calendar
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview
    @Environment(\.handoffServices) private var handoff
    @Environment(\.displayScale) private var displayScale

    /// `calendarReader`: the person's calendar when they turned it on, for
    /// the meetings that overlapped the item's sessions (SPEC-DELTA 5).
    init(itemId: String, work: any WorkReader, reader: BrainReader, open: @escaping (RecallRoute) -> Void,
         name: String? = nil, refreshEvery: Duration = .seconds(120), model: WorkingOnItemModel? = nil,
         selected: Hit? = nil, calendarReader: (any CalendarReader)? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.itemId = itemId
        self.work = work
        self.reader = reader
        self.open = open
        self.name = name
        self.refreshEvery = refreshEvery
        _model = StateObject(wrappedValue: model ?? WorkingOnItemModel(itemId: itemId, work: work, reader: reader,
                                                                       calendarReader: calendarReader, now: now))
        _selected = State(initialValue: selected)
    }

    var body: some View {
        AdaptiveEvidencePanes(showsDetail: selected != nil, backLabel: model.item?.name ?? WorkCopy.backToItem,
                              onDismissDetail: { selected = nil }) {
            ScrollView {
                page
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .padding(.bottom, 48)
                    .frame(maxWidth: 940, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .background(MCI.Color.background)
        } detail: {
            if let selected {
                DetailPaneView(hit: selected, reader: reader)
                    .id(selected.id)
            }
        }
        .task(id: itemId) {
            await model.reload()
            while !Task.isCancelled {
                do { try await Task.sleep(for: refreshEvery) } catch { return }
                // The days and pages already read stay; a forget reads all.
                await model.reload(keepingRead: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryDeletionSignal.notification)) { _ in
            selected = nil
            Task { await model.reload() }
        }
        .sheet(item: $folderSheet) { sheet in
            ProjectHandoffView(folderGuess: sheet.guess)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.state {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 60)
        case .failed:
            WorkEmptyState(symbol: "exclamationmark.triangle", title: WorkCopy.loadFailed,
                           actionTitle: WorkCopy.tryAgain) { Task { await model.reload() } }
        case .gone:
            WorkEmptyState(symbol: model.item.map { WorkFormat.symbol($0.kind) } ?? "square.stack",
                           title: (model.item?.name ?? name).map(WorkCopy.nothingLeft) ?? WorkCopy.nothingLeftToShow)
        case .loaded:
            if let item = model.item {
                VStack(alignment: .leading, spacing: 26) {
                    hiddenLine(item)
                    header(item)
                    if let newest = model.whereYouLeftOff {
                        whereYouLeftOff(newest, item: item)
                    }
                    columns(item)
                    history
                }
            }
        }
    }

    // MARK: Header

    @ViewBuilder
    private func hiddenLine(_ item: WorkItem) -> some View {
        if hides.keepsOut(item) {
            HStack(spacing: 12) {
                Text(hides.ids.contains(item.id) ? WorkCopy.notShownLine : WorkCopy.looksPersonal)
                    .font(.system(size: 13))
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                Spacer(minLength: 0)
                Button(WorkCopy.showInSidebar) { hides.show(item.id) }
                    .buttonStyle(WorkButtonStyle(small: true))
            }
            .padding(.vertical, 9)
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MCI.Color.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MCI.Color.border, lineWidth: 1))
        }
    }

    private func header(_ item: WorkItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            WorkKindTile(kind: item.kind)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.name)
                    .mciFont(.title)
                    .foregroundStyle(MCI.Color.foreground)
                    .lineLimit(2)
                    .help(item.name)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: WorkFormat.headerLine(item, now: now(), calendar: calendar))
                    .font(.system(size: 13))
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                Text(verbatim: WorkFormat.weekLine(item))
                    .font(.system(size: 13))
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                if item.kind == .code, claudeCodeStarts {
                    HStack(spacing: 4) {
                        Text(WorkCopy.claudeCodeStarts)
                            .foregroundStyle(MCI.Color.foregroundSecondary)
                        WorkLinkButton(title: WorkCopy.seeWhatItGets) {
                            if let route = RecallRoute(tab: "ai-tools") { open(route) }
                        }
                    }
                    .font(.system(size: 13))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                // Native, as the Ask button and ⋯ beside it are, so the row
                // shares one height, top edge and corner.
                Button(WorkCopy.resume) { open(.resume(item: item.id)) }
                    .buttonStyle(.borderedProminent)
                    .tint(MCI.Color.accentFill)
                    // Blue in a window in the background too, as it was.
                    .environment(\.controlActiveState, .key)
                    .help(WorkCopy.resume)
                // A code project's button opens Claude Code (or Codex) in
                // its folder (SPEC 5.3.1); ⌘↩ is this button.
                // The size of Resume and ⋯ beside it, as the prototype draws
                // the header's buttons.
                AskAIButton(source: .item(item.id), reader: reader, handlesCommandReturn: true,
                            itemMoments: item.moments, codeProject: item.kind == .code ? item.name : nil)
                Menu {
                    ForEach(WorkItemMenuItem.items(kind: item.kind, keptOut: hides.keepsOut(item), in: .itemPage),
                            id: \.self) { action in
                        Button(action.title) { perform(action, on: item) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(WorkCopy.more)
                .help(WorkCopy.more)
            }
            .padding(.top, 4)
        }
    }

    // MARK: Where you left off

    private func whereYouLeftOff(_ newest: Hit, item: WorkItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkSectionTitle(title: WorkCopy.whereYouLeftOff)
            HStack(alignment: .top, spacing: 18) {
                Button {
                    selected = model.leftOffScreenshot ?? newest
                } label: {
                    MomentPictureView(hit: model.leftOffScreenshot, size: CGSize(width: 240, height: 150),
                                      appBundleId: newest.appBundleId)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(MCI.Color.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(WorkCopy.screenshotOf(item.name))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: MomentRowText.headline(newest))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(MCI.Color.foreground)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(verbatim: WorkFormat.clock(Date(timeIntervalSince1970: Double(newest.tsUs) / 1_000_000),
                                                        calendar: calendar))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(MCI.Color.foregroundSecondary)
                    }
                    if let lines = MomentRowText.codeLines(newest) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.prefix(2).enumerated()), id: \.offset) { _, line in
                                Text(verbatim: line)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(MCI.Color.foregroundSecondary)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        Text(verbatim: MomentRowText.preview(newest))
                            .font(.system(size: 14))
                            .foregroundStyle(MCI.Color.foregroundSecondary)
                            .lineLimit(2)
                    }
                    Text(verbatim: MomentRowText.origin(newest, count: model.hits.prefix(while: {
                        $0.appBundleId == newest.appBundleId && $0.windowTitle == newest.windowTitle
                    }).count))
                        .font(.system(size: 10.5))
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let action = openAction(newest) {
                            Button(action.title, action: action.perform)
                                .buttonStyle(WorkButtonStyle(small: true))
                                .disabled(isSyntheticPreview)
                        }
                        Button(WorkCopy.showInHistory) { showInHistory(newest.id) }
                            .buttonStyle(WorkButtonStyle(small: true))
                    }
                    .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .workCard(padding: 16)
        }
    }

    /// The ⋯ menu's items (SPEC 3.2).
    private func perform(_ action: WorkItemMenuItem, on item: WorkItem) {
        switch action {
        case .showInSidebar: hides.show(item.id)
        case .hideFromSidebar: hides.hide(item.id)
        case .showInHistory: showInHistory(item.moments.first)
        case .contextForThisFolder:
            // Today's ⌘J sheet, in the project's folder.
            folderSheet = FolderSheet(guess: isSyntheticPreview ? nil : item.folderGuess)
        case .copyForYourAI:
            let services = HandoffServices.resolved(handoff, isSyntheticPreview: isSyntheticPreview)
            Task { await AskAIButton.copyForYourAI(.item(item.id), services: services) }
        }
    }

    /// "Open Page" for a page with an address, else "Open {App}" for an app
    /// on this Mac; none for an app that's gone.
    private func openAction(_ hit: Hit) -> (title: String, perform: () -> Void)? {
        if let address = hit.url, let url = URL(string: address), ["http", "https"].contains(url.scheme ?? "") {
            return (WorkCopy.openPage, { NSWorkspace.shared.open(url) })
        }
        guard let bundle = hit.appBundleId,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return (WorkCopy.open(Formatters.appDisplayName(bundle)), {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        })
    }

    // MARK: Files, Seen alongside, conversations, meetings

    @ViewBuilder
    private func columns(_ item: WorkItem) -> some View {
        let code = item.kind == .code && !item.files.isEmpty
        VStack(alignment: .leading, spacing: 26) {
            if code {
                HStack(alignment: .top, spacing: 28) {
                    files(item).frame(maxWidth: .infinity, alignment: .topLeading)
                    seenAlongside.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                seenAlongside
            }
            if !model.conversations.isEmpty || !model.meetings.isEmpty {
                HStack(alignment: .top, spacing: 28) {
                    if !model.conversations.isEmpty {
                        conversations.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    if !model.meetings.isEmpty {
                        meetings.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
    }

    private func files(_ item: WorkItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkSectionTitle(title: WorkCopy.files)
            VStack(spacing: 0) {
                ForEach(model.shownFiles, id: \.name) { file in
                    NearRowView(title: file.name, detail: "", monospaced: true, symbol: "doc",
                                trailing: WorkFormat.whenShort(us: file.lastUs, now: now(), calendar: calendar)) {
                        showInHistory(file.moment)
                    }
                    .help(WorkCopy.showInHistory)
                }
            }
            if model.moreFiles > 0 {
                WorkLinkButton(title: WorkCopy.andMore(model.moreFiles), chevron: false) {
                    withAnimation(MCI.Motion.standard) { model.showsAllFiles = true }
                }
                .font(.system(size: 12.5))
            }
        }
    }

    private var seenAlongside: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkSectionTitle(title: WorkCopy.seenAlongside, lead: WorkCopy.seenAlongsideLead)
            if model.alongside.isEmpty {
                Text(WorkCopy.nothingYet)
                    .font(.system(size: 12))
                    .foregroundStyle(MCI.Color.foregroundSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.alongside) { row in
                        NearRowView(title: row.title, detail: row.detail) { select(row.moment) }
                    }
                }
            }
        }
    }

    private var conversations: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkSectionTitle(title: WorkCopy.conversations, lead: WorkCopy.conversationsLead)
            VStack(spacing: 0) {
                ForEach(model.conversations) { row in
                    NearRowView(title: row.title, detail: row.detail) { select(row.moment) }
                }
            }
        }
    }

    private var meetings: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkSectionTitle(title: WorkCopy.meetings, lead: WorkCopy.meetingsLead)
            VStack(spacing: 0) {
                ForEach(model.meetings) { event in
                    let start = UInt64(max(0, event.start.timeIntervalSince1970 * 1_000_000))
                    let end = UInt64(max(0, event.end.timeIntervalSince1970 * 1_000_000))
                    NearRowView(title: event.title,
                                detail: WorkCopy.meetingLine(calendar: event.calendarName,
                                                             when: WorkFormat.whenShort(us: start, now: now(),
                                                                                        calendar: calendar))) {
                        open(.history(of: Int64(start)...Int64(max(start, end))))
                    }
                }
            }
        }
    }

    private func select(_ moment: UInt64) {
        if let hit = model.nearHits[moment] ?? model.hits.first(where: { $0.id == moment }) {
            selected = hit
        } else {
            showInHistory(moment)
        }
    }

    private func showInHistory(_ moment: UInt64?) {
        guard let moment else { return }
        open(RecallRoute(place: .ask, clearsField: true, focusEventId: moment))
    }

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                WorkSectionTitle(title: WorkCopy.history)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    ForEach(model.dayButtons) { day in
                        let on = day.id == model.shownDay?.id
                        Button(day.label) { show(day) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(on ? MCI.Color.foreground : MCI.Color.foregroundSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(on ? Color.primary.opacity(0.065) : Color.clear))
                            .accessibilityAddTraits(on ? .isSelected : [])
                    }
                    if !model.olderDays.isEmpty {
                        olderDaysMenu
                    }
                }
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(HistorySections.group(hits: model.dayHits, sessions: [], calendar: calendar)) { section in
                    hourHeading(section)
                    ForEach(section.rows) { row in
                        Button {
                            selected = row.hit
                        } label: {
                            HitRow(hit: row.hit, showsClockTime: true, count: row.count, screenshot: row.screenshot)
                                .padding(.horizontal, 6)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selected?.id == row.hit.id ? MCI.Color.accentSubtle : Color.clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if model.canLoadEarlier {
                HStack {
                    Spacer()
                    if model.isLoadingEarlier {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(WorkCopy.showEarlier) { Task { await model.loadEarlier() } }
                            .buttonStyle(WorkButtonStyle())
                    }
                    Spacer()
                }
                .padding(.top, 10)
            }
        }
    }

    /// The days past the buttons: "Earlier", or the older day shown.
    private var olderDaysMenu: some View {
        let shown = model.olderDays.first { $0.id == model.shownDay?.id }
        return Menu {
            ForEach(model.olderDays) { day in
                Toggle(day.label, isOn: Binding(get: { day.id == model.shownDay?.id }, set: { _ in show(day) }))
            }
        } label: {
            Text(shown?.label ?? WorkCopy.earlier)
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(shown != nil ? MCI.Color.foreground : MCI.Color.foregroundSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(shown != nil ? Color.primary.opacity(0.065) : Color.clear))
        .accessibilityLabel(shown?.label ?? WorkCopy.earlier)
        .accessibilityAddTraits(shown != nil ? .isSelected : [])
    }

    /// A day's History: read first when it isn't yet.
    private func show(_ day: ItemDay) {
        Task { await model.show(day: day.id) }
    }

    private func hourHeading(_ section: HistorySection) -> some View {
        let label: String = switch section.owner {
        case let .hour(startUs): Formatters.clockHour(us: startUs, locale: calendar.locale ?? .autoupdatingCurrent,
                                                      timeZone: calendar.timeZone)
        case let .session(block): block.title
        }
        return VStack(alignment: .leading, spacing: 7) {
            Text(verbatim: label)
                .font(.system(size: 12))
                .foregroundStyle(MCI.Color.foregroundSecondary)
            Rectangle().fill(MCI.Color.borderStrong).frame(height: 1)
        }
        .padding(.top, 14)
        .accessibilityAddTraits(.isHeader)
    }
}
