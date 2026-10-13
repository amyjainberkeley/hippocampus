import Foundation

/// Prompt text for each task. Kept apart from the engine so it can be read,
/// tested and tuned on its own.
///
/// The framing follows GUM (Shaikh et al., 2025): propositions are inferences
/// about the user, not restatements of the screen; reasoning comes before the
/// claim; confidence and decay are calibrated on fixed scales; and nothing
/// sensitive about anyone is recorded.
public enum Prompts {
    /// Hard cap on any single text field sent to the model. The on-device
    /// model's window is about 4,096 tokens for prompt and answer together.
    public static let maxFieldCharacters = 6_000

    public static func instructions(userName: String) -> String {
        """
        You are the understanding layer of Hippocampus, a Mac app that privately \
        remembers what its user sees and does. Everything stays on this Mac.
        The user is \(name(userName)). Other people named on screen are not the user.
        When you write to the user, say "you". When you write a claim about them, \
        start with their name. Never assume anyone's gender.
        Write plainly and specifically, using the names that appear on screen \
        (projects, products, documents, people) instead of generic words.
        Only state what the observations support. Never judge the user or their \
        day as productive, unproductive, distracted, stuck, good or bad. Give \
        advice only when asked.
        Never record passwords, codes, account or card numbers, or health, legal \
        or financial details about anyone. Leave them out entirely.
        Use short sentences. No dashes used as pauses, no semicolons, no lists of \
        adjectives. Say a thing once, and do not hedge it twice. In text meant for \
        the user, never say "the user", "observations", "signals", "captures", \
        "memories" or "sources". Say "your screen" and "earlier" instead. Give \
        times the way a clock shows them.
        """
    }

    public static func propose(_ input: ProposeInput) -> String {
        let user = name(input.userName)
        var prompt = """
        Below are observations of \(user)'s screen and activity over a stretch of \
        time: what was visible, what they searched for, and measured signals such \
        as typing, reading and switching between windows.

        Propose up to three propositions about \(user). Each must say something \
        different from the others and be useful to an assistant tomorrow: what \
        they are working on, what they are trying to achieve, how they tend to \
        work, what they prefer, what they know or are learning, who they work \
        with, or what took them several tries. Infer; do not summarize the \
        screen, and skip anything trivial. Say what they do, not what kind \
        of person they are. Leave out pauses and counts of keys, clicks and \
        scrolls. Not everything is work: watching, \
        shopping, personal errands and browsing for fun are interests or \
        states, never projects. Start each with "\(user)".

        Kinds: project (named work in progress), goal (an outcome they want), \
        state (true of them right now), habit (a repeated way of working), \
        preference (a choice they make), skill (what they know or are \
        learning), relationship (someone they work with, and how), struggle \
        (something that took them several tries).

        For each, first give the reasoning (which observations, and why), then \
        the proposition, its kind, and two scores.
        Confidence: 10 they stated it themselves on screen; 7 several \
        observations imply it; 4 one observation suggests it; 1 a guess.
        Decay: 1 a lasting trait or interest; 4 a project that runs for weeks; \
        7 a task for this week; 10 true only this hour.

        """
        if !input.known.isEmpty {
            prompt += """
            Already believed (do not repeat these; refine one only if the \
            observations change it):
            \(input.known.prefix(8).map { "- \(clip($0, 300))" }.joined(separator: "\n"))

            """
        }
        prompt += "Observations:\n\(clip(withoutInputCounts(input.observation), maxFieldCharacters))"
        return prompt
    }

    public static func relate(_ input: RelateInput) -> String {
        """
        A new proposition about the user and some stored ones. For each stored \
        proposition, say whether it is identical (the same claim, perhaps worded \
        differently), similar (about the same thing, but adding or contradicting \
        something) or unrelated.

        New: \(clip(input.proposition, 600))

        Stored:
        \(input.candidates.prefix(8).map { "\($0.id): \(clip($0.text, 400))" }.joined(separator: "\n"))
        """
    }

    public static func revise(_ input: ReviseInput) -> String {
        let user = name(input.userName)
        func render(_ draft: PropositionDraft) -> String {
            "\(clip(draft.text, 500)) (confidence \(draft.confidence)/10, decay \(draft.decay)/10; because: \(clip(draft.reasoning, 500)))"
        }
        return """
        Merge what is known about \(user) into one proposition. If the new \
        evidence agrees, keep the claim and raise confidence. If it contradicts, \
        state what is now true and lower confidence if unsure. Keep it one \
        sentence starting with "\(user)". Give the reasoning first.

        New: \(render(input.new))

        Earlier:
        \(input.old.prefix(4).map { "- \(render($0))" }.joined(separator: "\n"))
        """
    }

    public static func episode(_ input: EpisodeInput) -> String {
        let user = name(input.userName)
        return """
        Below is one session of \(user)'s work: the windows and pages on screen, \
        searches, and measured signals (typing, reading, pauses, switching). \
        Write to \(user) as "you", and refer to anyone else by name. \
        Name the activity, describe what was on the surface, and say what lay \
        beneath it: what they were trying to do. If they switched back and \
        forth between two windows or reworded a search, say that plainly. \
        Leave out pauses and counts of keys, clicks and scrolls. Do not \
        contradict the record. Do not guess at motives the record does not \
        show. If nothing notable shows, say so plainly.

        \(clip(withoutInputCounts(input.observation), maxFieldCharacters))
        """
    }

