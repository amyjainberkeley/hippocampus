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
            VStack(spacing: OnboardingDesign.Space.xl) {
                VStack(spacing: OnboardingDesign.Space.md) {
                    SectionChip(text: "Connect")
                    OnboardingDesign.TypeRamp.title("Connect Claude Code")
                        .multilineTextAlignment(.center)
                }

                OnboardingDesign.TypeRamp.body("Hippocampus exposes 5 MCP tools to any AI agent on your Mac — Claude Code is what we use day-to-day. Ask it \"what was I doing at 2pm,\" \"find the doc I had open yesterday about embeddings,\" or \"what was that PR I reviewed Tuesday\" and it answers from your brain. Zero network — stays on this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                toolList

                stateView

                OnboardingDesign.TypeRamp.footnote("Skip and connect later from the menu bar → Connect to Claude Code…")
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var toolList: some View {
        VStack(alignment: .leading, spacing: OnboardingDesign.Space.sm) {
            toolRow(name: "mci_recall", note: "semantic search over your captures")
            toolRow(name: "mci_events_since", note: "browse a time window")
            toolRow(name: "mci_episodes", note: "grouped work sessions")
            toolRow(name: "mci_events_by_app", note: "narrow to one app")
            toolRow(name: "mci_stats", note: "brain status + capture rate")
        }
        .glassCard(padding: OnboardingDesign.Space.md)
        .frame(maxWidth: 440)
    }

    private func toolRow(name: String, note: String) -> some View {
        HStack(spacing: OnboardingDesign.Space.sm) {
            OnboardingDesign.TypeRamp.mono(name)
                .foregroundColor(OnboardingDesign.Palette.accent)
                .frame(width: 140, alignment: .leading)
            OnboardingDesign.TypeRamp.caption(note)
                .foregroundColor(.secondary)
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
            .onboardingPrimary()

        case .running:
            HStack(spacing: OnboardingDesign.Space.sm) {
                ProgressView()
                    .controlSize(.small)
                OnboardingDesign.TypeRamp.body("Registering…")
                    .foregroundStyle(.secondary)
            }

        case .success(let message):
            VStack(spacing: OnboardingDesign.Space.sm) {
                HStack(spacing: OnboardingDesign.Space.sm) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(OnboardingDesign.Palette.success)
                    OnboardingDesign.TypeRamp.headline("Connected")
                }
                OnboardingDesign.TypeRamp.caption(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }
            .glassCard(padding: OnboardingDesign.Space.lg)

        case .failure(let message):
            VStack(spacing: OnboardingDesign.Space.sm) {
                HStack(spacing: OnboardingDesign.Space.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(OnboardingDesign.Palette.attention)
                    OnboardingDesign.TypeRamp.headline("Couldn't register")
                }
                OnboardingDesign.TypeRamp.mono(message)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                HStack(spacing: OnboardingDesign.Space.md) {
                    Button("Try again") {
                        viewModel.reset()
                    }
                    .onboardingSecondary()

                    Button("Copy command") {
                        copyToClipboard(viewModel.manualCommand)
                    }
                    .onboardingSecondary()
                }
            }
            .glassCard(padding: OnboardingDesign.Space.lg)
        }
    }

    private func copyToClipboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
