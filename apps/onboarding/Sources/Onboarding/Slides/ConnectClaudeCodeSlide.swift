import SwiftUI
import OnboardingKit
#if canImport(AppKit)
import AppKit
#endif

struct ConnectClaudeCodeSlide: View {
    @StateObject var viewModel = ConnectClaudeCodeViewModel(
        registrar: DefaultClaudeCodeRegistrar()
    )

    var body: some View {
        SlideContainer {
            VStack(spacing: 22) {
                OnboardingTheme.title("Connect Claude Code")

                Text("Hippocampus exposes 5 MCP tools to any AI agent on your Mac — Claude Code is what we use day-to-day. Ask it \"what was I doing at 2pm,\" \"find the doc I had open yesterday about embeddings,\" or \"what was that PR I reviewed Tuesday\" and it answers from your brain. Zero network — stays on this Mac.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                toolList

                stateView

                Text("Skip and connect later from the menu bar → Connect to Claude Code…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var toolList: some View {
        VStack(alignment: .leading, spacing: 4) {
            toolRow(name: "mci_recall", note: "semantic search over your captures")
            toolRow(name: "mci_events_since", note: "browse a time window")
            toolRow(name: "mci_episodes", note: "grouped work sessions")
            toolRow(name: "mci_events_by_app", note: "narrow to one app")
            toolRow(name: "mci_stats", note: "brain status + capture rate")
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 440)
    }

    private func toolRow(name: String, note: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(OnboardingTheme.accentBlue)
                .frame(width: 140, alignment: .leading)
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch viewModel.state {
        case .idle:
            Button {
                Task.detached { await viewModel.runRegister() }
            } label: {
                Label("Connect Claude Code", systemImage: "link")
                    .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(OnboardingTheme.accentBlue)
            .controlSize(.large)

        case .running:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Registering…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

        case .success(let message):
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Connected")
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }

        case .failure(let message):
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Couldn't register")
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                HStack(spacing: 10) {
                    Button("Try again") {
                        viewModel.reset()
                    }
                    .buttonStyle(.bordered)

                    Button("Copy command") {
                        copyToClipboard(viewModel.manualCommand)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
