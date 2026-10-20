import HippocampusKit
import SwiftUI

/// Preferences, AI Tools (SPEC 3.8, 5.4, 5.5): which tools look things up in
/// your memory and start their sessions with your recent work, the switch
/// for each, and Disconnect, so stopping a tool is one click. Every word is
/// in `AIToolsCopy` and `HandoffCopy`.
struct SessionContextPreferencesView: View {
    let supervisor: ProcessSupervisor?
    /// Runs Connect AI Tools…, then calls back so the pane reads again.
    let connect: (@escaping () -> Void) -> Void
    /// Fixed facts for the off-screen renderer; nil reads them from disk.
    var preview: Facts?

    struct Facts {
        var connected: Set<AITool>
        var statuses: [AITool: SessionContextConfigurationStatus]
        /// The tools on this Mac; nil when every tool named above is.
        var installed: Set<AITool>?
        var chatGPTInstalled = false
        /// Codex's hook is in, and Codex hasn't run it yet.
        var codexNeedsStep = false

        init(
            connected: Set<AITool>, statuses: [AITool: SessionContextConfigurationStatus],
            installed: Set<AITool>? = nil, chatGPTInstalled: Bool = false, codexNeedsStep: Bool = false
        ) {
            self.connected = connected
            self.statuses = statuses
            self.installed = installed
            self.chatGPTInstalled = chatGPTInstalled
            self.codexNeedsStep = codexNeedsStep
        }
    }

    /// The question showing.
    enum Asking: Identifiable {
        case share(AITool)
        case disconnect(AITool)
        case disconnectAll

        var id: String {
            switch self {
            case .share(let tool): "share-\(tool.rawValue)"
            case .disconnect(let tool): "disconnect-\(tool.rawValue)"
            case .disconnectAll: "disconnect-all"
            }
        }
    }

    @State private var facts: Facts
    @State private var message: String?
    @State private var asking: Asking?

