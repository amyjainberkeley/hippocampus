import Foundation

/// The words of Library (SPEC 3.4, 9 and SPEC-DELTA 1): History, and its
/// lenses Documents, Code and Conversations, each History's own rows and
/// detail filtered by kind. Headers, lead lines, empty states and the
/// actions on a moment go here. Titles and buttons are Title Case,
/// sentences are sentences. Every string passes `CopyStyleValidator` and
/// `scripts/check-launch-copy.sh`.
public enum LibraryCopy {
    // MARK: The lenses

    public enum Documents {
        public static let lead = "Docs, notes, sheets and designs you worked on."
        public static let emptyTitle = "No documents yet."
        public static let emptyBody = "Docs, notes, sheets and designs you work on show up here."
    }

    public enum Code {
        public static let lead = "Projects you worked on in an editor or a terminal."
        public static let emptyTitle = "No code yet."
        public static let emptyBody = "Projects you open in an editor or a terminal show up here."
    }

    public enum Conversations {
        public static let lead = "Chats, email and AI chats you read."
        public static let emptyTitle = "No conversations yet."
        public static let emptyBody = "Chats and email you read show up here."
        // The chips under the lead line.
        public static let all = "All"
        public static let chat = "Chat"
        public static let email = "Email"
        public static let ai = "AI"
        /// A chip with nothing in it.
        public static let noChats = "No chats yet."
        public static let noEmail = "No email yet."
        public static let noAIChats = "No AI chats yet."
        /// The chips' group, for VoiceOver.
        public static let filterLabel = "Show"
    }

    /// The lead line under a lens's title.
    public static func lead(_ lens: LibraryLens) -> String {
        switch lens {
        case .documents: Documents.lead
        case .code: Code.lead
        case .conversations: Conversations.lead
        }
    }

    /// A lens with nothing in it yet: what fills it, and when.
    public static func empty(_ lens: LibraryLens) -> (title: String, body: String) {
        switch lens {
        case .documents: (Documents.emptyTitle, Documents.emptyBody)
        case .code: (Code.emptyTitle, Code.emptyBody)
        case .conversations: (Conversations.emptyTitle, Conversations.emptyBody)
        }
    }

    /// Conversations with a chip picked that has nothing in it.
    public static func emptyConversations(_ filter: ConversationFilter) -> String {
        switch filter {
        case .all: Conversations.emptyTitle
        case .chat: Conversations.noChats
        case .email: Conversations.noEmail
        case .ai: Conversations.noAIChats
        }
    }

    // MARK: Days, as Apple Notes heads them

    public static let today = "Today"
    public static let yesterday = "Yesterday"
    public static let previous7Days = "Previous 7 Days"
    public static let previous30Days = "Previous 30 Days"

    // MARK: The end of a list

    /// At the oldest day kept: "Older moments are deleted after 90 days."
    public static func olderDeleted(days: Int) -> String {
        days == 1 ? "Older moments are deleted after 1 day." : "Older moments are deleted after \(days) days."
    }

    /// Opens Preferences, where how long moments are kept is set.
    public static let change = "Change\u{2026}"
    public static let showEarlier = "Show Earlier"

    // MARK: The field's scope (SPEC 2.8)

    public enum Search {
        /// Before the bar's two choices.
        public static let label = "Search:"
        public static let everything = "Everything"
        /// Over a scope's matches: "9 matches in trailhead-shop".
        public static func matches(_ count: Int, in scope: String) -> String {
            count == 1 ? "1 match in \(scope)" : "\(count) matches in \(scope)"
        }

        /// A scope with no match, over [Search Everything].
        public static func nothingIn(_ scope: String) -> String { "Nothing in \(scope) matched." }

        public static let searchEverything = "Search Everything"
    }

    // MARK: History (SPEC 3.4)

    public enum History {
        /// Today, before anything is saved.
        public static let emptyTodayTitle = "Nothing saved yet."
        public static let emptyTodayBody = "Moments show up here a few seconds after you see them."
        public static let emptyPastDay = "Nothing saved on this day."
        /// The day control's button on another day.
        public static let today = "Today"
        public static let previousDay = "Previous Day"
        public static let nextDay = "Next Day"
        /// A session's own time, opened from Today: back to its whole day.
        public static let wholeDay = "Whole Day"

        /// "Part of trailhead-shop ›": the Working On item a moment belongs to.
        public static func partOf(_ name: String) -> String { "Part of \(name)" }

        // The actions on a moment.
        public static let open = "Open"
        public static let copyText = "Copy Text"
        public static let openLink = "Open Link"
        public static let openScreenshot = "Open Screenshot"
        /// Their tooltips, with their keys.
        public static let openLinkHelp = "Open Link (\u{2318}O)"
        public static let openScreenshotHelp = "Open Screenshot (Space)"
        public static let copyForYourAI = "Copy for Your AI"
        public static let showRelated = "Show Related"

        /// The detail's trash button, and its menu item for a row of one moment.
        public static let forgetThisMoment = "Forget This Moment"
        public static let forgetThisMomentMenu = "Forget This Moment\u{2026}"
        /// A row that holds a run of one window, or several rows picked.
        public static func forgetMoments(_ count: Int) -> String {
            count == 1 ? forgetThisMoment : "Forget \(count) Moments"
        }

        public static func forgetMomentsMenu(_ count: Int) -> String {
            count == 1 ? forgetThisMomentMenu : "Forget \(count) Moments\u{2026}"
        }

        /// The trash button's tooltip, with its key.
        public static func forgetHelp(_ count: Int) -> String {
            "\(forgetMoments(count)) (\u{2318}\u{232B})"
        }

        /// An hour heading's menu: "Forget 2 PM to 3 PM…".
        public static func forgetHour(_ range: String) -> String { "Forget \(range)\u{2026}" }

        /// "2 PM to 3 PM": an hour, as the menu and its question name it.
        public static func hourRange(_ start: String, _ end: String) -> String { "\(start) to \(end)" }

        /// Several rows picked: "3 moments selected".
        public static func selected(_ count: Int) -> String {
            count == 1 ? "1 moment selected" : "\(count) moments selected"
        }

        /// What the trash and Forget do, for VoiceOver.
        public static let forgetHint = "Deletes it from this Mac for good."
    }
}
