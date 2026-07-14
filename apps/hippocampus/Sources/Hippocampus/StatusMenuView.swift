// SPDX-License-Identifier: TBD-private
import SwiftUI
import HippocampusKit

struct StatusMenuView: View {
    @ObservedObject var supervisor: ProcessSupervisor
    @ObservedObject var loginItemVM: LoginItemViewModel
    let updater: SparkleUpdaterService
    @ObservedObject var preferencesStore: PreferencesStore

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

            quickActionsSection

            if !supervisor.state.isActive && supervisor.state != .starting {
                Button("Start Recording") {
                    supervisor.start()
                }
            } else if supervisor.state.isActive {
                Button("Stop Recording") {
                    supervisor.stop()
                }
            }

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

            // Freemium tier indicator (cycle 8.48). Non-interactive
            // trust signal. See `docs/business/tier-structure.md` — in
            // v1.0 every user is on the Free tier forever; Pro is a
            // v1.5+ addition that never retroactively gates a shipped
            // feature (trust invariant #1). Rendered as a disabled
            // menu row so it visually reads as a status label rather
            // than an actionable button.
            Text("You're on Free forever")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("About Hippocampus") {
                openPreferencesWindow()
            }

            // "Learn more" — public landing page. Cotypist parity: an
            // always-visible link out to marketing / docs so a user
            // who's never opened the app before still has a discovery
            // path to features they haven't found yet. See brief §Steps
            // "Learn more — opens landing page".
            Button("Learn more") {
                if let url = URL(string: "https://hippocampus-swart.vercel.app") {
                    NSWorkspace.shared.open(url)
                }
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
        .sheet(isPresented: $showKeyWrapAudit) {
            KeyWrapAuditView(
                initialReport: currentKeyWrapReport(),
                reverify: { currentKeyWrapReport() },
                onClose: { showKeyWrapAudit = false }
            )
        }
    }

    private func currentKeyWrapReport() -> KeyWrapAuditReport {
        let keyURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MCI/dev.key")
        return KeyWrapAuditor.inspectFile(at: keyURL)
    }

    @ViewBuilder
    private var briefsMenuItem: some View {
        // Filesystem is ground truth (CEO dogfood 2026-05-26).
        // Previously this read `UserDefaults.standard.bool(forKey:
        // "MCIBriefModelDownloaded")`, but that flag survives across
        // installs / `cfprefsd` caches even after the model dir is
        // wiped — so the menu showed "Daily Briefs" toggle while the
        // model wasn't on disk. `BriefModelPresence.isQwen3Installed()`
        // checks `~/Library/Application Support/MCI/Models/
        // qwen3-1.7b-fp16/Qwen3-1.7B-FP16.mlmodelc/` directly. The
        // SwiftUI menu re-renders this body on every open, so the
        // toggle/button state stays in sync with the filesystem.
        let modelDownloaded = BriefModelPresence.isQwen3Installed()
        if modelDownloaded {
            Toggle("Daily Briefs", isOn: $briefsEnabled)
                .onChange(of: briefsEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "MCIBriefsEnabled")
                }
        } else {
            // Qwen3-1.7B FP16 Core ML model now live (PR #192). Clicking
            // surfaces the download sheet → ModelDownloadView pulls the
            // tarball from HF, SHA-verifies against
            // `HippocampusKit/Resources/models.json`, unpacks under
            // `~/Library/Application Support/MCI/Models/qwen3-1.7b-fp16/`
            // where brief_worker (apps/agent) picks it up on its next
            // 06:00 cycle or first-launch fast path.
            Button("Daily Briefs: Off — Download Model…") {
                // Open the dedicated `Window` scene (id: "model-download")
                // declared in HippocampusApp.body — NOT a SwiftUI `.sheet`,
                // which SwiftUI dismissed along with the MenuBarExtra
                // menu before the sheet could present (CEO dogfood
                // 2026-05-26 "nothing happens when I click Download
                // Model").
                openWindow(id: "model-download")
                #if canImport(AppKit)
                NSApp.activate(ignoringOtherApps: true)
                #endif
            }
            .help("Daily briefs summarize your day with Qwen3-1.7B (~2.5 GB download, runs entirely on your Mac).")
        }
    }

    /// The single source of truth the header uses; matches the dot
    /// baked into the menu-bar icon overlay so the two surfaces
    /// always agree. See `MenuBarStatus.derive` for precedence rules.
    private var menuBarStatus: MenuBarStatus {
        MenuBarStatus.derive(
            from: supervisor.state,
            tccRevokedSurface: supervisor.tccRevokedSurface
        )
    }

    /// Cotypist-style always-visible quick-action block. The six
    /// verbs a user needs at their fingertips regardless of what the
    /// current state is:
    ///
    ///   - Pause / Resume Capture  ⌘⇧P  (toggle; label flips per state)
    ///   - Open Recall Popup       ⇧⌘Space (global spotlight-style
    ///                              popup already registered by
    ///                              PR #79 — this menu item is a
    ///                              visible fallback + discovery hint)
    ///   - Show Recall Window      ⌘R
    ///   - Show Timeline           ⌘T  (⌘8 in the recall-ui window,
    ///                              but from the menu-bar the entry
    ///                              point is a distinct verb; deep-links
    ///                              to `timeline` tab via MCI_INITIAL_TAB)
    ///   - Preferences             ⌘,  (opens About/Prefs sheet)
    ///
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

        Button(paused ? "Resume Capture" : "Pause Capture") {
            toggleUserPause()
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])

        Button("Open Recall Popup") {
            supervisor.openRecallUI()
        }
        .keyboardShortcut(.space, modifiers: [.command, .shift])

        Divider()

        Button("Show Recall Window") {
            supervisor.openRecallUI()
        }
        .keyboardShortcut("r", modifiers: [.command])

        Button("Show Timeline") {
            supervisor.openRecallUI(initialTab: "timeline")
        }
        .keyboardShortcut("t", modifiers: [.command])

        Button("Preferences…") {
            openPreferencesWindow()
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()
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
        HStack(spacing: 6) {
            Circle()
                .fill(menuBarStatus.indicatorColor)
                .frame(width: 8, height: 8)
            Text(supervisor.state.statusText)
                .font(.headline)
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

    /// Open (or focus) the comprehensive Preferences window bound to
    /// the ⌘, shortcut. All dependencies were wired in
    /// `HippocampusApp.configurePreferencesController` at launch; this
    /// call is idempotent — the controller lazily creates the NSPanel
    /// on first invocation and focuses the existing window thereafter.
    private func openPreferencesWindow() {
        #if canImport(AppKit)
        PreferencesWindowController.shared.show()
        #endif
    }

}
