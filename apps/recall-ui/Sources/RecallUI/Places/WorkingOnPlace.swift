import RecallUIKit
import SwiftUI

/// Working On, all of it (SPEC 3.3, SPEC-DELTA 2): every project and
/// document by name as a card with its newest screenshot, kind, apps, when
/// it was last worked on and its time this week; This week, Earlier, and
/// what isn't in the sidebar (closed). The field filters the names (the
/// shell's field, through `filter`); right-click hides or shows an item in
/// the sidebar.
struct WorkingOnPlace: View {
    let work: any WorkReader
    let reader: BrainReader
    let open: (RecallRoute) -> Void
    /// What the field filters the names by.
    var filter = ""
    /// Read again every two minutes while shown (SPEC 2.3).
    var refreshEvery: Duration = .seconds(120)

    @StateObject private var model: WorkingOnModel
    @State private var showsNotShown = false
    @Environment(\.workItemHides) private var hides
    @Environment(\.workMoments) private var injectedMoments
    private var moments: WorkMomentCache { injectedMoments ?? .shared }
    @Environment(\.retentionDays) private var retentionDays
    @Environment(\.workNow) private var now
    @Environment(\.workDisplayCalendar) private var calendar
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview
    @Environment(\.handoffServices) private var handoff

    init(work: any WorkReader, reader: BrainReader, open: @escaping (RecallRoute) -> Void, filter: String = "",
         refreshEvery: Duration = .seconds(120), model: WorkingOnModel? = nil, showsNotShown: Bool = false) {
        self.work = work
        self.reader = reader
        self.open = open
        self.filter = filter
        self.refreshEvery = refreshEvery
        _model = StateObject(wrappedValue: model ?? WorkingOnModel(reader: work))
        _showsNotShown = State(initialValue: showsNotShown)
    }

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(NavigationCopy.workingOn)
                        .mciFont(.title)
                        .foregroundStyle(MCI.Color.foreground)
                        .accessibilityAddTraits(.isHeader)
                    Text(WorkCopy.workingOnLead)
                        .font(.system(size: 13))
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                }
                content
            }
            .pageColumn()
        }
        .background(MCI.Color.background)
        .onChange(of: filter) { _, value in model.filter = value }
        .task {
            model.filter = filter
            await model.reload()
            await loadPictures()
            while !Task.isCancelled {
                do { try await Task.sleep(for: refreshEvery) } catch { return }
                await model.reload()
                await loadPictures()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryDeletionSignal.notification)) { _ in
            Task {
                await model.reload()
                await loadPictures()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading where model.snapshot.items.isEmpty:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 40)
        case .failed:
            WorkEmptyState(symbol: "exclamationmark.triangle", title: WorkCopy.loadFailed,
                           actionTitle: WorkCopy.tryAgain) { Task { await model.reload() } }
        default:
            let groups = model.groups(hidden: hides.ids, shown: hides.shown)
            if model.snapshot.items.isEmpty {
                WorkEmptyState(symbol: "square.stack", title: WorkCopy.workingOnEmptyTitle,
                               message: WorkCopy.workingOnEmptyBody)
            } else if groups.isEmpty {
                WorkEmptyState(symbol: "magnifyingglass", title: WorkCopy.nothingMatched(NavigationCopy.workingOn))
            } else {
                ForEach(groups) { group in
                    section(group)
                }
                // Kept until forgotten (0): nothing is deleted, so no line.
                if retentionDays > 0 {
                    retentionLine
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ group: WorkingOnGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if group.kind == .notShown {
                Button {
                    withAnimation(MCI.Motion.snap) { showsNotShown.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MCI.Color.foregroundSecondary)
                            .rotationEffect(.degrees(showsNotShown ? 90 : 0))
                        Text(group.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MCI.Color.foreground)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsNotShown ? "expanded" : "collapsed")
                if showsNotShown {
                    grid(group.items, notShown: true)
                }
            } else {
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MCI.Color.foreground)
                    .accessibilityAddTraits(.isHeader)
                grid(group.items, notShown: false)
            }
        }
    }

    private func grid(_ items: [WorkItem], notShown: Bool) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(items) { item in
                WorkItemCard(item: item, picture: moments.hit(item.thumbnailMoment),
                             note: notShown ? WorkingOnModel.whyNotShown(item, hidden: hides.ids, shown: hides.shown) : nil,
                             now: now(), calendar: calendar,
                             showInSidebar: notShown ? { show(item) } : nil) {
                    open(RecallRoute(workItem: item.id))
                }
                .contextMenu { menu(for: item) }
            }
        }
    }

    /// Show or Hide in Sidebar, Show in History, Copy for Your AI (SPEC 3.3).
    private func menu(for item: WorkItem) -> some View {
        ForEach(WorkItemMenuItem.items(kind: item.kind, keptOut: hides.keepsOut(item), in: .showAll),
                id: \.self) { action in
            Button(action.title) { perform(action, on: item) }
        }
    }

    private func perform(_ action: WorkItemMenuItem, on item: WorkItem) {
        switch action {
        case .showInSidebar: show(item)
        case .hideFromSidebar: hides.hide(item.id)
        case .showInHistory: showInHistory(item)
        case .copyForYourAI:
            // The builder's message for the item, by the clipboard rules (SPEC 5.3.6).
            let services = HandoffServices.resolved(handoff, isSyntheticPreview: isSyntheticPreview)
            Task { await AskAIButton.copyForYourAI(.item(item.id), services: services) }
        case .contextForThisFolder:
            break
        }
    }

    private func show(_ item: WorkItem) {
        hides.show(item.id)
    }

    private func showInHistory(_ item: WorkItem) {
        guard let newest = item.moments.first else { return }
        open(RecallRoute(place: .ask, clearsField: true, focusEventId: newest))
    }

    private var retentionLine: some View {
        HStack(spacing: 12) {
            Text(WorkCopy.retention(days: retentionDays))
                .font(.system(size: 12))
                .foregroundStyle(MCI.Color.foregroundSecondary)
            Spacer(minLength: 0)
            Button(WorkCopy.change) {
                guard !isSyntheticPreview else { return }
                Task { _ = await WorkspacePreferencesRouter.shared.open(.privacy, bundleURL: Bundle.main.bundleURL) }
            }
            .buttonStyle(WorkButtonStyle(small: true))
        }
        .padding(.top, 2)
    }

    private func loadPictures() async {
        await moments.load(model.snapshot.items.compactMap(\.thumbnailMoment), reader: reader)
    }
}

