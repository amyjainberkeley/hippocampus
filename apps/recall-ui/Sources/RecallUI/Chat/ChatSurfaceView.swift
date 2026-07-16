// ChatSurfaceView.swift — ⌘9 Chat surface STUB (cycle 8.52).
//
// UI-only preview of the future V2-P12 chat-with-your-memory
// experience per ADR-0035 (`docs/decisions/0035-v2-p12-chat-surface-
// anylanguagemodel.md`, Status: Proposed 2026-07-13). Zero ML runtime,
// zero network, zero new dependencies — this file gives Amy (CEO) a
// concrete artifact to review before ratifying ADR-0035.
//
// # Shape
//
// Top-to-bottom:
//   1. "Coming soon" banner — soft accent-tinted callout naming v1.5.
//   2. Message transcript (or empty state with welcome + prompt chips).
//   3. Input row (text field + Send button).
//
// The layout mirrors ChatGPT / Claude / Raycast AI, on the MCI design
// system tokens (`MCI.Color`, `MCI.Font`, `MCI.Spacing`, `MCI.Radius`).
//
// # Guardrails
//
// - Every "assistant" reply is a static stub composed by
//   `ChatViewModel.stubResponse(for:)` — clearly framed as preview.
// - No model artifacts, no `AnyLanguageModel` dependency.
// - Send button is enabled (so the shape is testable end-to-end) but
//   the banner + reply copy both name "v1.5" so users can't mistake
//   the preview for a shipped feature.

import AppKit
import RecallUIKit
import SwiftUI

/// The ⌘9 Chat tab. Wraps a `ChatViewModel` and composes the banner /
/// transcript / input rows on the MCI design-system grid.
struct ChatSurfaceView: View {
    @StateObject var viewModel: ChatViewModel = ChatViewModel()
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            comingSoonBanner
                .padding(.horizontal, MCI.Spacing.xl)
                .padding(.top, MCI.Spacing.l)
                .padding(.bottom, MCI.Spacing.s)

            Group {
                if viewModel.isEmpty {
                    emptyState
                } else {
                    transcript
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(MCI.Color.border)
            inputRow
        }
        .background(MCI.Color.background)
        .onAppear { inputFocused = true }
    }

    // MARK: - Banner

