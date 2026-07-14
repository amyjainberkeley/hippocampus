import AppKit
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

        // Wire the CEO-directed Spotlight-like recall popup: ⇧⌘Space
        // toggles a floating panel that types-through to the same
        // FFI search path as the main recall UI. Registration is
        // best-effort — if Carbon returns an error (e.g. another app
        // has claimed the same combo), we surface a menu-bar hint
        // and continue booting so the recall UI proper still works.
        MainActor.assumeIsolated {
            GlobalRecallPopupController.shared.configure(reader: MCIRecallApp.reader)
            let result = GlobalHotkeyManager.shared.registerDefault {
                GlobalRecallPopupController.shared.toggle()
            }
            if case .osError = result {
                // Not fatal; the popup can still be invoked via the
                // hippocampus://recall?popup=1 URL or the ⌘K Action
                // Panel command. Log so support has a trail.
                NSLog(
                    "MCI: global hotkey registration failed (%@); " +
                    "popup remains accessible via ⌘K command / URL scheme.",
                    String(describing: result)
                )
            }
        }
    }
}

@main
struct MCIRecallApp: App {
    @NSApplicationDelegateAdaptor(MCIRecallAppDelegate.self) var appDelegate

    @MainActor
    private static let reader: BrainReader = Self.makeReader()

