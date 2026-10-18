import Foundation

// The words on Overview (RULINGS W5 to W7, I11, V; spec-copy S4.11). The
// Right now card's caption and buttons, "What your AI starts with", "Connect",
// "Show in History" and the writer caption are shared with other places and
// live in `UserFacingCopy` itself. `OverviewCopyTests` holds every string
// here to the style rules.

public extension UserFacingCopy {
    enum Overview {
        public static let loading = "Loading\u{2026}"
        public static let dayUnavailable = "Couldn\u{2019}t load this day"
        public static let tryAgain = "Try Again"
        public static let previousDay = "Previous day"
        public static let nextDay = "Next day"
        public static let today = "Today"

        /// Today, with nothing saved (RULINGS W7).
        public static let todayEmpty = "Your day fills in as you work. It stays on this Mac."
        /// Another day, with nothing saved (RULINGS W7).
        public static let pastDayEmpty = "Nothing saved on this day."
        /// Hovering time with nothing saved on the strip (RULINGS W6).
        public static let nothingSaved = "Nothing saved"

        // The first day of the person's memory, before its first session:
        // where they land after setup (Oct 18).

        /// Over the first day while Hippocampus is remembering.
        public static let firstDayTitle = "Your memory starts now."
        public static let firstDayBody = "Your day fills in here as you work. It stays on this Mac."
        /// The first day while Hippocampus is not remembering: off, paused or
        /// waiting for a permission. The sidebar's footer says the same.
        public static let firstDayOffTitle = "Hippocampus isn\u{2019}t remembering right now."
        public static let firstDayOffBody = "Your day fills in here once it is. It stays on this Mac."
        /// Opens Preferences, where remembering is turned on.
        public static let openPreferences = "Open Preferences"

        /// The first thing to try: "Press Shift twice in any app to ask about
        /// something you saw." `phrase` is the Ask key as the app names it;
        /// empty when nothing opens Ask.
        public static func firstDayAsk(_ phrase: String) -> String {
            phrase.isEmpty
                ? "Choose a key for Ask in Preferences."
                : "\(phrase) in any app to ask about something you saw."
        }

        /// The mark for now on the first day's strip, for VoiceOver.
        public static let now = "Now"

        /// Under the Right now card when no AI tool starts its sessions with
        /// what Hippocampus knows (RULINGS W5, onboarding product critique 4).
        public static let connectLine = "Claude Code and Codex can start with what you\u{2019}re working on."
        /// "What your AI starts with", with nothing to send yet.
        public static let aiKnowsNothingYet = "Nothing yet. A session is added a few minutes after it ends."
        /// Unfolds every line a connected AI is given, and folds them again.
        public static let showAll = "Show All"
        public static let showLess = "Show Less"

        /// A session's hover text: "Pricing page copy · 9:05 – 9:34 AM".
        public static func sessionHelp(title: String, time: String) -> String {
            "\(title) \u{00B7} \(time)"
        }

        /// A session that held more than one kind of work.
        public static func mostly(_ first: String, some second: String) -> String {
            "Mostly \(first), some \(second)"
        }

        /// One app of a session with its time in front: "Notes · 19m".
        public static func appTime(_ app: String, _ duration: String) -> String {
            "\(app) \u{00B7} \(duration)"
        }

        /// The session's length after its time: "9:05 – 9:34 AM · 29m".
        public static func timeAndLength(_ time: String, _ length: String) -> String {
            "\(time) \u{00B7} \(length)"
        }

        /// The disclosure over what a model wrote about a session (RULINGS W4).
        public static let noticedTitle = "What Hippocampus noticed"
        /// Above a session's search chips, and the day's searches.
        public static let lookedUp = "You looked up"
        /// After "Copy for your AI" put a session on the clipboard.
        public static let copied = "Copied"
        public static let couldNotCopy = "Couldn\u{2019}t copy. Try again."
        /// Closes the day's searches.
        public static let hide = "Hide"
        /// The day's account, behind one disclosure (RULINGS I11, V).
        public static let summaryTitle = "Summary"
        /// Help on the "Active …" fact: what the word measures (overview
        /// contract section 9, insights product critique 2).
        public static let activeHelp = "Active means you typed, clicked or scrolled in the last minute."

        /// One line under the day when the model cannot write: everything
        /// else on Overview works without it.
        public static func modelLine(_ reason: ModelUnavailableReason) -> String {
            switch reason {
            case .appleIntelligenceOff:
                "Apple Intelligence is off. New sessions are named after their windows."
            case .deviceNotEligible:
                "This Mac can\u{2019}t run Apple Intelligence. Sessions are named after their windows."
            case .modelNotReady:
                "Apple Intelligence is getting ready. New sessions are named after their windows."
            case .needsAModel:
                "Summaries need Apple Intelligence or your own model. New sessions are named after their windows."
            case .notAvailable:
                "Apple Intelligence isn\u{2019}t available. New sessions are named after their windows."
            }
        }

        /// The strip's accessibility label.
        public static let stripLabel = "Sessions of the day"
        /// The legend's accessibility hint.
        public static let legendHint = "Shows only this kind of work"
    }
}
