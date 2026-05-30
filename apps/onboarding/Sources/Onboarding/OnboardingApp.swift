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

    init() {
        #if canImport(AppKit)
        let sr: any TCCPermission = RealScreenRecordingPermission()
        let ax: any TCCPermission = RealAccessibilityPermission()
        #else
        let sr: any TCCPermission = StubTCCPermission(kind: .screenRecording)
        let ax: any TCCPermission = StubTCCPermission(kind: .accessibility)
        #endif

        _flowVM = StateObject(wrappedValue: OnboardingFlowViewModel(
            screenRecording: sr, accessibility: ax
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
        let fdaPermission: any FullDiskAccessPermission = RealFullDiskAccessPermission()
        #else
        let detector: any BrowserDetector = StubBrowserDetector()
        let appsDetector: any RunningAppsDetector = StubRunningAppsDetector()
        let fdaPermission: any FullDiskAccessPermission = StubFullDiskAccessPermission()
        #endif
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
                .frame(
                    width: OnboardingTheme.windowWidth,
                    height: OnboardingTheme.windowHeight
                )
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
