import Foundation
import FoundationModels
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
        DayOutput(headline: "h", narrative: "n", insights: ["a", "b", "c"])
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

    func testWhatIsOnScreenIsSourceOneAndLeavesRoomForFewerMemories() {
        let memories = (2...12).map { Memory(n: $0, when: "Tue 3:12 PM", source: "Slack", text: String(repeating: "m", count: 480)) }
        let screen = "[1] Preview — invoice-4471.pdf\nAmount due 2,300 dollars by October 30."
        let asked = Prompts.answer(AnswerInput(userName: "Amy", question: "what am I looking at?", now: screen,
                                              memories: memories, propositions: [], today: "Monday"))
        XCTAssertTrue(asked.contains("[1] On screen right now, Preview — invoice-4471.pdf:\nAmount due 2,300 dollars by October 30."))
        XCTAssertTrue(asked.contains("Source 1 is what is on Amy's screen right now."))
        XCTAssertTrue(asked.contains("write \"you\" and \"your\""))
        XCTAssertTrue(asked.contains("[8] ") && !asked.contains("[9] "), "seven memories follow the screen")
        XCTAssertFalse(asked.contains(String(repeating: "m", count: 401)), "and each is shorter")

        // Only the app's name is known: nothing is called the screen, and all ten memories fit.
        let plain = Prompts.answer(AnswerInput(userName: "Amy", question: "team price?", now: "Using Slack",
                                              memories: memories, propositions: [], today: "Monday"))
        XCTAssertFalse(plain.contains("Source 1 is what is on"))
        XCTAssertTrue(plain.contains("On screen right now:\nUsing Slack"))
        XCTAssertTrue(plain.contains("[11] ") && !plain.contains("[12] "))
    }

    func testPromptsFrameTheUserAndBoundInput() {
        let prompt = Prompts.propose(ProposeInput(userName: "Amy", observation: String(repeating: "x", count: 20_000), known: ["Amy writes Rust"]))
        XCTAssertTrue(prompt.contains("Start each with \"Amy\""))
        XCTAssertTrue(prompt.contains("- Amy writes Rust"))
        XCTAssertLessThan(prompt.count, 8_000, "the observation is clipped to fit the model's window")
        XCTAssertTrue(Prompts.instructions(userName: "").contains("The user is the user."))
        XCTAssertTrue(Prompts.instructions(userName: "Amy").contains("Other people named on screen are not the user"))
    }

    func testTheInstructionsSetTheVoiceAndKeepTheirOwnStyle() {
        let instructions = Prompts.instructions(userName: "Amy")
        XCTAssertTrue(instructions.contains("When you write to the user, say \"you\". When you write a claim about them, start with their name. Never assume anyone's gender."))
        XCTAssertFalse(instructions.contains("by name or as \"they\""))
        XCTAssertTrue(instructions.contains("productive, unproductive, distracted, stuck, good or bad. Give advice only when asked."))
        XCTAssertTrue(instructions.contains("Use short sentences. No dashes used as pauses, no semicolons, no lists of adjectives."))
        XCTAssertTrue(instructions.contains("never say \"the user\", \"observations\", \"signals\", \"captures\", \"memories\" or \"sources\""))
        XCTAssertTrue(instructions.contains("Give times the way a clock shows them."))
        XCTAssertFalse(instructions.contains(";") || instructions.contains("—"), "they follow their own rules")
    }

    func testTheDayPromptAsksForTheWorkInOrderAndNothingCut() {
        let prompt = Prompts.day(DayInput(userName: "Amy", facts: "Active at the computer: 5 h 30 min.",
                                          episodes: ["Pricing the Team plan"], propositions: []))
        for cut in ["suggest", "advice", "tomorrow", "broke", "fragmented", "hesitat"] {
            XCTAssertFalse(prompt.lowercased().contains(cut), cut)
        }
        XCTAssertTrue(prompt.contains("addressed to them as \"you\"."))
        XCTAssertTrue(prompt.contains("Use only the facts below."))
        XCTAssertTrue(prompt.contains("Say what they worked on, in order and for how long, using the session titles, and what they looked up."))
        XCTAssertTrue(prompt.contains("Be specific: times, durations, apps, searches."))
        XCTAssertTrue(prompt.contains("Active at the computer: 5 h 30 min.\n"))
        XCTAssertTrue(prompt.contains("- Pricing the Team plan"))
    }

    func testTheDayAccountIsAskedForNoSuggestionAndAtMostThreeInsights() throws {
        let day = try properties(of: GDay.self)
        XCTAssertEqual(Set(day.keys), ["headline", "narrative", "insights"])
        XCTAssertEqual(day["insights"]?["maxItems"] as? Int, 3)
        XCTAssertNil(day["insights"]?["minItems"], "a thin day is not padded")
    }

    func testADayReplyStillCarriesTheSuggestionKeyAlwaysEmpty() async throws {
        let reply = try object(await MindServer(engine: FakeEngine()).handle(
            try request(4, "day", ["user_name": "A", "facts": "f", "episodes": [], "propositions": []])))
        let output = try XCTUnwrap(reply["output"] as? [String: Any])
        // The agent decodes all four keys.
        XCTAssertEqual(Set(output.keys), ["headline", "narrative", "insights", "suggestion"])
        XCTAssertEqual(output["suggestion"] as? String, "")
    }

    func testNoPromptForWrittenTextInvitesAJudgement() throws {
        let observation = "Notes, Launch plan: typed the beta date."
        let prompts = [
            Prompts.propose(ProposeInput(userName: "Amy", observation: observation, known: [])),
            Prompts.episode(EpisodeInput(userName: "Amy", observation: observation)),
            Prompts.day(DayInput(userName: "Amy", facts: observation, episodes: [], propositions: [])),
        ]
        for prompt in prompts {
            for word in ["stuck", "hesitat", "attention", "focus"] {
                XCTAssertFalse(prompt.lowercased().contains(word), "\(word) in: \(prompt.prefix(60))")
            }
        }
        XCTAssertTrue(prompts[0].contains("struggle (something that took them several tries)"))
        XCTAssertTrue(prompts[1].contains("If they switched back and forth between two windows or reworded a search, say that plainly."))
        XCTAssertTrue(prompts[1].contains("Leave out pauses and counts of keys, clicks and scrolls."))
        let beneath = try XCTUnwrap(properties(of: GEpisode.self)["beneath"]?["description"] as? String)
        XCTAssertTrue(beneath.contains("'Nothing notable.'"), "the sentinel the agent hides")
        for word in ["hesitat", "attention"] {
            XCTAssertFalse(beneath.lowercased().contains(word), word)
        }
    }

    func testASuggestionSaysFirstWhatYouWereDoing() throws {
        XCTAssertEqual(try properties(of: GSuggestion.self)["why"]?["description"] as? String,
                       "One sentence that starts with what the user was doing, so they can see why this is suggested")
    }

    /// What a guided-generation shape asks the model for, by property.
    private func properties<T: Generable>(of type: T.Type) throws -> [String: [String: Any]] {
        let data = try JSONEncoder().encode(T.generationSchema)
        let json = String(decoding: data, as: UTF8.self)
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], json)
        return try XCTUnwrap(schema["properties"] as? [String: [String: Any]], json)
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
