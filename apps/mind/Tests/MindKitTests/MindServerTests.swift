import Foundation
import XCTest
@testable import MindKit

private struct FakeEngine: MindEngine {
    var reason: String?
    var failWith: MindError?

    func unavailableReason() -> String? { reason }
    func propose(_ input: ProposeInput) async throws -> ProposeOutput {
        if let failWith { throw failWith }
        return ProposeOutput(propositions: [
            PropositionDraft(text: "\(input.userName) is pricing a team plan", reasoning: "searched it", kind: "project", confidence: 7, decay: 4),
        ])
    }
    func relate(_ input: RelateInput) async throws -> RelateOutput {
        RelateOutput(relations: input.candidates.map { Relation(id: $0.id, relation: .similar) })
    }
    func revise(_ input: ReviseInput) async throws -> PropositionDraft { input.new }
    func episode(_ input: EpisodeInput) async throws -> EpisodeOutput {
        EpisodeOutput(title: "Pricing", surface: "Read docs.", beneath: "Nothing notable.")
    }
    func day(_ input: DayInput) async throws -> DayOutput {
        DayOutput(headline: "h", narrative: "n", insights: ["a", "b", "c"], suggestion: "s")
    }
    func answer(_ input: AnswerInput) async throws -> AnswerOutput {
        AnswerOutput(answer: "On Tuesday.", sources: [1])
    }
    func suggest(_ input: SuggestInput) async throws -> SuggestOutput {
        SuggestOutput(suggestions: [SuggestionItem(title: "Resume", why: "w", usefulness: 8)])
    }
}

