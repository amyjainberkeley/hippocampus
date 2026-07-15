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
            VStack(alignment: .leading, spacing: OnboardingDesign.Space.xl) {
                VStack(alignment: .leading, spacing: OnboardingDesign.Space.sm) {
                    SectionChip(text: "MCP Servers")
                    OnboardingDesign.TypeRamp.title("Connect MCP Servers (optional)")
                }

                OnboardingDesign.TypeRamp.body("If you have any local MCP servers running (e.g. gchat, Slack, Linear), paste the URL here. Hippocampus only connects to localhost — never to the internet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520, alignment: .leading)

                addServerCard

                registeredServersList

                OnboardingDesign.TypeRamp.footnote("To add or remove servers later, edit ~/Library/Application Support/MCI/mcp-servers.toml — full Settings UI ships in v1.0.x. You can skip this step entirely; the registry stays empty.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 520, alignment: .leading)
            }
        }
        .task {
            await mcpVM.load()
        }
    }

    private var addServerCard: some View {
        VStack(alignment: .leading, spacing: OnboardingDesign.Space.md) {
            sectionHeader(
                title: "Add a server",
                subtitle: "Loopback only (http://127.0.0.1, http://[::1], or http://localhost)."
            )

            HStack(alignment: .top, spacing: OnboardingDesign.Space.md) {
                VStack(alignment: .leading, spacing: OnboardingDesign.Space.xs + 2) {
                    fieldLabel("Name")
                    TextField("gchat", text: $mcpVM.pendingName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                }
                VStack(alignment: .leading, spacing: OnboardingDesign.Space.xs + 2) {
                    fieldLabel("URL")
                    TextField("http://127.0.0.1:7890/mcp", text: $mcpVM.pendingURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
            }

            VStack(alignment: .leading, spacing: OnboardingDesign.Space.xs + 2) {
                fieldLabel("Authorization header (optional)")
                SecureField("Bearer sk-...", text: $mcpVM.pendingAuthHeader)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 380)
                OnboardingDesign.TypeRamp.footnote("Sent on every request. Stored in plaintext in the TOML file (mode 0600).")
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: OnboardingDesign.Space.sm) {
                Button("Add server") {
                    Task { _ = await mcpVM.addPending() }
                }
                .onboardingPrimary()
                .disabled(addDisabled)

                if let banner = mcpVM.lastBanner {
                    Text(banner)
                        .font(.system(size: 11))
                        .foregroundStyle(OnboardingDesign.Palette.success)
                    Button("Dismiss") { mcpVM.dismissBanner() }
                        .onboardingText()
                }
            }

            if let err = mcpVM.lastError {
                HStack(alignment: .top, spacing: OnboardingDesign.Space.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(OnboardingDesign.Palette.attention)
                    Text(err.displayMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingDesign.Palette.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Dismiss") { mcpVM.dismissError() }
                        .onboardingText()
                }
            }
        }
        .glassCard(padding: OnboardingDesign.Space.lg)
    }

    private var registeredServersList: some View {
        VStack(alignment: .leading, spacing: OnboardingDesign.Space.sm) {
            sectionHeader(
                title: "Registered (\(mcpVM.entries.count))",
                subtitle: "Servers below will connect when the agent next launches."
            )
            if mcpVM.entries.isEmpty {
                OnboardingDesign.TypeRamp.caption("No servers registered. Add one above or click Continue to skip.")
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, OnboardingDesign.Space.xs + 2)
            } else {
                VStack(spacing: OnboardingDesign.Space.sm - 2) {
                    ForEach(mcpVM.entries) { entry in
                        registeredRow(entry: entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func registeredRow(entry: McpServerEntry) -> some View {
        HStack(spacing: OnboardingDesign.Space.md) {
            Image(systemName: entry.enabled ? "checkmark.circle.fill" : "pause.circle")
                .foregroundStyle(entry.enabled ? OnboardingDesign.Palette.success : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                Text(entry.url)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if entry.authHeader != nil {
                Text("auth")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, OnboardingDesign.Space.sm - 2)
                    .padding(.vertical, 2)
                    .background(OnboardingDesign.Palette.accentSoft, in: Capsule())
                    .foregroundStyle(OnboardingDesign.Palette.accent)
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
        .glassCard(padding: OnboardingDesign.Space.sm)
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            OnboardingDesign.TypeRamp.headline(title)
            OnboardingDesign.TypeRamp.caption(subtitle)
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
