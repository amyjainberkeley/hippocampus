import SwiftUI
import AppKit
import OnboardingKit

/// Pulls the Onboarding window to the foreground the instant it appears.
///
/// Without this, the Onboarding executable spawned by `HippocampusApp`
/// (a child `Process`) can sit behind whatever the user was looking at
/// when they double-clicked the .app — they see the menu-bar icon
/// appear, then a few seconds of nothing, with the Onboarding window
/// silently behind their browser/Finder. Calling `NSApp.activate` on
/// `applicationDidFinishLaunching` makes the window grab focus the
/// moment it's ready (CEO dogfood feedback, 2026-05-26).
final class OnboardingAppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the window ends setup, as Done does. The resume file keeps
    /// the step, and the app opens what follows when this process exits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Started by `OnboardingEntryPoint`, which answers the Screen Recording
/// probe commands first. One window, 760 by 560 with its title bar hidden:
/// the four screens, or the panel the app asked for.
struct OnboardingApp: App {
    @NSApplicationDelegateAdaptor(OnboardingAppDelegate.self) var appDelegate

    /// What `MCI_ONBOARDING_STEP` asked for, once consent is known.
    private let launch: OnboardingLaunch
    @StateObject private var flowVM: OnboardingFlowViewModel
    @StateObject private var prepareBrainVM: PrepareBrainViewModel
    @StateObject private var extensionVM: BrowserExtensionViewModel
    @StateObject private var allowlistEditorVM: AllowlistEditorViewModel
    @StateObject private var mcpServersVM: McpServersViewModel

    init() {
        let consentStore = FileOnboardingConsentStore()
        let launch = OnboardingLaunch.parse(ProcessInfo.processInfo.environment["MCI_ONBOARDING_STEP"])
            .resolved(consentGiven: consentStore.isGiven)
        self.launch = launch
        let initialScreen: OnboardingScreen? = if case .flow(let screen) = launch { screen } else { nil }
        let fullDiskAccess: any FullDiskAccessPermission = RealFullDiskAccessPermission()

        _flowVM = StateObject(wrappedValue: OnboardingFlowViewModel(
            screenRecording: RealScreenRecordingPermission(),
            accessibility: RealAccessibilityPermission(),
            // The browser extension panel's Safari flow asks for Automation.
            automation: RealAutomationPermission(),
            fullDiskAccess: fullDiskAccess,
            // The flow keeps its place; a panel keeps its state in memory.
            stateStore: launch.usesResumeFile ? FileOnboardingStateStore() : InMemoryOnboardingStateStore(),
            consentStore: consentStore,
            initialScreen: initialScreen
        ))
        // Setup offers no model download.
        _prepareBrainVM = StateObject(wrappedValue: PrepareBrainViewModel(
            keyGenerator: LocalKeyGenerator(),
            modelDownloader: StubModelDownloader()
        ))
        _extensionVM = StateObject(wrappedValue: BrowserExtensionViewModel(
            detector: RealBrowserDetector()
        ))
        _allowlistEditorVM = StateObject(wrappedValue: AllowlistEditorViewModel(
            baselineStore: SignedBaselineAllowlistStore(),
            userStore: FileUserAllowlistStore(),
            detector: RealRunningAppsDetector(),
            fdaPermission: fullDiskAccess
        ))
        _mcpServersVM = StateObject(wrappedValue: McpServersViewModel(
            store: FileMcpServersStore()
        ))
    }

    var body: some Scene {
        // A single window: there is no second setup to open with ⌘N.
        Window("Hippocampus", id: "setup") {
            root
                .preferredColorScheme(.light)
                .environmentObject(flowVM)
                .environmentObject(prepareBrainVM)
                .environmentObject(extensionVM)
                .environmentObject(allowlistEditorVM)
                .environmentObject(mcpServersVM)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    @ViewBuilder
    private var root: some View {
        switch launch {
        case .flow:
            OnboardingFlowView()
        case .panel(let panel):
            OnboardingPanelView(panel: panel) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
