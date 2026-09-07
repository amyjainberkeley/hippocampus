import AppKit
import Combine
import RecallUIKit
import SwiftUI

/// Pulls the Recall window to the foreground the instant it appears.
///
/// Without this, opening Recall from the menu-bar "Open Recall…" item
/// lands the window BEHIND the current foreground app (CEO dogfood
/// feedback 2026-05-26). Same pattern as the OnboardingAppDelegate
/// fix from PR #195.
final class MCIRecallAppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Cycle 8.51 — enterprise audit trail. Record every launch to
        // the plaintext audit log so the "who touched user data when"
        // trail is complete for a security-review buyer. Fire-and-forget:
        // AuditLog.record is thread-safe and never throws to the caller.
        AuditLog.shared.record(
            action: .appLaunched,
            details: [
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "unknown",
            ]
        )

        // The always-running Hippocampus shell owns the system-wide hotkey.
        // This child process owns only the popup and handles the initial
        // command passed by the shell.
        MainActor.assumeIsolated {
            GlobalRecallPopupController.shared.configure(reader: MCIRecallApp.reader)
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(receiveRecallCommand(_:)),
                name: RecallLaunchRequest.distributedCommandName,
                object: nil
            )
            let launchRequest = RecallLaunchRequest(
                environment: ProcessInfo.processInfo.environment
            )
            if launchRequest.openPopup {
                DispatchQueue.main.async {
                    GlobalRecallPopupController.shared.show()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc
    private func receiveRecallCommand(_ notification: Notification) {
        guard let request = RecallLaunchRequest(userInfo: notification.userInfo) else { return }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            let navigationRequest = RecallLaunchRequest(
                tab: request.tab,
                focusEventId: request.focusEventId,
                openPopup: false
            )
            NotificationCenter.default.post(
                name: RecallLaunchRequest.localCommandName,
                object: navigationRequest
            )
            if request.openPopup {
                GlobalRecallPopupController.shared.show()
            }
        }
    }
}

@main
struct MCIRecallApp: App {
    @NSApplicationDelegateAdaptor(MCIRecallAppDelegate.self) var appDelegate

    @MainActor
    // fileprivate (not private): MCIRecallAppDelegate (a separate type in this
    // same file) reads MCIRecallApp.reader to wire the global-recall popup.
    fileprivate static let reader: BrainReader = Self.makeReader()

