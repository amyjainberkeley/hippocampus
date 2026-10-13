import Foundation

/// JSON schemas for a model server, one per reply. They mirror the guided-
/// generation shapes in `FoundationEngine.swift`, guide text included, and a
/// test holds the two together on macOS 26. Each is written out as text in
/// property order, because property order is generation order: reasoning
/// comes before the claim it supports.
enum Schemas {
    /// The kinds a proposition can have. Any other becomes `state`.
    static let kinds = ["project", "goal", "state", "habit", "preference", "skill", "relationship", "struggle"]

    static let proposition = object([
        ("reasoning", string("Which observations support this and why")),
        ("text", string("One sentence about the user, starting with their name and never using he or she")),
        ("kind", choice("What the proposition is about", kinds)),
        ("confidence", integer("Confidence: 10 stated by them on screen, 7 implied by several observations, 4 suggested by one, 1 a guess", 1...10)),
        ("decay", integer("Decay: 1 lasting trait, 4 a project for weeks, 7 a task this week, 10 true only this hour", 1...10)),
    ])

    static let propositions = object([
        ("propositions", array(proposition, "Up to three distinct propositions", maxItems: 3)),
    ])

    static let relation = object([
        ("id", integer("The stored proposition's number")),
        ("relation", choice(nil, ["identical", "similar", "unrelated"])),
    ])

    static let relations = object([("relations", array(relation, nil))])

    static let episode = object([
        ("title", string("Three to seven words naming the activity, using names from the observations")),
        ("surface", string("Two sentences, to the user as 'you', on what was on screen and what you did there, with no pauses or counts")),
        ("beneath", string("Under 40 words, to the user as 'you', on what you were trying to do, or 'Nothing notable.'")),
    ])

    static let day = object([
        ("headline", string("One sentence naming the day's main work, with no judgement")),
        ("narrative", string("One to four short sentences to the user as 'you', adding detail the headline does not have")),
    ])

    static let dayFacts = object([
        ("insights", array(string(nil), "Up to three short sentences to the user as 'you', each restating a different fact as written", maxItems: 3)),
    ])

    static let answer = object([
        ("answer", string("The answer, one to four sentences, from the memories only")),
        ("sources", array(integer(nil), "Numbers of the memories the answer uses")),
    ])

    static let suggestion = object([
        ("title", string("Short title under eight words, naming the thing from the observations")),
        ("why", string("One sentence to the user as 'you' that starts with what you were doing, so you can see why this is suggested")),
        ("usefulness", integer("How likely the user wants this right now", 1...10)),
    ])

    static let suggestions = object([
        ("suggestions", array(suggestion, "Up to four suggestions", maxItems: 4)),
    ])

    // MARK: Building

    private static func object(_ properties: [(String, String)]) -> String {
        let fields = properties.map { "\(quoted($0.0)):\($0.1)" }.joined(separator: ",")
        let required = properties.map { quoted($0.0) }.joined(separator: ",")
        return #"{"type":"object","properties":{"# + fields + #"},"required":["# + required + #"],"additionalProperties":false}"#
    }

    private static func string(_ description: String?) -> String {
        #"{"type":"string""# + described(description) + "}"
    }

    private static func integer(_ description: String?, _ range: ClosedRange<Int>? = nil) -> String {
        let bounds = range.map { #","minimum":\#($0.lowerBound),"maximum":\#($0.upperBound)"# } ?? ""
        return #"{"type":"integer""# + described(description) + bounds + "}"
    }

    private static func choice(_ description: String?, _ values: [String]) -> String {
        #"{"type":"string""# + described(description) + #","enum":["# + values.map(quoted).joined(separator: ",") + "]}"
    }

    private static func array(_ items: String, _ description: String?, maxItems: Int? = nil) -> String {
        let most = maxItems.map { #","maxItems":\#($0)"# } ?? ""
        return #"{"type":"array""# + described(description) + most + #","items":"# + items + "}"
    }

    private static func described(_ description: String?) -> String {
        description.map { #","description":"# + quoted($0) } ?? ""
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
