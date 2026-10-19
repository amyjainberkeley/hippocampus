import Foundation
import XCTest
@testable import MindKit

private struct FakeEngine: MindEngine {
    var reason: String?
    var failWith: MindError?

    var label: String { "fake" }
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
    func caption(_ input: CaptionInput) async throws -> CaptionOutput {
        if let failWith { throw failWith }
        return CaptionOutput(captions: input.moments.map { CaptionLine(n: $0.n, caption: "Reading \($0.title)") })
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
        let on = try object(MindServer(engine: FakeEngine()).readyLine())
        XCTAssertEqual(on["available"] as? Bool, true)
        XCTAssertEqual(on["engine"] as? String, "fake", "who writes the answers")
        let off = try object(MindServer(engine: FakeEngine(reason: "apple_intelligence_off")).readyLine())
        XCTAssertEqual(off["available"] as? Bool, false)
        XCTAssertEqual(off["reason"] as? String, "apple_intelligence_off")
        XCTAssertNil(off["engine"], "no one writes them")
    }

    func testProposeRoundTripsWithSnakeCaseInput() async throws {
        let reply = try object(await MindServer(engine: FakeEngine()).handle(
            try request(3, "propose", ["user_name": "Sam", "observation": "searched pricing", "known": []])))
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
            ("caption", ["moments": [["n": 1, "app": "Chrome", "title": "Accent menu", "text": "t"]]]),
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

    func testCaptionsComeBackByNumber() async throws {
        let reply = try object(await MindServer(engine: FakeEngine()).handle(try request(9, "caption", ["moments": [
            ["n": 1, "app": "Chrome", "title": "Accent menu", "text": "Press and hold a letter key, then choose an accent."],
            ["n": 2, "app": "Figma", "title": "Checkout redesign", "text": "Hero, three columns"],
        ]])))
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let lines = try XCTUnwrap((reply["output"] as? [String: Any])?["captions"] as? [[String: Any]])
        XCTAssertEqual(lines.map { $0["n"] as? Int }, [1, 2])
        XCTAssertEqual(lines.first?["caption"] as? String, "Reading Accent menu")
    }

    func testTheCaptionPromptAsksForTheScreenNotThePerson() {
        let prompt = Prompts.caption(CaptionInput(moments: [
            CaptionMoment(n: 1, app: "Chrome", title: "How to type accents on a Mac", text: "Press and hold a letter key, then choose an accent."),
            CaptionMoment(n: 2, app: "Figma", title: "Checkout redesign", text: String(repeating: "x", count: 5_000)),
        ]))
        XCTAssertTrue(prompt.contains("1. Chrome, How to type accents on a Mac\nPress and hold a letter key, then choose an accent."))
        XCTAssertTrue(prompt.contains("verb ending in -ing"))
        XCTAssertTrue(prompt.contains("nothing it does not show"))
        XCTAssertTrue(prompt.contains("no guesses about their job, health, money, relationships or identity"))
        XCTAssertLessThan(prompt.count, 2_000, "each text is cut short")
    }

    func testCaptionAnswersKeepToTheMomentsAskedAbout() {
        let input = CaptionInput(moments: [
            CaptionMoment(n: 1, app: "Chrome", title: "t", text: "x"),
            CaptionMoment(n: 2, app: "Chrome", title: "t", text: "x"),
        ])
        let output = CaptionInputs.answered([
            CaptionLine(n: 2, caption: "Reading the plan\nand more"),
            CaptionLine(n: 2, caption: "A second line for two"),
            CaptionLine(n: 7, caption: "Nobody asked"),
            CaptionLine(n: 1, caption: "   "),
        ], for: input)
        XCTAssertEqual(output.captions, [CaptionLine(n: 2, caption: "Reading the plan")])
        let bounded = CaptionInputs.bounded(CaptionInput(moments: (1...10).map {
            CaptionMoment(n: $0, app: "App", title: String(repeating: "t", count: 300), text: String(repeating: "x", count: 900))
        }), textCharacters: 400, moments: 6)
        XCTAssertEqual(bounded.moments.count, 6)
        XCTAssertLessThanOrEqual(bounded.moments[0].text.count, 401)
        XCTAssertLessThanOrEqual(bounded.moments[0].title.count, 201)
    }

    func testWhatIsOnScreenIsSourceOneAndLeavesRoomForFewerMemories() {
        let memories = (2...12).map { Memory(n: $0, when: "Tue 3:12 PM", source: "Slack", text: String(repeating: "m", count: 480)) }
        let screen = "[1] Preview — invoice-4471.pdf\nAmount due 2,300 dollars by October 30."
        let asked = Prompts.answer(AnswerInput(userName: "Sam", question: "what am I looking at?", now: screen,
                                              memories: memories, propositions: [], today: "Monday"))
        XCTAssertTrue(asked.contains("[1] On screen right now, Preview — invoice-4471.pdf:\nAmount due 2,300 dollars by October 30."))
        XCTAssertTrue(asked.contains("Source 1 is what is on Sam's screen right now."))
        XCTAssertTrue(asked.contains("write \"you\" and \"your\""))
        XCTAssertTrue(asked.contains("[8] ") && !asked.contains("[9] "), "seven memories follow the screen")
        XCTAssertFalse(asked.contains(String(repeating: "m", count: 401)), "and each is shorter")

        // Only the app's name is known: nothing is called the screen, and all ten memories fit.
        let plain = Prompts.answer(AnswerInput(userName: "Sam", question: "team price?", now: "Using Slack",
                                              memories: memories, propositions: [], today: "Monday"))
        XCTAssertFalse(plain.contains("Source 1 is what is on"))
        XCTAssertTrue(plain.contains("On screen right now:\nUsing Slack"))
        XCTAssertTrue(plain.contains("[11] ") && !plain.contains("[12] "))
    }

    func testPromptsFrameTheUserAndBoundInput() {
        let prompt = Prompts.propose(ProposeInput(userName: "Sam", observation: String(repeating: "x", count: 20_000), known: ["Sam writes Rust"]))
        XCTAssertTrue(prompt.contains("Start each with \"Sam\""))
        XCTAssertTrue(prompt.contains("- Sam writes Rust"))
        XCTAssertLessThan(prompt.count, 8_000, "the observation is clipped to fit the model's window")
        XCTAssertTrue(Prompts.instructions(userName: "").contains("The user is the user."))
        XCTAssertTrue(Prompts.instructions(userName: "Sam").contains("Other people named on screen are not the user"))
    }

    /// Audit product-4: a mailbox's name and other people's subject lines
    /// were read as the user's own plans.
    func testProposalsReadAnInboxAndATitleAsOtherPeoplesWords() {
        let prompt = Prompts.propose(ProposeInput(
            userName: "Sam",
            observation: "09:12–09:20 Mail — \"Inbox – Northwind Travel\": reading for 8 min. Text: Harbor Ferries: spring timetable",
            known: []
        ))
        XCTAssertTrue(prompt.contains(
            "An inbox, a feed or a page of results shows what other people wrote: its senders, subjects and headlines are theirs, not Sam's plans."
        ))
        XCTAssertTrue(prompt.contains("A window's title or an app's name says where Sam was, not what they did there."))
        XCTAssertTrue(prompt.contains("Make no guess about Sam's job search, health, money or relationships."))
        XCTAssertTrue(prompt.contains("Start each with \"Sam\"."))
    }

    func testTheInstructionsSetTheVoiceAndKeepTheirOwnStyle() {
        let instructions = Prompts.instructions(userName: "Sam")
        XCTAssertTrue(instructions.contains("When you write to the user, say \"you\". When you write a claim about them, start with their name. Never assume anyone's gender."))
        XCTAssertFalse(instructions.contains("by name or as \"they\""))
        XCTAssertTrue(instructions.contains("productive, unproductive, distracted, stuck, good or bad. Give advice only when asked."))
        XCTAssertTrue(instructions.contains("Use short sentences. No dashes used as pauses, no semicolons, no lists of adjectives."))
        XCTAssertTrue(instructions.contains("never say \"the user\", \"observations\", \"signals\", \"captures\", \"memories\" or \"sources\""))
        XCTAssertTrue(instructions.contains("Give times the way a clock shows them."))
        XCTAssertFalse(instructions.contains(";") || instructions.contains("—"), "they follow their own rules")
    }

    func testTheDayPromptAsksForTheWorkInOrderAndNothingCut() {
        let input = DayInput(userName: "Sam", facts: "Active at the computer: 5 h 30 min.\nSearches (1): \"team plan pricing\".",
                             episodes: ["14:02–14:31 Pricing the Team plan"], propositions: [])
        for prompt in [Prompts.day(input), Prompts.dayFacts(input)] {
            for cut in ["suggest", "advice", "tomorrow", "broke", "fragmented", "hesitat"] {
                XCTAssertFalse(prompt.lowercased().contains(cut), cut)
            }
        }
        let prompt = Prompts.day(input)
        XCTAssertTrue(prompt.contains("Write every sentence to Sam as \"you\", and refer to anyone else by name."))
        XCTAssertTrue(prompt.contains("Use only the sessions and facts below"))
        XCTAssertTrue(prompt.contains("Say what they worked on, in order, using the session titles and their times, and what they looked up."))
        XCTAssertTrue(prompt.contains("Sessions:\n- 14:02–14:31 Pricing the Team plan\n"))
        XCTAssertTrue(prompt.hasSuffix("Facts:\nSearches (1): \"team plan pricing\"."))
    }

    func testNoSessionIsGivenALength() throws {
        // A session line holds only clock times. Asked "for how long", with
        // the day's totals beside the sessions, the model wrote "You worked
        // on the invoice list for 2 hours and 15 minutes" (the Code total)
        // and made other lengths up. The account now sees no totals, and the
        // insights that restate them see no sessions.
        let facts = [
            "Active at the computer: 5 h 30 min.",
            "First activity 09:12, last 17:40.",
            "By kind of work: Code 2 h 15 min, Writing 1 h 10 min, Communication 50 min.",
            "By app: Xcode 2 h 15 min, Notes 1 h 10 min, Slack 50 min.",
            "Focus blocks: 09:40–11:10 code in Xcode.",
            "Searches (2): \"swiftui list selection\", \"sqlite fts5 bm25\".",
        ]
        let input = DayInput(userName: "Sam", facts: facts.joined(separator: "\n"), episodes: [
            "09:40–10:10 Invoice list in SwiftUI: You were building the invoice list view.",
            "14:02–14:31 Pricing the Team plan: You were settling the Team plan price before the beta.",
        ], propositions: [])
        let account = Prompts.day(input)
        XCTAssertFalse(account.contains("how long") || account.contains("duration"))
        XCTAssertTrue(account.contains("Never give a session a length, and never work one out from times."))
        XCTAssertTrue(account.hasSuffix("Facts:\nFirst activity 09:12, last 17:40.\nSearches (2): \"swiftui list selection\", \"sqlite fts5 bm25\"."),
                      "no totals beside the sessions")
        let totals = Prompts.dayFacts(input)
        XCTAssertTrue(totals.contains("Restate them to Sam as \"you\". Keep each one as written and add nothing to it."))
        XCTAssertTrue(totals.hasSuffix("Facts:\n" + facts.joined(separator: "\n")))
        XCTAssertFalse(totals.contains("Invoice list") || totals.contains("Team plan"), "no session beside the totals")
        XCTAssertEqual(try Shape.day.properties["headline"]?["description"] as? String,
                       "One sentence naming the day's main work, with no judgement")
        XCTAssertEqual(try Shape.dayFacts.properties["insights"]?["description"] as? String,
                       "Up to three short sentences to the user as 'you', each restating a different fact as written")
    }

    func testTheDayAsksOnlyForWhatItHolds() {
        // Asked what they looked up on a day with no searches, the model
        // made searches up, once in a loop.
        let noSearches = Prompts.day(DayInput(userName: "Sam", facts: "First activity 13:10, last 15:40.", episodes: [
            "13:20–13:44 Launch notes for the beta: You were drafting the beta announcement in Notes.",
        ], propositions: []))
        XCTAssertTrue(noSearches.contains("Say what they worked on, in order, using the session titles and their times. Never"))
        XCTAssertFalse(noSearches.contains("looked up"))
        let noSessions = Prompts.day(DayInput(userName: "Sam", facts: "Searches (1): \"eurostar luggage rules\".",
                                              episodes: [], propositions: []))
        XCTAssertTrue(noSessions.contains("Sessions. Say what they looked up. Never"))
        XCTAssertFalse(noSessions.contains("worked on"))
    }

    func testTheDayPromptLeavesOutHowOftenAppsChanged() {
        // The agent still sends these lines. The account must not report
        // them back as where the day broke.
        let facts = [
            "Active at the computer: 1 h 5 min.",
            "By app: Slack 35 min, Notes 30 min.",
            "No stretch of 25 minutes or more on one kind of work.",
            "App switches: 140 (129 per active hour).",
            "Most fragmented hour: 15:00 with 48 switches.",
            "Searches (1): \"team plan pricing\".",
        ].joined(separator: "\n")
        let input = DayInput(userName: "Sam", facts: facts, episodes: [
            "13:20–13:44 Launch notes for the beta: You were drafting the beta announcement in Notes.",
        ], propositions: [])
        for prompt in [Prompts.day(input), Prompts.dayFacts(input)] {
            for cut in ["switch", "fragmented", "no stretch"] {
                XCTAssertFalse(prompt.lowercased().contains(cut), cut)
            }
        }
        XCTAssertTrue(Prompts.day(input).hasSuffix("Facts:\nSearches (1): \"team plan pricing\"."))
        XCTAssertTrue(Prompts.dayFacts(input).hasSuffix("Facts:\nActive at the computer: 1 h 5 min.\nBy app: Slack 35 min, Notes 30 min.\nSearches (1): \"team plan pricing\"."))
    }

    func testADayNamesOnlyItsOwnSessionsAndIsNotPadded() throws {
        let input = DayInput(userName: "Sam", facts: "First activity 13:10, last 15:40.", episodes: [
            "13:20–13:44 Launch notes for the beta: You were drafting the beta announcement in Notes.",
            "13:50–14:00 Invoice list: Nothing notable.",
        ], propositions: ["Sam is setting per-seat pricing for the Team plan with Priya."])
        let prompt = Prompts.day(input)
        XCTAssertTrue(prompt.contains("name only work listed under Sessions."))
        XCTAssertTrue(prompt.contains("Say each thing once"))
        for written in [prompt, Prompts.dayFacts(input)] {
            XCTAssertFalse(written.contains("per-seat"), "what Hippocampus believes about Sam is not the day's work")
        }
        XCTAssertTrue(prompt.contains("in Notes.\n- 13:50–14:00 Invoice list\n\nFacts:"), "no placeholder to repeat")
        let empty = Prompts.day(DayInput(userName: "Sam", facts: "Active at the computer: 20 min.", episodes: [], propositions: ["Sam writes Rust."]))
        XCTAssertTrue(empty.hasSuffix("Sessions:\nNone.\n\nFacts:\nNone."), empty)
        XCTAssertEqual(try Shape.day.properties["narrative"]?["description"] as? String,
                       "One to four short sentences to the user as 'you', adding detail the headline does not have")
    }

    func testTheDayAccountIsAskedForNoSuggestionAndAtMostThreeInsights() throws {
        XCTAssertEqual(Set(try Shape.day.properties.keys), ["headline", "narrative"])
        let insights = try XCTUnwrap(Shape.dayFacts.properties["insights"])
        XCTAssertEqual(insights["maxItems"] as? Int, 3)
        XCTAssertNil(insights["minItems"], "a thin day is not padded")
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
            Prompts.propose(ProposeInput(userName: "Sam", observation: observation, known: [])),
            Prompts.episode(EpisodeInput(userName: "Sam", observation: observation)),
            Prompts.day(DayInput(userName: "Sam", facts: observation, episodes: [], propositions: [])),
            Prompts.dayFacts(DayInput(userName: "Sam", facts: observation, episodes: [], propositions: [])),
        ]
        for prompt in prompts {
            for word in ["stuck", "hesitat", "attention", "focus"] {
                XCTAssertFalse(prompt.lowercased().contains(word), "\(word) in: \(prompt.prefix(60))")
            }
        }
        XCTAssertTrue(prompts[0].contains("struggle (something that took them several tries)"))
        // Claims once read "Sam is a multitasker" and "Sam is a
        // self-motivated worker who likes to research on their own".
        XCTAssertTrue(prompts[0].contains("Say what they do, not what kind of person they are."))
        XCTAssertEqual(try Shape.proposition.properties["text"]?["description"] as? String,
                       "One sentence about the user, starting with their name and never using he or she")
        // The observation carries ", 290 keys, paused 3 min with no input"
        // on window lines. Claims and session notes leave both out.
        XCTAssertTrue(prompts[0].contains("Leave out pauses and counts of keys, clicks and scrolls."))
        XCTAssertTrue(prompts[1].contains("If they switched back and forth between two windows or reworded a search, say that plainly."))
        XCTAssertTrue(prompts[1].contains("Leave out pauses and counts of keys, clicks and scrolls."))
        let episode = try Shape.episode.properties
        let surface = try XCTUnwrap(episode["surface"]?["description"] as? String)
        XCTAssertTrue(surface.hasSuffix("with no pauses or counts"), surface)
        let beneath = try XCTUnwrap(episode["beneath"]?["description"] as? String)
        XCTAssertTrue(beneath.contains("'Nothing notable.'"), "the sentinel the agent hides")
        for word in ["hesitat", "attention"] {
            XCTAssertFalse(beneath.lowercased().contains(word), word)
        }
    }

