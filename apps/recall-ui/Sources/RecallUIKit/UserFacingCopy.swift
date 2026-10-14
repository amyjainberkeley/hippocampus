// UserFacingCopy.swift — canonical plain-English copy for user-facing
// error and status strings.
//
// Cycle 8.54 product-readiness audit polish gap #2 fix — "Cryptic
// engineer-jargon in user-facing error strings" (see
// `docs/research/2026-07-13-copy-audit.md` +
// `docs/design/copy-style-guide.md`). Every string here replaces a
// prior string that either exposed a raw `\(error)`, leaked an
// internal identifier ("brain", "helper", "mci-agent", "SCStream"),
// or apologized without naming a next action.
//
// The internal thrown `BrainReaderError` values are unchanged — they
// remain engineer-facing (log + crash reports). Only the strings a
// user actually reads are rewritten.

import Foundation

/// Canonical user-facing copy strings. Every entry is enumerated in
/// `CopyStyleTests` and grep-linted against the copy style guide:
/// (1) no raw error codes, (2) no engineer jargon, (3) failures name
/// a next action.
public enum UserFacingCopy {

    // Memory (brain) unreachable — used by SearchView and TimelineView.
    // Prior copy was "Couldn't open your brain".
    public static let memoryUnreachableTitle =
        "Hippocampus couldn\u{2019}t open your memory"
    public static let memoryUnreachableBody =
        "Check that Hippocampus is running in the menu bar, then try again."
    public static let openHippocampusAction = "Open Hippocampus"

    // Brief / timeline / event-detail load failures. Reassuring body
    // ("Your captures are safe") replaces the prior raw `\(error)`.
    public static let briefLoadFailedTitle = "This brief didn\u{2019}t load"
    public static let timelineLoadFailedTitle = "Your timeline didn\u{2019}t load"
    public static let loadFailedBody =
        "Your captures are safe — this was a display hiccup. "
        + "Try again in a moment."
    public static let eventDetailFailedTitle =
        "This event\u{2019}s details didn\u{2019}t load"

    /// Stale-event body — replaces "Event no longer in brain (may
    /// have been suppressed)." Uses "marked private" as the
    /// user-visible synonym for our internal redaction/denylist path.
    public static let eventNoLongerAvailable =
        "This event isn\u{2019}t available anymore — it may have "
        + "been deleted or marked private."

    // Privacy Dashboard mutations — reassuring copy + next action.
    public static let deleteFailedBanner =
        "Delete didn\u{2019}t go through. Nothing was removed — "
        + "your captures are unchanged. Try again in a moment."
    public static let deleteBlockedBanner =
        "Hippocampus is updating your memory. Quit Hippocampus, leave "
        + "this window open, then try deleting again."
    public static let dashboardLoadFailedBanner =
        "The Privacy Dashboard couldn\u{2019}t load right now. "
        + "Try relaunching Hippocampus."
    public static let exportFailedBanner =
        "Export didn\u{2019}t finish. Check that your Downloads "
        + "folder has free space, then try again."
    public static let auditExportFailedBanner =
        "Activity-log export didn\u{2019}t finish. Check that your "
        + "Downloads folder has free space, then try again."

    // Custom-names editor.
    public static func customNamesValidationFailed(_ detail: String) -> String {
        "Couldn\u{2019}t save your custom names — \(detail)"
    }
    public static func customNamesParseFailed(_ detail: String) -> String {
        "Couldn\u{2019}t read the custom-names file — \(detail)"
    }
    public static let customNamesWriteFailed =
        "Couldn\u{2019}t save to disk. Check that Hippocampus has "
        + "permission to write to your Application Support folder."
    public static let unexpectedErrorGeneric =
        "Something went wrong. Try again — if it keeps happening, "
        + "use \u{201C}Send Feedback\u{201D} from the menu bar."

    // Menu-bar & MCP registration.
    public static let tccRevokedNotificationTitle =
        "Hippocampus paused capture"
    public static let mcpAgentMissing =
        "Hippocampus can\u{2019}t find its Claude Code connector. "
        + "Try reinstalling Hippocampus."
    public static let mcpRegisterFailed =
        "Couldn\u{2019}t connect to Claude Code. Try again — if it "
        + "keeps happening, use \u{201C}Send Feedback\u{201D}."

    /// PrivacyDashboard fresh-brain empty-state title. "brain" →
    /// "memory" (see MCIEmptyState.noPrivacyEvents).
    public static let emptyPrivacyEventsFreshTitle = "Your memory is empty"