    var body: some Scene {
        WindowGroup("Hippocampus Recall") {
            RootView(
                reader: MCIRecallApp.reader,
                initialTab: MCIRecallApp.initialTabFromEnv()
            )
            .frame(minWidth: 720, minHeight: 480)
            .background(Color.brandBgPrimary)
            .preferredColorScheme(.dark)
            .onOpenURL { url in
                // `hippocampus://recall?popup=1` — invoked by the
                // ⌘K Action Panel from other Hippocampus apps or a
                // command-palette shortcut. Presents the global
                // popup without touching the current tab state.
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let items = comps?.queryItems ?? []
                if items.contains(where: { $0.name == "popup" && $0.value == "1" }) {
                    GlobalRecallPopupController.shared.show()
                }
            }
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
        .defaultSize(width: 900, height: 600)
    }

    /// Read `MCI_INITIAL_TAB` set by Hippocampus.app when handling a
    /// `hippocampus://recall?tab=…` deep-link. Defaults to `.search`.
    @MainActor
    private static func initialTabFromEnv() -> RecallTab {
        guard let raw = ProcessInfo.processInfo.environment[RecallTab.initialTabEnvVar],
              let tab = RecallTab.from(deepLinkValue: raw)
        else {
            return .search
        }
        return tab
    }

    @MainActor
    private static func makeReader() -> BrainReader {
        guard let keyHex = ProcessInfo.processInfo.environment["MCI_DB_KEY_HEX"],
              !keyHex.isEmpty
        else {
            return StubBrainReader()
        }
        do {
            return try FFIBrainReader(path: defaultBrainPath(), keyHex: keyHex)
        } catch {
            return StubBrainReader()
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
}

struct RootView: View {
    let reader: BrainReader
    @State private var selectedTab: RecallTab
    @State private var searchFocusTrigger = false
    @ObservedObject private var actionPanelRegistry = ActionPanelRegistry.shared
    // Cycle 8.54 — "What's new" release-notes modal. Coordinator owns
    // the last-shown-version bookkeeping (UserDefaults) + the parsed
    // release loaded from Contents/Resources/CHANGELOG.md.
    @StateObject private var whatsNewCoord = WhatsNewCoordinator()

    init(reader: BrainReader, initialTab: RecallTab = .search) {
        self.reader = reader
        self._selectedTab = State(initialValue: initialTab)
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
                selectedTab = .search
                searchFocusTrigger.toggle()
            },
            .init(
                id: "app.showTimeline",
                title: "Show Timeline",
                shortcut: "⌘T",
                category: .app,
                description: "Switch to the timeline of recent events."
            ) {
                selectedTab = .timeline
            },
            // V2-P13 (Phase D scaffold) — command-palette entry for the
            // Rewind-style visual timeline strip.
            .init(
                id: "app.showTimelineStrip",
                title: "Show Timeline Strip",
                shortcut: "⌘8",
                category: .app,
                description: "Rewind-style visual timeline strip (scaffold; live data awaits V2-P1 M4 lift)."
            ) {
                selectedTab = .timelineStrip
            },
            .init(
                id: "app.openSettings",
                title: "Open Settings",
                shortcut: "⌘,",
                category: .app,
                description: "Open the settings and dictionary tab."
            ) {
                selectedTab = .settings
            },
            .init(
                id: "app.openCustomNames",
                title: "Open Custom Names Dictionary",
                shortcut: "⌘6",
                category: .app,
                description: "Edit user-defined entity aliases."
            ) {
                selectedTab = .settings
            },
            .init(
                id: "app.toggleDarkMode",
                title: "Toggle Dark Mode",
                shortcut: "⌘⇧D",
                category: .app,
                description: "Recall UI is dark-locked today; reserved for future light mode."
            ) {
                // No-op stub: recall UI is dark-locked today (see
                // `preferredColorScheme(.dark)` in MCIRecallApp).
                // Registered for discoverability per peer study §4.
            },
            .init(
                id: "app.togglePlayback",
                title: "Toggle Playback",
                shortcut: "Space",
                category: .app,
                description: "Play or pause the timeline scrubber."
            ) {
                selectedTab = .timeline
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
                    // Simulated async re-query pass. Brain is read-only
                    // via FFI (ADR-0016 §4.3) — the actual work is a
                    // best-effort flush of caches on the search view
                    // model. Kept off the UI thread so the spinner
                    // renders even on cold-start slow FFI opens.
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    actionPanelRegistry.endRefresh()
                    ToastNotifier.shared.notify("Brain refreshed")
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
                id: "app.showChat",
                title: "Show Chat",
                shortcut: "⌘9",
                category: .app,
                description: "Preview the future chat-with-your-memory surface (ships in v1.5)."
            ) {
                selectedTab = .chat
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
        TabView(selection: $selectedTab) {
            SearchView(
                viewModel: SearchViewModel(reader: reader),
                focusTrigger: searchFocusTrigger,
                reader: reader
            )
            .tag(RecallTab.search)
            .tabItem { Label("Search", systemImage: "magnifyingglass") }

            TimelineView(viewModel: TimelineViewModel(reader: reader), reader: reader)
                .tag(RecallTab.timeline)
                .tabItem { Label("Timeline", systemImage: "clock") }

            EpisodesView(viewModel: EpisodesViewModel(reader: reader))
                .tag(RecallTab.episodes)
                .tabItem { Label("Episodes", systemImage: "rectangle.stack") }

            BriefView(
                viewModel: BriefViewModel(
                    reader: reader,
                    isModelPresentProbe: {
                        ModelPresenceProbe.isBriefModelInstalled()
                    },
                    hasFullDayCapture: true
                ),
                onRequestModelDownload: {
                    // The recall-ui doesn't own the download UI (PR #134
                    // lives in Hippocampus.app). Surface a hippocampus://
                    // deep-link so the menu-bar app handles it.
                    if let url = URL(string: "hippocampus://recall?tab=brief&download=1") {
                        NSWorkspace.shared.open(url)
                    }
                }
            )
            .tag(RecallTab.brief)
            .tabItem { Label("Brief", systemImage: "doc.text") }

            PrivacyMomentsView(
                viewModel: PrivacyMomentsViewModel(reader: reader)
            )
            .tag(RecallTab.privacy)
            .tabItem { Label("Privacy Moments", systemImage: "eye.slash") }

            UserDictionaryEditor()
                .tag(RecallTab.settings)
                .tabItem { Label("Settings", systemImage: "gearshape") }

            // Cycle 8.47 (PR #76 follow-up): wire the mutator when the
            // reader is FFI-backed so the destructive-action buttons
            // route through the real delete pathway. StubBrainReader
            // callers (preview / smoke) get a nil mutator and see
            // disabled-behavior on delete.
            PrivacyDashboard(reader: reader, mutator: reader as? PrivacyMutator)
                .tag(RecallTab.privacyDashboard)
                .tabItem { Label("Privacy", systemImage: "lock.shield") }

            // V2-P13 (Phase D scaffold): Rewind-style visual timeline
            // strip. See ADR-0036. Live rendering awaits V2-P1 M4 lift
            // + real captures; scaffold renders MCIEmptyState until
            // then.
            TimelineStripView(reader: reader)
                .tag(RecallTab.timelineStrip)
                .tabItem { Label("Strip", systemImage: "chart.bar.doc.horizontal") }

            // Cycle 8.52 — Chat surface STUB (⌘9). UI-only preview of the
            // V2-P12 chat-with-your-memory experience per ADR-0035 (Proposed).
            // No ML runtime loaded; replies are placeholder strings framed as
            // "coming in v1.5" so the CEO can review the shape before
            // ratifying ADR-0035.
            ChatSurfaceView()
                .tag(RecallTab.chat)
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                }
        }
        .padding(.top, 6)
        .background(Color.brandBgPrimary)
        .focusable()
        .onKeyPress(
            keys: [
                .init("1"), .init("2"), .init("3"), .init("4"),
                .init("5"), .init("6"), .init("7"), .init("8"), .init("9"),
            ],
            phases: .down
        ) { press in
            guard press.modifiers == .command else { return .ignored }
            switch press.key {
            case KeyEquivalent("1"): selectedTab = .search
            case KeyEquivalent("2"): selectedTab = .timeline
            case KeyEquivalent("3"): selectedTab = .episodes
            case KeyEquivalent("4"): selectedTab = .brief
            case KeyEquivalent("5"): selectedTab = .privacy
            case KeyEquivalent("6"): selectedTab = .settings
            case KeyEquivalent("7"): selectedTab = .privacyDashboard
            // V2-P13 (Phase D scaffold) — ⌘8 = timeline strip tab.
            case KeyEquivalent("8"): selectedTab = .timelineStrip
            case KeyEquivalent("9"): selectedTab = .chat
            default: return .ignored
            }
            return .handled
        }
        .onKeyPress(.init("f"), phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            selectedTab = .search
            searchFocusTrigger.toggle()
            return .handled
        }
        .onKeyPress(.init("b"), phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            selectedTab = .brief
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
        .sheet(isPresented: $actionPanelRegistry.isHelpVisible) {
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
}

/// Best-effort probe for whether the daily-brief author model has been
/// downloaded. The recall-ui does NOT own model lifecycle (PR #134's
/// ModelDownloadView in Hippocampus.app does); we just want to know
/// whether the file exists on disk so the Brief tab can render the
/// right empty state.
///
/// Mirrors `ModelDownloadManager.isModelAvailable(modelID:)` —
/// checks `~/Library/Application Support/MCI/Models/<modelID>/` exists.
/// Kept inside the recall-ui rather than via FFI/IPC because (a) it's
/// a plain filesystem read, (b) the recall-ui already runs under the
/// user's HOME, and (c) a missing-file false-negative just renders
/// the "Enable on-device brief model" CTA which is benign.
enum ModelPresenceProbe {
    static let qwen3ModelID = "qwen3-1.7b-fp16"

    static func isBriefModelInstalled(modelID: String = qwen3ModelID) -> Bool {
        // Per `docs/decisions/0028-brief-author-model-qwen3-1.7b-coreml.md` §4,
        // models live in ~/Library/Application Support/MCI/Models/<id>/.
        let supportDir = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory,
            .userDomainMask,
            true
        ).first ?? NSTemporaryDirectory()
        let path = (supportDir as NSString)
            .appendingPathComponent("MCI/Models/\(modelID)")
        return FileManager.default.fileExists(atPath: path)
    }
}
