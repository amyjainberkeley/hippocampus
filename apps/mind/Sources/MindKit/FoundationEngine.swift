import Foundation
import FoundationModels

// Guided-generation shapes. Property order is generation order: reasoning is
// produced before the claim it supports.

@Generable
enum GKind: String {
    case project, goal, state, habit, preference, skill, relationship, struggle
}

@Generable
struct GProposition {
    @Guide(description: "Which observations support this and why")
    var reasoning: String
    @Guide(description: "One sentence about the user, starting with their name")
    var text: String
    @Guide(description: "What the proposition is about")
    var kind: GKind
    @Guide(description: "Confidence: 10 stated by them on screen, 7 implied by several observations, 4 suggested by one, 1 a guess", .range(1...10))
    var confidence: Int
    @Guide(description: "Decay: 1 lasting trait, 4 a project for weeks, 7 a task this week, 10 true only this hour", .range(1...10))
    var decay: Int
}

@Generable
struct GPropositions {
    @Guide(description: "Up to three distinct propositions", .maximumCount(3))
    var propositions: [GProposition]
}

@Generable
enum GRelationKind: String { case identical, similar, unrelated }

@Generable
struct GRelation {
    @Guide(description: "The stored proposition's number")
    var id: Int
    var relation: GRelationKind
}

@Generable
struct GRelations {
    var relations: [GRelation]
}

@Generable
struct GEpisode {
    @Guide(description: "Three to seven words naming the activity, using names from the observations")
    var title: String
    @Guide(description: "Two sentences, to the user as 'you', on what was on screen and what you did")
    var surface: String
    @Guide(description: "Under 40 words, to the user as 'you', on what you were trying to do, or 'Nothing notable.'")
    var beneath: String
}

// No advice: the day's account says what happened. `DayOutput` still carries
// an empty `suggestion` for the agent.
@Generable
struct GDay {
    @Guide(description: "One sentence naming the day's main work and the active time, with no judgement")
    var headline: String
    @Guide(description: "Three to five sentences to the user as 'you', adding detail the headline does not have")
    var narrative: String
    @Guide(description: "Up to three specific observations, each citing a time, a duration, an app or a search", .maximumCount(3))
    var insights: [String]
}

@Generable
struct GAnswer {
    @Guide(description: "The answer, one to four sentences, from the memories only")
    var answer: String
    @Guide(description: "Numbers of the memories the answer uses")
    var sources: [Int]
}

@Generable
struct GSuggestion {
    @Guide(description: "Short title under eight words, naming the thing from the observations")
    var title: String
    @Guide(description: "One sentence that starts with what the user was doing, so they can see why this is suggested")
    var why: String
    @Guide(description: "How likely the user wants this right now", .range(1...10))
    var usefulness: Int
}

@Generable
struct GSuggestions {
    @Guide(description: "Up to four suggestions", .maximumCount(4))
    var suggestions: [GSuggestion]
}

/// The real engine: Apple's on-device language model.
public struct FoundationEngine: MindEngine {
    public init() {}

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

    private func generate<T: Generable>(
        _ type: T.Type,
        userName: String,
        prompt: String,
        temperature: Double = 0.3
    ) async throws -> T {
        let session = LanguageModelSession(instructions: Prompts.instructions(userName: userName))
        do {
            let response = try await session.respond(
                to: prompt,
                generating: type,
                options: GenerationOptions(temperature: temperature)
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

    public func day(_ input: DayInput) async throws -> DayOutput {
        let result = try await generate(GDay.self, userName: input.userName, prompt: Prompts.day(input), temperature: 0.4)
        return DayOutput(headline: result.headline, narrative: result.narrative, insights: result.insights)
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

    private func draft(_ g: GProposition) -> PropositionDraft {
        PropositionDraft(text: g.text, reasoning: g.reasoning, kind: g.kind.rawValue,
                         confidence: min(10, max(1, g.confidence)), decay: min(10, max(1, g.decay)))
    }
}
