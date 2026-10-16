import Foundation

/// What Hippocampus gives a connected AI without being asked, and what an AI
/// can look up when it asks (contract `what-is-sent.md`, RULINGS I7 and I12).
///
/// The You page and the Right now card take these facts from here and from
/// nowhere else, so their captions say what the agent does. A source-contract
/// test (`WhatIsSentContractTests`) holds every value to the Rust lines that
/// decide what is sent (`apps/agent/src/understanding/query.rs`,
/// `apps/agent/src/context_packet.rs`): changing one side alone fails it.
public enum WhatIsSent {
    /// "Recent work": the newest noted sessions sent, at most this many.
    public static let recentWorkLines = 4
    /// "Recent work" reaches back this many hours.
    public static let recentWorkHours = 12
    /// Things about the person sent with each session, at most this many.
    public static let aboutYouLines = 6
    /// Below this the agent sends nothing it inferred to any AI, unless the
    /// person confirmed it. Above it a thing still goes only once three
    /// moments on two days show it (`apps/agent/src/understanding/sending.rs`).
    public static let aboutYouMinConfidence = 0.75
    /// The most recently updated things the six are chosen from.
    public static let aboutYouCandidates = 60
    /// Things matching an AI's task that go first, at most this many.
    public static let aboutYouFocusMatches = 4
    /// A recent-work line's title is cut at this many characters.
    public static let titleChars = 80
    /// A recent-work line's detail is cut at this many characters.
    public static let detailChars = 180
    /// A statement about the person is cut at this many characters.
    public static let statementChars = 220
    /// A project or goal not seen again in this many days is "Not seen lately".
    public static let notSeenLatelyDays = 45
    /// Kinds that may be sent without being asked, in the agent's order.
    public static let sharedKinds = ["project", "goal", "habit", "preference", "skill"]
    /// Kinds an AI gets only when it looks them up.
    public static let lookUpOnlyKinds = ["relationship", "struggle"]
    /// Kinds never shown and never sent.
    public static let neverShownKinds = ["state"]
    /// The tools the context names for more, in the order it names them.
    public static let lookUpTools = ["mci_user_model", "mci_sessions", "mci_day"]

    /// System apps whose windows are never part of a session: the agent drops
    /// them before it makes sessions (`apps::is_noise`,
    /// `apps/agent/src/understanding/apps.rs`), and the window drops them from
    /// what it copies for an AI. Lower-cased, in the agent's order.
    public static let ignoredApps = [
        "com.apple.loginwindow",
        "com.apple.screensaver.engine",
        "com.apple.screensaver",
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.usernotificationcenter",
        "com.apple.spotlight",
        "com.apple.systemuiserver",
        "com.apple.securityagent",
        "com.apple.windowmanager",
        "ai.hippocampus",
    ]

    /// Whether the agent ignores `bundleId`, compared as the agent compares
    /// it: the whole id, ignoring ASCII case.
    public static func isIgnoredApp(_ bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return ignoredApps.contains(bundleId.lowercased())
    }

    /// A count as a person says it in a sentence: "four", "six", "12".
    public static func spelled(_ count: Int) -> String {
        let words = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        return (0..<words.count).contains(count) ? words[count] : String(count)
    }
}
