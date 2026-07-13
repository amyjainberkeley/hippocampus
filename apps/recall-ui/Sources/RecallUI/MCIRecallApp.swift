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
            .init(id: "app.newSearch", title: "New Search", shortcut: "⌘N", category: .search) {
                selectedTab = .search
                searchFocusTrigger.toggle()
            },
            .init(id: "app.showTimeline", title: "Show Timeline", shortcut: "⌘T", category: .app) {
                selectedTab = .timeline
            },
            .init(id: "app.openSettings", title: "Open Settings", shortcut: "⌘,", category: .app) {
                selectedTab = .settings
            },
            .init(
                id: "app.openCustomNames",
                title: "Open Custom Names Dictionary",
                shortcut: "⌘6",
                category: .app
            ) {
                selectedTab = .settings
            },
            .init(id: "app.toggleDarkMode", title: "Toggle Dark Mode", shortcut: "⌘⇧D", category: .app) {
                // No-op stub: recall UI is dark-locked today (see
                // `preferredColorScheme(.dark)` in MCIRecallApp).
                // Registered for discoverability per peer study §4.
            },
            .init(id: "app.togglePlayback", title: "Toggle Playback", shortcut: "Space", category: .app) {
                selectedTab = .timeline
            },
            .init(id: "app.refreshBrain", title: "Refresh Brain", shortcut: "⌘R", category: .app) {
                // Refresh is a no-op at this seam — brain is read-only
                // via FFI. Included for discoverability.
            },
            .init(id: "app.showOnboarding", title: "Show Onboarding", shortcut: "", category: .app) {
                if let url = URL(string: "hippocampus://onboarding?show=1") {
                    NSWorkspace.shared.open(url)
                }
            },
            .init(
                id: "app.exportDebugBundle",
                title: "Export Debug Bundle",
                shortcut: "",
                category: .debug
            ) {
                if let url = URL(string: "hippocampus://debug?export=1") {
                    NSWorkspace.shared.open(url)
                }
            },
            .init(
                id: "app.showHelp",
                title: "Show Help / Keyboard Shortcuts",
                shortcut: "⌘/",
                category: .app
            ) {
                if let url = URL(string: "hippocampus://help") {
                    NSWorkspace.shared.open(url)
                }
            },
            .init(
                id: "app.showGlobalRecallPopup",
                title: "Show Global Recall Popup",
                shortcut: "⇧⌘Space",
                category: .app
            ) {
                GlobalRecallPopupController.shared.show()
            },
            .init(id: "app.quit", title: "Quit Hippocampus Recall", shortcut: "⌘Q", category: .app) {
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

            PrivacyDashboard(reader: reader)
                .tag(RecallTab.privacyDashboard)
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .padding(.top, 6)
        .background(Color.brandBgPrimary)
        .focusable()
        .onKeyPress(
            keys: [
                .init("1"), .init("2"), .init("3"), .init("4"),
                .init("5"), .init("6"), .init("7"),
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
        .registerActionPanelCommands(globalCommands, registry: actionPanelRegistry)
        .actionPanelHost(registry: actionPanelRegistry)
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
