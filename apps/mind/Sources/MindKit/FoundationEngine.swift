#if canImport(FoundationModels) && !MIND_NO_FOUNDATION_MODELS
import Foundation
import FoundationModels

// Apple's on-device model, on macOS 26 only. Everything here is marked
// `@available(macOS 26.0, *)` so the binary still runs on macOS 14, where
// `EngineChoice` uses a model server on this Mac instead.

// Guided-generation shapes. Property order is generation order: reasoning is
// produced before the claim it supports. `Schemas.swift` holds the same
// shapes for a model server; a test keeps the two the same.

@available(macOS 26.0, *)
@Generable
enum GKind: String {
    case project, goal, state, habit, preference, skill, relationship, struggle
}

@available(macOS 26.0, *)
@Generable
struct GProposition {
    @Guide(description: "Which observations support this and why")
    var reasoning: String
    @Guide(description: "One sentence about the user, starting with their name and never using he or she")
    var text: String
    @Guide(description: "What the proposition is about")
    var kind: GKind
    @Guide(description: "Confidence: 10 stated by them on screen, 7 implied by several observations, 4 suggested by one, 1 a guess", .range(1...10))
    var confidence: Int
    @Guide(description: "Decay: 1 lasting trait, 4 a project for weeks, 7 a task this week, 10 true only this hour", .range(1...10))
    var decay: Int
}

@available(macOS 26.0, *)
@Generable
struct GPropositions {
    @Guide(description: "Up to three distinct propositions", .maximumCount(3))
    var propositions: [GProposition]
}

@available(macOS 26.0, *)
@Generable
enum GRelationKind: String { case identical, similar, unrelated }

@available(macOS 26.0, *)
@Generable
struct GRelation {
    @Guide(description: "The stored proposition's number")
    var id: Int
    var relation: GRelationKind
}

@available(macOS 26.0, *)
@Generable
struct GRelations {
    var relations: [GRelation]
}

@available(macOS 26.0, *)
@Generable
struct GEpisode {
    @Guide(description: "Three to seven words naming the activity, using names from the observations")
    var title: String
    @Guide(description: "Two sentences, to the user as 'you', on what was on screen and what you did there, with no pauses or counts")
    var surface: String
    @Guide(description: "Under 40 words, to the user as 'you', on what you were trying to do, or 'Nothing notable.'")
    var beneath: String
}

// No advice: the day's account says what happened. `DayOutput` still carries
// an empty `suggestion` for the agent. The insights are a second request
// that sees no sessions (`Prompts.dayFacts`).
@available(macOS 26.0, *)
@Generable
struct GDay {
    @Guide(description: "One sentence naming the day's main work, with no judgement")
    var headline: String
    @Guide(description: "One to four short sentences to the user as 'you', adding detail the headline does not have")
    var narrative: String
}

@available(macOS 26.0, *)
@Generable
struct GDayFacts {
    @Guide(description: "Up to three short sentences to the user as 'you', each restating a different fact as written", .maximumCount(3))
    var insights: [String]
}

@available(macOS 26.0, *)
@Generable
struct GAnswer {
    @Guide(description: "The answer, one to four sentences, from the memories only")
    var answer: String
    @Guide(description: "Numbers of the memories the answer uses")
    var sources: [Int]
}

@available(macOS 26.0, *)
@Generable
struct GSuggestion {
    @Guide(description: "Short title under eight words, naming the thing from the observations")
    var title: String
    @Guide(description: "One sentence to the user as 'you' that starts with what you were doing, so you can see why this is suggested")
    var why: String
    @Guide(description: "How likely the user wants this right now", .range(1...10))
    var usefulness: Int
}

@available(macOS 26.0, *)
@Generable
struct GSuggestions {
    @Guide(description: "Up to four suggestions", .maximumCount(4))
    var suggestions: [GSuggestion]
}

@available(macOS 26.0, *)
@Generable
struct GCaptionLine {
    @Guide(description: "The moment's number")
    var n: Int
    @Guide(description: "Three to eight words on what the moment was about, starting with a verb ending in -ing, in words from that moment's title and text")
    var caption: String
}

@available(macOS 26.0, *)
@Generable
struct GCaptions {
    @Guide(description: "One caption for each moment", .maximumCount(8))
    var captions: [GCaptionLine]
}

/// Apple's on-device language model.
@available(macOS 26.0, *)
public struct FoundationEngine: MindEngine {
    public init() {}

    public var label: String { "apple-foundation-models" }