    // The Ask key, named exactly as the menu-bar app names it
    // (`HippocampusKit/SoloKeyTrigger.swift`, `AskShortcut.swift`), for when
    // the app has not published what works now (RULINGS X2). The raw keys are
    // the stored values of `ai.hippocampus.prefs.askKey`. With the key off,
    // ⌃⇧Space still opens Ask (RULINGS G3).
    public static let askKeyNames: [String: (label: String, phrase: String)] = [
        "shiftTwice": ("⇧⇧", "Press Shift twice"),
        "rightShift": ("right ⇧", "Tap right Shift"),
        "rightCommand": ("right ⌘", "Tap right ⌘"),
        "rightOption": ("right ⌥", "Tap right ⌥"),
        "off": ("⌃⇧Space", "Press ⌃⇧Space"),
    ]

    /// The instruction for a key the window has no phrase for.
    public static func askKeyPhrase(_ label: String) -> String {
        "Press \(label)"
    }

    /// Who wrote a session's title, a note or the day's summary, as the
    /// caption names it (RULINGS I11): Apple Intelligence for Apple's
    /// on-device model, a model server's model by its own name
    /// ("local:qwen3:4b" is "qwen3:4b"), any other model by its own name. Nil
    /// when it was measured, not written.
    public static func writerName(_ writtenBy: String) -> String? {
        switch writtenBy {
        case "", "measured", "local:": nil
        case "apple-foundation-models": "Apple Intelligence"
        case let local where local.hasPrefix("local:"): String(local.dropFirst("local:".count))
        default: writtenBy
        }
    }

    /// "Written on this Mac by {writer}" (RULINGS I11).
    public static func writtenOnThisMac(by writtenBy: String) -> String? {
        writerName(writtenBy).map { "Written on this Mac by \($0)" }
    }

    /// "Right" or "Forget" could not be saved, so nothing changed (RULINGS I8).
    public static let verdictNotSaved = "Couldn\u{2019}t save that. Try again."

    // The words around a moment's text (RULINGS T12, T17).

    /// The heading over a moment's text: what was on screen, or on a web
    /// page. Text from anywhere else is just "Text".
    public static func momentTextHeading(sourceKind: String?) -> String {
        switch sourceKind {
        case "screen_ocr", "screen_context": "On screen"
        case "browser_page", "browser_page_with_ocr": "On the page"
        default: "Text"
        }
    }

    public static let momentTextLoading = "Loading\u{2026}"
    public static let momentTextEmpty = "No text here."
    /// The window held more text than one read takes: its end is missing.
    public static let momentTextFirstPart = "Showing the first part."
    /// The whole text could not be read, so the list's excerpt shows. It may
    /// be taken around a search's words, so it is not "the first part".
    public static let momentTextExcerpt = "Showing part of it."
    /// Copies what is shown: the text, and the rest of the window when open.
    public static let copyTextAction = "Copy Text"
    /// The closed disclosure after a moment's text: tabs, sidebars, menus.
    public static let alsoInThisWindow = "Also in this window"

    /// "1 line", "12 lines": how much "Also in this window" holds.
    public static func lineCount(_ count: Int) -> String {
        count == 1 ? "1 line" : "\(count) lines"
    }

    // The Right now card and a session's actions (RULINGS W5, W8).

    /// While working: "Now · since 2:12 PM", from the start of the run of
    /// sessions that touch.
    public static func rightNowSince(_ time: String) -> String {
        "Now \u{00B7} since \(time)"
    }

    /// When not working: "Last saved 2:36 PM".
    public static func lastSavedAt(_ time: String) -> String {
        "Last saved \(time)"
    }

    /// Copies that session's own moments (RULINGS I13).
    public static let copyForYourAI = "Copy for your AI"
    /// Opens the page the moment was on.
    public static let openPage = "Open Page"

    /// Brings the moment's app to the front: "Open Notes".
    public static func openApp(_ name: String) -> String {
        "Open \(name)"
    }

    /// Over the lines a connected AI is given when a session starts.
    public static let yourAIAlreadyKnows = "Your AI already knows"
    /// No AI tool starts its sessions with these lines yet.
    public static let connectAction = "Connect"
    /// History on a session's own time (RULINGS W8).
    public static let showInHistory = "Show in History"
    /// History's next page down.
    public static let showEarlier = "Show Earlier"

    /// "1 moment", "4 moments": several moments of one window in a row.
    public static func momentCount(_ count: Int) -> String {
        count == 1 ? "1 moment" : "\(count) moments"
    }

    // The groups on You (contract model-page.md section 4).

