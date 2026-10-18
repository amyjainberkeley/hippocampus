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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        MainActor.assumeIsolated {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(receiveRecallCommand(_:)),
                name: RecallLaunchRequest.distributedCommandName,
                object: nil
            )
        }
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

    @objc
    private func receiveRecallCommand(_ notification: Notification) {
        guard let request = RecallLaunchRequest(userInfo: notification.userInfo) else { return }
        Task { @MainActor in
            // A request for the old popup alone leaves the window where it is.
            if request.navigationTab != nil || request.focusEventId != nil {
                NSApp.activate(ignoringOtherApps: true)
            }
            NotificationCenter.default.post(
                name: RecallLaunchRequest.localCommandName,
                object: request
            )
        }
    }
}

/// Started by `RecallEntryPoint`.
struct MCIRecallApp: App {
    @NSApplicationDelegateAdaptor(MCIRecallAppDelegate.self) var appDelegate

    @MainActor
    // fileprivate (not private): the live workspace below reads it.
    fileprivate static let reader: BrainReader = Self.makeReader()

    /// The day, the person and answers, read through the bundled agent. Its
    /// children stop with the window (`ChildProcesses`, RULINGS G7).
    @MainActor
    fileprivate static let understanding: UnderstandingReader = AgentUnderstandingReader()

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
                launchRequest: launchRequest
            )
            .preferredColorScheme(.light)
            .frame(minWidth: 760, minHeight: 480)
            .background(Color.brandBgPrimary)
    }

    @MainActor
    private static func makeReader() -> BrainReader {
        let environment = ProcessInfo.processInfo.environment
        let reference = KeychainDatabaseKeyReference.from(environment: environment)
        do {
            let keyHex = try DevelopmentDatabaseKeyMaterial.hex(from: environment)
                ?? KeychainDatabaseKeyResolver().resolveHex(reference: reference)
            let path = environment["MCI_DB_PATH"] ?? defaultBrainPath()
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
            return try FFIBrainReader(path: path, keyHex: keyHex)
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
    /// "What your AI gets in this folder" (⌘J).
    case folderContext

    @MainActor
    func post() {
        NotificationCenter.default.post(name: Self.notification, object: WindowCommandBox(self))
    }
}

final class WindowCommandBox: NSObject {
    let command: WindowCommand
    init(_ command: WindowCommand) { self.command = command }
}

/// The menu bar's items for the window: no New Window, Preferences… and a Go
/// menu whose keys really work (critique-recall-engineering finding 6).
struct WindowCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .appSettings) {
            Button(UserFacingCopy.commandPreferences) {
                Task { _ = await WorkspacePreferencesRouter.shared.open(.general, bundleURL: Bundle.main.bundleURL) }
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu(UserFacingCopy.goMenu) {
            ForEach(MCI.Workspace.primaryDestinations) { destination in
                Button(destination.title) {
                    if let place = RecallPlace(rawValue: destination.id) {
                        WindowCommand.go(RecallRoute(place: place)).post()
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character(destination.keyboardShortcut)), modifiers: .command)
            }
            Divider()
            Button(UserFacingCopy.commandNewQuestion) { WindowCommand.go(.newQuestion).post() }
                .keyboardShortcut("n", modifiers: .command)
            Button(UserFacingCopy.commandHistory) { WindowCommand.go(.showHistory).post() }
                .keyboardShortcut("t", modifiers: .command)
            Button(UserFacingCopy.commandFind) { WindowCommand.go(.findInAsk).post() }
                .keyboardShortcut("f", modifiers: .command)
            Button(UserFacingCopy.commandFolderContext) { WindowCommand.folderContext.post() }
                .keyboardShortcut("j", modifiers: .command)
            Divider()
            Button(UserFacingCopy.commandRefresh) { WindowCommand.refresh.post() }
                .keyboardShortcut("r", modifiers: .command)
        }
    }
}

