import Foundation

/// The words on the window's frame: the sidebar's rows and its sections, the
/// field, the status menu and banner, the menus and forgetting (SPEC 2, 3.11
/// and 9, with SPEC-DELTA 1 and 2). Rows, buttons and menu items are Title
/// Case; sentences are sentences. Every string passes `CopyStyleValidator` and
/// `scripts/check-launch-copy.sh`. Times and counts are filled on the Mac.
public enum NavigationCopy {
    // MARK: Sidebar rows and sections

    public static let today = "Today"
    public static let workingOn = "Working On"
    public static let showAll = "Show All"
    public static let library = "Library"
    public static let history = "History"
    public static let webPages = "Web Pages"
    public static let documents = "Documents"
    public static let code = "Code"
    public static let conversations = "Conversations"
    public static let lookedUp = "Looked Up"
    public static let aboutYou = "About You"
    public static let aiTools = "AI Tools"
    public static let privacy = "Privacy"

    /// Said once, under Working On, the first time it appears (SPEC 2.3).
    public static let workingOnFootnote =
        "Hippocampus adds what you spend 30 minutes on, and takes it off after two weeks without it."

    /// A row's tooltip: its name and its key ("History  ⌘2").
    public static func rowTooltip(_ title: String, key: Character?) -> String {
        guard let key else { return title }
        return "\(title)  \u{2318}\(key)"
    }

    /// "Last worked on today at 2:20 PM".
    public static func lastWorkedOn(_ when: String) -> String {
        "Last worked on \(when)"
    }

    /// A Working On item's tooltip: its whole name, and when it was last
    /// worked on.
    public static func itemTooltip(name: String, when: String) -> String {
        "\(name) \u{00B7} \(lastWorkedOn(when))"
    }

    /// The kind of a Working On item, in words, for VoiceOver.
    public static func itemKind(_ kind: String) -> String {
        switch kind {
        case "code": "code project"
        case "design": "design"
        case "spreadsheet": "spreadsheet"
        default: "document"
        }
    }

    /// VoiceOver on a Working On item: "trailhead-shop, code project, last
    /// worked on 2:20 PM".
    public static func itemAccessibility(name: String, kind: String, when: String) -> String {
        "\(name), \(itemKind(kind)), last worked on \(when)"
    }

    /// VoiceOver on Show All: "Show all, 8 items".
    public static func showAllAccessibility(count: Int) -> String {
        count == 1 ? "Show all, 1 item" : "Show all, \(count) items"
    }

    /// VoiceOver for the one kind of badge.
    public static let aiToolsNeedsStep = "needs a step"
    public static let aboutYouSomethingNew = "something new is going to your AI"

    /// VoiceOver, once, the first time a Library row appears.
    public static func rowAdded(_ title: String) -> String {
        "\(title) added to the sidebar"
    }

    public static let hideFromSidebar = "Hide from Sidebar"
    public static let copyForYourAI = "Copy for Your AI"
    public static let turnOff = "Turn Off"
    public static let showInSidebar = "Show in Sidebar"
    public static let sidebarMenu = "Sidebar"
    public static let resetSidebar = "Reset Sidebar"
    public static let hideWorkingOn = "Hide Working On"
    public static let showWorkingOn = "Show Working On"
    public static let showSidebar = "Show Sidebar"
    public static let hideSidebar = "Hide Sidebar"

    // MARK: The hi mark, the footer and the gear

    /// The hi mark's VoiceOver label: "Hippocampus, Remembering". VoiceOver
    /// says "Button" and the hint after it.
    public static func hiMarkLabel(_ status: String) -> String {
        "Hippocampus, \(status)"
    }

    public static let hiMarkHint = "Shows controls."