    public static let groupWorkingOn = "Working on"
    public static let groupHowYouWork = "How you work"
    public static let groupSkills = "Skills"
    public static let groupPeople = "People"
    public static let groupStruggles = "Where you got stuck"

    // The window: its title, its places and the sidebar (RULINGS W10, X9).

    public static let windowTitle = "Hippocampus"
    /// The sidebar's footer, from the saved status.
    public static let footerRemembering = "Remembering"
    public static let footerNotRemembering = "Not remembering"
    /// The footer when there is no saved status at all.
    public static let footerNoStatus = "Not remembering right now."
    public static let footerHelp = "Open Preferences"

    // Ask (spec-recall S3, RULINGS S1, T17).

    public static let askPlaceholder = "Ask or search your memory"
    /// The field while answers cannot come on this Mac: it only searches.
    public static let searchOnlyPlaceholder = "Search anything you\u{2019}ve seen"
    /// Return asks what is typed.
    public static let askKeyHintReturn = "\u{21A9} Ask"
    /// Only ⌘Return asks what is typed.
    public static let askKeyHintCommandReturn = "\u{2318}\u{21A9} Ask"
    public static let askThinking = "Thinking on your Mac\u{2026}"
    public static let askFailed = "Couldn\u{2019}t answer that. Try again."
    public static let tryAgainAction = "Try Again"
    public static let stopAction = "Stop"
    public static let sourcesHeading = "Sources"
    /// Over the matches when an answer is shown.
    public static let moreFromYourMemory = "More from your memory"
    public static let filtersAction = "Filters"
    public static let clearAction = "Clear"
    public static let nothingMatched = "Nothing matched"
    public static let matchModeLabel = "Match"
    public static let matchModeExact = "Exact words"
    public static let matchModeMeaning = "Meaning"
    public static let matchModeHelp = "Exact words finds those words. Meaning also finds related things."
    /// Meaning search cannot use several apps or a link filter.
    public static let meaningFiltersUnavailable = "Meaning can\u{2019}t use these filters"
    /// Copies context for the question, with sources.
    public static let copyForYourAIHelp = "Copies this, your recent work and what Hippocampus knows about you, with sources."
    public static let copiedToast = "Copied"
    public static let copyFailedTitle = "Couldn\u{2019}t copy"
    public static let copyFailedBody = "Check that Hippocampus is running in the menu bar, then try again."

    /// Why there is no answer, in the Ask panel's words (`CommandBarModel.explain`).
    public static func noAnswer(_ reason: String?) -> String {
        switch reason {
        case "apple_intelligence_off": "Turn on Apple Intelligence in System Settings to get answers."
        case "device_not_eligible", "not_installed", "cannot_launch", "needs_macos_26":
            "Answers need macOS 26 with Apple Intelligence."
        case "model_not_ready": "Apple Intelligence is still getting ready."
        case "needs_apple_intelligence_or_local_model": "Answers need Apple Intelligence or your own model."
        case "local_server_unreachable": "Your model server isn\u{2019}t answering."
        case "local_model_missing": "Your model server doesn\u{2019}t have that model."
        case "local_model_unset": "Your model server has no model to answer with."
        case "local_model_not_local": "That model runs in the cloud. Pick one that runs on this Mac."
        case "local_server_not_local": "Hippocampus only talks to model servers on this Mac."
        default: "Couldn\u{2019}t write an answer."
        }
    }

    /// Where a moment came from, in one word or two: "Screen", "Web page".
    public static func momentSource(sourceKind: String?) -> String {
        switch sourceKind {
        case "screen_ocr", "screen_context": "Screen"
        case "browser_page", "browser_page_with_ocr": "Web page"
        case "transcript_import": "AI session"
        case "structured_app": "App"
        case "mcp_resource": "Connected app"
        default: "Other"
        }
    }

    /// "Safari \u{00B7} 2:14 PM": a source under an answer.
    public static func sourceLine(app: String, time: String) -> String {
        "\(app) \u{00B7} \(time)"
    }

    // History, inside Ask (RULINGS W8).

    public static let historyEmptyToday = "Nothing saved yet"
    public static let historyEmptyPastDay = "Nothing saved on this day."
    public static let historyLoadFailed = "Couldn\u{2019}t load History"
    public static let historyLoadFailedBody = "Nothing is lost. Try again."
    public static let previousDay = "Previous day"
    public static let nextDay = "Next day"
    public static let todayAction = "Today"
    public static let backToResults = "Results"
    public static let backToHistory = "History"
    public static let wholeDayAction = "Show Whole Day"

    // Commands and menus (spec-copy S4.10).

