import AppKit
import RecallUIKit
import SwiftUI

/// The page on screen: a place, or a Working On item's page (SPEC 2.2).
typealias MemoryWorkspaceSelection = WindowPage

extension WindowPage {
    // The window's places by name, and the names they had before the sidebar
    // (Overview, Ask, You), so a scene or a route written either way reads.
    static let today = WindowPage.place(.today)
    static let history = WindowPage.place(.history)
    static let overview = WindowPage.place(.today)
    static let ask = WindowPage.place(.history)
    static let you = WindowPage.place(.aboutYou)
    static let aboutYou = WindowPage.place(.aboutYou)
    static let aiTools = WindowPage.place(.aiTools)
    static let privacy = WindowPage.place(.privacy)
    static let webPages = WindowPage.place(.webPages)
    static let lookedUp = WindowPage.place(.lookedUp)
    static let workingOn = WindowPage.place(.workingOn)

    /// ⌘`key`'s page, shown in the sidebar or not (keys never move).
    init?(keyboardShortcut key: Character) {
        guard let place = SidebarPlace(key: key) else { return nil }
        self = .place(RecallPlace(place))
    }
}

/// One route for the window to apply, with a sequence so the same route
/// twice is applied twice (a second "Show in History" on one session).
struct RecallRouteRequest: Equatable {
    let route: RecallRoute
    let sequence: UInt64
}

/// What off-screen pictures set that a person would otherwise do: a menu
/// open, the pointer resting on an item, the narrow window's sidebar shown.
struct WindowShellPreset {
    var sidebar: SidebarModel?
    var choices = SidebarHides.Choices()
    var narrowSidebarOpen = false
    var sidebarHidden = false
    /// The status menu drawn open, from the footer or the hi mark.
    var statusMenu: StatusMenuAnchor?
    var statusMenuPauseOpen = false
    var hoveredItem: String?
    var showsFootnote = false
    var showsNewSidebarLine = false
    var forgetSheet: ForgetRecentChoice?
    var canGoBack = false

    enum StatusMenuAnchor { case hiMark, footer }
}

/// The window: the sidebar, the field over every memory page, the banner
/// whenever remembering isn't on, and the page (SPEC 2). It owns every
/// place's model, so what a place shows survives moving between them
/// (critique-recall-engineering finding 16).
struct MemoryWorkspaceView: View {
    let reader: BrainReader
    /// What the places read about the day and the person. Required, so the
    /// synthetic preview can never fall back to the agent and the person's
    /// own memory (critique-recall-engineering finding 12).
    let understanding: UnderstandingReader
    /// What the person works on: the sidebar's Working On, Web Pages.
    let work: any WorkReader
    @Binding var selection: MemoryWorkspaceSelection
    /// The newest route from a link, the app or a command.
    var routeRequest: RecallRouteRequest? = nil
    /// Moves on each time a command asks for the cursor in the field.
    var fieldFocusRequest = 0
    var isSyntheticPreview = false
    /// The status Hippocampus saves, for a window with no pipe.
    var healthLoader: @Sendable () async -> CaptureHealthReceipt? = { await CaptureHealthReceipt.load() }
    var contextExporter: @Sendable (String) async throws -> String = { try await ContextHandoffExporter.export(focus: $0) }
    var calendar: Calendar = .current
    var now: @Sendable () -> Date = { Date() }
    /// The app opened the window on Demo Memory: the small Demo tag shows by
    /// the window's controls (`DemoTag`, SPEC-DELTA 6).
    var isDemoMemory = false
    /// The private pipe to the app; nil for a window opened by hand.
    var channel: (any WindowChannelSending)?
    /// Whether the menu-bar app runs (for a window opened by hand).
    var appRunning: @Sendable () -> Bool = { false }
    /// People who used the preview see one line about the new sidebar, once.
    var isUpgrade = false
    /// Off-screen pictures draw the window's controls; the live window's
    /// are the system's own.
    var drawsWindowControls = false
    var preset: WindowShellPreset?
    let hides: SidebarHides
    /// Where the sidebar's little screenshots come from.
    let pictures: SidebarPictures
    /// The notes at the bottom: the window's own; a picture brings its own.
    @ObservedObject var notes: BottomNotes