    init(supervisor: ProcessSupervisor?, connect: @escaping (@escaping () -> Void) -> Void, preview: Facts? = nil) {
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
            HStack {
                Button(AIToolsCopy.connectButton) {
                    connect { Task { await refresh() } }
                }
                Spacer()
                if !facts.connected.isEmpty || facts.statuses.values.contains(.configured) {
                    Button(HandoffCopy.disconnectAllButton) { asking = .disconnectAll }
                }
            }
            Text(HandoffCopy.companyLine + " " + AIToolsCopy.whileQuit)
                .font(PreferencesStyle.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).font(PreferencesStyle.captionFont)
            }
        }
        .task { await refresh() }
        .alert(item: $asking) { asking in alert(for: asking) }
    }

    private func isConnected(_ tool: AITool) -> Bool {
        facts.connected.contains(tool) || facts.statuses[tool] == .configured
    }

    private func toolRow(_ tool: AITool) -> some View {
        let connected = isConnected(tool)
        let lookUps = facts.connected.contains(tool)
        let status = facts.statuses[tool] ?? .notConfigured
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(tool.name).font(.headline)
                Spacer()
                Text(connected ? AIToolsCopy.connected : AIToolsCopy.notConnected)
                    .font(PreferencesStyle.captionFont)
                    .foregroundStyle(.secondary)
            }
            if tool == .codex, facts.chatGPTInstalled {
                Text(HandoffCopy.chatGPTShares)
                    .font(PreferencesStyle.captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(HandoffCopy.lookUpsSwitch)
                Spacer()
                Text(lookUps ? "On" : "Off").foregroundStyle(.secondary)
            }
            Toggle(AIToolsCopy.sessionToggle, isOn: Binding(
                get: { status == .configured },
                set: { on in
                    if on { asking = .share(tool) } else { apply(tool, enabled: false) }
                }
            ))
            .disabled(!connected || status == .disabledByClient || status == .overridden)
            if let note = AIToolsCopy.status(status, for: tool) {
                Text(note)
                    .font(PreferencesStyle.captionFont)
                    .foregroundStyle(.secondary)
            }
            if tool == .codex, facts.codexNeedsStep, status == .configured {
                VStack(alignment: .leading, spacing: 2) {
                    Text(HandoffCopy.codexNeedsStep).font(PreferencesStyle.captionFont.weight(.semibold))
                    Text(HandoffCopy.codexStep)
                        .font(PreferencesStyle.captionFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if connected {
                Button(HandoffCopy.disconnectButton) { asking = .disconnect(tool) }
            }
        }
    }

    private func alert(for asking: Asking) -> Alert {
        switch asking {
        case .share(let tool):
            Alert(
                title: Text(AIToolsCopy.shareTitle(tool)),
                message: Text(AIToolsCopy.shareMessage(tool)),
                primaryButton: .default(Text(AIToolsCopy.share)) { apply(tool, enabled: true) },
                secondaryButton: .cancel(Text(AIToolsCopy.dontShare))
            )
        case .disconnect(let tool):
            Alert(
                title: Text(HandoffCopy.disconnectTitle(tool.name)),
                message: Text(HandoffCopy.disconnectMessage),
                primaryButton: .destructive(Text(HandoffCopy.disconnect)) { disconnect([tool]) },
                secondaryButton: .cancel(Text(HandoffCopy.cancel))
            )
        case .disconnectAll:
            Alert(
                title: Text(HandoffCopy.disconnectAllTitle),
                message: Text(HandoffCopy.disconnectAllMessage),
                primaryButton: .destructive(Text(HandoffCopy.disconnect)) { disconnect(AITool.allCases) },
                secondaryButton: .cancel(Text(HandoffCopy.cancel))
            )
        }
    }

    private func installer() throws -> SessionContextInstaller {
        guard let supervisor else { throw SessionContextInstallError.unsafePath }
        return try SessionContextInstaller.forApp(executableURL: Bundle.main.executableURL, dbURL: supervisor.dbPath)
    }

    private func refresh() async {
        if let preview {
            facts = preview
            return
        }
        var statuses: [AITool: SessionContextConfigurationStatus] = [:]
        var needsStep = false
        if let installer = try? installer() {
            for tool in AITool.allCases {
                statuses[tool] = try? installer.status(for: tool)
            }
            needsStep = (try? installer.codexHookStatus()) == .configured && !Self.hookRan(installer)
        }
        // Claude Code's settings file can be large: read it off the main thread.
        let environment = ProcessInfo.processInfo.environment
        let connected = await Task.detached(priority: .userInitiated) {
            AIToolRegistrations.connected(environment: environment)
        }.value
        let chatGPT = DestinationDetector.live().installed().contains { $0.tool == .chatgpt }
        facts = Facts(connected: connected, statuses: statuses, chatGPTInstalled: chatGPT, codexNeedsStep: needsStep)
    }

    /// Codex has run the hook since it last changed: its mark is newer.
    private static func hookRan(_ installer: SessionContextInstaller) -> Bool {
        func modified(_ url: URL) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        guard let ran = modified(installer.codexHookMarkURL), let installed = modified(installer.codexHooksURL) else {
            return false
        }
        return ran >= installed
    }

    private func apply(_ tool: AITool, enabled: Bool) {
        guard preview == nil else { return }
        do {
            try installer().setEnabled(enabled, for: tool)
            message = enabled ? AIToolsCopy.turnedOn(tool) : AIToolsCopy.turnedOff(tool)
        } catch {
            message = (error as? SessionContextInstallError)?.errorDescription
                ?? "Couldn’t change that tool’s settings. Try again."
        }
        Task { await refresh() }
    }

    /// Disconnect: the hooks and Codex's instruction come out first, each
    /// file as it was before Connect, then the look-up entries.
    private func disconnect(_ tools: [AITool]) {
        guard preview == nil, let supervisor else { return }
        Task {
            var failed: [AITool] = []
            if let installer = try? installer() {
                for tool in tools {
                    do { try installer.setEnabled(false, for: tool) } catch { failed.append(tool) }
                }
            }
            if let agent = supervisor.agentBinaryPath {
                let connector = AIToolConnector(agentURL: agent, baseEnvironment: supervisor.sanitizedChildEnvironment())
                let done = (try? await connector.disconnect(tools)) ?? [:]
                failed += tools.filter { done[$0] != true && !failed.contains($0) }
            } else {
                failed = tools
            }
            message = failed.isEmpty
                ? HandoffCopy.disconnected(AIToolsCopy.names(tools))
                : HandoffCopy.couldNotDisconnect(AIToolsCopy.names(failed))
            await refresh()
        }
    }
}