    public static let commandNewQuestion = "New Question"
    public static let commandNewQuestionDetail = "Start a new question."
    public static let commandHistory = "History"
    public static let commandHistoryDetail = "See what you saw, in order."
    public static let commandPreferences = "Preferences\u{2026}"
    public static let commandNames = "Names You Use"
    public static let commandNamesDetail = "Tell Hippocampus when two names mean the same thing."
    public static let commandRefresh = "Refresh"
    public static let commandRefreshDetail = "Load the newest moments."
    public static let refreshingToast = "Refreshing\u{2026}"
    public static let commandSupportReport = "Save a Report for Support"
    public static let commandSupportReportDetail = "A file with your screen content removed."
    public static let commandShortcuts = "Keyboard Shortcuts"
    public static let commandWhatsNew = "What\u{2019}s New"
    public static let commandWhatsNewDetail = "What changed in this version."
    public static let commandCloseWindow = "Close Hippocampus Window"
    /// ⌘J: what your AI gets in a folder you choose.
    public static let commandFolderContext = "Context for a Folder\u{2026}"
    public static let goMenu = "Go"

    // A moment's detail and its screenshot (spec-copy S4.12, RULINGS T17).

    public static let noScreenshot = "No screenshot"
    public static let screenshotMissing = "Screenshot missing"
    public static let openInApp = "Open in App"
    public static let openLink = "Open Link"
    public static let showRelated = "Show Related"
    public static let showRelatedHelp = "See related moments in other apps"
    public static func showRelatedCount(_ count: Int) -> String {
        count == 1 ? "Show 1 related moment" : "Show \(count) related moments"
    }
    public static func mentions(_ name: String) -> String {
        "Show moments that mention \(name)"
    }
    public static func moreNames(_ count: Int) -> String {
        "\(count) more names"
    }
    public static func names(_ names: [String]) -> String {
        "Names: " + names.joined(separator: ", ")
    }
    public static let previousAction = "Previous"
    public static let nextAction = "Next"
    public static let closeAction = "Close"
    public static let screenshotLoadFailed = "Couldn\u{2019}t open this screenshot"
    public static let saveContextAction = "Save Context\u{2026}"
    /// The moment was deleted, made private, or its number now names another.
    public static let momentGone = "This moment is gone."
    public static let momentLoadFailed = "Couldn\u{2019}t load this moment. Try again."
    public static let momentChangedNothingSaved = "This moment changed, so nothing was saved. Try again."
    public static let saveContextFailedTitle = "Couldn\u{2019}t save context"
    public static let saveContextFailedBody = "Couldn\u{2019}t save there. Choose another folder."
    public static let copyFailedTryAgain = "Couldn\u{2019}t copy. Try again."
    public static let relatedLoadFailed = "Couldn\u{2019}t load related moments. Try again."

    // Filters, the command palette and release notes (spec-copy S4.10, S4.12).

    public static let meaningFiltersSeveralApps = "Switch to Exact words to filter by several apps or by link."
    public static let meaningMayMissMatches = "Some matches may be missing. Switch to Exact words to see them all."
    public static let hasLinkFilter = "Has a link"
    public static let datesTitle = "Dates"
    public static func moreApps(_ count: Int) -> String { "More apps (\(count))" }
    public static let commandFieldLabel = "Command"
    public static let shortcutsSheetLabel = "Keyboard shortcuts"
    public static let whatsNewNothingListed = "Nothing listed for this version."
    public static let whatsNewNoNotes = "No notes for this version."
    public static let whatsNewReopen = "\u{2318}\u{21E7}N opens this again."

    // What is remembered, and deleting it (spec-copy S4.13).

    public static func recentMoments(_ count: Int) -> String { "Recent moments (\(count))" }
    public static func exportedMoments(_ count: Int) -> String {
        "Saved \(count) moments to Downloads. The file isn\u{2019}t encrypted."
    }
    public static let deleteLast24hExplanation = "Everything from the last 24 hours is deleted for good."
    public static let deleteEverythingExplanation = "Every moment, session and summary is deleted for good."
    public static let deleteEverythingTitle = "Delete everything Hippocampus remembers?"
    public static let deleteUnavailable = "Deleting isn\u{2019}t available."
    public static let deleteAction = "Delete"
    /// Writes straight to Downloads: no further step, so no ellipsis.
    public static let exportEverythingAction = "Export Everything"
    public static let deleteLast24hAction = "Delete Last 24 Hours\u{2026}"
    public static let deleteEverythingAction = "Delete Everything\u{2026}"
    public static let exportNotEncrypted = "Exported files aren\u{2019}t encrypted."
    public static let savedToDownloads = "Saved to Downloads."
    public static let storageText = "Text"
    public static let storageScreenshots = "Screenshots"
    public static let auditTitle = "Deletes and exports"
    public static let auditExportAction = "Export"
    public static let auditCaption = "Hippocampus keeps a list of every delete and export, on this Mac."
    public static let auditEmpty = "Nothing yet."