/// One card of Show All: the item's newest screenshot (its kind's symbol
/// without one, and for a name that looks personal), its name, its kind and
/// apps, when it was last worked on and its time this week.
struct WorkItemCard: View {
    let item: WorkItem
    let picture: Hit?
    /// Why it isn't in the sidebar, when it isn't.
    var note: String?
    let now: Date
    let calendar: Calendar
    var showInSidebar: (() -> Void)?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 0) {
                    pictureArea
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: item.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(MCI.Color.foreground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(item.name)
                        Text(verbatim: [WorkFormat.kindLabel(item.kind), WorkFormat.placesList(item)]
                            .filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                            .font(.system(size: 12))
                            .foregroundStyle(MCI.Color.foregroundSecondary)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(verbatim: WorkFormat.whenShort(us: item.lastUs, now: now, calendar: calendar))
                            Spacer(minLength: 0)
                            Text(verbatim: item.weekMinutes > 0
                                ? WorkFormat.duration(minutes: item.weekMinutes)
                                : WorkCopy.inAllTime(WorkFormat.duration(minutes: max(1, item.totalMinutes))))
                                .monospacedDigit()
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, note == nil ? 12 : 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let note {
                VStack(alignment: .leading, spacing: 8) {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let showInSidebar {
                        Button(WorkCopy.showInSidebar, action: showInSidebar)
                            .buttonStyle(WorkButtonStyle(small: true))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: MCI.Radius.l, style: .continuous).fill(MCI.Color.surface))
        .clipShape(RoundedRectangle(cornerRadius: MCI.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MCI.Radius.l, style: .continuous)
            .strokeBorder(hovering ? MCI.Color.borderStrong : MCI.Color.border, lineWidth: 1))
        .onHover { inside in
            withAnimation(MCI.Motion.snap) { hovering = inside }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(WorkFormat.accessibilityLabel(item, now: now, calendar: calendar))
        .accessibilityAddTraits(.isButton)
    }

    private var pictureArea: some View {
        GeometryReader { geometry in
            let size = CGSize(width: geometry.size.width, height: geometry.size.height)
            ZStack {
                MCI.Color.background
                if picture?.thumbnailURL != nil, !item.looksPersonal {
                    MomentPictureView(hit: picture, size: size, cornerRadius: 0)
                } else {
                    Image(systemName: WorkFormat.symbol(item.kind))
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(MCI.Color.foregroundMuted)
                }
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MCI.Color.border).frame(height: 1)
        }
        .accessibilityLabel(WorkCopy.screenshotOf(item.name))
    }
}
