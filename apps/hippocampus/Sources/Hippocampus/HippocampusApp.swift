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
            }
        } label: {
            MenuBarIcon(supervisor: supervisor)
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
