import HippocampusKit
import SwiftUI

struct SessionContextPreferencesView: View {
    @ObservedObject var supervisor: ProcessSupervisor
    @State private var claudeStatus = "Not checked"
    @State private var codexStatus = "Not checked"
    @State private var message: String?
    @State private var connecting = false
    @State private var consentClient: Client?

    private enum Client: String, Identifiable {
        case claude = "Claude Code", codex = "Codex"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesStyle.sectionSpacing) {
            Text("AI Context").font(PreferencesStyle.sectionTitleFont)
            Text("Memory shared with an AI client may be sent to its model provider and retained in its session history. Hippocampus adds no network transmission.")
                .font(PreferencesStyle.captionFont)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude Code").font(.headline)
                Text(claudeStatus).font(PreferencesStyle.captionFont)
                Text("Local session hook: startup, resume, clear, and compaction. Configuration does not verify delivery; client policy can disable hooks.")
                    .font(PreferencesStyle.captionFont).foregroundStyle(.secondary)
                HStack {
                    Button { consentClient = .claude } label: {
                        Label("Enable Session Context", systemImage: "link.badge.plus")
                    }
                    Button { apply(.claude, enabled: false) } label: {
                        Label("Remove", systemImage: "link.badge.minus")
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Codex").font(.headline)
                Text(codexStatus).font(PreferencesStyle.captionFont)
                Text("Persistent AGENTS.md instructions request the Hippocampus MCP tool. Requires MCP registration. Retrieval is client-directed, not a guaranteed session hook.")
                    .font(PreferencesStyle.captionFont).foregroundStyle(.secondary)
                HStack {
                    Button { consentClient = .codex } label: {
                        Label("Enable Context Instructions", systemImage: "doc.badge.plus")
                    }
                    Button { apply(.codex, enabled: false) } label: {
                        Label("Remove", systemImage: "link.badge.minus")
                    }
                }
            }
            Divider()
            HStack {
                Button { registerMCP() } label: {
                    Label("Register MCP Tools", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .disabled(connecting)
                Button { refresh() } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                }
            }
            if let message {
                Text(message).font(PreferencesStyle.captionFont).textSelection(.enabled)
            }
        }
        .task { refresh() }
        .alert(item: $consentClient) { client in
            Alert(
                title: Text("Share local memory with \(client.rawValue)?"),
                message: Text(client == .claude
                    ? "Enable a user-level hook for local Claude sessions in all projects. It supplies a bounded cited packet focused on the working directory, which can include memory from other projects. Claude and its model provider may receive and retain it. No secret keys are added to settings. Restart Claude after enabling or removing."
                    : "Add user-level Codex instructions requesting a bounded cited memory packet through MCP. Codex and its model provider may receive and retain memory from any project. Tool availability, permissions, and instruction overrides still apply. Restart Codex after enabling or removing."),
                primaryButton: .default(Text("Enable")) { apply(client, enabled: true) },
                secondaryButton: .cancel()
            )
        }
    }

    private func installer() throws -> SessionContextInstaller {
        guard let executable = Bundle.main.executableURL else { throw SessionContextInstallError.unsafePath }
        let environment = ProcessInfo.processInfo.environment
        func directory(_ key: String) throws -> URL? {
            guard let path = environment[key], !path.isEmpty else { return nil }
            guard path.hasPrefix("/") else { throw SessionContextInstallError.unsafePath }
            return URL(fileURLWithPath: path)
        }
        return try SessionContextInstaller(
            homeURL: FileManager.default.homeDirectoryForCurrentUser,
            executableURL: executable, dbURL: supervisor.dbPath,
            claudeConfigURL: directory("CLAUDE_CONFIG_DIR"), codexHomeURL: directory("CODEX_HOME")
        )
    }

    private func refresh() {
        do {
            let installer = try installer()
            do { claudeStatus = label(try installer.claudeStatus()) }
            catch { claudeStatus = diagnostic(error) }
            do { codexStatus = label(try installer.codexStatus()) }
            catch { codexStatus = diagnostic(error) }
        } catch { message = diagnostic(error) }
    }

    private func apply(_ client: Client, enabled: Bool) {
        do {
            let installer = try installer()
            switch client {
            case .claude: try installer.setClaudeEnabled(enabled)
            case .codex: try installer.setCodexEnabled(enabled)
            }
            message = enabled
                ? "Configuration saved. Restart \(client.rawValue). Context delivery has not been verified."
                : "Context setup removed. Restart \(client.rawValue). Previously shared context remains in client history. MCP registration is unchanged."
        } catch { message = diagnostic(error) }
        refresh()
    }

    private func registerMCP() {
        guard let agent = supervisor.agentBinaryPath else {
            message = "The bundled agent is unavailable."
            return
        }
        connecting = true
        let environment = supervisor.sanitizedChildEnvironment()
        Task {
            defer { connecting = false }
            do {
                message = try await AIToolConnector(agentURL: agent, baseEnvironment: environment).connectAll()
                    + "\nRegistration is not proof of context delivery."
            } catch { message = "MCP registration failed. Client connection has not been verified." }
        }
    }

    private func label(_ status: SessionContextConfigurationStatus) -> String {
        switch status {
        case .notConfigured: "Not configured"
        case .configured: "Configured; context delivery not verified"
        case .disabledByClient: "Disabled in Claude settings"
        case .overridden: "Blocked by Codex AGENTS.override.md"
        }
    }

    private func diagnostic(_ error: Error) -> String {
        (error as? SessionContextInstallError)?.errorDescription
            ?? "Client settings could not be updated. No connection has been verified."
    }
}
