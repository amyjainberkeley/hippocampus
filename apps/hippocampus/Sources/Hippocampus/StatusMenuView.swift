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
    @State private var briefsEnabled: Bool = UserDefaults.standard.bool(forKey: "MCIBriefsEnabled")
    @State private var mcpRegistering = false
    @State private var showTCCResetConfirm = false
    @State private var showKeyWrapAudit = false
    // `Window` scene (HippocampusApp.body) hosts the model-download UI;
    // `openWindow(id:)` survives the MenuBarExtra menu close that
    // dismisses any `.sheet`-attached SwiftUI presentation.
    @Environment(\.openWindow) private var openWindow

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
        switch modelProvisioner.state {
        case .ready where modelProvisioner.isReadyOnDisk:
            Toggle("Daily Briefs", isOn: $briefsEnabled)
                .onChange(of: briefsEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "MCIBriefsEnabled")
                }
        case .ready:
            Button("Daily Briefs: Restore bundled model") {
                modelProvisioner.refreshIfMissing()
            }
            .help("The local Daily Briefs model is missing. Restore it from this app bundle.")
        case .provisioning:
            Text("Daily Briefs: Preparing bundled model…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Button("Daily Briefs: Retry bundled model setup") {
                modelProvisioner.startIfNeeded()
            }
            .help("The bundled model was not prepared. Retry local setup; no data leaves this Mac.")
        case .unavailable:
            Button("Daily Briefs: Off — Download Model…") {
                openWindow(id: "model-download")
                #if canImport(AppKit)
                NSApp.activate(ignoringOtherApps: true)
                #endif
            }
            .help("Daily briefs summarize your day with Qwen3-1.7B (~2.5 GB download, runs entirely on your Mac).")
        case .notStarted:
            Text("Daily Briefs: Checking local model…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The single source of truth the header uses; matches the dot
    /// baked into the menu-bar icon overlay so the two surfaces
    /// always agree. See `MenuBarStatus.derive` for precedence rules.
    private var menuBarStatus: MenuBarStatus {
        MenuBarStatus.derive(
            from: supervisor.state,
            captureEnabled: supervisor.captureEnabled,
            tccRevokedSurface: supervisor.tccRevokedSurface
        )
    }

    /// Always-visible quick actions a user needs regardless of state:
    ///
    ///   - Pause / Resume Capture  ⌘⇧P  (toggle; label flips per state)
    ///   - Open Recall             ⌘R
    ///   - Open Timeline           ⌘T  (⌘8 in the recall-ui window,
    ///                              but from the menu-bar the entry
    ///                              point is a distinct verb; deep-links
    ///                              to `timeline` tab via MCI_INITIAL_TAB)
    /// Pause is a USER-initiated pause distinct from the TCC-revoke
    /// pause (PR #80) and the screen-share-leak pause (PR #75). It
    /// flips `UserPauseController.shared.isPaused` AND asks the
    /// supervisor to SIGSTOP the helper via the existing `setPaused`
    /// path so the visible `MenuBarStatus` derivation flips to
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
    ///   - `supervisor.setPaused(_:)` — the SIGSTOP/SIGCONT gate on
    ///     the capture helper. Only fired if the supervisor is in a
    ///     paused-compatible state (`.running` / `.paused`); otherwise
    ///     we still flip the user flag so a subsequent `.start()`
    ///     honours it.
    private func toggleUserPause() {
        let nextPaused = UserPauseController.shared.togglePaused()
        if supervisor.state == .running || supervisor.state == .paused {
            supervisor.setPaused(nextPaused)
        }
    }

    @ViewBuilder
    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("Hippocampus")
                    .font(.headline)
                Spacer(minLength: 12)
                Circle()
                    .fill(menuBarStatus.indicatorColor)
                    .frame(width: 7, height: 7)
                Text(menuBarStatus.displayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if supervisor.captureEnabled {
                if let health = supervisor.health {
                    Text(health.displayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if supervisor.state.isActive {
                    Text("Waiting for first capture…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Screen capture is off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
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
            let proc = ChildProcessEnvironment.makeProcess(baseEnvironment: childEnvironment)
            proc.executableURL = agentPath
            proc.arguments = ["connect", "--all"]
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
                    // Cycle 8.54 copy audit — user-facing title + no
                    // Internal connector jargon should not leak here.
                    showAlert(
                        title: "Couldn\u{2019}t connect AI tools",
                        message:
                            "Try again in a moment — if it keeps "
                            + "happening, use \u{201C}Send Feedback\u{201D} "
                            + "from the menu bar."
                    )
                }
                return
            }
            let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            await MainActor.run {
                mcpRegistering = false
                if proc.terminationStatus == 0 {
                    let msg = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    showAlert(title: "Connected", message: msg.isEmpty ? "Hippocampus connected the AI tools installed on this Mac." : msg)
                } else {
                    // Cycle 8.54 copy audit — never surface raw
                    // "exited with code -N" to the user. Stderr detail
                    // is preserved for the technical case; on the
                    // "no detail" path we swap in plain-English copy
                    // instead of the exit-code leak.
                    let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    showAlert(
                        title: "Couldn\u{2019}t connect AI tools",
                        message: detail.isEmpty
                            ? "Try again in a moment — if it keeps happening, "
                              + "use \u{201C}Send Feedback\u{201D} from the menu bar."
                            : detail
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
