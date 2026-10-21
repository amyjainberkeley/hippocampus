import Foundation

/// The window's words for handing context to AI tools (SPEC 5 and 9): the
/// Ask {Tool} button and its menu, the notes after it opens a tool, the
/// first-use sheet and the AI Tools page. Every string passes
/// `CopyStyleValidator` and `scripts/check-launch-copy.sh`.
public enum HandoffCopy {
    // MARK: The button and its menu (SPEC 9, 120 and 121)

    /// "Ask Claude"; "Ask Your AI" before a tool is chosen.
    public static func ask(_ tool: String?) -> String { tool.map { "Ask \($0)" } ?? "Ask Your AI" }
    /// ⌘K's row for the selection or page (SPEC 2.9): "Ask Claude About This".
    public static func askAboutThis(_ tool: String?) -> String { ask(tool) + " About This" }
    public static func openIn(_ tool: String) -> String { "Open in \(tool)" }
    public static func copyFor(_ tool: String) -> String { "Copy for \(tool)" }
    public static let copyForYourAI = "Copy for Your AI"
    public static let includeScreenshot = "Include Screenshot"
    public static let includeAboutMe = "Include What Hippocampus Knows About Me"
    /// VoiceOver's name for the button's menu half: "Ask Claude, menu button"
    /// reads as the label and the role (SPEC 5.7).
    public static func menuLabel(_ label: String) -> String { label }

    // MARK: Notes (SPEC 9, 122 to 132)

    public static func opened(_ tool: String) -> String { "Opened in \(tool). You send it from there." }
    public static let copyInstead = "Copy Instead"
    public static let screenshotPaste = "Press ⌘V to add the screenshot."
    public static let copyScreenshot = "Copy Screenshot"
    public static func copiedPaste(_ tool: String) -> String { "Copied. In \(tool), start a new chat and press ⌘V." }
    public static let clears = "Clears in 2 minutes."
    public static let copied = "Copied. Clears in 2 minutes."
    public static func copiedRunClaude(_ folder: String) -> String { "Copied. Run claude in \(folder), then press ⌘V." }
    public static let yourProject = "your project"
    public static let openTerminalHere = "Open Terminal Here"
    public static func shortened(_ tool: String) -> String { "Shortened to fit \(tool)’s message box." }
    public static let copyFullVersion = "Copy Full Version"

    public static func heldBack(_ lines: Int) -> String {
        lines == 1
            ? "1 line left out: it looked like a password or code."
            : "\(lines) lines left out: they looked like passwords or codes."
    }

    public static func forgotten(_ moments: Int) -> String {
        moments == 1
            ? "1 moment was forgotten, so it’s left out."
            : "\(moments) moments were forgotten, so they’re left out."
    }

    public static let people = "Includes messages from other people."
    public static func notInstalled(_ tool: String, site: String) -> String {
        "\(tool) isn’t on this Mac. Copied, and opened \(site)."
    }
    public static func couldNotOpen(_ tool: String) -> String { "Couldn’t open \(tool). It’s copied instead." }
    public static let locked = "Hippocampus couldn’t open your memory. Open Hippocampus, then try again."
    public static let couldNotCopy = "Couldn’t copy. Try again."
    public static let couldNotOpenTerminal = "Couldn’t open Terminal in that folder."

    // MARK: The first time for each tool (SPEC 9, 133)

    public static func firstUseTitle(_ tool: String) -> String { "Ask \(tool) opens \(tool) with what you picked." }
    public static func firstUseTitleProject(_ project: String) -> String {
        "Open in Claude Code starts a new session in \(project) with what you picked."
    }
    public static func firstUseBody(_ tool: String) -> String {
        "Nothing is sent until you press send in \(tool). What you send goes to the company that runs \(tool)."
    }
    public static func firstUseBodyPasted(_ tool: String) -> String {
        "\(tool) chats can’t be filled in from another app, so it’s copied for you to paste. " + firstUseBody(tool)
    }
    public static func firstUseFolderLead() -> String { "Opens a new session in " }
    public static let firstUseFolderTail = ". Claude Code asks you to confirm the folder."
    public static func openTool(_ tool: String) -> String { "Open \(tool)" }
    public static func copyAndOpen(_ tool: String) -> String { "Copy and Open \(tool)" }
    public static let cancel = "Cancel"
    public static let whatGoes = "What goes in the message box"
    public static func size(words: Int, moments: Int) -> String {
        "About \(words) words · " + (moments == 1 ? "1 moment" : "\(moments) moments")
    }

