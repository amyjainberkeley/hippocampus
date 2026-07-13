// ChatViewModel.swift — pure logic + state for the ⌘9 Chat surface
// STUB (cycle 8.52). Lives in RecallUIKit so `RecallUIKitTests` can
// exercise the send/echo flow headlessly without linking the executable
// or spinning up a SwiftUI scene.
//
// # Scope
//
// This is a UI-only preview per ADR-0035 (`docs/decisions/0035-v2-p12-
// chat-surface-anylanguagemodel.md`, Status: Proposed 2026-07-13). No
// on-device LLM (Qwen3-4B MLX) is loaded, no `AnyLanguageModel`
// dependency is added, no network I/O happens. The view model exists
// so the CEO can see the intended shape of the future V2-P12 chat
// experience — a concrete artifact for the ADR-0035 ratification pass.
//
// Every "assistant" reply is a canned placeholder response that:
//   1. Echoes the user's question verbatim (so the shape is visible).
//   2. States that grounded answers land in v1.5 via local RAG.
//   3. Links to ADR-0035 for the "how" (the substrate decision).
//
// # Contract (do not break without CTO + CEO sign-off)
//
// - No network I/O. Sendable. Fully synchronous logic; the async
//   `send` seam exists so the future implementation can slot into the
//   same call site without churn at the view layer.
// - The prompt-chip catalog is stable — snapshot tests pin it.
// - `stubResponse(for:)` is a pure function so tests can pin the exact
//   copy the user sees during the preview period.

import Combine
import Foundation

// MARK: - Model

/// A single chat message in the transcript. Mirrors the shape we expect
/// `foundation-models-utilities`'s transcript primitive to expose in
/// V2-P12 — id + role + text + timestamp — so swapping the stub for the
/// real backend at Phase 7 PR 18 is a data-source swap, not a view
/// rewrite.
public struct ChatMessage: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable, Hashable {
        case user
        case assistant
        /// Reserved for future system-prompt injection (Skills API in
        /// `foundation-models-utilities`). Not rendered in the stub;
        /// present so ADR-0035's transcript shape is expressible.
        case system
    }

    public let id: UUID
    public let role: Role
    public let text: String
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

// MARK: - Prompt chips

/// Suggested-prompt catalog surfaced above the input field on empty
/// state (Raycast AI pattern from the cycle-8.45 peer study §4.3). The
/// four entries are the canonical MCI examples of the shape the V2-P12
/// chat surface will support once grounded on the brain.
public enum ChatSuggestedPrompt: String, CaseIterable, Sendable, Identifiable {
    case yesterdayReading = "What did I read yesterday?"
    case meetingsThisWeek = "Summarize my meetings this week"
    case findArticle = "Show me the article about vector databases"
    case codeContext = "What was I debugging in VSCode last night?"

    public var id: String { rawValue }

    /// SF Symbol accompanying the chip. Purely decorative; the label
    /// text is the primary affordance.
    public var symbol: String {
        switch self {
        case .yesterdayReading: return "book"
        case .meetingsThisWeek: return "calendar"
        case .findArticle:      return "doc.text.magnifyingglass"
        case .codeContext:      return "chevron.left.forwardslash.chevron.right"
        }
    }
}

// MARK: - View model

/// Owns the message transcript + input-field state for the Chat tab.
/// `@MainActor` so `@Published` writes on the UI thread are guaranteed
/// safe; the send seam is `async` so the future MLX-Swift generate call
/// can slot in without touching the view.
@MainActor
public final class ChatViewModel: ObservableObject {
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public var draft: String = ""
    @Published public private(set) var isGenerating: Bool = false

    public init(messages: [ChatMessage] = []) {
        self.messages = messages
    }

    /// True when the transcript has no messages yet — the empty-state
    /// welcome + suggested prompts render off this flag.
    public var isEmpty: Bool { messages.isEmpty }

    /// Fires a user message into the transcript and appends the stub
    /// assistant reply. Returns without doing anything if `text` is
    /// whitespace-only. Idempotent w.r.t. `isGenerating` — the flag is
    /// briefly true while the (currently synchronous) stub response is
    /// composed, matching the async-generate shape the real
    /// implementation will have.
    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userMessage = ChatMessage(role: .user, text: trimmed)
        messages.append(userMessage)
        draft = ""
        isGenerating = true

        // Small artificial latency so the "generating" state is
        // perceivable during dogfood review. Kept tiny (80ms) so tests
        // don't drag. Real generate at Phase 7 will replace this.
        try? await Task.sleep(nanoseconds: 80_000_000)

        let reply = ChatMessage(
            role: .assistant,
            text: Self.stubResponse(for: trimmed)
        )
        messages.append(reply)
        isGenerating = false
    }

    /// Fills the draft field from a suggested prompt without sending.
    /// The user still hits ⏎ / clicks Send — matches the Raycast AI
    /// "chip fills the field, doesn't fire the query" affordance.
    public func fillDraft(from prompt: ChatSuggestedPrompt) {
        draft = prompt.rawValue
    }

    /// Clears the transcript. Used by tests + the "New chat" affordance
    /// registered in the Action Panel.
    public func clear() {
        messages.removeAll()
        draft = ""
        isGenerating = false
    }

    // MARK: - Stub response

    /// Pure function that returns the canned "coming in v1.5" reply for
    /// a given user question. Kept static so tests can pin exact copy
    /// without instantiating the view model.
    ///
    /// The copy deliberately:
    ///   - Echoes the user's question so the shape is visible.
    ///   - States the arrival version (v1.5).
    ///   - Names Qwen3-4B + local RAG so the CEO can see the substrate.
    ///   - Points at ADR-0035 for the "how" (the substrate decision).
    public static func stubResponse(for question: String) -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            Chat with your memory arrives in v1.5. Your question was: \
            \u{201C}\(trimmed)\u{201D}. In the shipped version, this \
            response will be a natural-language answer grounded in your \
            captures via a local Qwen3-4B RAG pass — no cloud, no \
            network. See ADR-0035 for the substrate decision.
            """
    }
}