    @StateObject private var ask: AskViewModel
    @StateObject private var overview: OverviewViewModel
    @StateObject private var you: UserModelViewModel
    @StateObject private var forgetting: ForgetCoordinator
    /// Pages pushed inside About You: the names you use.
    @State private var youPath: [RecallYouPage] = []
    @State private var status: WindowStatus
    @State private var sidebar = SidebarUpdates()
    @State private var choices: SidebarHides.Choices
    @State private var navigation = NavigationHistory()
    @State private var sidebarHidden = false
    @State private var narrowSidebarOpen = false
    /// The window is narrower than `narrowWidth`: the sidebar shows over
    /// the page when asked for.
    @State private var isNarrow = false
    @State private var hovered: (item: SidebarWorkItem, frame: CGRect)?
    @State private var preview: (item: SidebarWorkItem, frame: CGRect)?
    @State private var showsFootnote = false
    @State private var showsNewSidebarLine = false
    @State private var forgetSheet: ForgetRecentSheetItem?
    /// The Working On item whose Resume sheet a route asked for.
    @State private var resumeSheet: ResumeSheetItem?
    @AppStorage("window.sidebar.width") private var sidebarWidth = Double(SidebarMetrics.defaultWidth)
    @FocusState private var fieldFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    init(
        reader: BrainReader,
        understanding: UnderstandingReader,
        work: any WorkReader = PreviewWorkReader(),
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
        status: WindowStatus? = nil,
        isDemoMemory: Bool = false,
        channel: (any WindowChannelSending)? = nil,
        appRunning: @escaping @Sendable () -> Bool = { false },
        forget: ForgetCoordinator? = nil,
        hides: SidebarHides = SidebarHides(),
        isUpgrade: Bool = false,
        drawsWindowControls: Bool = false,
        preset: WindowShellPreset? = nil,
        pictures: SidebarPictures? = nil,
        notes: BottomNotes = .shared
    ) {
        self.reader = reader
        self.understanding = understanding
        self.work = work
        _selection = selection
        self.routeRequest = routeRequest
        self.fieldFocusRequest = fieldFocusRequest
        self.isSyntheticPreview = isSyntheticPreview
        self.healthLoader = healthLoader
        self.contextExporter = contextExporter
        self.calendar = calendar
        self.now = now
        self.isDemoMemory = isDemoMemory
        self.channel = channel
        self.appRunning = appRunning
        self.hides = hides
        self.isUpgrade = isUpgrade
        self.drawsWindowControls = drawsWindowControls
        self.preset = preset
        self.pictures = pictures ?? .reading(reader)
        self.notes = notes
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
        // Nothing in the synthetic preview deletes anything or writes a
        // pending forget anywhere.
        _forgetting = StateObject(wrappedValue: forget ?? ForgetCoordinator(
            mutator: isSyntheticPreview ? nil : reader as? PrivacyMutator,
            channel: channel,
            store: PendingForgetStore(directory: nil, memory: ""),
            appRunning: appRunning,
            now: now))
        _status = State(initialValue: status ?? .unknown)
        _choices = State(initialValue: preset?.choices ?? hides.choices)
        if let preset {
            if let model = preset.sidebar { _sidebar = State(initialValue: SidebarUpdates(shown: model)) }
            _sidebarHidden = State(initialValue: preset.sidebarHidden)
            _narrowSidebarOpen = State(initialValue: preset.narrowSidebarOpen)
            _showsFootnote = State(initialValue: preset.showsFootnote)
            _showsNewSidebarLine = State(initialValue: preset.showsNewSidebarLine)
            if let choice = preset.forgetSheet {
                _forgetSheet = State(initialValue: ForgetRecentSheetItem(choice: choice))
            }
        }
    }

    /// The field opens empty every time: nothing typed is kept on disk
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

    // MARK: Layout