struct RootView: View {
    let reader: BrainReader
    let understanding: UnderstandingReader
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
    /// takes (critique-recall-engineering finding 5).
    init(
        reader: BrainReader,
        understanding: UnderstandingReader,
        launchRequest: RecallLaunchRequest = RecallLaunchRequest(tab: nil, focusEventId: nil, openPopup: false)
    ) {
        self.reader = reader
        self.understanding = understanding
        let route = RecallRoute(launchRequest)
        self._selection = State(initialValue: MemoryWorkspaceSelection(place: route.place(keeping: .overview)))
        self._routeRequest = State(initialValue: RecallRouteRequest(route: route, sequence: 1))
    }

    /// Global (non-contextual) commands, shown in the command palette and the
    /// keyboard shortcuts sheet. The keys themselves are the menu bar's.
    private var globalCommands: [ActionPanelCommand] {
        [
            .init(
                id: "app.newSearch",
                title: UserFacingCopy.commandNewQuestion,
                shortcut: "⌘N",
                category: .search,
                description: UserFacingCopy.commandNewQuestionDetail
            ) {
                go(.newQuestion)
            },
            .init(
                id: "app.showTimeline",
                title: UserFacingCopy.commandHistory,
                shortcut: "⌘T",
                category: .app,
                description: UserFacingCopy.commandHistoryDetail
            ) {
                go(.showHistory)
            },
            .init(
                id: "app.openSettings",
                title: UserFacingCopy.commandPreferences,
                shortcut: "⌘,",
                category: .app
            ) {
                Task { _ = await WorkspacePreferencesRouter.shared.open(.general, bundleURL: Bundle.main.bundleURL) }
            },
            .init(
                id: "app.openCustomNames",
                title: UserFacingCopy.commandNames,
                shortcut: "",
                category: .app,
                description: UserFacingCopy.commandNamesDetail
            ) {
                go(.names)
            },
            .init(
                id: "app.folderContext",
                title: UserFacingCopy.commandFolderContext,
                shortcut: "⌘J",
                category: .app
            ) {
                showsFolderContext = true
            },
            .init(
                id: "app.refreshBrain",
                title: UserFacingCopy.commandRefresh,
                shortcut: "⌘R",
                category: .app,
                description: UserFacingCopy.commandRefreshDetail
            ) {
                refresh()
            },
            .init(
                id: "app.exportDebugBundle",
                title: UserFacingCopy.commandSupportReport,
                shortcut: "",
                category: .debug,
                description: UserFacingCopy.commandSupportReportDetail
            ) {
                if let url = URL(string: "hippocampus://debug?export=1") {
                    NSWorkspace.shared.open(url)
                }
            },
            .init(
                id: "app.showHelp",
                title: UserFacingCopy.commandShortcuts,
                shortcut: "⌘/",
                category: .app
            ) {
                actionPanelRegistry.showHelp()
            },
            // Cycle 8.54 — "What's new" release-notes viewer. Fires the
            // WhatsNewCoordinator's on-demand path (bypasses last-shown
            // check) so the user can revisit the changelog any time.
            .init(
                id: "app.whatsNew",
                title: UserFacingCopy.commandWhatsNew,
                shortcut: "⌘⇧N",
                category: .app,
                description: UserFacingCopy.commandWhatsNewDetail
            ) {
                whatsNewCoord.showOnDemand()
            },
            .init(
                id: "app.quit",
                title: UserFacingCopy.commandCloseWindow,
                shortcut: "⌘Q",
                category: .app
            ) {
                NSApp.terminate(nil)
            },
        ]
    }

    var body: some View {
        MemoryWorkspaceView(
            reader: reader,
            understanding: understanding,
            selection: $selection,
            routeRequest: routeRequest,
            fieldFocusRequest: fieldFocusRequest
        )
        .background(Color.brandBgPrimary)
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
                let destination = MemoryWorkspaceSelection(
                    keyboardShortcut: press.key.character
                )
            else {
                return .ignored
            }
            go(RecallRoute(place: destination.place))
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
    /// way: the workspace applies it (selection, then what Ask shows).
    private func go(_ route: RecallRoute) {
        if route.focusesField { fieldFocusRequest &+= 1 }
        routeRequest = RecallRouteRequest(route: route, sequence: nextRouteSequence)
        nextRouteSequence &+= 1
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