    private var comingSoonBanner: some View {
        HStack(alignment: .top, spacing: MCI.Spacing.m) {
            Image(systemName: "sparkles")
                .foregroundStyle(MCI.Color.accent)
                .font(.system(size: 16, weight: .semibold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: MCI.Spacing.xxs) {
                Text("Chat is a preview — coming to v1.5")
                    .mciFont(.bodyStrong)
                    .foregroundStyle(MCI.Color.foreground)
                Text("Ask anything below to see the shape of the future "
                     + "experience. Real answers, grounded in your "
                     + "captures via on-device Qwen3-4B, ship in v1.5.")
                    .mciFont(.caption)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(MCI.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: MCI.Radius.l)
                .fill(MCI.Color.accentSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MCI.Radius.l)
                .stroke(MCI.Color.accentDim.opacity(0.4), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Chat is a preview. Coming to v1.5.")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: MCI.Spacing.xl) {
                VStack(spacing: MCI.Spacing.s) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 48, weight: .regular))
                        .foregroundStyle(MCI.Color.accent.opacity(0.85))
                        .accessibilityHidden(true)
                    Text("Ask your memory anything")
                        .mciFont(.title)
                        .foregroundStyle(MCI.Color.foreground)
                    Text("Type a question below or try one of these:")
                        .mciFont(.body)
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, MCI.Spacing.xxl)

                promptChipRow
                    .padding(.horizontal, MCI.Spacing.xl)
                Spacer(minLength: MCI.Spacing.xl)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var promptChipRow: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: MCI.Spacing.s),
                GridItem(.flexible(), spacing: MCI.Spacing.s),
            ],
            spacing: MCI.Spacing.s
        ) {
            ForEach(ChatSuggestedPrompt.allCases) { prompt in
                Button {
                    viewModel.fillDraft(from: prompt)
                    inputFocused = true
                } label: {
                    HStack(spacing: MCI.Spacing.s) {
                        Image(systemName: prompt.symbol)
                            .foregroundStyle(MCI.Color.accent)
                        Text(prompt.rawValue)
                            .mciFont(.body)
                            .foregroundStyle(MCI.Color.foreground)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, MCI.Spacing.m)
                    .padding(.vertical, MCI.Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: MCI.Radius.m)
                            .fill(MCI.Color.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: MCI.Radius.m)
                            .stroke(MCI.Color.border, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(prompt.rawValue)
                .accessibilityHint("Fills the input with this prompt")
            }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MCI.Spacing.l) {
                    ForEach(viewModel.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                    if viewModel.isGenerating {
                        typingIndicator
                            .id("typing-indicator")
                    }
                }
                .padding(.horizontal, MCI.Spacing.xl)
                .padding(.vertical, MCI.Spacing.l)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation(MCI.Motion.standard) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var typingIndicator: some View {
        HStack(spacing: MCI.Spacing.s) {
            Image(systemName: "ellipsis")
                .symbolEffect(.pulse)
                .foregroundStyle(MCI.Color.foregroundMuted)
            Text("Composing preview reply…")
                .mciFont(.caption)
                .foregroundStyle(MCI.Color.foregroundMuted)
        }
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(spacing: MCI.Spacing.s) {
            TextField(
                "Ask your memory anything…",
                text: $viewModel.draft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .focused($inputFocused)
            .mciFont(.body)
            .foregroundStyle(MCI.Color.foreground)
            .padding(.horizontal, MCI.Spacing.m)
            .padding(.vertical, MCI.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: MCI.Radius.m)
                    .fill(MCI.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MCI.Radius.m)
                    .stroke(MCI.Color.border, lineWidth: 0.5)
            )
            .onSubmit(sendCurrentDraft)

            Button(action: sendCurrentDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(
                        sendEnabled ? MCI.Color.accent : MCI.Color.foregroundMuted
                    )
            }
            .buttonStyle(.plain)
            .disabled(!sendEnabled)
            .help(sendEnabled
                  ? "Send (⏎) — returns a preview response; live in v1.5"
                  : "Type a question to send")
            .accessibilityLabel("Send message")
        }
        .padding(MCI.Spacing.m)
        .background(MCI.Color.background)
    }

    private var sendEnabled: Bool {
        !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isGenerating
    }

    private func sendCurrentDraft() {
        guard sendEnabled else { return }
        let text = viewModel.draft
        Task { await viewModel.send(text) }
    }
}

// MARK: - Message row

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: MCI.Spacing.m) {
            avatar
            VStack(alignment: .leading, spacing: MCI.Spacing.xxs) {
                Text(roleLabel)
                    .mciFont(.caption)
                    .foregroundStyle(MCI.Color.foregroundMuted)
                Text(message.text)
                    .mciFont(.body)
                    .foregroundStyle(MCI.Color.foreground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(roleLabel). \(message.text)")
    }

    private var avatar: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(iconColor)
            .frame(width: 28, height: 28)
            .background(
                Circle().fill(bgColor)
            )
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "Hippocampus (preview)"
        case .system: return "System"
        }
    }

    private var symbol: String {
        switch message.role {
        case .user: return "person.fill"
        case .assistant: return "brain.head.profile"
        case .system: return "gearshape.fill"
        }
    }

    private var iconColor: SwiftUI.Color {
        switch message.role {
        case .user: return MCI.Color.foreground
        case .assistant: return MCI.Color.accent
        case .system: return MCI.Color.foregroundMuted
        }
    }

    private var bgColor: SwiftUI.Color {
        switch message.role {
        case .user: return MCI.Color.surface
        case .assistant: return MCI.Color.accentSubtle
        case .system: return MCI.Color.surface
        }
    }
}

// MARK: - Previews

#if DEBUG  // Previews are dev-only tooling; excluded from release builds (the #Preview macro plugin ships with Xcode, not the CLI toolchain). macOS-15 SDK migration 2026-07-15.
#Preview("Empty state") {
    ChatSurfaceView()
        .frame(width: 720, height: 480)
        .preferredColorScheme(.dark)
}

#Preview("Populated") {
    let vm = ChatViewModel(messages: [
        ChatMessage(role: .user, text: "What did I read yesterday?"),
        ChatMessage(
            role: .assistant,
            text: ChatViewModel.stubResponse(
                for: "What did I read yesterday?"
            )
        ),
    ])
    return ChatSurfaceView(viewModel: vm)
        .frame(width: 720, height: 480)
        .preferredColorScheme(.dark)
}
#endif
