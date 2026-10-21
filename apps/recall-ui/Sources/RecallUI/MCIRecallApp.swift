import AppKit
import Combine
import RecallUIKit
import SwiftUI

/// Pulls the Recall window to the foreground the instant it appears.
///
/// Without this, opening Recall from the menu-bar "Open Recall…" item
/// lands the window BEHIND the current foreground app (owner dogfood
/// feedback 2026-05-26). Same pattern as the OnboardingAppDelegate
/// fix from PR #195.
final class MCIRecallAppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    /// The window ends with the app that opened it, and stops its children
    /// first (RULINGS G7, G7a).
    private var lifetime: ProcessLifetime?
    /// This process is quitting (its last window closed, or the app asked):
    /// a command finds nothing to show, so it is not answered. Main thread.
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A pipe or socket whose reader has gone is an error to handle, never
        // a signal that ends the window (as the app does).
        signal(SIGPIPE, SIG_IGN)
        lifetime = ProcessLifetime { _ in
            ChildProcesses.shared.terminateAll()
            exit(0)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        #if DEBUG
        if NativePreviewConfiguration(arguments: CommandLine.arguments) != nil { return }
        #endif

        // Record every launch in the plain-text audit log, so the trail of
        // who touched the memory, and when, is complete. Fire-and-forget:
        // AuditLog.record is thread-safe and never throws to the caller.
        AuditLog.shared.record(
            action: .appLaunched,
            details: [
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "unknown",
            ]
        )

        // Ask keeps nothing on disk: clear what older builds saved once
        // (critique-recall-engineering finding 18).
        UserDefaults.standard.removeObject(forKey: QueryPersistence.defaultKey)

        // The always-running Hippocampus shell owns the system-wide key and
        // the Ask panel. This window has no popup of its own: a request for
        // one opens hippocampus://ask (RULINGS W3).
        //
        // Delivered at once, even while this window is in the background:
        // the app waits for the answer before it brings the window forward.
        MainActor.assumeIsolated {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(receiveRecallCommand(_:)),
                name: RecallLaunchRequest.distributedCommandName,
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
    }

    /// Quitting, or the last window closing: a forget waiting out its Undo
    /// note, or under way, is finished first, within a bound, so a moment
    /// the person forgot never stays readable until the window next opens
    /// (SPEC 3.11). Meanwhile the process stays, and a window still open
    /// says "Forgetting…".
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminating = true
        #if DEBUG
        // The preview opens no memory, and touches none on its way out.
        if NativePreviewConfiguration(arguments: CommandLine.arguments) != nil { return .terminateNow }
        #endif
        let waits = MainActor.assumeIsolated {
            MCIRecallApp.forget.finishBeforeQuitting {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return waits ? .terminateLater : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        ChildProcesses.shared.terminateAll()
    }

    /// The window is all this process is for, so it ends with the window.
    /// Opening it again (the menu, Ask, opening Hippocampus) then starts a
    /// fresh one on the place asked for. A process left running without a
    /// window took those requests with nothing to show them in, so opening
    /// Hippocampus looked like it did nothing (Oct 18).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// A command from the app (opening Hippocampus, the menu, Ask). It is
    /// answered only when the window shows itself: a process that is
    /// quitting, or whose last window just closed, stays silent, and the app
    /// opens a fresh window once this one has ended. A minimized window comes
    /// back out of the Dock first: the app can bring this process forward,
    /// but only the process can deminiaturize its window.
    @objc
    private func receiveRecallCommand(_ notification: Notification) {
        guard let request = RecallLaunchRequest(userInfo: notification.userInfo) else { return }
        let answer = RecallLaunchRequest.acknowledgement(for: notification.userInfo)
        Task { @MainActor in
            let windows = NSApp.windows.filter(\.canBecomeMain)
            let states = windows.map { RecallWindowState(isVisible: $0.isVisible, isMiniaturized: $0.isMiniaturized) }
            guard RecallCommandAnswer.decide(terminating: self.terminating, windows: states) == .show else { return }
            // A request for the old popup alone leaves the window where it is.
            if request.bringsWindowForward {
                for window in windows where window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                NSApp.unhide(nil)
                windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            NotificationCenter.default.post(
                name: RecallLaunchRequest.localCommandName,
                object: request
            )
            if let answer {
                DistributedNotificationCenter.default().postNotificationName(
                    RecallLaunchRequest.acknowledgementName,
                    object: String(ProcessInfo.processInfo.processIdentifier),
                    userInfo: answer,
                    deliverImmediately: true
                )
            }
        }
    }
}

/// Started by `RecallEntryPoint`.
struct MCIRecallApp: App {
    @NSApplicationDelegateAdaptor(MCIRecallAppDelegate.self) var appDelegate

    /// The first thing the window does: its private pipe's descriptors are
    /// marked close-on-exec before any child process can start (SPEC 2.6.4).
    init() {
        _ = Self.channel
    }

    @MainActor
    // fileprivate (not private): the live workspace below reads it.
    fileprivate static let reader: BrainReader = Self.makeReader()

    /// The day, the person and answers, read through the bundled agent. Its
    /// children stop with the window (`ChildProcesses`, RULINGS G7).
    @MainActor
    fileprivate static let understanding: UnderstandingReader = AgentUnderstandingReader()

    /// What the person works on, for the sidebar's Working On, its pages,
    /// Web Pages and Today: the bundled agent's `work` read, kept two
    /// minutes and cleared by any delete (SPEC 3.12.2).
    @MainActor
    fileprivate static let work: any WorkReader = AgentWorkReader.shared

    /// The private pipe from the app that opened this window (SPEC 2.6.4),
    /// opened first thing so its descriptors are close-on-exec before any
    /// child starts. Nil for a window opened by hand.
    @MainActor
    fileprivate static let channel: WindowChannel? = WindowChannel.open()

    /// Forgetting, with the pending file beside the verdict inbox.
    @MainActor
    fileprivate static let forget = ForgetCoordinator(
        mutator: reader as? PrivacyMutator,
        channel: channel,
        store: PendingForgetStore(
            directory: ProcessInfo.processInfo.environment["MCI_DEVELOPMENT_FILE_KEY"] == "1"
                ? nil : PendingForgetStore.defaultDirectory(),
            memory: ProcessInfo.processInfo.environment["MCI_DB_PATH"] ?? "default"),
        appRunning: { MCIRecallApp.appIsRunning() })

    /// Whether the menu-bar app runs: another process of this bundle.
    nonisolated static func appIsRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    var body: some Scene {
        WindowGroup("Hippocampus") {
            #if DEBUG
            if let preview = NativePreviewConfiguration(arguments: CommandLine.arguments) {
                NativeRecallPreview(configuration: preview)
            } else {
                liveWorkspace
            }
            #else
            liveWorkspace
            #endif
        }
        .defaultPosition(.center)
        .defaultSize(width: 1100, height: 720)
        // The window draws its own top: the field row, and the window's
        // controls over the sidebar (SPEC 2.1).
        .windowStyle(.hiddenTitleBar)
        .commands { WindowCommands() }
    }

    @ViewBuilder
    private var liveWorkspace: some View {
            let launchRequest = RecallLaunchRequest(
                environment: ProcessInfo.processInfo.environment
            )
            RootView(
                reader: MCIRecallApp.reader,
                understanding: MCIRecallApp.understanding,
                work: MCIRecallApp.work,
                launchRequest: launchRequest,
                isDemoMemory: DemoMemoryMode.isOn(environment: ProcessInfo.processInfo.environment),
                channel: MCIRecallApp.channel,
                forget: MCIRecallApp.forget,
                opening: WindowOpening.shared.page(),
                isUpgrade: UserDefaults.standard.string(forKey: WhatsNewCoordinator.lastShownKey) != nil,
                services: .app()
            )
            // The window follows the Mac's appearance (SPEC 2.14).
            .frame(minWidth: 760, minHeight: 480)
            .background(MCI.Color.background)
    }

    @MainActor
    private static func makeReader() -> BrainReader {
        let environment = ProcessInfo.processInfo.environment
        let reference = KeychainDatabaseKeyReference.from(environment: environment)
        do {
            // During a key change both Keychain items exist and only one
            // opens the memory: each is tried, newest first.
            let keys = try DevelopmentDatabaseKeyMaterial.hex(from: environment).map { [$0] }
                ?? KeychainDatabaseKeyResolver().resolveHexCandidates(reference: reference)
            let path = environment["MCI_DB_PATH"] ?? defaultBrainPath()
            var lastError: Error = KeychainDatabaseKeyError.missing
            for keyHex in keys {
                if let modelPath = embeddingModelPath(environment: environment) {
                    do {
                        return try FFIBrainReader(
                            path: path,
                            keyHex: keyHex,
                            modelPath: modelPath
                        )
                    } catch {
                        NSLog(
                            "MCI: semantic Recall unavailable; retrying lexical mode: %@",
                            error.localizedDescription
                        )
                    }
                }
                do {
                    return try FFIBrainReader(path: path, keyHex: keyHex)
                } catch {
                    lastError = error
                }
            }
            throw lastError
        } catch {
            let message = "Recall cannot open the encrypted brain: \(error.localizedDescription)"
            NSLog("MCI: %@", message)
            return UnavailableBrainReader(message: message)
        }
    }

    @MainActor
    private static func defaultBrainPath() -> String {
        let supportDir = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory,
            .userDomainMask,
            true
        ).first ?? NSTemporaryDirectory()
        return (supportDir as NSString)
            .appendingPathComponent("MCI/mci.sqlite")
    }

    private static func embeddingModelPath(environment: [String: String]) -> String? {
        if let configured = environment["MCI_ARCTIC_MODEL_PATH"], !configured.isEmpty {
            return configured
        }
        guard let resources = Bundle.main.resourceURL else { return nil }
        let bundled = resources
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("ArcticEmbedS_FP16.mlmodelc", isDirectory: true)
        return FileManager.default.fileExists(atPath: bundled.path) ? bundled.path : nil
    }
}

/// What the window's menus ask of it: a place, a route, or a refresh.
enum WindowCommand {
    static let notification = Notification.Name("ai.hippocampus.recall.window-command.v1")

    case go(RecallRoute)
    case refresh
    /// "Context for This Folder…" (⌘J).
    case folderContext
    /// ⌘T: today's date on Today and History; elsewhere, Today.
    case goToToday
    /// ⌘← and ⌘→ on Today and History.
    case moveDay(Int)

    @MainActor
    func post() {
        NotificationCenter.default.post(name: Self.notification, object: WindowCommandBox(self))
    }
}

final class WindowCommandBox: NSObject {
    let command: WindowCommand
    init(_ command: WindowCommand) { self.command = command }
}

/// The menu bar's items for the window (SPEC 2.10, 2.11 with SPEC-DELTA 1):
/// no New Window, Preferences…, a Go menu whose keys really work (⌘1 Today
/// to ⌘9 AI Tools; Privacy from its row and the status menu), and the View
/// menu's sidebar tidying.
struct WindowCommands: Commands {
    @ObservedObject private var menu = WindowMenuState.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .appSettings) {
            Button(UserFacingCopy.commandPreferences) {
                Task { _ = await WorkspacePreferencesRouter.shared.open(.general, bundleURL: Bundle.main.bundleURL) }
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(before: .sidebar) {
            Button(menu.sidebarHidden ? NavigationCopy.showSidebar : NavigationCopy.hideSidebar) {
                WindowShellCommand.toggleSidebar.post()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Menu(NavigationCopy.sidebarMenu) {
                Toggle(NavigationCopy.workingOn, isOn: Binding(get: { !menu.workingOnHidden },
                                                               set: { _ in WindowShellCommand.toggleWorkingOn.post() }))
                ForEach(SidebarPlace.libraryKinds) { kind in
                    Toggle(kind.title, isOn: Binding(get: { menu.kinds.contains(kind) },
                                                     set: { _ in WindowShellCommand.toggleKind(kind).post() }))
                }
                Divider()
                Button(NavigationCopy.resetSidebar) { WindowShellCommand.resetSidebar.post() }
            }
            Button(menu.workingOnHidden ? NavigationCopy.showWorkingOn : NavigationCopy.hideWorkingOn) {
                WindowShellCommand.toggleWorkingOn.post()
            }
            Divider()
        }
        CommandMenu(NavigationCopy.goMenu) {
            ForEach(SidebarPlace.allCases) { place in
                if let key = place.key {
                    Button(place.title) { WindowCommand.go(RecallRoute(place: RecallPlace(place))).post() }
                        .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
                } else {
                    Button(place.title) { WindowCommand.go(RecallRoute(place: RecallPlace(place))).post() }
                }
            }
            Divider()
            Button(NavigationCopy.newQuestion) { WindowCommand.go(.newQuestion).post() }
                .keyboardShortcut("n", modifiers: .command)
            Button(NavigationCopy.find) { WindowCommand.go(.findInAsk).post() }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            Button(NavigationCopy.back) { WindowShellCommand.back.post() }
                .keyboardShortcut("[", modifiers: .command)
            Button(NavigationCopy.forward) { WindowShellCommand.forward.post() }
                .keyboardShortcut("]", modifiers: .command)
            Divider()
            Button(NavigationCopy.goToToday) { WindowCommand.goToToday.post() }
                .keyboardShortcut("t", modifiers: .command)
            // The field wins while typing: ⌘← and ⌘→ move its cursor then.
            Button(NavigationCopy.previousDay) { WindowCommand.moveDay(-1).post() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(menu.fieldFocused)
            Button(NavigationCopy.nextDay) { WindowCommand.moveDay(1).post() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(menu.fieldFocused)
            Divider()
            Button(NavigationCopy.contextForThisFolder) { WindowCommand.folderContext.post() }
                .keyboardShortcut("j", modifiers: .command)
            Button(NavigationCopy.forgetRecentCommand) { WindowShellCommand.forgetRecent(.tenMinutes).post() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
            Divider()
            Button(UserFacingCopy.commandRefresh) { WindowCommand.refresh.post() }
                .keyboardShortcut("r", modifiers: .command)
        }
    }
}

struct RootView: View {
    let reader: BrainReader
    let understanding: UnderstandingReader
    var work: any WorkReader = PreviewWorkReader()
    /// The app opened this window on Demo Memory (SPEC-DELTA 6).
    var isDemoMemory = false
    var channel: (any WindowChannelSending)?
    var forget: ForgetCoordinator?
    var isUpgrade = false
    /// What the pages reach beyond the memory: this Mac's in the app.
    var services = WindowServices()
    @State private var selection: MemoryWorkspaceSelection
    @State private var routeRequest: RecallRouteRequest?
    @State private var nextRouteSequence: UInt64 = 2
    @State private var fieldFocusRequest = 0
    @State private var showsFolderContext = false
    private let actionPanelRegistry = ActionPanelRegistry.shared
    @State private var isHelpVisible = ActionPanelRegistry.shared.isHelpVisible
    // Cycle 8.54 — "What's new" release-notes modal. Coordinator owns
    // the last-shown-version bookkeeping (UserDefaults) + the parsed
    // release loaded from Contents/Resources/CHANGELOG.md.
    @StateObject private var whatsNewCoord = WhatsNewCoordinator()

    /// The window opens where the app asked: the same route a running window
    /// takes (critique-recall-engineering finding 5). With nowhere asked
    /// for, on the page it was left on less than an hour ago, else Today
    /// (SPEC 2.16).
    init(
        reader: BrainReader,
        understanding: UnderstandingReader,
        work: any WorkReader = PreviewWorkReader(),
        launchRequest: RecallLaunchRequest = RecallLaunchRequest(tab: nil, focusEventId: nil, openPopup: false),
        isDemoMemory: Bool = false,
        channel: (any WindowChannelSending)? = nil,
        forget: ForgetCoordinator? = nil,
        opening: WindowPage = .today,
        isUpgrade: Bool = false,
        services: WindowServices = WindowServices()
    ) {
        self.reader = reader
        self.understanding = understanding
        self.work = work
        self.isDemoMemory = isDemoMemory
        self.channel = channel
        self.forget = forget
        self.isUpgrade = isUpgrade
        self.services = services
        let route = RecallRoute(launchRequest)
        let first: WindowPage = route.workItem.map(WindowPage.item) ?? route.place.map(WindowPage.place) ?? opening
        self._selection = State(initialValue: first)
        self._routeRequest = State(initialValue: RecallRouteRequest(route: route, sequence: 1))
    }

    /// Global (non-contextual) commands, shown in the ⌘K bar under its
    /// groups: Go To, Moments, Actions and Help (SPEC 2.9).
    private var globalCommands: [ActionPanelCommand] {
        var commands: [ActionPanelCommand] = SidebarPlace.allCases.map { place in
            .init(
                id: "go.\(place.rawValue)",
                title: place.title,
                shortcut: place.key.map { "\u{2318}\($0)" } ?? "",
                category: .goTo
            ) {
                go(RecallRoute(place: RecallPlace(place)))
            }
        }
        commands += [
            .init(
                id: "app.newSearch",
                title: UserFacingCopy.commandNewQuestion,
                shortcut: "\u{2318}N",
                category: .moments,
                description: UserFacingCopy.commandNewQuestionDetail
            ) {
                go(.newQuestion)
            },
            // Pause, Resume and the rest: the window registers the one
            // action its status offers now (`statusCommands`).
            .init(
                id: "app.forgetRecent",
                title: NavigationCopy.forgetLastTenMinutes,
                shortcut: "\u{21E7}\u{2318}\u{232B}",
                category: .actions
            ) {
                WindowShellCommand.forgetRecent(.tenMinutes).post()
            },
            .init(
                id: "app.folderContext",
                title: UserFacingCopy.commandFolderContext,
                shortcut: "\u{2318}J",
                category: .actions
            ) {
                showsFolderContext = true
            },
            .init(
                id: "app.openSettings",
                title: UserFacingCopy.commandPreferences,
                shortcut: "\u{2318},",
                category: .actions
            ) {
                Task { _ = await WorkspacePreferencesRouter.shared.open(.general, bundleURL: Bundle.main.bundleURL) }
            },
            .init(
                id: "app.openCustomNames",
                title: UserFacingCopy.commandNames,
                shortcut: "",
                category: .actions,
                description: UserFacingCopy.commandNamesDetail
            ) {
                go(.names)
            },
            .init(
                id: "app.refreshBrain",
                title: UserFacingCopy.commandRefresh,
                shortcut: "\u{2318}R",
                category: .actions,
                description: UserFacingCopy.commandRefreshDetail
            ) {
                refresh()
            },
            .init(
                id: "app.showHelp",
                title: UserFacingCopy.commandShortcuts,
                shortcut: "\u{2318}/",
                category: .help
            ) {
                actionPanelRegistry.showHelp()
            },
            // Cycle 8.54 — "What's new" release-notes viewer. Fires the
            // WhatsNewCoordinator's on-demand path (bypasses last-shown
            // check) so the user can revisit the changelog any time.
            .init(
                id: "app.whatsNew",
                title: UserFacingCopy.commandWhatsNew,
                shortcut: "\u{21E7}\u{2318}N",
                category: .help,
                description: UserFacingCopy.commandWhatsNewDetail
            ) {
                whatsNewCoord.showOnDemand()
            },
            .init(
                id: "app.exportDebugBundle",
                title: UserFacingCopy.commandSupportReport,
                shortcut: "",
                category: .help,
                description: UserFacingCopy.commandSupportReportDetail
            ) {
                if let url = URL(string: "hippocampus://debug?export=1") {
                    NSWorkspace.shared.open(url)
                }
            },
            .init(
                id: "app.quit",
                title: UserFacingCopy.commandCloseWindow,
                shortcut: "\u{2318}Q",
                category: .help
            ) {
                NSApp.terminate(nil)
            },
        ]
        return commands
    }

    var body: some View {
        MemoryWorkspaceView(
            reader: reader,
            understanding: understanding,
            work: work,
            selection: $selection,
            routeRequest: routeRequest,
            fieldFocusRequest: fieldFocusRequest,
            isDemoMemory: isDemoMemory,
            channel: channel,
            appRunning: { MCIRecallApp.appIsRunning() },
            forget: forget,
            hides: .shared,
            isUpgrade: isUpgrade,
            services: services
        )
        .background(MCI.Color.background)
        .onOpenURL { url in
            guard let request = RecallLaunchRequest(url: url) else { return }
            go(RecallRoute(request))
        }
        .onReceive(
            NotificationCenter.default.publisher(for: RecallLaunchRequest.localCommandName)
        ) { notification in
            guard let request = notification.object as? RecallLaunchRequest else { return }
            go(RecallRoute(request))
        }
        .onReceive(NotificationCenter.default.publisher(for: WindowCommand.notification)) { notification in
            guard let box = notification.object as? WindowCommandBox else { return }
            switch box.command {
            case let .go(route): go(route)
            case .refresh: refresh()
            case .folderContext: showsFolderContext = true
            case .goToToday: goToToday()
            case let .moveDay(days): moveDay(by: days)
            }
        }
        .focusable(true, interactions: .automatic)
        .onKeyPress(
            keys: Set(
                MCI.Workspace.allDestinations.compactMap { destination in
                    destination.keyboardShortcut.first.map { KeyEquivalent($0) }
                }
            ),
            phases: .down
        ) { press in
            guard
                press.modifiers == .command,
                let destination = MemoryWorkspaceSelection(keyboardShortcut: press.key.character),
                case let .place(place) = destination
            else {
                return .ignored
            }
            go(RecallRoute(place: place))
            return .handled
        }
        .onKeyPress(.init("/"), phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            actionPanelRegistry.showHelp()
            return .handled
        }
        .onKeyPress(.init("n"), phases: .down) { press in
            // Cycle 8.54 — ⌘⇧N opens the "What's new" release notes.
            // Guarded on the exact chord (Cmd + Shift, nothing else)
            // so a bare ⌘N (New Question) still routes cleanly.
            guard press.modifiers == [.command, .shift] else { return .ignored }
            whatsNewCoord.showOnDemand()
            return .handled
        }
        .onKeyPress(.init("z"), phases: .down) { press in
            // ⌘Z undoes the last forget while its note shows; the field's
            // own text undo comes first while it is typed in.
            guard press.modifiers == .command, forget?.undoable != nil else { return .ignored }
            WindowShellCommand.undoForget.post()
            return .handled
        }
        .registerActionPanelCommands(globalCommands, registry: actionPanelRegistry)
        .actionPanelHost(registry: actionPanelRegistry)
        .onReceive(actionPanelRegistry.$isHelpVisible.removeDuplicates().receive(on: RunLoop.main)) {
            isHelpVisible = $0
        }
        .sheet(isPresented: Binding(
            get: { isHelpVisible },
            set: { isHelpVisible = $0; actionPanelRegistry.isHelpVisible = $0 }
        )) {
            KeyboardShortcutsSheet(registry: actionPanelRegistry)
        }
        .sheet(isPresented: $whatsNewCoord.isVisible) {
            WhatsNewModal(coord: whatsNewCoord)
        }
        .sheet(isPresented: $showsFolderContext) {
            ProjectHandoffView()
        }
        .task {
            // Fire once per launch: if the current version is new
            // (last-shown-version != current), show the modal. The
            // coordinator no-ops on repeat launches at the same
            // version, so this is safe to call on every boot.
            whatsNewCoord.maybeShowOnBoot()
        }
    }

    /// Every route, from a link, the app, a menu or a button, goes the same
    /// way: the workspace applies it (the page, then what it shows).
    private func go(_ route: RecallRoute) {
        if route.focusesField { fieldFocusRequest &+= 1 }
        routeRequest = RecallRouteRequest(route: route, sequence: nextRouteSequence)
        nextRouteSequence &+= 1
    }

    /// ⌘T: today's date on Today and History; elsewhere, Today (SPEC 2.10).
    private func goToToday() {
        let today = Date()
        switch selection {
        case .place(.history):
            go(RecallRoute(place: .history, day: today))
        default:
            go(RecallRoute(place: .today, day: today))
        }
    }

    /// ⌘← and ⌘→ on Today and History: the day before or after, never past
    /// today.
    private func moveDay(by days: Int) {
        WindowDayMove.shared.move(days)
    }

    /// "Refresh": forget what was read about the day and the person, then
    /// read everything shown again.
    private func refresh() {
        Task { @MainActor in
            actionPanelRegistry.beginRefresh()
            await understanding.invalidate()
            MemoryRefreshSignal.post()
            actionPanelRegistry.endRefresh()
            ToastNotifier.shared.notify(UserFacingCopy.refreshingToast)
        }
    }
}

/// ⌘← and ⌘→ from the Go menu, for the page that shows a day.
@MainActor
final class WindowDayMove: ObservableObject {
    static let shared = WindowDayMove()
    @Published private(set) var days = 0
    @Published private(set) var sequence = 0

    func move(_ days: Int) {
        self.days = days
        sequence += 1
    }
}
