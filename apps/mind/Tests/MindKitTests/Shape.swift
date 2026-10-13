import Foundation
#if canImport(FoundationModels) && !MIND_NO_FOUNDATION_MODELS
import FoundationModels
#endif
@testable import MindKit

/// Each reply's shape: the JSON schema a model server is sent, and on macOS
/// 26 Foundation Models' guided-generation schema.
enum Shape: String, CaseIterable {
    case proposition, propositions, relation, relations, episode, day, dayFacts, answer, suggestion, suggestions

    var local: String {
        switch self {
        case .proposition: Schemas.proposition
        case .propositions: Schemas.propositions
        case .relation: Schemas.relation
        case .relations: Schemas.relations
        case .episode: Schemas.episode
        case .day: Schemas.day
        case .dayFacts: Schemas.dayFacts
        case .answer: Schemas.answer
        case .suggestion: Schemas.suggestion
        case .suggestions: Schemas.suggestions
        }
    }

    /// Foundation Models' schema as JSON, or nil on a Mac without it.
    var guided: Data? {
        #if canImport(FoundationModels) && !MIND_NO_FOUNDATION_MODELS
        if #available(macOS 26.0, *) {
            let schema: GenerationSchema = switch self {
            case .proposition: GProposition.generationSchema
            case .propositions: GPropositions.generationSchema
            case .relation: GRelation.generationSchema
            case .relations: GRelations.generationSchema
            case .episode: GEpisode.generationSchema
            case .day: GDay.generationSchema
            case .dayFacts: GDayFacts.generationSchema
            case .answer: GAnswer.generationSchema
            case .suggestion: GSuggestion.generationSchema
            case .suggestions: GSuggestions.generationSchema
            }
            return try? JSONEncoder().encode(schema)
        }
        #endif
        return nil
    }

    /// The schema the engine in use asks for: the guided one when there is one.
    var schema: [String: Any] {
        get throws { try Self.object(guided ?? Data(local.utf8)) }
    }

    /// What the schema in use asks for, by property.
    var properties: [String: [String: Any]] {
        get throws { (try schema["properties"] as? [String: [String: Any]]) ?? [:] }
    }

    static func object(_ data: Data) throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