    /// Narrower than this, the sidebar hides; the sidebar button shows it
    /// over the page, and picking a row hides it again (SPEC 2.12).
    static let narrowWidth: CGFloat = 860

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < Self.narrowWidth
            let showsSidebar = !narrow && !sidebarHidden
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    if showsSidebar {
                        sidebarView(width: CGFloat(sidebarWidth))
                            .frame(width: CGFloat(sidebarWidth))
                            .background(sidebarBackdrop)
                        SidebarResizeHandle(width: $sidebarWidth)
                    }
                    mainColumn(sidebarHidden: !showsSidebar)
                }
                if narrow && narrowSidebarOpen {
                    // The sidebar over the page, with a shadow; a click on the
                    // page hides it.
                    Color.black.opacity(0.001)
                        .onTapGesture { narrowSidebarOpen = false }
                    sidebarView(width: SidebarMetrics.defaultWidth)
                        .frame(width: SidebarMetrics.defaultWidth)
                        .frame(maxHeight: .infinity)
                        .background(sidebarBackdrop)
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(MCI.Color.windowEdge).frame(width: 1)
                        }
                        .shadow(color: .black.opacity(0.18), radius: 20, x: 12, y: 0)
                        .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                }
                if let preview {
                    WorkingOnPreviewCard(item: preview.item, pictures: pictures, calendar: calendar, now: now)
                        .offset(previewOffset(for: preview.frame, in: geometry,
                                              sidebar: narrow ? SidebarMetrics.defaultWidth : CGFloat(sidebarWidth)))
                        .allowsHitTesting(false)
                        .transition(reduceMotion ? .opacity
                                    : .opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                }
                statusMenuPicture(narrow: narrow)
            }
            .animation(MCI.Motion.standard, value: narrowSidebarOpen)
            .animation(MCI.Motion.snap, value: preview?.item.id)
            .onAppear { isNarrow = narrow }
            .onChange(of: narrow) { _, now in
                isNarrow = now
                if !now { narrowSidebarOpen = false }
            }
        }
        .coordinateSpace(name: "window")
        .background(MCI.Color.background)
        .ignoresSafeArea()
        // The title is the app's name, and is not drawn (SPEC 2.1).
        .navigationTitle(UserFacingCopy.windowTitle)
        .onDisappear {
            // Where the window is left, for the next open within the hour.
            guard !isSyntheticPreview, preset == nil else { return }
            WindowOpening.shared.remember(selection, now: now())
        }
        .background(WindowChromeConfigurator())
        .sheet(item: $resumeSheet) { item in
            ResumeSheet(itemId: item.id)
        }
        .overlay(alignment: .top) {
            // A picture can't show a sheet's window: it is drawn in place.
            if drawsWindowControls, let item = forgetSheet {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.06)
                    ForgetRecentSheet(choice: item.choice, now: item.openedAt ?? now(), calendar: calendar,
                                      saysFirstForget: true, forget: { _ in }, cancel: {})
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(MCI.Color.border, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 10)
                        .padding(.top, 60)
                }
            }
        }
        .sheet(item: drawsWindowControls ? .constant(nil) : $forgetSheet) { item in
            ForgetRecentSheet(
                choice: item.choice, now: item.openedAt ?? now(), calendar: calendar,
                saysFirstForget: hides.firstForgetDue,
                forget: { choice in
                    forgetSheet = nil
                    forgetRecent(choice, at: item.openedAt ?? now())
                },
                cancel: { forgetSheet = nil }
            )
        }
        .task(id: routeRequest?.sequence) {
            guard let routeRequest else { return }
            await apply(routeRequest.route)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, preset == nil else { return }
            MemoryRefreshSignal.post()
            await loadStatus()
            await loadSidebar()
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard !Task.isCancelled else { return }
                MemoryRefreshSignal.post()
                await loadStatus()
                ticks += 1
                // Working On is read every two minutes while the window is
                // in front (SPEC 2.3).
                if ticks % 12 == 0 { await loadSidebar() }
            }
        }
        .task {
            guard preset == nil, let channel else { return }
            for await pushed in channel.statuses() {
                status = WindowStatus(pushed).forgetting(forgetting.phase)
            }
        }
        .task {
            guard preset == nil, !isSyntheticPreview else { return }
            if await forgetting.finishLeftover() != nil { MemoryRefreshSignal.post() }
        }
        .onChange(of: forgetting.phase) { _, phase in
            status = status.forgetting(phase)
        }
        .onChange(of: fieldFocusRequest) { _, _ in focusField() }
        .onChange(of: ask.fieldFocusRequest) { _, _ in focusField() }
        .onChange(of: selection) { _, page in
            guard !isSyntheticPreview, preset == nil else { return }
            WindowOpening.shared.remember(page, now: now())
        }
        .onReceive(NotificationCenter.default.publisher(for: MemoryDeletionSignal.notification)) { _ in
            Task { await loadSidebar() }
        }
        .onReceive(NotificationCenter.default.publisher(for: WindowShellCommand.notification)) { note in
            guard let box = note.object as? WindowShellCommandBox else { return }
            perform(box.command)
        }
        .onChange(of: forgetting.undoable) { _, undoable in
            guard let undoable else { return }
            notes.show(NavigationCopy.forgotMoments(undoable.count),
                       detail: hides.firstForgetDue ? NavigationCopy.firstForget : nil,
                       action: BottomNote.Action(title: NavigationCopy.undoAction) { forgetting.undo() })
            hides.firstForgetSaid()
        }
        .onReceive(WindowDayMove.shared.$sequence.dropFirst()) { _ in
            moveDay(by: WindowDayMove.shared.days)
        }
        .onChange(of: fieldFocused) { _, focused in
            if WindowMenuState.shared.fieldFocused != focused { WindowMenuState.shared.fieldFocused = focused }
        }
        .registerActionPanelCommands(goToItems, registry: .shared)
        .onAppear { publishMenuState() }
        .onChange(of: choices) { _, _ in publishMenuState() }
        .onChange(of: sidebarHidden) { _, _ in publishMenuState() }
        // Every place forgets through the shell's coordinator: the hold,
        // Undo, and a crash's leftover (SPEC 3.11).
        .environment(\.forgetCoordinator, forgetting)
        // Whether Hippocampus is remembering, as the banner says: Today
        // never shows "Now" while it isn't (SPEC 3.1).
        .environment(\.windowStatus, status)
        // Outermost, so sheets and every place see it: in the synthetic
        // preview nothing opens the person's own data or deletes anything.
        .environment(\.isSyntheticPreview, isSyntheticPreview)
    }

    /// Off-screen pictures paint the sidebar's colour, since the system's
    /// material can't be drawn there; the live window shows the material.
    @ViewBuilder
    private var sidebarBackdrop: some View {
        if drawsWindowControls {
            MCI.Color.sidebar
        } else {
            SidebarMaterial()
        }
    }

    private func sidebarView(width: CGFloat) -> some View {
        SidebarView(
            model: sidebar.shown,
            selection: selection.sidebarRow(listing: sidebar.shown.workingOn),
            status: status,
            choices: choices,
            showsFootnote: showsFootnote,
            width: width,
            drawsWindowControls: drawsWindowControls,
            pictures: pictures,
            calendar: calendar,
            now: now,
            select: { row in go(to: WindowPage(row: row)) },
            actions: sidebarActions,
            restingOn: preset?.hoveredItem
        )
        .overlay(alignment: .topLeading) {
            if isDemoMemory {
                DemoTag()
                    .padding(.leading, drawsWindowControls ? 90 : 88)
                    .frame(height: 52)
            }
        }
    }

    private var sidebarActions: SidebarActions {
        SidebarActions(
            openStatusMenu: { anchor in openStatusMenu(from: anchor) },
            openPreferences: openPreferences,
            toggleSidebar: toggleSidebar,
            hideItem: { id in
                hides.hide(item: id)
                reloadChoices(applyAtOnce: true)
            },
            showInHistory: { id in Task { await showItemInHistory(id) } },
            copyForYourAI: { _ in },
            folderContext: { WindowCommand.folderContext.post() },
            hideKind: { kind in
                hides.hide(kind: kind)
                reloadChoices(applyAtOnce: true)
            },
            toggleKind: { kind in toggleKind(kind) },
            resetSidebar: {
                hides.reset()
                reloadChoices(applyAtOnce: true)
            },
            setWorkingOnHidden: { hidden in
                hides.setWorkingOnHidden(hidden)
                choices.workingOnHidden = hidden
            },
            setLibraryCollapsed: { collapsed in
                hides.setLibraryCollapsed(collapsed)
                choices.libraryCollapsed = collapsed
            },
            pointerInside: { inside in
                if !inside { setPreview(nil) }
                withAnimation(MCI.Motion.standard) { _ = sidebar.pointer(inside: inside) }
            },
            focusInside: { inside in
                withAnimation(MCI.Motion.standard) { _ = sidebar.focus(inside: inside) }
            },
            hoverItem: { item, frame in setPreview(item.map { ($0, frame) }) }
        )
    }

    private func mainColumn(sidebarHidden: Bool) -> some View {
        VStack(spacing: 0) {
            WindowTopBar(
                page: selection,
                canGoBack: navigation.canGoBack || ask.showsMatches || preset?.canGoBack == true,
                canGoForward: navigation.canGoForward,
                sidebarHidden: sidebarHidden,
                drawsWindowControls: drawsWindowControls,
                isDemoMemory: isDemoMemory,
                ask: ask,
                fieldFocused: $fieldFocused,
                back: goBack,
                forward: goForward,
                toggleSidebar: toggleSidebar
            )
            if let banner = status.banner(now: now(), calendar: calendar, locale: locale) {
                StatusBanner(banner: banner, perform: perform)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            if showsNewSidebarLine, selection == .today, !ask.showsMatches {
                NewSidebarLine {
                    hides.sidebarLineSaid()
                    showsNewSidebarLine = false
                }
            }
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MCI.Color.background)
                // The newest note from any place (`BottomNotes.show`):
                // nothing at all until there is one.
                .overlay(alignment: .bottom) { BottomNoteHost(notes: notes) }
        }
        .animation(MCI.Motion.standard, value: status.banner(now: now(), calendar: calendar, locale: locale))
    }

    /// The page, or the field's results in its place (SPEC 2.8).
    @ViewBuilder
    private var pageContent: some View {
        if selection.hasField, ask.showsMatches {
            FieldResults(model: ask, reader: reader, contextExporter: contextExporter)
        } else {
            page
                .id(selection)
                .transition(.opacity.animation(MCI.Motion.snap))
        }
    }

    @ViewBuilder
    private var page: some View {
        switch selection {
        case .place(.today):
            OverviewPlace(model: overview, reader: reader, open: open, search: searchInField)
        case .place(.history):
            HistoryView(history: ask.history, reader: reader, calendar: calendar, now: now)
        case .place(.webPages):
            WebPagesPlace(work: work, reader: reader, open: open)
        case .place(.documents):
            DocumentsPlace(reader: reader, open: open)
        case .place(.code):
            CodePlace(reader: reader, open: open)
        case .place(.conversations):
            ConversationsPlace(reader: reader, open: open)
        case .place(.lookedUp):
            LookedUpPlace(understanding: understanding, reader: reader, open: open)
        case .place(.workingOn):
            WorkingOnPlace(work: work, reader: reader, open: open)
        case let .item(id):
            WorkingOnItemPlace(itemId: id, work: work, reader: reader, open: open)
        case .place(.aboutYou):
            NavigationStack(path: $youPath) {
                YouPlace(model: you, open: open)
                    .navigationDestination(for: RecallYouPage.self) { page in
                        youPage(page)
                    }
            }
        case .place(.aiTools):
            AIToolsPlace(understanding: understanding, open: open)
        case .place(.privacy):
            if isSyntheticPreview || drawsWindowControls {
                // The page reads the activity log on this Mac: the preview
                // and pictures never open it.
                Color.clear
            } else {
                PrivacyDashboard(reader: reader, mutator: reader as? PrivacyMutator)
            }
        }
    }

    /// A page pushed inside About You. Never reached in the preview.
    @ViewBuilder
    private func youPage(_ page: RecallYouPage) -> some View {
        switch page {
        case .privacy:
            PrivacyDashboard(reader: reader, mutator: reader as? PrivacyMutator)
        case .names:
            UserDictionaryEditor()
        }
    }

    // MARK: The status menu

    private func openStatusMenu(from anchor: MenuAnchor.Holder) {
        guard let view = anchor.view else { return }
        let above = view.convert(view.bounds, to: nil).minY < 140
        StatusMenu.open(status, from: view, above: above) { command in
            switch command {
            case let .pause(choice):
                send(.pause, until: choice.until(now: now(), calendar: calendar))
            case let .action(action):
                perform(action)
            case let .forget(choice):
                forgetSheet = ForgetRecentSheetItem(choice: choice, openedAt: now())
            case .privacy:
                go(to: .privacy)
            case .preferences:
                openPreferences()
            }
        }
    }

    /// The menu drawn open, in a picture (a picture can't open a real menu).
    @ViewBuilder
    private func statusMenuPicture(narrow: Bool) -> some View {
        if let anchor = preset?.statusMenu {
            let menu = StatusMenuFacsimile(status: status, showsPauseChoices: preset?.statusMenuPauseOpen == true)
            switch anchor {
            case .footer:
                menu
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 12)
                    .padding(.bottom, 44)
            case .hiMark:
                menu
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 14)
                    .padding(.top, 52 + 30 + 4)
            }
        }
    }

    // MARK: What the controls do

    /// The banner's button, and the menu's actions. Every change to
    /// remembering goes over the private pipe; navigation never does.
    private func perform(_ action: WindowStatus.Action) {
        switch action {
        case .pause: send(.pause)
        case .resume, .resumeNow: send(.resume)
        case .turnOn: send(.turnOn)
        case .turnOff: send(.pause)
        case let .openSystemSettings(permission): send(.openSystemSettings, permission: permission.rawValue)
        case .tryAgain: send(.tryAgain)
        case .quit: send(.quit)
        case .finishSetup:
            guard !isSyntheticPreview, let url = URL(string: "hippocampus://onboarding/show") else { return }
            NSWorkspace.shared.open(url)
        case .openHippocampus:
            guard !isSyntheticPreview else { return }
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }

    private func send(_ op: WindowChannelProtocol.Op, until: Date? = nil, permission: String? = nil) {
        guard let channel, !isSyntheticPreview else { return }
        Task { _ = await channel.send(WindowChannelRequest(op: op, until: until, permission: permission),
                                      timeout: .seconds(15)) }
    }

    private func openPreferences() {
        guard !isSyntheticPreview else { return }
        Task { _ = await WorkspacePreferencesRouter.shared.open(.general, bundleURL: Bundle.main.bundleURL) }
    }

    private func forgetRecent(_ choice: ForgetRecentChoice, at click: Date) {
        hides.firstForgetSaid()
        let request = ForgetRequest.recent(choice, now: click, calendar: calendar)
        Task {
            switch await forgetting.forget(request) {
            case .forgotten:
                notes.show(NavigationCopy.forgotten)
            case .failed:
                notes.show(NavigationCopy.couldNotForget,
                                 action: BottomNote.Action(title: NavigationCopy.tryAgain) {
                                     forgetRecent(choice, at: click)
                                 })
            case .needsApp:
                notes.show(NavigationCopy.openHippocampusToForget,
                                 action: BottomNote.Action(title: NavigationCopy.openHippocampus) {
                                     perform(.openHippocampus)
                                 })
            case .unavailable:
                notes.show(NavigationCopy.couldNotForget)
            }
        }
    }

    private func perform(_ command: WindowShellCommand) {
        switch command {
        case .back: goBack()
        case .forward: goForward()
        case .toggleSidebar: toggleSidebar()
        case let .toggleKind(kind): toggleKind(kind)
        case .resetSidebar:
            hides.reset()
            reloadChoices(applyAtOnce: true)
        case .toggleWorkingOn:
            let hidden = !choices.workingOnHidden
            hides.setWorkingOnHidden(hidden)
            choices.workingOnHidden = hidden
        case let .forgetRecent(choice):
            forgetSheet = ForgetRecentSheetItem(choice: choice, openedAt: now())
        case .undoForget:
            if forgetting.undo() { notes.dismiss() }
        case .reloadSidebar:
            reloadChoices(applyAtOnce: true)
        }
    }

    private func toggleSidebar() {
        if isNarrow {
            narrowSidebarOpen.toggle()
        } else {
            withAnimation(MCI.Motion.standard) { sidebarHidden.toggle() }
        }
    }

    private func toggleKind(_ kind: SidebarPlace) {
        if sidebar.shown.kindsWithMoments.contains(kind) {
            hides.hide(kind: kind)
        } else {
            hides.show(kind: kind)
        }
        reloadChoices(applyAtOnce: true)
    }

    /// The person tidied the sidebar: their own change is drawn at once.
    private func reloadChoices(applyAtOnce: Bool) {
        choices = hides.choices
        Task { await loadSidebar(personAsked: applyAtOnce) }
    }

    private func publishMenuState() {
        WindowMenuState.shared.update(kinds: sidebar.shown.kindsWithMoments, workingOnHidden: choices.workingOnHidden,
                                      sidebarHidden: sidebarHidden)
    }

    /// ⌘K's Go To lists every Working On item in the sidebar by name
    /// (SPEC 2.9); its places are the root's.
    private var goToItems: [ActionPanelCommand] {
        sidebar.shown.workingOn.compactMap { id in
            sidebar.shown.items[id].map { item in
                ActionPanelCommand(id: "go.item.\(id)", title: item.name, shortcut: "", category: .goTo) {
                    go(to: .item(id))
                }
            }
        }
    }

    // MARK: Reading the sidebar and the status

    private func loadStatus() async {
        guard channel == nil, !isSyntheticPreview else { return }
        let receipt = await healthLoader()
        let current = WindowStatus(byHand: receipt, appRunning: appRunning(), now: now())
        status = current.forgetting(forgetting.phase)
    }

    /// Reads Working On and which kinds hold something. The new list is
    /// drawn only while the pointer and focus are elsewhere (SPEC 2.3);
    /// a change the person made is drawn at once.
    private func loadSidebar(personAsked: Bool = false) async {
        guard preset?.sidebar == nil else { return }
        // A read that fails keeps the last list for this launch, quietly
        // (SPEC 2.12).
        guard let snapshot = try? await work.work(days: 14) else { return }
        let apps = (try? await reader.listObservedApps(limit: 200, timeFromUs: nil)) ?? []
        let sawSearch = !(overview.overview?.searches.isEmpty ?? true)
        let kinds = LibraryKinds.kinds(apps: apps, snapshot: snapshot, sawSearch: sawSearch)
        let memory = isSyntheticPreview ? "synthetic" : ProcessInfo.processInfo.environment["MCI_DB_PATH"] ?? "default"
        let before = hides.appearedKinds(memory: memory)
        let appeared = hides.noteAppeared(kinds, memory: memory)
        // VoiceOver hears the first new row once, ever, not every one
        // (SPEC 2.15).
        if let first = SidebarPlace.libraryKinds.first(where: { appeared.contains($0) && !before.contains($0) }),
           !isSyntheticPreview, hides.takeRowAnnouncement() {
            AccessibilityNotification.Announcement(NavigationCopy.rowAdded(first.title)).post()
        }
        let model = SidebarModel.make(snapshot: snapshot, kinds: appeared, hides: hides.choices)
        let first = sidebar.shown.workingOn.isEmpty && !model.workingOn.isEmpty
        withAnimation(MCI.Motion.standard) {
            if personAsked { sidebar.apply(model) } else { sidebar.receive(model) }
        }
        if first, sidebar.shown == model, hides.takeFootnote() {
            showsFootnote = true
        }
        if isUpgrade, hides.sidebarLineDue {
            showsNewSidebarLine = true
        }
        publishMenuState()
    }

    // MARK: Moving between pages

    private var location: WindowLocation {
        WindowLocation(page: selection, query: ask.query, selectedMoment: ask.history.selectedHitId)
    }

    /// Opens `page`: the field empties and the page shows; Back returns to
    /// where the window was. A question being asked keeps running (SPEC 2.8).
    private func go(to page: WindowPage) {
        narrowSidebarOpen = false
        guard page != selection || ask.showsMatches else { return }
        navigation.leave(location)
        selection = page
        emptyField()
    }

    /// The field empties without stopping a question being asked: coming
    /// back to it shows its answer.
    private func emptyField() {
        guard ask.showsMatches else { return }
        if ask.search.isShowingFocusedEvent {
            ask.search.clear()
        } else {
            ask.query = ""
        }
    }

    /// ⌘[: results showing bring the page back; otherwise the page before.
    private func goBack() {
        if selection.hasField, ask.showsMatches {
            emptyField()
            return
        }
        guard let previous = navigation.goBack(from: location) else { return }
        restore(previous)
    }

    private func goForward() {
        guard let next = navigation.goForward(from: location) else { return }
        restore(next)
    }

    private func restore(_ location: WindowLocation) {
        selection = location.page
        ask.query = location.query
        if let moment = location.selectedMoment, location.page == .history {
            ask.history.selectedHitId = moment
        }
    }

    /// ⌘← and ⌘→: the day before or after on Today and History, never
    /// past today.
    private func moveDay(by days: Int) {
        let today = calendar.startOfDay(for: now())
        switch selection {
        case .place(.today):
            guard let date = calendar.date(byAdding: .day, value: days, to: overview.selectedDate),
                  calendar.startOfDay(for: date) <= today else { return }
            overview.selectedDate = date
        case .place(.history):
            let current = ask.history.day.map { Date(timeIntervalSince1970: Double($0.startUs) / 1_000_000) } ?? now()
            guard let date = calendar.date(byAdding: .day, value: days, to: current),
                  calendar.startOfDay(for: date) <= today else { return }
            Task { await ask.history.show(day: MemoryDay(date: date, calendar: calendar)) }
        default:
            break
        }
    }

    private func focusField() {
        Task { @MainActor in
            await Task.yield()
            fieldFocused = true
        }
    }

    /// The pointer rests on a Working On item: its preview fades in after
    /// 0.4 s, the same way as the day strip's (SPEC-DELTA 2).
    private func setPreview(_ hover: (SidebarWorkItem, CGRect)?) {
        guard let hover else {
            hovered = nil
            preview = nil
            return
        }
        hovered = (hover.0, hover.1)
        let id = hover.0.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard let current = hovered, current.item.id == id else { return }
            preview = current
        }
    }

    /// Beside the sidebar, level with the row, inside the window.
    private func previewOffset(for frame: CGRect, in geometry: GeometryProxy, sidebar: CGFloat) -> CGSize {
        let window = geometry.frame(in: .global)
        let x = sidebar + 8
        let height = WorkingOnPreviewCard.size.height
        let y = min(max(8, frame.midY - window.minY - height / 2), geometry.size.height - height - 8)
        return CGSize(width: x, height: y)
    }

    private func showItemInHistory(_ id: String) async {
        guard let item = try? await work.item(id: id, before: nil), let newest = item.moments.first,
              let hit = try? await reader.fetchEventsByIds([newest]).first else {
            go(to: .history)
            return
        }
        let us = Int64(clamping: hit.tsUs)
        await apply(RecallRoute.history(of: us...us, selecting: Int64(clamping: newest)))
    }

    // MARK: Routes

    /// A route from a link, the app, a command or a place: the page, then
    /// what it shows.
    private func apply(_ route: RecallRoute) async {
        if route.opensPreferences {
            openPreferences()
        }
        if route.opensAskPanel, !isSyntheticPreview {
            // The window has no panel of its own: the menu bar opens Ask.
            NSWorkspace.shared.open(RecallRoute.askPanelURL)
        }
        var target: WindowPage?
        if route.youPath.contains(.privacy) {
            // What's remembered was a page inside You; Privacy is its own.
            target = .privacy
        } else if let item = route.workItem {
            target = .item(item)
        } else if let place = route.place {
            target = .place(place)
        } else if route.focusesField, !selection.hasField {
            target = .history
        }
        if let target, target != selection {
            navigation.leave(location)
            selection = target
            emptyField()
            narrowSidebarOpen = false
        }
        switch selection {
        case .place(.history):
            await ask.open(route)
        case .place(.today):
            overview.open(route)
        case .place(.aboutYou):
            // Only a route that names About You moves its pages. The preview
            // opens none: they read the person's own files.
            if route.place == .aboutYou {
                youPath = isSyntheticPreview ? [] : route.youPath
            }
        default:
            if route.clearsField { ask.clear() }
        }
        if route.focusesField { focusField() }
        // Resume's sheet lists what it would open; nothing opens until the
        // person clicks in it (SPEC-DELTA 3).
        if route.showsResume, let item = route.workItem {
            resumeSheet = ResumeSheetItem(id: item)
        }
        if let choice = route.forgetRecent {
            forgetSheet = ForgetRecentSheetItem(choice: choice, openedAt: now())
        }
    }

    /// What a place asks of the window: "Show in History", a session row on
    /// About You, a page inside About You.
    private func open(_ route: RecallRoute) {
        Task { await apply(route) }
    }

    /// A search chip on Today: its words in the field, searched.
    private func searchInField(_ text: String) {
        ask.query = text
        Task { await ask.search.runSearch() }
    }
}