final class MindServerTests: XCTestCase {
    private func object(_ data: Data) throws -> [String: Any] {
        XCTAssertEqual(data.last, 0x0A, "every reply is one line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func request(_ id: Int, _ task: String, _ input: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": id, "task": task, "input": input])
    }

    func testReadyLineReportsAvailability() throws {
        XCTAssertEqual(try object(MindServer(engine: FakeEngine()).readyLine())["available"] as? Bool, true)
        let off = try object(MindServer(engine: FakeEngine(reason: "apple_intelligence_off")).readyLine())
        XCTAssertEqual(off["available"] as? Bool, false)
        XCTAssertEqual(off["reason"] as? String, "apple_intelligence_off")
    }

    func testProposeRoundTripsWithSnakeCaseInput() async throws {
        let reply = try object(await MindServer(engine: FakeEngine()).handle(
            try request(3, "propose", ["user_name": "Amy", "observation": "searched pricing", "known": []])))
        XCTAssertEqual(reply["id"] as? Int, 3)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let output = try XCTUnwrap(reply["output"] as? [String: Any])
        let first = try XCTUnwrap((output["propositions"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["text"] as? String, "Sam is pricing a team plan")
        XCTAssertEqual(first["confidence"] as? Int, 7)
    }

    func testEveryTaskAnswers() async throws {
        let server = MindServer(engine: FakeEngine())
        let inputs: [(String, [String: Any])] = [
            ("relate", ["proposition": "p", "candidates": [["id": 4, "text": "q"]]]),
            ("revise", ["user_name": "A", "new": ["text": "t", "reasoning": "r", "kind": "state", "confidence": 5, "decay": 5], "old": []]),
            ("episode", ["user_name": "A", "observation": "o"]),
            ("day", ["user_name": "A", "facts": "f", "episodes": [], "propositions": []]),
            ("answer", ["user_name": "A", "question": "q", "memories": [["n": 1, "when": "w", "source": "s", "text": "t"]], "propositions": [], "today": "Friday"]),
            ("suggest", ["user_name": "A", "now": "n", "recent": [], "propositions": []]),
        ]
        for (index, (task, input)) in inputs.enumerated() {
            let reply = try object(await server.handle(try request(index, task, input)))
            XCTAssertEqual(reply["ok"] as? Bool, true, task)
            XCTAssertEqual(reply["id"] as? Int, index, task)
        }
    }

    func testFailuresBecomeCodedReplies() async throws {
        let bad = try object(await MindServer(engine: FakeEngine()).handle(Data("not json".utf8)))
        XCTAssertEqual(bad["error"] as? String, "bad_request")
        let wrongShape = try object(await MindServer(engine: FakeEngine()).handle(try request(1, "propose", ["nope": 1])))
        XCTAssertEqual(wrongShape["error"] as? String, "bad_request")
        let off = try object(await MindServer(engine: FakeEngine(reason: "x")).handle(
            try request(2, "episode", ["user_name": "A", "observation": "o"])))
        XCTAssertEqual(off["error"] as? String, "unavailable")
        let long = try object(await MindServer(engine: FakeEngine(failWith: .contextTooLong)).handle(
            try request(5, "propose", ["user_name": "A", "observation": "o", "known": []])))
        XCTAssertEqual(long["error"] as? String, "context_too_long")
        XCTAssertEqual(long["id"] as? Int, 5)
    }

    func testPromptsFrameTheUserAndBoundInput() {
        let prompt = Prompts.propose(ProposeInput(userName: "Amy", observation: String(repeating: "x", count: 20_000), known: ["Amy writes Rust"]))
        XCTAssertTrue(prompt.contains("Start each with \"Amy\""))
        XCTAssertTrue(prompt.contains("- Amy writes Rust"))
        XCTAssertLessThan(prompt.count, 8_000, "the observation is clipped to fit the model's window")
        XCTAssertTrue(Prompts.instructions(userName: "").contains("The user is the user."))
        XCTAssertTrue(Prompts.instructions(userName: "Amy").contains("Other people named on screen are not the user"))
    }
}

/// Live probe: real Foundation Models on a realistic observation. Prints the
/// output for review. Run with MCI_LIVE_MIND=1.
final class FoundationEngineLiveProbe: XCTestCase {
    func testLiveTasks() async throws {
        guard ProcessInfo.processInfo.environment["MCI_LIVE_MIND"] == "1" else {
            throw XCTSkip("set MCI_LIVE_MIND=1")
        }
        let engine = FoundationEngine()
        if let reason = engine.unavailableReason() { throw XCTSkip("model unavailable: \(reason)") }
        let observation = """
        14:02–14:09 Google Chrome — "Pricing | Stripe Documentation" (stripe.com/docs/billing/subscriptions/pricing): read for 6 min (scrolling, no typing). Text: Per-seat pricing. Tiered pricing. Volume pricing charges the same price per unit…
        14:03 searched Google: "stripe per seat vs tiered pricing"
        14:05 searched Google: "team plan pricing saas 2026"
        14:09–14:16 Notes — "Launch plan": typed steadily (310 keys). Text: Beta ships to 40 design partners on Oct 21. Owner: Maya. Open question: Team plan price before the beta?
        14:16–14:24 Slack — "#pricing": read, switched back and forth with Notes 5 times. Text: Ravi: Let's land Team at $18 a seat, billed annually. Maya: Agreed, I'll update the pricing page today.
        14:24–14:31 Notes — "Launch plan": paused 3 min with no input, then typed "Team: $18/seat annual".
        """
        let start = Date()
        let proposed = try await engine.propose(ProposeInput(userName: "Amy", observation: observation, known: []))
        print("PROPOSE (\(String(format: "%.1f", Date().timeIntervalSince(start)))s)")
        for p in proposed.propositions { print(" -", p.kind, p.confidence, p.decay, p.text, "|", p.reasoning) }
        XCTAssertFalse(proposed.propositions.isEmpty)
        let episode = try await engine.episode(EpisodeInput(userName: "Amy", observation: observation))
        print("EPISODE", episode.title, "|", episode.surface, "|", episode.beneath)
        let answer = try await engine.answer(AnswerInput(
            userName: "Amy", question: "what did we decide for team pricing?", now: nil,
            memories: [Memory(n: 1, when: "Tue 2:16 PM", source: "Slack #pricing", text: "Ravi: Let's land Team at $18 a seat, billed annually. Maya: Agreed."),
                       Memory(n: 2, when: "Tue 2:09 PM", source: "Notes Launch plan", text: "Open question: Team plan price before the beta?")],
            propositions: proposed.propositions.map(\.text), today: "Friday, October 10"))
        print("ANSWER", answer.answer, answer.sources)
        XCTAssertTrue(answer.answer.contains("18"))
    }
}
