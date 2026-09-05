// SPDX-License-Identifier: TBD-private
import SwiftUI
import HippocampusKit

struct StatusMenuView: View {
    @ObservedObject var supervisor: ProcessSupervisor
    @ObservedObject var modelProvisioner: BriefModelProvisioner
    @ObservedObject var loginItemVM: LoginItemViewModel
    let updater: SparkleUpdaterService
    @ObservedObject var preferencesStore: PreferencesStore
    let onRequestQuit: () -> Void
    let onRequestRestart: () -> Void

    @State private var crashReportOptedIn: Bool = false
    @State private var mcpRegistering = false
    @State private var showTCCResetConfirm = false
    @State private var showKeyWrapAudit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader

            Divider()

            quickActionsSection

            switch RecordingControl.derive(
                from: supervisor.state,
                captureEnabled: supervisor.captureEnabled
            ) {
            case .start:
                Button("Start Recording") {
                    if supervisor.captureEnabled {
                        supervisor.start()
                    } else {
                        Task { @MainActor in
                            try? await supervisor.applyCaptureEnabled(true)
                        }
                    }
                }
            case .stop:
                Button("Stop Recording") {
                    Task { @MainActor in
                        try? await supervisor.applyCaptureEnabled(false)
                    }
                }
            case .none:
                EmptyView()
            }

            if supervisor.hasOnboarding {
                Button("Open Onboarding") {
                    _ = supervisor.openOnboarding()
                }
            }

            Divider()

            briefsMenuItem

            Button("Connect AI Tools…") {
                connectAITools()
            }
            .disabled(mcpRegistering)

            Divider()

            Button("Preferences…") {
                openPreferencesWindow()
            }
            .keyboardShortcut(",", modifiers: [.command])

            troubleshootSection

            Button("Send Feedback…") { sendFeedback() }

            Divider()

            Button("Quit Hippocampus") {
                onRequestQuit()
            }
            .keyboardShortcut("q")
        }
        .task {
            crashReportOptedIn = supervisor.isCrashReportOptedIn
            modelProvisioner.refreshIfMissing()
            if loginItemVM.shouldPrompt {
                loginItemVM.markPrompted()
            }
        }
        .sheet(isPresented: $showKeyWrapAudit) {
            KeyWrapAuditView(
                store: .defaultDatabaseKey,
                onClose: { showKeyWrapAudit = false }
            )
        }
    }

    @ViewBuilder
    private var briefsMenuItem: some View {
        Button("Open Daily Brief") {
            supervisor.openRecallUI(initialTab: "brief")
        }

        if modelProvisioner.state == .ready && modelProvisioner.isReadyOnDisk {
            Text("Brief quality: Rich local model")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Always-visible quick actions a user needs regardless of state:
    ///
    ///   - Pause / Resume Capture  ⌘⇧P  (toggle; label flips per state)
    ///   - Open Recall             ⌘R
    ///   - Open Timeline           ⌘T  (⌘8 in the recall-ui window,
    ///                              but from the menu-bar the entry
    ///                              point is a distinct verb; deep-links
    ///                              to `timeline` tab via MCI_INITIAL_TAB)
    /// Pause is a user-initiated stop distinct from the automatic
    /// TCC-revocation stop. It flips `UserPauseController.shared.isPaused`
    /// and asks the supervisor to stop the complete owned topology via `setPaused`
    /// so the visible `MenuBarStatus` derivation flips to
    /// `.paused`. The controller emits a `helper_health
    /// user_paused=<bool>` breadcrumb so the health-log ring
    /// distinguishes user pauses from automated ones.
    @ViewBuilder
    private var quickActionsSection: some View {
        let paused = (supervisor.state == .paused)
            || UserPauseController.shared.isPaused

        Button("Open Recall") {
            supervisor.openRecallUI()
        }
        .keyboardShortcut("r", modifiers: [.command])

        Button("Open Timeline") {
            supervisor.openRecallUI(initialTab: "timeline")
        }
        .keyboardShortcut("t", modifiers: [.command])

        if supervisor.captureEnabled {
            Button(paused ? "Resume Capture" : "Pause Capture") {
                toggleUserPause()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }

    /// Flip user pause state. Called from menu-bar ⌘⇧P and from the
    /// ⌘K Action Panel (PR #74). Keeps the two layers coherent:
    ///   - `UserPauseController.shared` — the user-facing flag +
    ///     breadcrumb emitter.
    ///   - `supervisor.setPaused(_:)` — a verified full-topology stop
    ///     followed by a fresh launch on resume. A pause requested before
    ///     or during startup is also forwarded so capture cannot race the
    ///     user's latest intent.
    private func toggleUserPause() {
        let nextPaused = UserPauseController.shared.togglePaused()
        supervisor.setPaused(nextPaused)
    }

    @ViewBuilder
    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Hippocampus").font(.headline)
            CaptureHealthView(supervisor: supervisor) {
                PreferencesWindowController.shared.show(section: .capture)
            }
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

            Button("Inspect Key Wrap…") {
                showKeyWrapAudit = true
            }

            Button("Reset TCC Permissions…") {
                showTCCResetConfirm = true
            }

            Divider()

            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)

            Toggle("Send Crash Reports", isOn: $crashReportOptedIn)
                .onChange(of: crashReportOptedIn) { _, newValue in
                    supervisor.setCrashReportOptedIn(newValue)
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
            let proc = ChildProcessEnvironment.makeProcess()
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
        onRequestRestart()
    }

    private func connectAITools() {
        guard let agentPath = supervisor.agentBinaryPath else {
            // Cycle 8.54 copy audit — plain-English replacement for the
            // engineer-only "mci-agent binary not found." Users have no
            // context for what "mci-agent" is.
            showAlert(
                title: "Couldn\u{2019}t connect AI tools",
                message:
                    "Hippocampus can\u{2019}t find its agent "
                    + "connector. Try reinstalling Hippocampus."
            )
            return
        }
        let childEnvironment = supervisor.sanitizedChildEnvironment()
        mcpRegistering = true
        Task.detached {
            do {
                let message = try await AIToolConnector(
                    agentURL: agentPath,
                    baseEnvironment: childEnvironment
                ).connectAll()
                await MainActor.run {
                    mcpRegistering = false
                    showAlert(title: "Connected", message: message)
                }
            } catch {
                await MainActor.run {
                    mcpRegistering = false
                    showAlert(
                        title: "Couldn\u{2019}t connect AI tools",
                        message: error.localizedDescription
                    )
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
        // Cycle 8.54 copy audit — the copy audit removed the raw
        // "Error" title everywhere except this fallback. Warning
        // styling still fires whenever the title contains "Couldn't"
        // (our new user-facing failure convention).
        alert.alertStyle = (title.contains("Couldn") || title == "Error")
            ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Open (or focus) the comprehensive Preferences window bound to
    /// the ⌘, shortcut. All dependencies were wired in
    /// `HippocampusApp.configurePreferencesController` at launch; this
    /// call is idempotent — the controller lazily creates the NSPanel
    /// on first invocation and focuses the existing window thereafter.
    ///
    /// Note (cycle 8.54): PR #105 replaced the legacy `openAboutWindow`
    /// NSAlert with a proper Preferences window; the About section lives
    /// there. Copy-audit updates from PR #106 that targeted the removed
    /// alert are moot — the About section already reads "memory" not
    /// "brain" per the shared UserFacingCopy vocabulary.
    private func openPreferencesWindow() {
        #if canImport(AppKit)
        PreferencesWindowController.shared.show()
        #endif
    }

}
