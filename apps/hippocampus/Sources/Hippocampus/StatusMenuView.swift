// SPDX-License-Identifier: TBD-private
import SwiftUI
import HippocampusKit

struct StatusMenuView: View {
    @ObservedObject var supervisor: ProcessSupervisor
    @ObservedObject var loginItemVM: LoginItemViewModel
    let updater: SparkleUpdaterService

    @State private var showAbout = false
    @State private var crashReportOptedIn: Bool = false
    @State private var briefsEnabled: Bool = UserDefaults.standard.bool(forKey: "MCIBriefsEnabled")
    @State private var showDownloadDialog = false
    @State private var mcpRegistering = false
    @State private var showTCCResetConfirm = false

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
                Button("Pause Capture") {
                    supervisor.setPaused(true)
                }
            } else if supervisor.state == .paused {
                Button("Resume Capture") {
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

            briefsMenuItem

            Button("Connect to Claude Code…") {
                connectToClaude()
            }
            .disabled(mcpRegistering)

            Button("Send Feedback") {
                sendFeedback()
            }

            Divider()

            troubleshootSection

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
        .sheet(isPresented: $showDownloadDialog) {
            ModelDownloadView(
                onDismiss: { showDownloadDialog = false },
                onComplete: {
                    briefsEnabled = true
                    showDownloadDialog = false
                }
            )
        }
    }

    @ViewBuilder
    private var briefsMenuItem: some View {
        let modelDownloaded = UserDefaults.standard.bool(forKey: "MCIBriefModelDownloaded")
        if modelDownloaded {
            Toggle("Daily Briefs", isOn: $briefsEnabled)
                .onChange(of: briefsEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "MCIBriefsEnabled")
                }
        } else {
            Button("Daily Briefs: Off — Download Model…") {
                showDownloadDialog = true
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

    @ViewBuilder
    private var troubleshootSection: some View {
        Menu("Troubleshoot…") {
            Button("Open Logs Folder") {
                let logDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/MCI")
                NSWorkspace.shared.open(logDir)
            }

            Button("Reset TCC Permissions…") {
                showTCCResetConfirm = true
            }

            Divider()

            Button("Open Screen Recording Settings") {
                openSettingsPane("Privacy_ScreenCapture")
            }

            Button("Open Accessibility Settings") {
                openSettingsPane("Privacy_Accessibility")
            }

            Divider()

            Button("Quit and Restart") {
                quitAndRestart()
            }
        }
        .alert("Reset TCC Permissions?", isPresented: $showTCCResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                resetTCCPermissions()
            }
        } message: {
            Text("Will reset Screen Recording, Accessibility, and Files grants. You'll need to re-grant on next launch.")
        }
    }

    private func openSettingsPane(_ pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func resetTCCPermissions() {
        let services = ["ScreenCapture", "Accessibility", "SystemPolicyAllFiles"]
        var results: [String] = []
        for service in services {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            proc.arguments = ["reset", service]
            do {
                try proc.run()
                proc.waitUntilExit()
                results.append("\(service): \(proc.terminationStatus == 0 ? "reset" : "failed")")
            } catch {
                results.append("\(service): error — \(error.localizedDescription)")
            }
        }
        showAlert(title: "TCC Reset Complete", message: results.joined(separator: "\n") + "\n\nQuit and relaunch to re-grant.")
    }

    private func quitAndRestart() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "sleep 1 && open \"\(bundlePath)\""]
        try? task.run()

        supervisor.stop()
        NSApp.terminate(nil)
    }

    private func connectToClaude() {
        guard let agentPath = supervisor.agentBinaryPath else {
            showAlert(title: "Error", message: "mci-agent binary not found.")
            return
        }
        mcpRegistering = true
        Task.detached {
            let proc = Process()
            proc.executableURL = agentPath
            proc.arguments = ["register-mcp"]
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                await MainActor.run {
                    mcpRegistering = false
                    showAlert(title: "Error", message: "Failed to run register-mcp: \(error.localizedDescription)")
                }
                return
            }
            let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            await MainActor.run {
                mcpRegistering = false
                if proc.terminationStatus == 0 {
                    let msg = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    showAlert(title: "Connected", message: msg.isEmpty ? "Hippocampus registered with Claude Code. Restart Claude Code to connect." : msg)
                } else {
                    let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    showAlert(title: "Error", message: detail.isEmpty ? "register-mcp exited with code \(proc.terminationStatus)" : detail)
                }
            }
        }
    }

    private func sendFeedback() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        // TODO: swap to hippocampus.ai/feedback once domain (#21) lands
        let subject = "Hippocampus feedback v\(version)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "mailto:hippocampus@amyjainberkeley.com?subject=\(subject)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = title == "Error" ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
