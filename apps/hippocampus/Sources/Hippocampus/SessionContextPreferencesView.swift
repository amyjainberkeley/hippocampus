import HippocampusKit
import SwiftUI

/// Preferences, AI Tools (RULINGS S4, product critique 5, spec-copy S4.5):
/// which tools are connected, and whether each starts its sessions with what
/// you are working on. Every word is in `AIToolsCopy`.
struct SessionContextPreferencesView: View {
    @ObservedObject var supervisor: ProcessSupervisor
    /// Runs Connect AI Tools…, then calls back so the pane reads again.
    let connect: (@escaping () -> Void) -> Void
    /// Fixed facts for the off-screen renderer; nil reads them from disk.
    var preview: Facts?

    struct Facts {
        var connected: Set<AITool>
        var statuses: [AITool: SessionContextConfigurationStatus]
    }

    @State private var facts: Facts
    @State private var message: String?
    @State private var asking: AITool?

    init(supervisor: ProcessSupervisor, connect: @escaping (@escaping () -> Void) -> Void, preview: Facts? = nil) {
        self.supervisor = supervisor
        self.connect = connect
        self.preview = preview
        _facts = State(initialValue: preview ?? Facts(connected: [], statuses: [:]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesStyle.sectionSpacing) {
            Text(AIToolsCopy.paneTitle).font(PreferencesStyle.sectionTitleFont)
            Text(AIToolsCopy.boundary)
                .font(PreferencesStyle.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(AITool.allCases) { tool in
                toolRow(tool)
                Divider()
            }
            Button(AIToolsCopy.connectButton) {
                connect { Task { await refresh() } }
            }
            Text(AIToolsCopy.whileQuit)
                .font(PreferencesStyle.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).font(PreferencesStyle.captionFont)
            }
        }
        .task { await refresh() }
        .alert(item: $asking) { tool in
            Alert(
                title: Text(AIToolsCopy.shareTitle(tool)),
                message: Text(AIToolsCopy.shareMessage(tool)),
                primaryButton: .default(Text(AIToolsCopy.share)) { apply(tool, enabled: true) },
                secondaryButton: .cancel()
            )
        }
    }

    private func toolRow(_ tool: AITool) -> some View {
        let connected = facts.connected.contains(tool)
        let status = facts.statuses[tool] ?? .notConfigured
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tool.name).font(.headline)
                Spacer()
                Text(connected ? AIToolsCopy.connected : AIToolsCopy.notConnected)
                    .font(PreferencesStyle.captionFont)
                    .foregroundStyle(.secondary)
            }
            Toggle(AIToolsCopy.sessionToggle, isOn: Binding(
                get: { status == .configured },
                set: { on in
                    if on { asking = tool } else { apply(tool, enabled: false) }
                }
            ))
            .disabled(!connected || status == .disabledByClient || status == .overridden)
            if let note = AIToolsCopy.status(status, for: tool) {
                Text(note)
                    .font(PreferencesStyle.captionFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func installer() throws -> SessionContextInstaller {
        try SessionContextInstaller.forApp(executableURL: Bundle.main.executableURL, dbURL: supervisor.dbPath)
    }

    private func refresh() async {
        if let preview {
            facts = preview
            return
        }
        var statuses: [AITool: SessionContextConfigurationStatus] = [:]
        if let installer = try? installer() {
            for tool in AITool.allCases {
                statuses[tool] = try? installer.status(for: tool)
            }
        }
        // Claude Code's settings file can be large: read it off the main thread.
        let environment = ProcessInfo.processInfo.environment
        let connected = await Task.detached(priority: .userInitiated) {
            AIToolRegistrations.connected(environment: environment)
        }.value
        facts = Facts(connected: connected, statuses: statuses)
    }

    private func apply(_ tool: AITool, enabled: Bool) {
        do {
            try installer().setEnabled(enabled, for: tool)
            message = enabled ? AIToolsCopy.turnedOn(tool) : AIToolsCopy.turnedOff(tool)
        } catch {
            message = (error as? SessionContextInstallError)?.errorDescription
                ?? "Couldn’t change that tool’s settings. Try again."
        }
        Task { await refresh() }
    }
}
