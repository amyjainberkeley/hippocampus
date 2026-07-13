import SwiftUI
import OnboardingKit

/// V2-MCP-2 — optional registration of locally-running MCP servers
/// (gchat / Slack / Linear / Notion / Asana / Todoist / Granola /
/// Otter / Figma / Apple-stock-via-MCP-bridge as of 2026-05).
///
/// Loopback-only per ADR-0001 amendment 2026-05-31. The slide writes
/// `~/Library/Application Support/MCI/mcp-servers.toml` (mode 0600,
/// uid-matched); the agent re-reads on next launch and connects one
/// HTTP+SSE transport per enabled row.
struct McpServersSlide: View {
    @EnvironmentObject var mcpVM: McpServersViewModel

    var body: some View {
        SlideContainer {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingTheme.title("Connect MCP Servers (optional)")

                Text("If you have any local MCP servers running (e.g. gchat, Slack, Linear), paste the URL here. Hippocampus only connects to localhost — never to the internet.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520, alignment: .leading)

                addServerCard

                registeredServersList

                Text("To add or remove servers later, edit ~/Library/Application Support/MCI/mcp-servers.toml — full Settings UI ships in v1.0.x. You can skip this step entirely; the registry stays empty.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 520, alignment: .leading)
            }
        }
        .task {
            await mcpVM.load()
        }
    }

    private var addServerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                title: "Add a server",
                subtitle: "Loopback only (http://127.0.0.1, http://[::1], or http://localhost)."
            )

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Name")
                    TextField("gchat", text: $mcpVM.pendingName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                }
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("URL")
                    TextField("http://127.0.0.1:7890/mcp", text: $mcpVM.pendingURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Authorization header (optional)")
                SecureField("Bearer sk-...", text: $mcpVM.pendingAuthHeader)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 380)
                Text("Sent on every request. Stored in plaintext in the TOML file (mode 0600).")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                Button("Add server") {
                    Task { _ = await mcpVM.addPending() }
                }
                .buttonStyle(.borderedProminent)
                .tint(OnboardingTheme.accentBlue)
                .disabled(addDisabled)

                if let banner = mcpVM.lastBanner {
                    Text(banner)
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Button("Dismiss") { mcpVM.dismissBanner() }
                        .buttonStyle(.borderless)
                }
            }

            if let err = mcpVM.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(err.displayMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Dismiss") { mcpVM.dismissError() }
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var registeredServersList: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: "Registered (\(mcpVM.entries.count))",
                subtitle: "Servers below will connect when the agent next launches."
            )
            if mcpVM.entries.isEmpty {
                Text("No servers registered. Add one above or click Continue to skip.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(mcpVM.entries) { entry in
                        registeredRow(entry: entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func registeredRow(entry: McpServerEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.enabled ? "checkmark.circle.fill" : "pause.circle")
                .foregroundStyle(entry.enabled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium))
                Text(entry.url)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if entry.authHeader != nil {
                Text("auth")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await mcpVM.remove(entry.name) }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this server")
            .accessibilityLabel("Remove MCP server \(entry.name)")
        }
        .padding(8)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private var addDisabled: Bool {
        mcpVM.pendingName.trimmingCharacters(in: .whitespaces).isEmpty
            || mcpVM.pendingURL.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