    var body: some Scene {
        WindowGroup("Hippocampus") {
            let launchRequest = RecallLaunchRequest(
                environment: ProcessInfo.processInfo.environment
            )
            RootView(
                reader: MCIRecallApp.reader,
                initialTab: launchRequest.tab ?? .search,
                initialFocusEventId: launchRequest.focusEventId
            )
            .preferredColorScheme(.light)
            .frame(minWidth: 720, minHeight: 440)
            .background(Color.brandBgPrimary)
            .task {
                // Per `docs/design/brief-viewer-spec.md` §"When the user
                // discovers their first brief": on Recall app launch, ask
                // for notification permission politely (once) and fire
                // the first-brief notification iff a brief exists and the
                // fire-once flag is not yet set.
                let reader = MCIRecallApp.reader
                let exists = (try? await reader.latestBrief()) != nil
                let latestDate = try? await reader.latestBrief()?.dateLocal
                let controller = BriefNotificationController()
                _ = await controller.checkAndMaybeFireFirstBriefNotification(
                    briefExists: exists,
                    latestBriefDate: latestDate
                )
            }
        }
        .defaultPosition(.center)
        .defaultSize(width: 920, height: 620)
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

struct RootView: View {
    let reader: BrainReader
    @State private var selection: MemoryWorkspaceSelection
    @State private var searchFocusTrigger = false
    @State private var focusRequest: RecallFocusRequest?
    @State private var nextFocusSequence: UInt64
    private let actionPanelRegistry = ActionPanelRegistry.shared
    @State private var isHelpVisible = ActionPanelRegistry.shared.isHelpVisible
    // Cycle 8.54 — "What's new" release-notes modal. Coordinator owns
    // the last-shown-version bookkeeping (UserDefaults) + the parsed
    // release loaded from Contents/Resources/CHANGELOG.md.
    @StateObject private var whatsNewCoord = WhatsNewCoordinator()

    init(
        reader: BrainReader,
        initialTab: RecallTab = .search,
        initialFocusEventId: UInt64? = nil
    ) {
        self.reader = reader
        self._selection = State(initialValue: MemoryWorkspaceSelection(initialTab: initialTab))
        self._focusRequest = State(
            initialValue: initialFocusEventId.map {
                RecallFocusRequest(eventId: $0, sequence: 1)
            }
        )
        self._nextFocusSequence = State(initialValue: initialFocusEventId == nil ? 1 : 2)
    }

    /// Global (non-contextual) commands. Registered once for the
    /// lifetime of the recall UI. Contextual commands (per-hit,
    /// per-view) are registered by their owning views on
    /// `.onAppear`.
    private var globalCommands: [ActionPanelCommand] {
        [
            .init(
                id: "app.newSearch",
                title: "New Search",
                shortcut: "⌘N",
                category: .search,
                description: "Focus the search field and clear it."
            ) {
                selection = .search
                searchFocusTrigger.toggle()
            },
            .init(
                id: "app.showTimeline",
                title: "Show Timeline",
                shortcut: "⌘T",
                category: .app,
                description: "Switch to the timeline of recent events."
            ) {
                selection = .timeline
            },
            .init(
                id: "app.openSettings",
                title: "Open Settings",
                shortcut: "⌘,",
                category: .app,
                description: "Open the settings and dictionary tab."
            ) {
                selection = .settings
            },
            .init(
                id: "app.openCustomNames",
                title: "Open Custom Names Dictionary",
                shortcut: "⌘\(MemoryWorkspaceSelection.settings.keyboardShortcutLabel)",
                category: .app,
                description: "Edit user-defined entity aliases."
            ) {
                selection = .settings
            },
            .init(
                id: "app.togglePlayback",
                title: "Toggle Playback",
                shortcut: "Space",
                category: .app,
                description: "Play or pause the timeline scrubber."
            ) {
                selection = .timeline
            },
            .init(
                id: "app.refreshBrain",
                title: "Refresh Brain",
                shortcut: "⌘R",
                category: .app,
                description: "Re-query the brain to pick up new captures."
            ) {
                Task { @MainActor in
                    actionPanelRegistry.beginRefresh()
                    MemoryRefreshSignal.post()
                    await Task.yield()
                    actionPanelRegistry.endRefresh()
                    ToastNotifier.shared.notify("Refreshing memory")
                }
            },
            .init(
                id: "app.showOnboarding",
                title: "Show Onboarding",
                shortcut: "",
                category: .app,
                description: "Re-run the onboarding flow."
            ) {
                // Cycle 8.48 — canonical form is
                // `hippocampus://onboarding/show`; the legacy
                // `?show=1` query-form is also honored by
                // `HippocampusApp.application(_:open:)` so any older
                // NSWorkspace-open callers keep working.
                if let url = URL(string: "hippocampus://onboarding/show") {
                    NSWorkspace.shared.open(url)
                }
            },
            .init(
                id: "app.exportDebugBundle",
                title: "Export Debug Bundle",
                shortcut: "",
                category: .debug,
                description: "Export a support bundle (redacted) for troubleshooting."
            ) {
                if let url = URL(string: "hippocampus://debug?export=1") {
                    NSWorkspace.shared.open(url)
                }
            },
            .init(
                id: "app.showHelp",
                title: "Show Help / Keyboard Shortcuts",
                shortcut: "⌘/",
                category: .app,
                description: "Show every registered command and its shortcut."
            ) {
                actionPanelRegistry.showHelp()
            },
            // Cycle 8.54 — "What's new" release-notes viewer. Fires the
            // WhatsNewCoordinator's on-demand path (bypasses last-shown
            // check) so the user can revisit the changelog any time.
            .init(
                id: "app.whatsNew",
                title: "What's New",
                shortcut: "⌘⇧N",
                category: .app,
                description: "Release notes for the version you're on (parses bundled CHANGELOG.md)."
            ) {
                whatsNewCoord.showOnDemand()
            },
            .init(
                id: "app.showGlobalRecallPopup",
                title: "Show Global Recall Popup",
                shortcut: "⇧⌘Space",
                category: .app,
                description: "Open the always-on Spotlight-style recall popup."
            ) {
                GlobalRecallPopupController.shared.show()
            },
            .init(
                id: "app.quit",
                title: "Quit Hippocampus Recall",
                shortcut: "⌘Q",
                category: .app,
                description: "Quit the recall app."
            ) {
                NSApp.terminate(nil)
            },
        ]
    }

    var body: some View {
        MemoryWorkspaceView(
            reader: reader,
            selection: $selection,
            searchFocusTrigger: searchFocusTrigger,
            focusRequest: focusRequest
        )
        .background(Color.brandBgPrimary)
        .onOpenURL { url in
            guard let request = RecallLaunchRequest(url: url) else { return }
            apply(request)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: RecallLaunchRequest.localCommandName)
        ) { notification in
            guard let request = notification.object as? RecallLaunchRequest else { return }
            apply(request)
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
            selection = destination
            return .handled
        }
        .onKeyPress(.init("f"), phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            selection = .search
            searchFocusTrigger.toggle()
            return .handled
        }
        .onKeyPress(.init("b"), phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            selection = .briefs
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
            // so a bare ⌘N (New Search) still routes cleanly through
            // the existing `app.newSearch` command.
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
        .task {
            // Fire once per launch: if the current version is new
            // (last-shown-version != current), show the modal. The
            // coordinator no-ops on repeat launches at the same
            // version, so this is safe to call on every boot.
            whatsNewCoord.maybeShowOnBoot()
        }
    }

    private func apply(_ request: RecallLaunchRequest) {
        if request.openPopup {
            GlobalRecallPopupController.shared.show()
        }
        if let tab = request.tab {
            selection = MemoryWorkspaceSelection(initialTab: tab)
        }
        if let eventId = request.focusEventId {
            selection = .search
            focusRequest = RecallFocusRequest(
                eventId: eventId,
                sequence: nextFocusSequence
            )
            nextFocusSequence &+= 1
        }
    }
}
