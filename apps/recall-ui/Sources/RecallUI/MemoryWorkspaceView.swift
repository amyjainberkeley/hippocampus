import AppKit
import RecallUIKit
import SwiftUI

/// The three places in the window (RULINGS G5): the sidebar's rows.
enum MemoryWorkspaceSelection: String, CaseIterable, Identifiable {
    case overview
    case ask
    case you

    var id: String { rawValue }

    init(place: RecallPlace) {
        switch place {
        case .overview: self = .overview
        case .ask: self = .ask
        case .you: self = .you
        }
    }

    /// Every old name keeps working and opens one of the three places
    /// (RULINGS X9).
    init(initialTab: RecallTab) {
        self.init(place: initialTab.place)
    }

    var place: RecallPlace {
        switch self {
        case .overview: .overview
        case .ask: .ask
        case .you: .you
        }
    }

    var descriptor: MCI.Workspace.Destination {
        MCI.Workspace.allDestinations.first { $0.id == rawValue }
            ?? MCI.Workspace.primaryDestinations[0]
    }

    var keyboardShortcutLabel: String {
        descriptor.keyboardShortcut
    }

    init?(keyboardShortcut: Character) {
        guard
            let destination = MCI.Workspace.destination(
                forKeyboardShortcut: String(keyboardShortcut)
            ),
            let selection = Self(rawValue: destination.id)
        else {
            return nil
        }
        self = selection
    }
}

/// One route for the window to apply, with a sequence so the same route
/// twice is applied twice (a second "Show in History" on one session).
struct RecallRouteRequest: Equatable {
    let route: RecallRoute
    let sequence: UInt64
}

/// The window: the hi mark, three places and whether Hippocampus is
/// remembering (RULINGS W10). It owns every place's model, so what a place
/// shows survives moving between them (critique-recall-engineering finding 16).
struct MemoryWorkspaceView: View {
    let reader: BrainReader
    /// What the places read about the day and the person. Required, so the
    /// synthetic preview can never fall back to the agent and the person's
    /// own memory (critique-recall-engineering finding 12).
    let understanding: UnderstandingReader
    @Binding var selection: MemoryWorkspaceSelection
    /// The newest route from a link, the app or a command.
    var routeRequest: RecallRouteRequest? = nil
    /// Moves on each time a command asks for the cursor in Ask's field.
    var fieldFocusRequest = 0
    var isSyntheticPreview = false
    /// The status Hippocampus saves, for the sidebar's footer.
    var healthLoader: @Sendable () async -> CaptureHealthReceipt? = { await CaptureHealthReceipt.load() }
    var contextExporter: @Sendable (String) async throws -> String = { try await ContextHandoffExporter.export(focus: $0) }
    var calendar: Calendar = .current
    var now: @Sendable () -> Date = { Date() }
    /// The app opened the window on Demo Memory: the small Demo tag shows by
    /// the title (`DemoTag`, SPEC-DELTA 6). Never set for the person's own.
    var isDemoMemory = false

    @StateObject private var ask: AskViewModel
    @StateObject private var overview: OverviewViewModel
    @StateObject private var you: UserModelViewModel
    /// Pages pushed inside You: what is remembered, the names you use. The
    /// shell owns the path so a route can open them (critique-recall-engineering
    /// finding 5).
    @State private var youPath: [RecallYouPage] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var status = SidebarStatus(receipt: nil)
    /// The Working On item whose Resume sheet a route asked for.
    @State private var resumeSheet: ResumeSheetItem?
    @Environment(\.scenePhase) private var scenePhase

    init(
        reader: BrainReader,
        understanding: UnderstandingReader,
        selection: Binding<MemoryWorkspaceSelection>,
        routeRequest: RecallRouteRequest? = nil,
        fieldFocusRequest: Int = 0,
        isSyntheticPreview: Bool = false,
        healthLoader: @escaping @Sendable () async -> CaptureHealthReceipt? = { await CaptureHealthReceipt.load() },
        contextExporter: @escaping @Sendable (String) async throws -> String = {
            try await ContextHandoffExporter.export(focus: $0)
        },
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        ask: AskViewModel? = nil,
        overview: OverviewViewModel? = nil,
        you: UserModelViewModel? = nil,
        status: SidebarStatus? = nil,
        isDemoMemory: Bool = false
    ) {
        self.reader = reader
        self.understanding = understanding
        _selection = selection
        self.routeRequest = routeRequest
        self.fieldFocusRequest = fieldFocusRequest
        self.isSyntheticPreview = isSyntheticPreview
        self.healthLoader = healthLoader
        self.contextExporter = contextExporter
        self.calendar = calendar
        self.now = now
        self.isDemoMemory = isDemoMemory
        _ask = StateObject(wrappedValue: ask ?? Self.makeAsk(
            reader: reader, understanding: understanding, calendar: calendar, now: now))
        _overview = StateObject(wrappedValue: overview ?? OverviewViewModel(
            understanding: understanding, calendar: calendar, healthLoader: healthLoader, now: now,
            savedBefore: { try await reader.isAnythingSaved(before: $0) }))
        // The preview's verdicts go nowhere: "Right" and "Forget" there must
        // never reach the folder the agent applies to the person's memory.
        _you = StateObject(wrappedValue: you ?? UserModelViewModel(
            understanding: understanding,
            verdicts: isSyntheticPreview ? VerdictInbox(directory: nil) : .shared))
        if let status { _status = State(initialValue: status) }
    }