    func testClaimsAndSessionNotesSeeNoKeyCountsOrPauses() {
        // The agent ends each window's line with what the input counted.
        // Screen text after "Text:" is kept as it was, whatever it says.
        let observation = """
        14:09–14:20 Notes — "Launch plan": typing for 11 min, 290 keys, paused 3 min with no input. Text: Price, 5 keys, paused 2 min with no input
        14:20–14:28 Slack — "#pricing": reading for 8 min, paused 50 s with no input
        14:28–14:35 Notes — "Launch plan": typing for 7 min, 120 keys
        14:30 searched Google: "team plan, 4 keys"
        Signals: switched back and forth between Notes — Launch plan and Slack — #pricing 6 times.
        """
        let expected = """
        14:09–14:20 Notes — "Launch plan": typing for 11 min. Text: Price, 5 keys, paused 2 min with no input
        14:20–14:28 Slack — "#pricing": reading for 8 min
        14:28–14:35 Notes — "Launch plan": typing for 7 min
        14:30 searched Google: "team plan, 4 keys"
        Signals: switched back and forth between Notes — Launch plan and Slack — #pricing 6 times.
        """
        XCTAssertTrue(Prompts.propose(ProposeInput(userName: "Sam", observation: observation, known: [])).hasSuffix("Observations:\n" + expected))
        XCTAssertTrue(Prompts.episode(EpisodeInput(userName: "Sam", observation: observation)).hasSuffix("\n\n" + expected))
    }

