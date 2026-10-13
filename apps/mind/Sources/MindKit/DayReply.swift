import Foundation

/// What the model wrote for a day, held to the lengths the facts state.
///
/// The account (headline and narrative) is written with no totals in view
/// (`Prompts.day`), so a length in it that its sessions and searches do not
/// hold was worked out from clock times or made up ("You worked on the
/// invoice list in SwiftUI for 20 minutes"), and the account is asked for
/// again. An insight may state only lengths the facts state: "1 h 5 min" was
/// once said back as "one hour and fifty minutes".
enum DayReply {
    /// The account, each sentence said once, or nil when it states a length
    /// that what it was `shown` does not.
    static func account(headline: String, narrative: String, shown: String) -> (headline: String, narrative: String)? {
        guard Set(minutes(in: headline + "\n" + narrative)).isSubset(of: minutes(in: shown)) else { return nil }
        var said = Set<String>()
        let once = sentences(narrative).filter { said.insert($0.lowercased().trimmingCharacters(in: .punctuationCharacters)).inserted }
        return (capitalizingYou(headline), capitalizingYou(once.joined(separator: " ")))
    }

    /// The insights that state only lengths the facts state.
    static func insights(_ insights: [String], facts: [String]) -> [String] {
        let stated = Set(minutes(in: facts.joined(separator: "\n")))
        return insights.filter { Set(minutes(in: $0)).isSubset(of: stated) }.map(capitalizingYou)
    }

    /// Each length in `text`, in minutes: "5 h 30 min", "1 hour and 5
    /// minutes", "an hour", "forty-five minutes". A length in seconds is -1
    /// and a vague one ("a few minutes", "you spent the day") is 0, which no
    /// fact states.
    static func minutes(in text: String) -> [Int] {
        let digits = text.lowercased()
            .replacing("half an hour", with: "30 minutes")
            .replacing(/\b(?:a few|a couple of|several)\s+(?=hours?\b|minutes?\b)/, with: "0 ")
            .replacing(/\b(?:spen[dt]s?|spending)\s+(?:the|your|all)(?:\s+whole)?\s+(?:day|morning|afternoon|evening)\b|\ball\s+day\b|\b(?:first|second|last)\s+half\s+of\s+(?:the|your)\s+day\b/, with: "0 minutes")
            .replacing(/\b[a-z]+(?:-[a-z]+)?\b/) { numbers[String($0.output)].map(String.init) ?? String($0.output) }
        let length = /\b(\d+(?:\.\d+)?)\s*(?:hours?|hrs?|h)\b(?:,?\s*(?:and\s+)?(\d+)\s*(?:minutes?|mins?|m)\b)?|\b(\d+)\s*(?:minutes?|mins?|m)\b|\b(\d+)\s*(?:seconds?|secs?)\b/
        return digits.matches(of: length).compactMap { match in
            let (_, hours, andMinutes, minutes, seconds) = match.output
            if seconds != nil { return -1 }
            if let hours { return Int((Double(hours) ?? 0) * 60) + (andMinutes.flatMap { Int($0) } ?? 0) }
            return minutes.flatMap { Int($0) }
        }
    }

    /// Number words a length is written with, as digits.
    private static let numbers: [String: Int] = {
        let ones = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        let teens = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        var numbers = ["a": 1, "an": 1]
        for (index, word) in ones.enumerated() { numbers[word] = index + 1 }
        for (index, word) in teens.enumerated() { numbers[word] = index + 10 }
        for (index, tens) in ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"].enumerated() {
            numbers[tens] = (index + 2) * 10
            for (one, word) in ones.enumerated() { numbers["\(tens)-\(word)"] = (index + 2) * 10 + one + 1 }
        }
        return numbers
    }()

    /// Sentences end at ".", "!" or "?" before a space, so "2.1" stays whole.
    static func sentences(_ text: String) -> [String] {
        text.matches(of: /(?s)\S.*?(?:[.!?]+(?=\s|$)|$)/).map { String($0.output) }
    }

    /// The model sometimes starts a sentence with the guides' lowercase "you".
    static func capitalizingYou(_ text: String) -> String {
        text.replacing(/(^|[.!?]\s+)you/) { $0.output.1 + "You" }
    }
}