    /// One line of the list of deletes and exports, in the past tense.
    public static func auditAction(_ action: AuditAction, details: [String: String]) -> String {
        switch action {
        case .appLaunched: "Opened Hippocampus"
        case .permissionsGranted: "Allowed a permission"
        case .permissionsRevoked: "Turned off a permission"
        case .deleteEvent: "Deleted a moment"
        case .deleteEventsInRange:
            details["range_hours"] == "24" ? "Deleted the last 24 hours" : "Deleted some moments"
        case .wipeBrain: "Deleted everything"
        case .exportJson: "Exported everything"
        case .settingsChange: "Changed a preference"
        }
    }

    // Names you use (spec-copy S4.13; no real person in the example).

    public static let namesTitle = "Names you use"
    public static let namesBody = "Tell Hippocampus when two names mean the same person or thing."
    public static let namesExample = "Example: Alex Rivera is also Alex, AR, @arivera."
    public static let namesEmpty = "No names yet."
    public static let namesAdd = "Add Name"
    public static let namesSaved = "Saved"
    public static let namesSave = "Save"
    public static let namesNameField = "Name"
    public static let namesAlsoCalledField = "Also called (separate with commas)"
    public static let namesRemove = "Remove"

    // What your AI gets in a folder (spec-copy S4.13, critique-recall-product 8).

    public static let folderTitle = "What your AI gets in this folder"
    public static let folderSubtitle = "Your last decisions, next steps, and their sources."
    public static let folderChoose = "Choose a project"
    public static let folderChooseAction = "Choose Folder\u{2026}"
    public static let folderChangeAction = "Change\u{2026}"
    public static let folderScope = "Uses the whole repository, and what was on screen while you worked in it."
    public static let folderLoading = "Getting it ready\u{2026}"
    public static let folderFailed = "Couldn\u{2019}t get context"
    public static let folderEmptyTitle = "Continue a project"
    public static let folderEmptyBody = "Choose the folder you worked in. Hippocampus writes up where you stopped, for you to check and copy."
    public static let folderNothingSent = "Nothing is sent anywhere until you copy it."
    public static func folderWrittenAt(_ time: String) -> String { "Written at \(time)." }
    public static let folderCopy = "Copy"
    public static let folderPanelTitle = "Choose a Project Folder"

    // Reading a screenshot again (RULINGS T5, T17).

    public static let readAgainAction = "Read Again"
    public static let readingAgain = "Reading\u{2026}"
    public static let readAgainCaption = "Some small text may be missing."
    public static let readAgainUnreadable = "Couldn\u{2019}t read this one. It may be too small or blurred."
    public static let readAgainTimedOut = "Reading took too long. Try again when your Mac is less busy."
    public static let readAgainBlocked = "This looked private, so the text isn\u{2019}t shown."
    public static let readAgainUnavailable = "Couldn\u{2019}t read this screenshot. Nothing was changed."
    /// ⌘F: the cursor in Ask's field.
    public static let commandFind = "Find"

    /// "Press Shift twice in any app to open Ask."
    public static func askKeyHelp(_ phrase: String) -> String {
        phrase.isEmpty ? "Choose a key for Ask in Preferences." : "\(phrase) in any app to open Ask."
    }
}

// MARK: - Copy-style validators (referenced by CopyStyleTests)

public enum CopyStyleValidator {
    /// Matches `-3815`-style codes, `errno=NNN`, `code=NNN`, and
    /// hex ids like `0x2A`. See copy-style-guide §2.
    public static func containsRawErrorCode(_ text: String) -> Bool {
        let patterns = [
            #"\B-\d{3,}\b"#,
            #"\berrno\s*[=:]\s*-?\d+"#,
            #"\bcode\s*[=:]\s*-?\d+"#,
            #"\b0x[0-9A-Fa-f]{2,}\b"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Jargon banned from user-facing copy. See copy-style-guide §3.
    public static let bannedJargon: [String] = [
        "SCStream", "TCC", "MCP", "FFI", "denylist",
        "cascade", "helper", "SQLCipher", "sentinel",
    ]

    public static func containsJargon(_ text: String) -> String? {
        let lower = text.lowercased()
        return bannedJargon.first { lower.contains($0.lowercased()) }
    }
}