/// Forget Recent's sheet, with the choice it opened on and when.
struct ForgetRecentSheetItem: Identifiable {
    let id = UUID()
    let choice: ForgetRecentChoice
    var openedAt: Date?
}

/// The line about the new sidebar, said once on Today to people who used
/// the preview (SPEC 2.12). The same sentence is in What's New.
private struct NewSidebarLine: View {
    let done: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15))
                .foregroundStyle(MCI.Color.foregroundSecondary)
                .accessibilityHidden(true)
            Text(NavigationCopy.sidebarIsNew)
                .font(.system(size: 13))
                .foregroundStyle(MCI.Color.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: MCI.Spacing.m)
            Button(NavigationCopy.okAction, action: done)
        }
        .padding(.leading, 22)
        .padding(.trailing, 20)
        .padding(.vertical, 9)
        .background(MCI.Color.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MCI.Color.hairline).frame(height: 1)
        }
    }
}

/// The edge between the sidebar and the page: drag it to widen or narrow
/// the sidebar, from 180 to 260 pt, remembered (SPEC 2.1).
private struct SidebarResizeHandle: View {
    @Binding var width: Double
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(MCI.Color.windowEdge)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let base = start ?? width
                                start = base
                                width = min(Double(SidebarMetrics.maxWidth),
                                            max(Double(SidebarMetrics.minWidth), base + drag.translation.width))
                            }
                            .onEnded { _ in start = nil }
                    )
            }
            .accessibilityHidden(true)
    }
}

