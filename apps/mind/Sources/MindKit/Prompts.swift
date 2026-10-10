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
        Refer to the user by name or as "they"; never assume anyone's gender.
        Write plainly and specifically, using the names that appear on screen \
        (projects, products, documents, people) instead of generic words.
        Only state what the observations support.
        Never record passwords, codes, account or card numbers, or health, legal \
        or financial details about anyone; leave them out entirely.
        """
    }

    public static func propose(_ input: ProposeInput) -> String {
        let user = name(input.userName)
        var prompt = """
        Below are observations of \(user)'s screen and activity over a stretch of \
        time: what was visible, what they searched for, and measured signals such \
        as typing, reading, pauses and switching between windows.

        Propose up to three propositions about \(user). Each must say something \
        different from the others and be useful to an assistant tomorrow: what \
        they are working on, what they are trying to achieve, how they tend to \
        work, what they prefer, what they know or are learning, who they work \
        with, or where they got stuck. Infer; do not summarize the screen, and \
        skip anything trivial. Start each with "\(user)".

        Kinds: project (named work in progress), goal (an outcome they want), \
        state (true of them right now), habit (a repeated way of working), \
        preference (a choice they make), skill (what they know or are \
        learning), relationship (someone they work with, and how), struggle \
        (where they hesitated or got stuck).

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
        prompt += "Observations:\n\(clip(input.observation, maxFieldCharacters))"
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
        Below is one stretch of \(user)'s work: the windows and pages on screen, \
        searches, and measured signals (typing, reading, pauses, switching). \
        Write to \(user) as "you", and refer to anyone else by name. \
        Name the activity, describe what was on the surface, and say what lay \
        beneath it: what you were trying to do and where attention went. \
        Mention hesitation or being stuck only when a signal shows it (a pause, \
        repeated switching, repeated or reworded searches, an error on screen), \
        and name that signal. Do not contradict the record: if they paused and \
        then finished, say that. Do not guess at motives the record does not \
        show. If nothing notable shows, say so plainly.

        \(clip(input.observation, maxFieldCharacters))
        """
    }

    public static func day(_ input: DayInput) -> String {
        let user = name(input.userName)
        return """
        Write \(user)'s account of their day on the computer, addressed to them \
        as "you"; refer to anyone else by name. Use only the facts below. Say what work got done, where focus \
        held and where it broke, what they looked up, and where they seemed to \
        hesitate. Be specific (name the work, the times, the durations). No \
        praise, no filler.

        Measured:
        \(clip(input.facts, 2_500))

        Stretches of work:
        \(input.episodes.prefix(16).map { "- \(clip($0, 220))" }.joined(separator: "\n"))

        What Hippocampus understands about \(user):
        \(input.propositions.prefix(8).map { "- \(clip($0, 200))" }.joined(separator: "\n"))
        """
    }

    public static func answer(_ input: AnswerInput) -> String {
        let user = name(input.userName)
        var prompt = """
        \(user) asks: \(clip(input.question, 500))

        Answer from \(user)'s own memories below. Be direct; one to four \
        sentences. Use their words for things. If the memories do not contain \
        the answer, say what you did find instead. List the numbers of the \
        memories you used.

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

    public static func suggest(_ input: SuggestInput) -> String {
        let user = name(input.userName)
        return """
        \(user) just opened Hippocampus. Predict up to four things they most \
        likely want right now, given what is on screen, what they did recently \
        and what is known about them. Each should be something Hippocampus can \
        do from memory: find something they saw, resume earlier work, recall \
        what they looked up, or summarize. Rate how likely each is wanted now, \
        1 to 10; only rate above 6 when the evidence is direct.

        On screen:
        \(clip(input.now, 1_200))

        Recently:
        \(input.recent.prefix(8).map { "- \(clip($0, 200))" }.joined(separator: "\n"))

        About \(user):
        \(input.propositions.prefix(6).map { "- \(clip($0, 200))" }.joined(separator: "\n"))
        """
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