    /// Ask opens empty every time: nothing typed is kept on disk
    /// (spec-recall S3, "Fresh start").
    @MainActor
    static func makeAsk(
        reader: BrainReader,
        understanding: UnderstandingReader,
        calendar: Calendar,
        now: @escaping @Sendable () -> Date
    ) -> AskViewModel {
        AskViewModel(
            search: SearchViewModel(
                reader: reader,
                persistence: QueryPersistence(environment: ["MCI_EPHEMERAL_UI_STATE": "1"])
            ),
            history: TimelineViewModel(
                reader: reader, pageSize: 200, day: MemoryDay(date: now(), calendar: calendar), now: now
            ),
            understanding: understanding,
            calendar: calendar
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            workspaceDetail
        }
        .background(Color.brandBgPrimary)
        .navigationTitle(UserFacingCopy.windowTitle)
        .modifier(DemoTagSlot(isDemoMemory: isDemoMemory))
        .sheet(item: $resumeSheet) { item in
            ResumeSheet(itemId: item.id)
        }
        .task(id: routeRequest?.sequence) {
            guard let routeRequest else { return }
            await apply(routeRequest.route)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            MemoryRefreshSignal.post()
            await loadStatus()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard !Task.isCancelled else { return }
                MemoryRefreshSignal.post()
                await loadStatus()
            }
        }
        // Outermost, so sheets and every place see it: in the synthetic
        // preview nothing opens the person's own data or deletes anything.
        .environment(\.isSyntheticPreview, isSyntheticPreview)
    }

    private func loadStatus() async {
        let receipt = await healthLoader()
        status = SidebarStatus(receipt: receipt, now: now())
    }

    /// A route from a link, the app, a command or a place: the place, then
    /// what it shows (a memory or History's range in Ask, a day and session
    /// on Overview, a page inside You).
    private func apply(_ route: RecallRoute) async {
        let place = route.place(keeping: selection.place)
        selection = MemoryWorkspaceSelection(place: place)
        if route.opensAskPanel, !isSyntheticPreview {
            // The window has no panel of its own: the menu bar opens Ask.
            NSWorkspace.shared.open(RecallRoute.askPanelURL)
        }
        switch place {
        case .ask:
            await ask.open(route)
        case .overview:
            overview.open(route)
        case .you:
            // Only a route that names You moves its pages; one that keeps the
            // place on screen leaves them. The preview opens neither page:
            // both read the person's own files.
            if route.place == .you {
                youPath = isSyntheticPreview ? [] : route.youPath
            }
        }
        // Resume's sheet lists what it would open; nothing opens until the
        // person clicks in it (SPEC-DELTA 3).
        if route.showsResume, let item = route.workItem {
            resumeSheet = ResumeSheetItem(id: item)
        }
    }

    /// What a place asks of the window: "Show in History", a session row on
    /// You, a page inside You.
    private func open(_ route: RecallRoute) {
        Task { await apply(route) }
    }

    /// A search chip on Overview: its words in Ask's field, searched.
    private func searchInAsk(_ text: String) {
        selection = .ask
        ask.query = text
        Task { await ask.search.runSearch() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowHiMarkView(remembering: status.remembering)
                .frame(height: 22)
                .foregroundStyle(Color.brandFgPrimary)
                .padding(.horizontal, MCI.Spacing.l)
                .padding(.top, MCI.Spacing.s)
                .padding(.bottom, MCI.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            List(selection: $selection) {
                ForEach(MemoryWorkspaceSelection.allCases) { item in
                    MemorySidebarRow(item: item)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Button {
                Task { _ = await WorkspacePreferencesRouter.shared.open(.capture, bundleURL: Bundle.main.bundleURL) }
            } label: {
                HStack(spacing: MCI.Spacing.s) {
                    Circle()
                        .fill(status.remembering ? Color.brandAccentFill : Color.brandFgMuted.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(status.text)
                        .mciFont(.caption)
                        .foregroundStyle(Color.brandFgSecondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .help(UserFacingCopy.footerHelp)
            .disabled(isSyntheticPreview)
            .padding(.horizontal, MCI.Spacing.l)
            .padding(.vertical, MCI.Spacing.m)
        }
        .background(Color.brandBgSecondary)
    }

    @ViewBuilder
    private var workspaceDetail: some View {
        Group {
            switch selection {
            case .overview:
                OverviewPlace(model: overview, reader: reader, open: open, search: searchInAsk)
            case .ask:
                AskPlace(
                    model: ask,
                    reader: reader,
                    fieldFocusRequest: fieldFocusRequest,
                    contextExporter: contextExporter,
                    calendar: calendar,
                    now: now
                )
            case .you:
                NavigationStack(path: $youPath) {
                    YouPlace(model: you, open: open)
                        .navigationDestination(for: RecallYouPage.self) { page in
                            youPage(page)
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.brandBgPrimary)
        // The newest note from any place (`BottomNotes.show`): nothing at
        // all until there is one.
        .overlay(alignment: .bottom) { BottomNoteHost() }
        .navigationTitle(UserFacingCopy.windowTitle)
    }

    /// A page pushed inside You. Neither is reached in the preview (`apply`).
    @ViewBuilder
    private func youPage(_ page: RecallYouPage) -> some View {
        switch page {
        case .privacy:
            PrivacyDashboard(reader: reader, mutator: reader as? PrivacyMutator)
        case .names:
            UserDictionaryEditor()
        }
    }
}

private struct MemorySidebarRow: View {
    let item: MemoryWorkspaceSelection

    var body: some View {
        // The selectable List row owns keyboard focus and selection appearance.
        Label(item.descriptor.title, systemImage: item.descriptor.systemImage)
            .mciFont(.body)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.descriptor.title)
    }
}