    func testASuggestionSaysFirstWhatYouWereDoing() throws {
        // spec-copy S4.15 item 5, said to the person: with "what the user
        // was doing" the model wrote the reason about them by name.
        XCTAssertEqual(try Shape.suggestion.properties["why"]?["description"] as? String,
                       "One sentence to the user as 'you' that starts with what you were doing, so you can see why this is suggested")
    }

    func testSuggestionsAreWrittenToYou() {
        let prompt = Prompts.suggest(SuggestInput(userName: "Sam", now: "Notes, Launch plan", recent: [
            "11:05 Invoice list in SwiftUI: Nothing notable.",
            "14:02 Pricing the Team plan: You were settling the Team plan price.",
        ], propositions: ["Sam is building an invoicing app."]))
        XCTAssertTrue(prompt.contains("Write each title and reason to Sam as \"you\"."))
        XCTAssertTrue(prompt.contains("- 11:05 Invoice list in SwiftUI\n- 14:02 Pricing the Team plan: You were settling the Team plan price."),
                      "no placeholder to repeat")
    }
}

#if canImport(FoundationModels) && !MIND_NO_FOUNDATION_MODELS
/// Live probe: real Foundation Models on a realistic observation. Prints the
/// output for review. Run with MCI_LIVE_MIND=1.
final class FoundationEngineLiveProbe: XCTestCase {
    func testLiveTasks() async throws {
        guard ProcessInfo.processInfo.environment["MCI_LIVE_MIND"] == "1" else {
            throw XCTSkip("set MCI_LIVE_MIND=1")
        }
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        let engine = FoundationEngine()
        if let reason = engine.unavailableReason() { throw XCTSkip("model unavailable: \(reason)") }
        // The agent's line format (observe.rs `render`), made-up content.
        let observation = """
        14:02–14:09 Google Chrome — "Pricing | Stripe Documentation" (stripe.com): reading for 7 min. Text: Per-seat pricing. Tiered pricing. Volume pricing charges the same price per unit…
        14:09–14:16 Notes — "Launch plan": typing for 7 min, 310 keys. Text: Beta ships to 40 design partners on Oct 21. Owner: Maya. Open question: Team plan price before the beta?
        14:16–14:24 Slack — "#pricing": reading for 8 min. Text: Ravi: Let's land Team at $18 a seat, billed annually. Maya: Agreed, I'll update the pricing page today.
        14:24–14:31 Notes — "Launch plan": typing a little for 7 min, 40 keys, paused 3 min with no input. Text: Team: $18/seat annual
        14:03 searched Google: "stripe per seat vs tiered pricing"
        14:05 searched Google: "team plan pricing saas 2026"
        Signals: switched back and forth between Notes — Launch plan and Slack — #pricing 5 times.
        """
        let start = Date()
        let proposed = try await engine.propose(ProposeInput(userName: "Sam", observation: observation, known: []))
        print("PROPOSE (\(String(format: "%.1f", Date().timeIntervalSince(start)))s)")
        for p in proposed.propositions { print(" -", p.kind, p.confidence, p.decay, p.text, "|", p.reasoning) }
        XCTAssertFalse(proposed.propositions.isEmpty)
        let episode = try await engine.episode(EpisodeInput(userName: "Sam", observation: observation))
        print("EPISODE", episode.title, "|", episode.surface, "|", episode.beneath)
        let answer = try await engine.answer(AnswerInput(
            userName: "Sam", question: "what did we decide for team pricing?", now: nil,
            memories: [Memory(n: 1, when: "Tue 2:16 PM", source: "Slack #pricing", text: "Ravi: Let's land Team at $18 a seat, billed annually. Maya: Agreed."),
                       Memory(n: 2, when: "Tue 2:09 PM", source: "Notes Launch plan", text: "Open question: Team plan price before the beta?")],
            propositions: proposed.propositions.map(\.text), today: "Friday, October 10"))
        print("ANSWER", answer.answer, answer.sources)
        XCTAssertTrue(answer.answer.contains("18"))

        // A thin day: one session, the fact lines the account leaves out,
        // and a belief about the person that is not today's work.
        let day = try await engine.day(DayInput(userName: "Sam", facts: [
            "Active at the computer: 1 h 5 min.",
            "First activity 13:10, last 15:40.",
            "By kind of work: Communication 35 min, Writing 30 min.",
            "By app: Slack 35 min, Notes 30 min.",
            "No stretch of 25 minutes or more on one kind of work.",
            "App switches: 140 (129 per active hour).",
            "Most fragmented hour: 15:00 with 48 switches.",
        ].joined(separator: "\n"), episodes: [
            "13:20–13:44 Launch notes for the beta: You were drafting the beta announcement in Notes.",
        ], propositions: ["Sam is setting per-seat pricing for the Team plan with Priya."]))
        print("DAY", day.headline, "|", day.narrative, "|", day.insights.joined(separator: " | "))
        let written = ([day.headline, day.narrative] + day.insights).joined(separator: " ").lowercased()
        for cut in ["fragmented", "per-seat"] {
            XCTAssertFalse(written.contains(cut), cut)
        }
        // A full day. The invoice list ran 30 + 30 min and the Team plan 29,
        // which no line states, so no sentence may give either a length.
        let full = try await engine.day(DayInput(userName: "Sam", facts: [
            "Active at the computer: 5 h 30 min.",
            "First activity 09:12, last 17:40.",
            "By kind of work: Code 2 h 15 min, Writing 1 h 10 min, Communication 50 min.",
            "By app: Xcode 2 h 15 min, Notes 1 h 10 min, Slack 50 min.",
            "Focus blocks: 09:40–11:10 code in Xcode.",
            "App switches: 212 (38 per active hour).",
            "Most fragmented hour: 15:00 with 64 switches.",
            "Searches (2): \"swiftui list selection\", \"sqlite fts5 bm25\".",
        ].joined(separator: "\n"), episodes: [
            "09:40–10:10 Invoice list in SwiftUI: You were building the invoice list view.",
            "10:10–10:40 Invoice list in SwiftUI: Nothing notable.",
            "14:02–14:31 Pricing the Team plan: You were settling the Team plan price before the beta.",
        ], propositions: []))
        print("FULL DAY", full.headline, "|", full.narrative, "|", full.insights.joined(separator: " | "))
        for sentence in [full.headline] + DayReply.sentences(full.narrative) + full.insights {
            let session = ["invoice", "team plan", "pricing"].contains { sentence.lowercased().contains($0) }
            XCTAssertFalse(session && !DayReply.minutes(in: sentence).isEmpty, sentence)
        }
        let suggested = try await engine.suggest(SuggestInput(
            userName: "Sam", now: "Safari, Plans and pricing | Stripe Docs\nPer-seat pricing. Tiered pricing.",
            recent: ["14:02 Pricing the Team plan: You were settling the Team plan price before the beta.",
                     "13:20 Launch notes for the beta: You were drafting the beta announcement in Notes.",
                     "11:05 Invoice list in SwiftUI: Nothing notable."],
            propositions: ["Sam is setting per-seat pricing for the Team plan with Priya."]))
        for s in suggested.suggestions { print("SUGGEST", s.usefulness, s.title, "|", s.why) }
    }
}
#endif
