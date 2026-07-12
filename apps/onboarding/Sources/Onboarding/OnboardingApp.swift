import SwiftUI
import OnboardingKit
#if canImport(AppKit)
import AppKit
#endif

#if canImport(AppKit)
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
}
#endif

@main
struct OnboardingApp: App {
    #if canImport(AppKit)
    @NSApplicationDelegateAdaptor(OnboardingAppDelegate.self) var appDelegate
    #endif

    @StateObject private var flowVM: OnboardingFlowViewModel
    @StateObject private var trustVM: TrustPanelViewModel
    @StateObject private var retentionVM: RetentionViewModel
    @StateObject private var extensionVM: BrowserExtensionViewModel
    @StateObject private var prepareBrainVM: PrepareBrainViewModel
    @StateObject private var allowlistEditorVM: AllowlistEditorViewModel
    @StateObject private var mcpServersVM: McpServersViewModel

    init() {
        #if canImport(AppKit)
        let sr: any TCCPermission = RealScreenRecordingPermission()
        let ax: any TCCPermission = RealAccessibilityPermission()
        // Wire the previously-orphaned Automation TCC surface. Used by
        // BrowserExtensionSlide's Safari flow (osascript → System
        // Events keystroke, which fires the Automation dialog) and
        // surfaced up-front in the PermissionsSlide pre-flight
        // overview. Fixes audit gap G1 — the Rewind bad pattern where
        // dialog #3 lands unannounced.
        let am: any TCCPermission = RealAutomationPermission()
        let fda: any FullDiskAccessPermission = RealFullDiskAccessPermission()
        #else
        let sr: any TCCPermission = StubTCCPermission(kind: .screenRecording)
        let ax: any TCCPermission = StubTCCPermission(kind: .accessibility)
        let am: any TCCPermission = StubTCCPermission(kind: .automation)
        let fda: any FullDiskAccessPermission = StubFullDiskAccessPermission()
        #endif

        _flowVM = StateObject(wrappedValue: OnboardingFlowViewModel(
            screenRecording: sr,
            accessibility: ax,
            automation: am,
            fullDiskAccess: fda
        ))
        _trustVM = StateObject(wrappedValue: TrustPanelViewModel(
            allowlistStore: StubAllowlistStore(),
            denylistStore: DiskDenylistEditorStore()
        ))
        _retentionVM = StateObject(wrappedValue: RetentionViewModel(
            store: DiskRetentionStore()
        ))

        #if canImport(AppKit)
        let detector: any BrowserDetector = RealBrowserDetector()
        let appsDetector: any RunningAppsDetector = RealRunningAppsDetector()
        #else
        let detector: any BrowserDetector = StubBrowserDetector()
        let appsDetector: any RunningAppsDetector = StubRunningAppsDetector()
        #endif
        // Share the same FDA permission instance across the flow VM
        // (drives the pre-flight overview pill) and the allowlist
        // editor (fires the actual deep-link on deep-hook toggle).
        // Two separate instances would drift out of sync — the
        // pre-flight would show "Not requested" even after the user
        // opened Settings from the Allowlist slide.
        let fdaPermission = fda
        _extensionVM = StateObject(wrappedValue: BrowserExtensionViewModel(
            detector: detector
        ))

        _prepareBrainVM = StateObject(wrappedValue: PrepareBrainViewModel(
            keyGenerator: LocalKeyGenerator(),
            modelDownloader: RealModelDownloader()
        ))

        _allowlistEditorVM = StateObject(wrappedValue: AllowlistEditorViewModel(
            baselineStore: StubAllowlistStore(),
            userStore: FileUserAllowlistStore(),
            detector: appsDetector,
            fdaPermission: fdaPermission
        ))

        _mcpServersVM = StateObject(wrappedValue: McpServersViewModel(
            store: FileMcpServersStore()
        ))
    }

    var body: some Scene {
        WindowGroup {
            OnboardingFlowView()
                .environmentObject(flowVM)
                .environmentObject(trustVM)
                .environmentObject(retentionVM)
                .environmentObject(extensionVM)
                .environmentObject(prepareBrainVM)
                .environmentObject(allowlistEditorVM)
                .environmentObject(mcpServersVM)
                .frame(
                    width: OnboardingTheme.windowWidth,
                    height: OnboardingTheme.windowHeight
                )
                // Deep-link entrypoint. `onboarding://start?migration=rewind`
                // (fired by the `/rewind` landing lane, cycle 8.37 PR #30)
                // flips the flow VM's `migrationSource` so `WelcomeSlide`
                // renders the Rewind sub-header. Unknown query values are
                // silently ignored — see `OnboardingFlowViewModel.applyLaunchURL`.
                .onOpenURL { url in
                    flowVM.applyLaunchURL(url)
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Troubleshoot") {
                Button("Reset Screen Recording Permission and Retry") {
                    Task {
                        flowVM.goTo(.permissions)
                        _ = await flowVM.screenRecordingPermission.resetAndRetry()
                        flowVM.refreshPermissions()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Open Screen Recording Settings") {
                    flowVM.screenRecordingPermission.openPrivacySettings()
                }

                Button("Open Accessibility Settings") {
                    flowVM.accessibilityPermission.openPrivacySettings()
                }
            }
        }
    }
}
