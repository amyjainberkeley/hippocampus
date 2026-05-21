// SPDX-License-Identifier: TBD-private
import SwiftUI
import HippocampusKit

struct StatusMenuView: View {
    @ObservedObject var supervisor: ProcessSupervisor
    @ObservedObject var loginItemVM: LoginItemViewModel
    let updater: SparkleUpdaterService

    @State private var showAbout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(supervisor.state.statusText)
                .font(.headline)

            Divider()

            if supervisor.state == .running {
                Button("Pause") {
                    supervisor.setPaused(true)
                }
            } else if supervisor.state == .paused {
                Button("Resume") {
                    supervisor.setPaused(false)
                }
            }

            if !supervisor.state.isActive && supervisor.state != .starting {
                Button("Start Recording") {
                    supervisor.start()
                }
            } else if supervisor.state.isActive {
                Button("Stop Recording") {
                    supervisor.stop()
                }
            }

            Divider()

            Button("Open Recall UI") {
                supervisor.openRecallUI()
            }
            .disabled(!supervisor.state.isActive)

            if supervisor.hasOnboarding {
                Button("Open Onboarding") {
                    _ = supervisor.openOnboarding()
                }
            }

            Divider()

            // Login Item
            Toggle("Launch at Login", isOn: Binding(
                get: { loginItemVM.isEnabled },
                set: { _ in loginItemVM.toggle() }
            ))

            Divider()

            // Sparkle updates
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)

            Toggle("Auto-Check for Updates", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }
            ))

            Divider()

            if let health = supervisor.health {
                Text(health.displayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No health data yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("View Logs in Console") {
                let logDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/MCI")
                NSWorkspace.shared.open(logDir)
            }

            Divider()

            Button("About Hippocampus") {
                showAbout = true
                openAboutWindow()
            }

            Button("Quit Hippocampus") {
                supervisor.stop()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .task {
            if loginItemVM.shouldPrompt {
                loginItemVM.markPrompted()
            }
        }
    }

    private func openAboutWindow() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let dbPath = supervisor.dbPath.path

        let alert = NSAlert()
        alert.messageText = "Hippocampus"
        alert.informativeText = """
            Version \(version)

            Your brain lives at:
            \(dbPath)

            Launch at Login: \(loginItemVM.isEnabled ? "ON" : "OFF")

            Built by MCI — Memory Context Interface.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
