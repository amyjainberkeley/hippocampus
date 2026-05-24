// SPDX-License-Identifier: TBD-private
import SwiftUI
import HippocampusKit

@main
struct HippocampusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var supervisor = ProcessSupervisor(
        locator: BundleBinaryLocator(),
        keyStore: FileKeyStore()
    )
    @StateObject private var loginItemVM = LoginItemViewModel(service: SMLoginItemService())
    private let updater = SparkleUpdaterService()

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(
                supervisor: supervisor,
                loginItemVM: loginItemVM,
                updater: updater
            )
            .task {
                appDelegate.supervisorRef = supervisor
                supervisor.start()
                updater.startUpdater()
                Self.autoLaunchOnboardingIfNeeded(supervisor: supervisor)
            }
        } label: {
            MenuBarIcon(supervisor: supervisor)
        }
    }

    /// On first launch (no `~/Library/Application Support/MCI/
    /// .onboarding-complete` sentinel), spawn the standalone Onboarding
    /// executable so the user lands in a guided flow instead of staring
    /// at an empty menu bar. No-op on subsequent launches.
    ///
    /// Defers by 1.0 s so the menu-bar icon paints first — otherwise
    /// the Onboarding window appears before the user has any visual
    /// confirmation the menu-bar app launched (jarring).
    @MainActor
    private static func autoLaunchOnboardingIfNeeded(supervisor: ProcessSupervisor) {
        guard !OnboardingSentinel.isComplete else { return }
        guard supervisor.hasOnboarding else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            _ = supervisor.openOnboarding()
        }
    }
}

struct MenuBarIcon: View {
    @ObservedObject var supervisor: ProcessSupervisor

    var body: some View {
        switch supervisor.state {
        case .running:
            Image(systemName: "brain.filled.head.profile")
        case .paused:
            Image(systemName: "brain.head.profile")
        case .crashed:
            Image(systemName: "exclamationmark.circle.fill")
        default:
            Image(systemName: "brain.head.profile")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    var supervisorRef: ProcessSupervisor?

    func applicationWillTerminate(_ notification: Notification) {
        supervisorRef?.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "hippocampus", url.host == "recall" else { continue }
            // Parse `?tab=brief` (or other) per the Brief Viewer spec:
            // `hippocampus://recall?tab=brief` deep-links the Brief tab.
            // Unknown values fall through to the recall-ui's default tab.
            let initialTab: String? = URLComponents(
                url: url, resolvingAgainstBaseURL: false
            )?
            .queryItems?
            .first(where: { $0.name == "tab" })?
            .value
            Task { @MainActor in
                supervisorRef?.openRecallUI(initialTab: initialTab)
            }
        }
    }
}