/// The system's sidebar material behind the sidebar, live: it goes solid
/// with Reduce Transparency, as the system does.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Commands from the menu bar that change the window's own frame.
enum WindowShellCommand: Equatable {
    static let notification = Notification.Name("ai.hippocampus.recall.window-shell.v1")

    case back
    case forward
    case toggleSidebar
    case toggleKind(SidebarPlace)
    case resetSidebar
    case toggleWorkingOn
    case forgetRecent(ForgetRecentChoice)
    case undoForget
    /// Read Working On and the kinds again now: Show in Sidebar on Show
    /// All, or anything else that changed what the sidebar lists.
    case reloadSidebar

    @MainActor
    func post() {
        NotificationCenter.default.post(name: Self.notification, object: WindowShellCommandBox(self))
    }
}

final class WindowShellCommandBox: NSObject {
    let command: WindowShellCommand
    init(_ command: WindowShellCommand) { self.command = command }
}

/// What the View menu shows: which kinds the sidebar lists, and whether
/// Working On is hidden.
@MainActor
final class WindowMenuState: ObservableObject {
    static let shared = WindowMenuState()
    @Published private(set) var kinds: Set<SidebarPlace> = []
    @Published private(set) var workingOnHidden = false
    @Published private(set) var sidebarHidden = false
    /// The cursor is in the field: ⌘← and ⌘→ move it, not the day.
    @Published var fieldFocused = false