    /// An observation without the key counts and pauses the agent still
    /// writes at the end of each window's line ("…: typing for 11 min, 290
    /// keys, paused 3 min with no input. Text: …"). What was on screen,
    /// after "Text:", is left as it is.
    static func withoutInputCounts(_ observation: String) -> String {
        observation.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let end = line.range(of: ". Text: ")?.lowerBound ?? line.endIndex
            let header = line[..<end]
                .replacing(/, paused \d+ (?:min|s) with no input$/, with: "")
                .replacing(/, \d+ keys$/, with: "")
            return String(header + line[end...])
        }.joined(separator: "\n")
    }

    /// Fact lines the day's account leaves out: how often apps changed and
    /// where the day broke up. The agent still sends them.
    static let cutDayFacts = ["App switches:", "Most fragmented hour:", "No stretch of"]

    /// The day's account says only what happened that day. What Hippocampus
    /// believes about the person is left out: the small model wrote it up as
    /// the day's work.
    public static func day(_ input: DayInput) -> String {
        let user = name(input.userName)
        let facts = input.facts
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in !cutDayFacts.contains { line.hasPrefix($0) } }
            .joined(separator: "\n")
        let sessions = input.episodes.prefix(16).map { "- \(clip(session($0), 220))" }
        return """
        Write \(user)'s account of their day on the computer. Write every \
        sentence to \(user) as "you", and refer to anyone else by name. Use \
        only the facts and sessions below, and name only work listed under \
        Sessions. Say what they worked on, in order and for how long, using \
        the session titles, and what they looked up. Be specific: times, \
        durations, apps, searches. No praise, no filler. Say each thing once, \
        and do not repeat the headline in the narrative.

        Sessions:
        \(sessions.isEmpty ? "None." : sessions.joined(separator: "\n"))

        Facts:
        \(clip(facts, 2_500))
        """
    }

    public static func answer(_ input: AnswerInput) -> String {
        let user = name(input.userName)
        // The agent numbers a capture of the window in front as source 1.
        let screen = input.now.map { clip($0, 2_600) } ?? ""
        guard screen.hasPrefix("[1] ") else {
            var prompt = """
            \(user) asks: \(clip(input.question, 500))

            Answer from \(user)'s own memories below. You are speaking to \
            \(user): write "you" and "your", never "\(user)" or "they". Be \
            direct; one to four sentences. Use their words for things. If the \
            memories do not contain the answer, say what you did find instead. \
            List the numbers of the memories you used.

            Today is \(input.today).

            """
            if let now = input.now, !now.isEmpty {
                prompt += "On screen right now:\n\(clip(now, 1_200))\n\n"
            }
            if !input.propositions.isEmpty {
                prompt += "About \(user):\n\(input.propositions.prefix(6).map { "- \(clip($0, 200))" }.joined(separator: "\n"))\n\n"
            }
            prompt += "Memories:\n"
            prompt += input.memories.prefix(10).map { "[\($0.n)] \($0.when), \($0.source): \(clip($0.text, 500))" }.joined(separator: "\n")
            return prompt
        }
        // With the screen shown: it is the first source, it takes room the
        // model's small window would otherwise give to memories, and what is
        // known about the person goes last so the answer starts from what is
        // in front of them, not from their profile.
        let header = screen.dropFirst(4).prefix { $0 != "\n" }
        let text = screen.drop { $0 != "\n" }.dropFirst()
        var prompt = """
        \(user) asks: \(clip(input.question, 500))

        Source 1 is what is on \(user)'s screen right now. The others are \
        things they saw earlier. You are speaking to \(user): write "you" and \
        "your", never "\(user)" or "they". Answer in one to four sentences, \
        using their words for things. When they ask about the screen or \
        "this", answer from source 1 first. Use an earlier source only when it \
        adds to the answer. Say only what the sources say; do not guess who \
        people are. If no source holds the answer, say what you did find. \
        List the numbers of the sources you used.

        Today is \(input.today).

        [1] On screen right now, \(header):
        \(text)

        """
        if !input.memories.isEmpty {
            prompt += "\nSeen earlier:\n"
            prompt += input.memories.prefix(7).map { "[\($0.n)] \($0.when), \($0.source): \(clip($0.text, 400))" }.joined(separator: "\n")
            prompt += "\n"
        }
        if !input.propositions.isEmpty {
            prompt += "\nBackground on \(user), only if it helps:\n\(input.propositions.prefix(4).map { "- \(clip($0, 200))" }.joined(separator: "\n"))\n"
        }
        return prompt
    }

    public static func suggest(_ input: SuggestInput) -> String {
        let user = name(input.userName)
        return """
        \(user) just opened Hippocampus. Predict up to four things they most \
        likely want right now, given what is on screen, what they did recently \
        and what is known about them. Each should be something Hippocampus can \
        do from memory: find something they saw, resume earlier work, recall \
        what they looked up, or summarize. Write each title and reason to \
        \(user) as "you". Rate how likely each is wanted now, 1 to 10; only \
        rate above 6 when the evidence is direct.

        On screen:
        \(clip(input.now, 1_200))

        Recently:
        \(input.recent.prefix(8).map { "- \(clip(session($0), 200))" }.joined(separator: "\n"))

        About \(user):
        \(input.propositions.prefix(6).map { "- \(clip($0, 200))" }.joined(separator: "\n"))
        """
    }

    /// A session line ("{time} {title}: {what lay beneath}") without the
    /// placeholder the episode task writes when nothing stood out, so the
    /// model does not repeat it.
    static func session(_ line: String) -> String {
        let placeholder = ": Nothing notable."
        return line.hasSuffix(placeholder) ? String(line.dropLast(placeholder.count)) : line
    }

    static func name(_ userName: String) -> String {
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "the user" : clip(trimmed, 60)
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