    /// The footer status for VoiceOver: "Remembering. Last saved 12 seconds
    /// ago." (VoiceOver adds the menu role).
    public static func footerAccessibility(title: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return title }
        let sentence = detail.hasSuffix(".") ? detail : detail + "."
        return "\(title). \(sentence)"
    }

    public static let preferences = "Preferences"

    // MARK: The field

    public static let back = "Back"
    public static let forward = "Forward"
    /// The field on a Working On page or Show All.
    public static let workingOnPlaceholder = "Search what you\u{2019}re working on"
    public static let findKey = "\u{2318}F"

    /// Shown once on Today to people who used the preview (SPEC 2.12).
    public static let sidebarIsNew =
        "The sidebar is new. Today shows where you left off, Working On lists what you spend time on, and History has its own place."
    public static let okAction = "OK"

    // MARK: Status: the menu, the footer and the banner

    public static let remembering = "Remembering"
    public static let notRemembering = "Not remembering"
    public static let forgetting = "Forgetting\u{2026}"
    /// The footer while the window applies a forget a crash left behind.
    public static let finishingForget = "Finishing a forget\u{2026}"
    public static let lowPower = "Low Power Mode is on, so only the window you\u{2019}re using is read."

    public static let pause = "Pause"
    public static let pauseForAnHour = "For 1 Hour"
    public static let pauseUntilTomorrow = "Until Tomorrow"
    public static let pauseUntilResume = "Until I Resume"
    public static let resume = "Resume"
    public static let resumeNow = "Resume Now"
    public static let turnOn = "Turn On"
    public static let openSystemSettings = "Open System Settings\u{2026}"
    public static let tryAgain = "Try Again"
    public static let quitHippocampus = "Quit Hippocampus"
    public static let finishSetup = "Finish Setup\u{2026}"
    public static let openHippocampus = "Open Hippocampus"
    public static let forgetLastTenMinutes = "Forget the Last 10 Minutes\u{2026}"
    public static let forgetLastHour = "Forget the Last Hour\u{2026}"
    public static let forgetToday = "Forget Today\u{2026}"
    public static let privacyMenu = "Privacy\u{2026}"
    public static let preferencesMenu = "Preferences\u{2026}"

    /// "Paused since 2:40 PM. Nothing new is saved until you resume."
    public static func bannerPaused(since time: String) -> String {
        "Paused since \(time). Nothing new is saved until you resume."
    }

    /// "Paused until 3:40 PM. Nothing new is saved until then."
    public static func bannerPausedUntil(_ time: String) -> String {
        "Paused until \(time). Nothing new is saved until then."
    }

    public static let bannerPausedNoTime = "Paused. Nothing new is saved until you resume."
    public static let bannerOff = "Remembering is off. What\u{2019}s already saved is still here."

    /// "Screen Recording is off for Hippocampus, so nothing new is saved."
    public static func bannerPermission(_ permission: String) -> String {
        "\(permission) is off for Hippocampus, so nothing new is saved."
    }

    public static let bannerNotSaving = "Hippocampus can\u{2019}t confirm anything new was saved."
    public static let bannerCouldNotStop = "Hippocampus may still be reading the screen."
    public static let bannerCouldNotTurnOn = "It didn\u{2019}t start, so remembering is still off."
    public static let bannerNotSetUp = "Setup isn\u{2019}t finished, so nothing is read yet."
    public static let bannerNotRunning = "Hippocampus isn\u{2019}t running, so nothing new is saved."

    public static let screenRecording = "Screen Recording"
    public static let accessibility = "Accessibility"

    // MARK: Forgetting (SPEC 3.11)

    public static let forgetRecentTitle = "Forget recent memory?"
    public static let lastTenMinutes = "The last 10 minutes"
    public static let lastHour = "The last hour"
    public static let todayChoice = "Today"

    /// "since 2:31 PM"
    public static func since(_ time: String) -> String {
        "since \(time)"
    }

    public static let sinceMidnight = "since midnight"
    public static let forgetRecentBody = "Everything saved then is deleted from this Mac for good."
    public static let typeForget = "Type FORGET to confirm."
    /// The word typed to forget today.
    public static let forgetWord = "FORGET"
    public static let forgetAction = "Forget"
    public static let cancelAction = "Cancel"
    public static let firstForget =
        "Forgetting removes it from this Mac. What you already sent to an AI tool stays in that tool."
    public static let forgotten = "Forgotten."
    public static let couldNotForget = "Couldn\u{2019}t forget it. It\u{2019}s still saved."
    public static let openHippocampusToForget = "To forget, open Hippocampus first."
    public static let undoAction = "Undo"

    /// "Forgot 1 moment." / "Forgot 4 moments."
    public static func forgotMoments(_ count: Int) -> String {
        count == 1 ? "Forgot 1 moment." : "Forgot \(count) moments."
    }

    // The confirmations a page shows before a larger forget (SPEC 3.11 and
    // 9, rows 107 to 113). Cancel is their default; Return never forgets.

    /// "Forget 2:12 to 2:36 PM?" (a session) or "Forget 2 PM to 3 PM?" (an hour).
    public static func forgetSpanTitle(_ span: String) -> String {
        "Forget \(span)?"
    }

    /// "Everything saved from 2:12 to 2:36 PM is deleted from this Mac for
    /// good: 41 moments and their screenshots."
    public static func forgetSpanBody(_ span: String, moments: Int) -> String {
        "Everything saved from \(span) is deleted from this Mac for good: \(momentsWord(moments)) and their screenshots."
    }

    /// "Forget “Rounding half to even”?"
    public static func forgetPageTitle(_ title: String) -> String {
        "Forget \u{201C}\(title)\u{201D}?"
    }

    /// "6 moments from 3 days are deleted from this Mac for good, with their screenshots."
    public static func forgetPageBody(moments: Int, days: Int) -> String {
        let from = days == 1 ? "1 day" : "\(days) days"
        let verb = moments == 1 ? "is" : "are"
        return "\(momentsWord(moments)) from \(from) \(verb) deleted from this Mac for good, with their screenshots."
    }

    /// "Forget the search “per seat vs tiered pricing”?"
    public static func forgetSearchTitle(_ query: String) -> String {
        "Forget the search \u{201C}\(query)\u{201D}?"
    }

    public static let forgetSearchBody =
        "The search and the results page you saw are deleted from this Mac for good."

    /// More than 20 selected: "Forget 36 moments?"
    public static func forgetSelectionTitle(_ count: Int) -> String {
        "Forget \(count) moments?"
    }

    public static let forgetSelectionBody = "Their text and screenshots are deleted from this Mac for good."
    public static let forgetTodayTitle = "Forget today?"
    public static let forgetLastDayTitle = "Forget the last 24 hours?"

    /// "Everything saved since midnight is deleted from this Mac for good:
    /// 1,284 moments and their screenshots."
    public static func forgetSinceBody(_ since: String, moments: Int) -> String {
        "Everything saved since \(since) is deleted from this Mac for good: \(momentsWord(moments)) and their screenshots."
    }

    static func momentsWord(_ count: Int) -> String {
        let number = count.formatted(.number.grouping(.automatic))
        return count == 1 ? "1 moment" : "\(number) moments"
    }

    // MARK: Menus and the command bar

    public static let goMenu = "Go"
    public static let newQuestion = "New Question"
    public static let find = "Find"
    public static let goToToday = "Go to Today"
    public static let previousDay = "Previous Day"
    public static let nextDay = "Next Day"
    public static let contextForThisFolder = "Context for This Folder\u{2026}"
    public static let refresh = "Refresh"
    public static let forgetRecentCommand = "Forget Recent\u{2026}"
    public static let keyboardShortcuts = "Keyboard Shortcuts"
    public static let commandBar = "Command Bar"

    /// The ⌘K groups, in order (SPEC 2.9), which the shortcuts sheet's
    /// headings use too.
    public static let groupGoTo = "Go To"
    public static let groupMoments = "Moments"
    public static let groupActions = "Actions"
    public static let groupHelp = "Help"
}