    func update(kinds: Set<SidebarPlace>, workingOnHidden: Bool, sidebarHidden: Bool) {
        if self.kinds != kinds { self.kinds = kinds }
        if self.workingOnHidden != workingOnHidden { self.workingOnHidden = workingOnHidden }
        if self.sidebarHidden != sidebarHidden { self.sidebarHidden = sidebarHidden }
    }
}

/// The window's forgetting, for every place: History's rows, Today's
/// sessions, Web Pages and Privacy forget through it, so a forget while
/// remembering holds it still instead of failing (SPEC 3.11).
private struct ForgetCoordinatorKey: EnvironmentKey {
    static let defaultValue: ForgetCoordinator? = nil
}

extension EnvironmentValues {
    var forgetCoordinator: ForgetCoordinator? {
        get { self[ForgetCoordinatorKey.self] }
        set { self[ForgetCoordinatorKey.self] = newValue }
    }
}

/// Whether Hippocampus is remembering, as the window shows it, for every
/// place (the menu bar's own words over the pipe).
private struct WindowStatusKey: EnvironmentKey {
    static let defaultValue = WindowStatus.unknown
}

extension EnvironmentValues {
    var windowStatus: WindowStatus {
        get { self[WindowStatusKey.self] }
        set { self[WindowStatusKey.self] = newValue }
    }
}
