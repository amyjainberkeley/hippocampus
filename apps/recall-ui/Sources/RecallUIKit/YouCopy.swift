import Foundation

// The words on You (RULINGS I7, I8, I10, V; contract model-page.md). The
// numbers in its captions come from `WhatIsSent`, the one Swift statement of
// what a connected AI is given. `OverviewCopyTests` holds every string here
// to the style rules.

public extension UserFacingCopy {
    enum You {
        // MARK: About You (SPEC 3.7)

        /// The page's title, as the sidebar names it, and its line.
        public static let title = "About You"
        public static let lead = "What your AI tools can be told about you. Fix anything that\u{2019}s wrong."
        /// The group the agent calls "working_on": "Working On" is the sidebar's.
        public static let projectsAndGoals = "Projects and goals"
        /// Pushes the names editor.
        public static let namesYouUse = "Names You Use\u{2026}"
        /// Under the lines, while Apple Intelligence writes them.
        public static let writtenByAppleIntelligence = "Written on this Mac by Apple Intelligence."

        public static let recentWorkTitle = "Recent work"
        /// Under "Recent work": which sessions a connected AI is given.
        public static var recentWorkCaption: String {
            "Your AI gets your last \(WhatIsSent.spelled(WhatIsSent.recentWorkLines)) sessions "
                + "from the past \(WhatIsSent.recentWorkHours) hours."
        }
        public static var recentWorkEmpty: String {
            "No sessions in the past \(WhatIsSent.recentWorkHours) hours."
        }

        public static let sharedTitle = "What your AI can be told about you"
        /// RULINGS I7: the session hook sends no focus, so the six are the surest.
        public static var sharedCaption: String {
            "Up to \(WhatIsSent.spelled(WhatIsSent.aboutYouLines)) go to your AI at the start of each session, "
                + "the ones Hippocampus is surest of."
        }
        /// Once, under the heading (insights product critique 10).
        public static let exactWords = "The exact words, which is why they use your name. Fix anything that\u{2019}s wrong."
        /// Under the heading when nothing is sure enough to send yet, while
        /// other items wait under "Not sent unless your AI looks it up".
        public static let sharedEmpty = "Nothing is sent about you yet."
        public static let keptBackTitle = "Not sent unless your AI looks it up"
        public static let notSeenLatelyTitle = "Not seen lately"
        /// RULINGS I7.
        public static let footer = "Your AI can also search what you\u{2019}ve seen and look up your day when it needs to."

        public static let right = "Right"
        public static let rightHelp = "That\u{2019}s right"
        public static let forget = "Forget"
        public static let forgetHelp = "Forget this for good"
        public static let forgotten = "Forgotten."
        public static let undo = "Undo"
        public static let why = "Why"
        /// Over the model's reasoning, inside "Why".
        public static let reasoningCaption = "Its reasoning, written on this Mac"

        /// Where an item came from, in plain words (RULINGS I7).
        public static func basis(_ basis: ModelItem.Basis, daysSeen: Int) -> String {
            switch basis {
            case .confirmed: "You confirmed this"
            case .seenOnDays where daysSeen >= 2: "Seen on \(daysSeen) days"
            case .seenOnDays, .seenOnce: "Seen once"
            }
        }

        /// After the basis of a line no AI tool is given yet.
        public static let notSentYet = "Not sent yet"
        /// Once, over the lines, while any of them says `notSentYet`.
        public static let notSentLine =
            "Your AI tools aren\u{2019}t told the lines marked Not sent yet. Mark one Right to send it."

        /// A line's basis, and for a line no AI tool is given yet, that it
        /// isn't: "Seen once · Not sent yet".
        public static func basis(_ item: ModelItem) -> String {
            let said = basis(item.basis, daysSeen: item.daysSeen)
            return item.waitsToBeSent ? "\(said) \u{00B7} \(notSentYet)" : said
        }

        public static let nothingLearnedTitle = "Nothing learned yet."
        public static let nothingLearnedBody =
            "This fills in after a few sessions. It needs Apple Intelligence or a model on this Mac."
        public static let unavailableTitle = "Couldn\u{2019}t load this page"

        /// The footer line when Apple Intelligence cannot write: what is
        /// already known still shows (insights product critique 10).
        public static func modelLine(_ reason: ModelUnavailableReason) -> String {
            switch reason {
            case .appleIntelligenceOff:
                "Hippocampus learns about you with Apple Intelligence, which is off on this Mac. "
                    + "Your day and search still work."
            case .deviceNotEligible:
                "Hippocampus learns about you with Apple Intelligence, which this Mac can\u{2019}t run. "
                    + "Your day and search still work."
            case .modelNotReady:
                "Hippocampus learns about you with Apple Intelligence, which is still getting ready. "
                    + "Your day and search still work."
            case .needsAModel:
                "Hippocampus learns about you with Apple Intelligence or your own model. "
                    + "Your day and search still work."
            case .notAvailable:
                "Hippocampus learns about you with Apple Intelligence, which isn\u{2019}t available. "
                    + "Your day and search still work."
            }
        }

        public static let yourDataTitle = "Your data"
        /// Pushes what is remembered, with its deletes.
        public static let rememberedRow = "What\u{2019}s remembered, and deleting it"
        /// What a delete also takes (contract model-page.md section 5).
        public static let rememberedCaption = "Deleting a moment also forgets what was learned from it."
        /// The same name the page it opens carries.
        public static let namesRow = "Names you use"
        public static let aiToolsRow = "AI Tools"

        /// A session an item was learned in: "Oct 12, 2:02 – 2:31 PM".
        public static func sessionRow(date: String, time: String) -> String {
            "\(date), \(time)"
        }
    }
}
