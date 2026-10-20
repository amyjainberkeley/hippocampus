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
        /// Today's first-day card says `connectRecentWork` (SPEC 9, row 52).
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

        // MARK: Today (SPEC 3.1, SPEC-DELTA 5)

        /// The legend's words that aren't the sidebar's: the day strip's six
        /// kinds are Code, Documents, Conversations, Web Pages, Calls and Other.
        public static let calls = "Calls"
        public static let other = "Other"

        /// The card after a gap: "Where you left off · Yesterday at 6:12 PM".
        public static func leftOff(_ when: String) -> String {
            "Where you left off \u{00B7} \(when)"
        }

        /// When the card's session was: "Today at 2:35 PM", "Yesterday at
        /// 6:12 PM", "Friday at 6:12 PM", "Oct 2 at 6:12 PM".
        public static func at(_ day: String, _ time: String) -> String {
            "\(day) at \(time)"
        }

        public static let yesterday = "Yesterday"

        /// The day's section and, on the right, its span ("9:05 AM – 2:41 PM").
        public static let yourDay = "Your day"
        /// Today with nothing saved yet this morning.
        public static let todayNothingYet = "Nothing saved yet today. Your day fills in here as you work."
        public static let lookedUpToday = "Looked up today"
        /// Opens Looked Up.
        public static let all = "All"

        /// Under the card on a morning: Working On items from the last day of
        /// use not opened today. "Also from yesterday:", "Also from Friday:".
        public static func alsoFrom(_ day: String) -> String {
            "Also from \(day):"
        }

        /// The card's ⋯ menu, and its VoiceOver name.
        public static let more = "More"
        /// The card's ⋯ menu: everything saved in the session's time.
        public static func forgetSession(_ range: String) -> String {
            "Forget \(range)\u{2026}"
        }

        /// The card for VoiceOver: "Now, since 2:12 PM: Trailhead pricing v3, Figma and Notes".
        public static func cardLabel(_ moment: String, title: String, apps: [String]) -> String {
            let names = ListFormatter.localizedString(byJoining: apps)
            return names.isEmpty ? "\(moment): \(title)" : "\(moment): \(title), \(names)"
        }

        /// A length on Today: "36 min", "1 hr, 5 min", as the system writes it.
        public static func minutes(_ us: Int64, locale: Locale = .autoupdatingCurrent) -> String {
            let minutes = max(1, Int((Double(max(0, us)) / 60_000_000).rounded()))
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute]
            formatter.unitsStyle = .short
            formatter.zeroFormattingBehavior = .dropAll
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = locale
            formatter.calendar = calendar
            return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
        }

        /// An app and its time on a card: "VS Code 9 min".
        public static func appMinutes(_ app: String, _ length: String) -> String {
            "\(app) \(length)"
        }

        // The first day.

        /// Paused on the first day.
        public static let firstDayPausedBody = "Your day fills in here when you resume. It stays on this Mac."
        /// A permission off on the first day; the banner above names it.
        public static let firstDayPermissionBody =
            "Your day fills in here once the permission is back on. It stays on this Mac."
        /// Opens AI Tools in Preferences, where tools are connected.
        public static let connect = "Connect\u{2026}"
        public static let connectRecentWork = "Claude Code and Codex can start with your recent work."
        /// "Saved so far: 6 moments." with the newest under it.
        public static func savedSoFar(_ count: UInt64) -> String {
            count == 1 ? "Saved so far: 1 moment." : "Saved so far: \(count.formatted()) moments."
        }

        public static let seeThemInHistory = "See Them in History"

        // The calendar, offered once (SPEC-DELTA 5).

        public static let showCalendarLine = "Show your calendar on Today."
        public static let showCalendar = "Show Calendar"
        /// A calendar bar over the strip, for VoiceOver and its tooltip.
        public static func calendarItem(_ title: String, time: String) -> String {
            "\(title), \(time), from your calendar"
        }

        /// A screenshot, for VoiceOver: "Screenshot: Checkout tax rounding, 2:31 PM".
        public static func screenshotLabel(_ title: String, time: String) -> String {
            "Screenshot: \(title), \(time)"
        }
    }
}
