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

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(supervisor: supervisor)
                .task {
                    appDelegate.supervisorRef = supervisor
                    supervisor.start()
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
}