    // MARK: The AI Tools page (SPEC 3.8; SPEC 9, 90 to 100)

    public static let pageTitle = "AI Tools"
    /// What leaves this Mac, exactly: memory goes only when the person sends
    /// it or a tool they connected asks for it. "Nothing leaves" was not
    /// exact: the update check leaves too, carrying nothing from memory
    /// (PRIVACY.md, "What leaves your Mac").
    public static let lead = "Your memory leaves this Mac only when you send it, or a tool you connected asks for it."
    public static let onTheirOwn = "On their own"
    public static let withOneKey = "With one key"
    public static let alsoOnThisMac = "Also on this Mac"
    public static let connected = "Connected"
    public static let notConnected = "Not connected"
    public static let getsRecentWork = "Gets your recent work at each session start."
    public static let looksThingsUp = "Looks things up when a question needs it."
    public static func turnedOffIn(_ tool: String) -> String { "Turned off in \(tool)’s own settings" }
    public static let codexAsked = "Asked to fetch your recent work when a task starts. Codex decides."
    /// Connect writes Hippocampus into Codex's settings file
    /// (`~/.codex/config.toml`). OpenAI documents that the ChatGPT desktop
    /// app shares that file with the Codex CLI and IDE extension, and that
    /// ChatGPT on the web doesn't read it
    /// (https://developers.openai.com/codex/mcp, read Oct 20, 2026). Chats
    /// get memory only when the person sends it (`chatGPTUse`).
    public static let chatGPTShares = "Codex in ChatGPT’s desktop app uses the same settings, so it can look things up too."
    public static let codexNeedsStep = "Needs a step in Codex"
    public static let codexStep = "Codex asks you to allow new hooks once. Type /hooks in Codex and allow Hippocampus."
    public static let overridden = "Overridden by your AGENTS.override.md file"
    public static let lookUpsSwitch = "Look things up in my memory"
    public static let sessionSwitch = "Start each session with my recent work"
    public static let on = "On"
    public static let off = "Off"
    public static let whatItStartsWith = "What It Starts With"
    public static let showExactText = "Show the Exact Text"
    /// "About 120 words, written on this Mac from what you read on screen."
    /// The exact text opens by saying it is from the screen: the session
    /// titles and what a model wrote about them, and what was learned
    /// about the person (`render_understanding_block` in apps/agent).
    public static func startsWithSize(words: Int) -> String {
        "About \(words) words, written on this Mac from what you read on screen."
    }
    /// Connecting asks two questions, looking things up and starting each
    /// session with recent work (Share or Don't Share), so a session "can"
    /// start with it, as setup's third card says.
    public static func notConnectedNote(_ tool: String) -> String {
        "Once connected, each session can start with your recent work, and you can read every word here."
    }
    public static let codexNotConnectedNote =
        "Codex in ChatGPT’s desktop app uses the same settings, so connecting Codex lets it look things up too."
    public static let connectButton = "Connect…"
    public static let opens = "opens"
    public static let oneKeyTail = "with what you picked in its message box. You press send."
    public static let chatGPTUse = "Chats can’t read your memory yet. Use Ask ChatGPT."
    public static func use(_ tool: String) -> String { "Use Ask \(tool)." }
    public static let companyLine = "What a tool reads goes to the company that runs it."
    public static let whileQuit =
        "Connected tools can still read your memory while Hippocampus is quit; Disconnect stops that."
    public static let changeInPreferences = "Change in Preferences…"
    public static let empty = "No AI tools found on this Mac. Hippocampus works with Claude Code and Codex, "
        + "and with one key hands what you pick to Claude, ChatGPT and Cursor."
    public static let unavailable = "Couldn’t load this. Nothing is lost."
    public static let tryAgain = "Try Again"
    public static let youConfirmed = "You confirmed this"
    public static func seenOnDays(_ days: Int) -> String { days == 1 ? "Seen once" : "Seen on \(days) days" }
}
