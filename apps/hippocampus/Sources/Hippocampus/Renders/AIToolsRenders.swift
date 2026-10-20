#if DEBUG
import HippocampusKit
import SwiftUI

extension StatusPreviewRenderer {
    /// Preferences › AI Tools with Disconnect and Disconnect All
    /// (`prefs-ai-tools-*`, SPEC 5.5), from fixtures: nothing reads a real
    /// tool's settings. The questions are drawn as labelled facsimiles: an
    /// alert can't be drawn off screen.
    static var aiToolsPanes: [Pane] {
        func pane(_ name: String, _ facts: SessionContextPreferencesView.Facts) -> Pane {
            Pane(name: name, view: AnyView(
                SessionContextPreferencesView(supervisor: nil, connect: { done in done() }, preview: facts)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
            ))
        }
        return [
            pane("ai-tools-connected", .init(
                connected: [.claudeCode, .codex],
                statuses: [.claudeCode: .configured, .codex: .configured],
                chatGPTInstalled: true, codexNeedsStep: true
            )),
            pane("ai-tools-not-connected", .init(connected: [], statuses: [:])),
            pane("ai-tools-turned-off-in-claude-code", .init(
                connected: [.claudeCode],
                statuses: [.claudeCode: .disabledByClient, .codex: .notConfigured]
            )),
            Pane(name: "ai-tools-disconnect-question", view: AnyView(
                QuestionFacsimile(title: HandoffCopy.disconnectTitle("Claude Code"), message: HandoffCopy.disconnectMessage,
                                  confirm: HandoffCopy.disconnect, cancel: HandoffCopy.cancel)
            )),
            Pane(name: "ai-tools-disconnect-all-question", view: AnyView(
                QuestionFacsimile(title: HandoffCopy.disconnectAllTitle, message: HandoffCopy.disconnectAllMessage,
                                  confirm: HandoffCopy.disconnect, cancel: HandoffCopy.cancel)
            )),
            Pane(name: "ai-tools-connect-question", view: AnyView(
                QuestionFacsimile(
                    title: AIToolsCopy.connectTitle([.claudeCode, .codex]),
                    message: AIToolsCopy.connectMessage([.claudeCode, .codex], chatGPTInstalled: true),
                    confirm: HandoffCopy.connect, cancel: HandoffCopy.notNow
                )
            )),
            Pane(name: "ai-tools-session-question", view: AnyView(
                QuestionFacsimile(
                    title: AIToolsCopy.questionTitle,
                    message: AIToolsCopy.questionMessage([.claudeCode, .codex]),
                    confirm: AIToolsCopy.share, cancel: AIToolsCopy.dontShare
                )
            )),
        ]
    }
}

/// A question as macOS draws it, labelled as a facsimile: the hi mark, the
/// question, what it means, and its two buttons.
private struct QuestionFacsimile: View {
    let title: String
    let message: String
    let confirm: String
    let cancel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Facsimile of the question macOS shows")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            VStack(spacing: 12) {
                HiMarkView(style: .brand, state: .remembering)
                    .frame(height: 30)
                    .frame(width: 56, height: 56)
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) {
                    Text(confirm)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.white)
                    Text(cancel)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
                .font(.system(size: 13))
            }
            .padding(16)
            .frame(width: 260)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.15)))
            .frame(maxWidth: .infinity)
        }
        .padding(20)
    }
}
#endif