    public func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "apple_intelligence_off"
        case .unavailable(.deviceNotEligible):
            return "device_not_eligible"
        case .unavailable(.modelNotReady):
            return "model_not_ready"
        case .unavailable:
            return "unavailable"
        }
    }

    /// Load the model ahead of the first request.
    public func prewarm() {
        LanguageModelSession(instructions: Prompts.instructions(userName: "")).prewarm()
    }

    /// A reply cut off at `maximumResponseTokens` does not decode, and fails.
    private func generate<T: Generable>(
        _ type: T.Type,
        userName: String,
        prompt: String,
        temperature: Double = 0.3,
        maximumResponseTokens: Int? = nil
    ) async throws -> T {
        let session = LanguageModelSession(instructions: Prompts.instructions(userName: userName))
        do {
            let response = try await session.respond(
                to: prompt,
                generating: type,
                options: GenerationOptions(temperature: temperature, maximumResponseTokens: maximumResponseTokens)
            )
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: throw MindError.contextTooLong
            case .guardrailViolation, .refusal: throw MindError.refused
            case .assetsUnavailable: throw MindError.unavailable
            default: throw MindError.failed
            }
        }
    }

    public func propose(_ input: ProposeInput) async throws -> ProposeOutput {
        let result = try await generate(GPropositions.self, userName: input.userName, prompt: Prompts.propose(input))
        return ProposeOutput(propositions: result.propositions.map(draft))
    }

    public func relate(_ input: RelateInput) async throws -> RelateOutput {
        let result = try await generate(GRelations.self, userName: "", prompt: Prompts.relate(input), temperature: 0)
        let known = Set(input.candidates.map(\.id))
        return RelateOutput(relations: result.relations.filter { known.contains($0.id) }.map {
            Relation(id: $0.id, relation: RelationKind(rawValue: $0.relation.rawValue) ?? .unrelated)
        })
    }

    public func revise(_ input: ReviseInput) async throws -> PropositionDraft {
        draft(try await generate(GProposition.self, userName: input.userName, prompt: Prompts.revise(input)))
    }

    public func episode(_ input: EpisodeInput) async throws -> EpisodeOutput {
        let result = try await generate(GEpisode.self, userName: input.userName, prompt: Prompts.episode(input))
        return EpisodeOutput(title: result.title, surface: result.surface, beneath: result.beneath)
    }

    /// The account is asked for up to three times. On a day with little in
    /// it, the model can repeat one sentence until its window is full, about
    /// 50 s; cut off at 300 tokens, that reply fails in seconds. An account
    /// that states a length is asked for again too (`DayReply`).
    public func day(_ input: DayInput) async throws -> DayOutput {
        let prompt = Prompts.day(input)
        for _ in 1...3 {
            let written: GDay
            do {
                written = try await generate(GDay.self, userName: input.userName, prompt: prompt,
                                             temperature: 0.4, maximumResponseTokens: 300)
            } catch MindError.failed {
                continue
            }
            guard let account = DayReply.account(headline: written.headline, narrative: written.narrative, shown: prompt) else { continue }
            // Insights are optional, so the account stands without them.
            let facts = try? await generate(GDayFacts.self, userName: input.userName, prompt: Prompts.dayFacts(input),
                                            maximumResponseTokens: 300)
            return DayOutput(headline: account.headline, narrative: account.narrative,
                             insights: DayReply.insights(facts?.insights ?? [], facts: Prompts.dayFactLines(input.facts)))
        }
        throw MindError.failed
    }

    public func answer(_ input: AnswerInput) async throws -> AnswerOutput {
        let result = try await generate(GAnswer.self, userName: input.userName, prompt: Prompts.answer(input), temperature: 0.2)
        let valid = Set(input.memories.map(\.n))
        return AnswerOutput(answer: result.answer, sources: result.sources.filter(valid.contains))
    }

    public func suggest(_ input: SuggestInput) async throws -> SuggestOutput {
        let result = try await generate(GSuggestions.self, userName: input.userName, prompt: Prompts.suggest(input))
        return SuggestOutput(suggestions: result.suggestions.map {
            SuggestionItem(title: $0.title, why: $0.why, usefulness: min(10, max(1, $0.usefulness)))
        })
    }

    public func caption(_ input: CaptionInput) async throws -> CaptionOutput {
        let input = CaptionInputs.bounded(input, textCharacters: 600)
        guard !input.moments.isEmpty else { return CaptionOutput(captions: []) }
        let result = try await generate(GCaptions.self, userName: "", prompt: Prompts.caption(input), temperature: 0.2,
                                        maximumResponseTokens: 40 * input.moments.count + 40)
        return CaptionInputs.answered(result.captions.map { CaptionLine(n: $0.n, caption: $0.caption) }, for: input)
    }

    private func draft(_ g: GProposition) -> PropositionDraft {
        PropositionDraft(text: g.text, reasoning: g.reasoning, kind: g.kind.rawValue,
                         confidence: min(10, max(1, g.confidence)), decay: min(10, max(1, g.decay)))
    }
}
#endif
