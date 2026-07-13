// ChatViewModelTests.swift — pins the send/echo shape of the ⌘9 Chat
// surface STUB (cycle 8.52). We test the view model here rather than
// the SwiftUI view because RecallUIKitTests can't link the executable
// target, and because the invariants that matter for ADR-0035 review
// live on the model:
//
//   1. A user send produces exactly one user + one assistant message.
//   2. The stub response echoes the user's question verbatim so the
//      shape is legible to the CEO during ADR-0035 ratification.
//   3. Suggested prompts don't fire the query — they fill the draft.
//   4. Whitespace-only sends are no-ops.
//   5. `clear()` is a hard reset.

import XCTest
@testable import RecallUIKit

@MainActor
final class ChatViewModelTests: XCTestCase {

    // MARK: - Send

    func testSendAppendsUserAndAssistantMessages() async {
        let vm = ChatViewModel()
        XCTAssertTrue(vm.isEmpty)

        await vm.send("What did I read last week about vector databases?")

        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[0].text,
                       "What did I read last week about vector databases?")
        XCTAssertEqual(vm.messages[1].role, .assistant)
        XCTAssertFalse(vm.isEmpty)
        XCTAssertFalse(vm.isGenerating,
                       "isGenerating must reset once the stub reply is composed")
    }

    func testSendClearsDraft() async {
        let vm = ChatViewModel()
        vm.draft = "hello"
        await vm.send("hello")
        XCTAssertEqual(vm.draft, "")
    }

    func testWhitespaceOnlySendIsNoOp() async {
        let vm = ChatViewModel()
        await vm.send("   \n  ")
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertFalse(vm.isGenerating)
    }

    func testMultipleSendsGrowTranscript() async {
        let vm = ChatViewModel()
        await vm.send("first")
        await vm.send("second")
        XCTAssertEqual(vm.messages.count, 4)
        XCTAssertEqual(vm.messages.map(\.role),
                       [.user, .assistant, .user, .assistant])
    }

    // MARK: - Stub response shape

    func testStubResponseEchoesQuestion() {
        let out = ChatViewModel.stubResponse(for: "Summarize my meetings")
        XCTAssertTrue(out.contains("Summarize my meetings"),
                      "the preview reply must echo the question verbatim")
    }

    func testStubResponseNamesArrivalVersion() {
        let out = ChatViewModel.stubResponse(for: "anything")
        XCTAssertTrue(out.contains("v1.5"),
                      "the preview reply must name the arrival version")
    }

    func testStubResponseReferencesADR() {
        let out = ChatViewModel.stubResponse(for: "anything")
        XCTAssertTrue(out.contains("ADR-0035"),
                      "the preview reply must point at the substrate ADR")
    }

    func testStubResponseTrimsQuestion() {
        let out = ChatViewModel.stubResponse(for: "  hello  ")
        XCTAssertTrue(out.contains("\u{201C}hello\u{201D}"),
                      "the echoed question is trimmed of surrounding whitespace")
    }

    // MARK: - Suggested prompts

    func testFillDraftDoesNotFireQuery() {
        let vm = ChatViewModel()
        vm.fillDraft(from: .yesterdayReading)
        XCTAssertEqual(vm.draft, ChatSuggestedPrompt.yesterdayReading.rawValue)
        XCTAssertTrue(vm.messages.isEmpty,
                      "filling the draft must NOT fire a query — Raycast AI pattern")
    }

    func testAllSuggestedPromptsHaveNonEmptyLabelAndSymbol() {
        for prompt in ChatSuggestedPrompt.allCases {
            XCTAssertFalse(prompt.rawValue.isEmpty)
            XCTAssertFalse(prompt.symbol.isEmpty)
        }
    }

    func testSuggestedPromptCatalogIsStable() {
        // Snapshot pin — the CEO reviews these strings as part of the
        // ADR-0035 preview. Any change requires updating this test in
        // the same PR so the review trail is intact.
        XCTAssertEqual(
            ChatSuggestedPrompt.allCases.map(\.rawValue),
            [
                "What did I read yesterday?",
                "Summarize my meetings this week",
                "Show me the article about vector databases",
                "What was I debugging in VSCode last night?",
            ]
        )
    }

    // MARK: - Clear

    func testClearResetsEverything() async {
        let vm = ChatViewModel()
        await vm.send("first")
        vm.draft = "some draft"
        vm.clear()
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertEqual(vm.draft, "")
        XCTAssertFalse(vm.isGenerating)
    }

    // MARK: - Deep-link routing

    func testChatDeepLinkRoutes() {
        XCTAssertEqual(RecallTab.from(deepLinkValue: "chat"), .chat)
        XCTAssertEqual(RecallTab.from(deepLinkValue: "CHAT"), .chat)
    }

    func testChatTabRawValueMatchesKeybind() {
        // ⌘9 is the CEO-facing shortcut per the ADR-0035 preview brief;
        // the rawValue is the source of truth the keybind reads off.
        XCTAssertEqual(RecallTab.chat.rawValue, 9)
    }
}

@MainActor
final class ChatMessageTests: XCTestCase {
    func testMessagesWithSameFieldsAreDistinctByID() {
        // Every message gets a fresh UUID by default; two "same-text"
        // sends must not collide in the SwiftUI `Identifiable` seam.
        let a = ChatMessage(role: .user, text: "hi")
        let b = ChatMessage(role: .user, text: "hi")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a, b)
    }

    func testExplicitIDAllowsRoundtrip() {
        let id = UUID()
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let m = ChatMessage(id: id, role: .assistant, text: "hey", timestamp: ts)
        XCTAssertEqual(m.id, id)
        XCTAssertEqual(m.role, .assistant)
        XCTAssertEqual(m.text, "hey")
        XCTAssertEqual(m.timestamp, ts)
    }
}
