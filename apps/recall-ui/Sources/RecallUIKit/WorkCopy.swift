import Foundation

/// The words of Working On, its item pages, Web Pages, Looked Up and Resume
/// (SPEC 3 and 9, SPEC-DELTA 2 to 4). Buttons are Title Case, sentences
/// are sentences. Every string passes `CopyStyleValidator` and
/// `scripts/check-launch-copy.sh`.
public enum WorkCopy {
    // MARK: Resume (SPEC-DELTA 3)

    /// The primary button on a Working On page and Today's card, and the
    /// sheet's default button (⌘↩).
    public static let resume = "Resume"
    /// The sheet's title names what it reopens (launch playbook, decision
    /// 12): "Reopen Q4 investor update". Until the plan names it, or when
    /// it can't, what it lists.
    public static func resumeTitle(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return resumeTitleUnnamed }
        return "Reopen \(name)"
    }
    public static let resumeTitleUnnamed = "Reopen what was open"
    /// The sheet when nothing from the last session can be opened again.
    public static let resumeNothing = "Nothing to reopen."
    public static let cancel = "Cancel"
    /// Under the sheet's title, which names the item: where the list comes
    /// from, the item's last session, and when it was.
    public static func resumeLead(when: String) -> String {
        "What was open in its last session, \(when). Nothing opens until you click Resume."
    }
    /// The sheet's groups.
    public static let resumeCode = "Code"
    public static let resumeDocuments = "Documents"
    public static let resumePages = "Web Pages"
    public static let resumeApps = "Apps"
    /// Under Web Pages when there are more than ten.
    public static func resumeNewestTicked(_ count: Int) -> String {
        "The newest \(count) are ticked."
    }
    /// What the sheet's button will open, as it changes with the ticks.
    public static func resumeWillOpen(tabs: Int, apps: Int) -> String {
        "Opens \(counted(tabs: tabs, apps: apps))."
    }
    /// The note after Resume (no undo: closing them is the person's choice).
    public static func resumeOpened(tabs: Int, apps: Int) -> String {
        "Opened \(counted(tabs: tabs, apps: apps))."
    }
    /// Added to the note when some tabs were open already.
    public static func resumeAlreadyOpen(_ count: Int) -> String {
        count == 1 ? "1 was already open." : "\(count) were already open."
    }
    /// Added to the note when something didn't open.
    public static func resumeCouldntOpen(_ name: String) -> String {
        "Couldn’t open \(name)."
    }
    /// Nothing opened at all.
    public static let resumeOpenedNothing = "Nothing opened."

    /// Why a row can't open, or what opening it does (`reason` codes).
    public static func resumeMissing(_ name: String) -> String { "Couldn’t find \(name)" }
    public static let resumeSingleNote = "Notes opens the app; Hippocampus can’t open a single note"
    public static func resumeAppOnly(_ app: String) -> String {
        "\(app) opens the app; Hippocampus can’t open a single document"
    }
    public static func resumeNoFolder(_ app: String) -> String {
        "\(app) opens without the folder; Hippocampus doesn’t know where it is"
    }
    public static let resumeNoAddress = "Hippocampus doesn’t know this page’s address"
    /// In Demo Memory, a file, folder, document or page the made-up week
    /// invented: there is nothing real to open (`ResumeSheetModel.isMadeUp`).
    public static let resumeMadeUp = "Made up for the demo, so nothing opens."
    public static func resumeNotInstalled(_ app: String) -> String { "\(app) isn’t on this Mac" }
    /// A folder row's second line: what opens it.
    public static func resumeOpensIn(_ app: String) -> String { "Opens in \(app)" }

    static func counted(tabs: Int, apps: Int) -> String {
        let tabWords = tabs == 1 ? "1 tab" : "\(tabs) tabs"
        let appWords = apps == 1 ? "1 app" : "\(apps) apps"
        switch (tabs, apps) {
        case (0, 0): return "nothing"
        case (_, 0): return tabWords
        case (0, _): return appWords
        default: return "\(tabWords) and \(appWords)"
        }
    }

    // MARK: Working On, all of it (SPEC 3.3, SPEC-DELTA 2)

    public static let workingOnLead = "What you spent 30 minutes or more on. Kept until its moments are deleted."
    public static let thisWeek = "This week"
    public static let earlier = "Earlier"
    public static let notShownInSidebar = "Not shown in the sidebar"
    public static func notShownInSidebar(count: Int) -> String { "Not shown in the sidebar (\(count))" }
    public static let youHidIt = "You hid it from the sidebar."
    public static let looksPersonal = "Its name looks personal, so it isn’t shown in the sidebar."
    public static let showInSidebar = "Show in Sidebar"
    public static let hideFromSidebar = "Hide from Sidebar"
    public static let workingOnEmptyTitle = "Nothing here yet."
    public static let workingOnEmptyBody = "Projects and documents you spend 30 minutes on show up here."
    public static let fieldPlaceholder = "Search what you’re working on"
    public static func nothingMatched(_ scope: String) -> String { "Nothing in \(scope) matched." }
    public static let searchEverything = "Search Everything"
    /// The footnote the sidebar shows once, under Working On (SPEC 2.3).
    public static let sidebarFootnote =
        "Hippocampus adds what you spend 30 minutes on, and takes it off after two weeks without it."
    public static func retention(days: Int) -> String { "Older moments are deleted after \(days) days." }
    public static let change = "Change…"
    /// A card's or row's time this week, and in all for one from before.
    public static func thisWeekTime(_ duration: String) -> String { "\(duration) this week" }
    public static func inAllTime(_ duration: String) -> String { "\(duration) in all" }

    // MARK: Kinds

    public static let codeProject = "Code project"
    public static let document = "Document"
    public static let design = "Design"
    public static let spreadsheet = "Spreadsheet"

    // MARK: A Working On page (SPEC 3.2, SPEC-DELTA 4)

    public static func lastWorkedOn(_ when: String) -> String { "Last worked on \(when)" }
    public static func onDaysThisWeek(_ days: Int) -> String {
        days == 1 ? "On 1 day this week" : "On \(days) days this week"
    }
    public static let claudeCodeStarts = "Claude Code starts each session with your recent work."
    public static let seeWhatItGets = "See What It Gets"
    public static let whereYouLeftOff = "Where you left off"
    public static let files = "Files"
    public static let seenAlongside = "Seen alongside"
    public static let seenAlongsideLead = "Pages, searches and AI chats open around the same time."
    public static let conversations = "Conversations"
    public static let conversationsLead = "Chats and email open around the same time, by name only."
    public static let meetings = "Meetings"
    public static let meetingsLead = "From your calendar, while you worked on it."
    public static let history = "History"
    public static func andMore(_ count: Int) -> String { "And \(count) More" }
    public static let showEarlier = "Show Earlier"
    public static let showInHistory = "Show in History"
    public static let openPage = "Open Page"
    public static func open(_ app: String) -> String { "Open \(app)" }
    public static let more = "More"
    public static let contextForThisFolder = "Context for This Folder…"
    public static let copyForYourAI = "Copy for Your AI"
    public static let nothingYet = "Nothing yet."
    public static func nothingLeft(_ name: String) -> String { "Nothing left from \(name)." }
    public static let nothingLeftToShow = "Nothing left to show."
    public static let backToItem = "Back"
    /// A meeting's line: "Work · Today 2:00 PM".
    public static func meetingLine(calendar: String, when: String) -> String { "\(calendar) \u{00B7} \(when)" }
    public static let notShownLine = "Not shown in the sidebar."
    public static let loadFailed = "Couldn’t load this. Nothing is lost."
    public static let tryAgain = "Try Again"

    // MARK: Web Pages (SPEC 3.5)

    public static let webPagesLead = "Pages you read, newest first."
    public static let allBrowsers = "All Browsers"
    public static let today = "Today"
    public static let yesterday = "Yesterday"
    public static let previous7Days = "Previous 7 Days"
    public static let previous30Days = "Previous 30 Days"
    public static func onDays(_ days: Int) -> String { "on \(days) days" }
    public static func readOnDays(_ days: Int) -> String { "Read on \(days) days:" }
    public static func readTimes(_ times: Int, _ when: String) -> String { "Read \(times) times \(when):" }
    public static let openLink = "Open Link"
    public static let copyLink = "Copy Link"
    public static let forgetThisPage = "Forget This Page…"
    public static let noAddressesNote = "Page addresses are saved for browsers you allowed. Titles are always saved."
    public static let addBrowserExtension = "Add Browser Extension…"
    public static let webPagesEmptyTitle = "No web pages yet."
    public static let webPagesEmptyBody = "Pages you read in Safari, Chrome, Arc or Firefox show up here."
    public static func noPagesFrom(_ browser: String) -> String { "No pages from \(browser)." }

    // MARK: Looked Up (SPEC 3.6)

    public static let lookedUpLead = "Searches you made, newest first."
    public static func searchedTimes(_ times: Int) -> String { "searched \(times) times" }
    public static let openedNext = "Opened next"
    public static let nothingOpenedNext = "Nothing opened in the five minutes after."
    public static let searchAgain = "Search Again"
    public static let forgetThisSearch = "Forget This Search…"
    public static let lookedUpEmptyTitle = "Nothing looked up yet."
    public static let lookedUpEmptyBody =
        "Searches you make on Google, YouTube, GitHub and other sites show up here once Hippocampus can see the page’s address."

    // MARK: The sidebar's items (SPEC 2.2, SPEC-DELTA 2)

    /// An item's tooltip: "trailhead-shop · Last worked on today at 2:20 PM".
    public static func itemTooltip(name: String, when: String) -> String {
        "\(name) \u{00B7} \(lastWorkedOn(when))"
    }
    /// What VoiceOver reads for an item: "trailhead-shop, code project, last
    /// worked on 2:20 PM".
    public static func itemAccessibility(name: String, kind: String, when: String) -> String {
        "\(name), \(kind.lowercased()), last worked on \(when)"
    }
    /// Show All, read by VoiceOver: "Show all, 8 items".
    public static func showAllAccessibility(_ count: Int) -> String {
        count == 1 ? "Show all, 1 item" : "Show all, \(count) items"
    }
    /// A thumbnail, read by VoiceOver.
    public static func screenshotOf(_ name: String) -> String { "Screenshot of \(name)" }
}
