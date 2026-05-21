// SPDX-License-Identifier: TBD-private
import SwiftUI
import HippocampusKit

struct StatusMenuView: View {
    @ObservedObject var supervisor: ProcessSupervisor
    @ObservedObject var loginItemVM: LoginItemViewModel
    let updater: SparkleUpdaterService

    @State private var showAbout = false
    @State private var crashReportOptedIn: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader

            Divider()

            if let health = supervisor.health {
                Text(health.displayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if supervisor.state.isActive {
                Text("Waiting for first capture…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

            Toggle("Launch at Login", isOn: Binding(
                get: { loginItemVM.isEnabled },
                set: { _ in loginItemVM.toggle() }
            ))

            Divider()

            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)

            Toggle("Auto-Check for Updates", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }
            ))

            Divider()

            Toggle("Send Crash Reports", isOn: $crashReportOptedIn)
                .onChange(of: crashReportOptedIn) { _, newValue in
                    supervisor.setCrashReportOptedIn(newValue)
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
            crashReportOptedIn = supervisor.isCrashReportOptedIn
            if loginItemVM.shouldPrompt {
                loginItemVM.markPrompted()
            }
        }
    }

    @ViewBuilder
    private var statusHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(supervisor.state.statusText)
                .font(.headline)
        }
    }

    private var statusColor: Color {
        switch supervisor.state {
        case .running: return .green
        case .paused: return .yellow
        case .crashed: return .red
        default: return .secondary
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
