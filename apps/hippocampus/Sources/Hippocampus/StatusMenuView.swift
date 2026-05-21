// SPDX-License-Identifier: TBD-private
import SwiftUI
import HippocampusKit

struct StatusMenuView: View {
    @ObservedObject var supervisor: ProcessSupervisor

    @State private var showAbout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status line
            Text(supervisor.state.statusText)
                .font(.headline)

            Divider()

            // Pause / Resume
            if supervisor.state == .running {
                Button("Pause") {
                    supervisor.setPaused(true)
                }
            } else if supervisor.state == .paused {
                Button("Resume") {
                    supervisor.setPaused(false)
                }
            }

            // Start / Stop
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

            // Health snapshot
            if let health = supervisor.health {
                Text(health.displayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No health data yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // View logs
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

            Built by MCI — Memory Context Interface.
            See docs/decisions/ for the ADR ladder.

            // TODO: SMAppService LoginItem registration (Wave 2.A)
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
