// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The menu-bar app's words for handing context to AI tools (SPEC 5 and 9):
/// the Ask panel's keys and notes, the first time a tool is asked, the
/// questions Connect asks, and Preferences' Disconnect and Disconnect All.
/// Every string passes `MenuBarCopyStyleTests`' rules and
/// `scripts/check-launch-copy.sh`.
public enum HandoffCopy {
    // MARK: The Ask panel's keys (SPEC 9, 136)

    /// "Ask Claude", or "Ask Your AI…" before a tool is chosen.
    public static func askHint(_ tool: String?) -> String {
        tool.map { "Ask \($0)" } ?? "Ask Your AI…"
    }

    public static let openHint = "Open"
    public static let resumeHint = "Resume"
    public static let askHereHint = "Ask"
    public static let searchHint = "Search"
    public static let chooseHint = "Choose"
    /// ⌘D and ⌘U open the window's Today and About You.
    public static let todayHint = "Today"
    public static let aboutYouHint = "About You"
    public static let copyForYourAI = "Copy for Your AI"
    public static let copyAnswer = "Copy Answer"
    /// The panel's result groups.
    public static let workingOnGroup = "Working On"
    public static let webPagesGroup = "Web Pages"
    public static let momentsGroup = "From your memory"
    /// The tool picker, the first time ⌘↩ is pressed.
    public static let pickTitle = "Ask Your AI"
    public static let pickDetail = "Pick the AI tool ⌘↩ opens. You can change it in the window’s AI Tools."
    /// ⌘↩ with nothing typed over a window Hippocampus hasn't read.
    public static let nothingToSend = "Hippocampus hasn’t read this window, so there’s nothing to hand over yet."

    // MARK: Item kinds (SPEC 9, 55)

    public static func kind(_ kind: String) -> String {
        switch kind {
        case "code": "Code project"
        case "design": "Design"
        case "spreadsheet": "Spreadsheet"
        default: "Document"
        }
    }

    // MARK: Notes after a tool opens (SPEC 9, 122 to 132)

    public static func opened(_ tool: String) -> String { "Opened in \(tool). You send it from there." }
    public static let copyInstead = "Copy Instead"
    public static let screenshotPaste = "Press ⌘V to add the screenshot."
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

    // MARK: The first time a tool is asked (SPEC 9, 133)

    public static func firstUseTitle(_ tool: String) -> String { "Ask \(tool) opens \(tool) with what you picked." }
    public static func firstUseTitleProject(_ project: String) -> String {
        "Open in Claude Code starts a new session in \(project) with what you picked."
    }
    public static func firstUseBody(_ tool: String) -> String {
        "Nothing is sent until you press send in \(tool). What you send goes to the company that runs \(tool)."
    }
    /// ChatGPT, whose chats can't be filled in from another app.
    public static func firstUseBodyPasted(_ tool: String) -> String {
        "\(tool) chats can’t be filled in from another app, so it’s copied for you to paste. "
            + firstUseBody(tool)
    }
    public static func firstUseFolder(_ folder: String) -> String {
        "Opens a new session in \(folder). Claude Code asks you to confirm the folder."
    }
    public static func openTool(_ tool: String) -> String { "Open \(tool)" }
    public static func copyAndOpen(_ tool: String) -> String { "Copy and Open \(tool)" }
    public static let cancel = "Cancel"
    public static let whatGoes = "What goes in the message box"
    public static func size(words: Int, moments: Int) -> String {
        "About \(words) words · " + (moments == 1 ? "1 moment" : "\(moments) moments")
    }
    public static let includeScreenshot = "Include Screenshot"
    public static let includeAboutMe = "Include What Hippocampus Knows About Me"

    // MARK: AI Tools, in Preferences (SPEC 3.8, 5.4, 5.5; SPEC 9, 90 to 143)

    public static let lead = "Nothing leaves this Mac unless you send it, or a tool you connected asks for it."
    public static let companyLine = "What a tool reads goes to the company that runs it."
    public static let whileQuit =
        "Connected tools can still read your memory while Hippocampus is quit; Disconnect stops that."
    public static let lookUpsSwitch = "Look things up in my memory"
    public static let sessionSwitch = "Start each session with my recent work"
    public static let chatGPTShares = "ChatGPT’s desktop app uses Codex’s settings, so it can look things up too."
    public static let codexNeedsStep = "Needs a step in Codex"
    public static let codexStep = "Codex asks you to allow new hooks once. Type /hooks in Codex and allow Hippocampus."

    /// "Let Claude Code and Codex look things up in your memory?"
    public static func connectTitle(_ names: String) -> String { "Let \(names) look things up in your memory?" }

    public static func connectMessage(_ names: String, count: Int, chatGPTInstalled: Bool) -> String {
        let lines = count == 1
            ? "It can search what you’ve seen and read your sessions, your day and what Hippocampus learned about you, "
                + "when a question needs it. What it reads goes to the company that runs \(names). "
                + "It can read while Hippocampus is quit. " + keepsHistory(count: 1)
            : "They can search what you’ve seen and read your sessions, your day and what Hippocampus learned about you, "
                + "when a question needs it. What they read goes to the companies that run them. "
                + "They can read while Hippocampus is quit. " + keepsHistory(count: count)
        return chatGPTInstalled ? lines + " " + chatGPTShares : lines
    }

    /// A connected tool keeps its own copy of what it reads (storage review
    /// S6), and Hippocampus can't reach it.
    public static func keepsHistory(count: Int) -> String {
        count == 1
            ? "It also keeps what it reads in its own history on this Mac, unencrypted. "
                + "Forgetting something in Hippocampus doesn’t remove it there."
            : "They also keep what they read in their own history on this Mac, unencrypted. "
                + "Forgetting something in Hippocampus doesn’t remove it there."
    }

    public static let connect = "Connect"
    public static let notNow = "Not Now"

    // A connected tool's history, when other accounts on this Mac can open
    // it (storage review S6). Offered, never done without asking.

    /// "Make Codex’s history private?"
    public static func privateHistoryTitle(_ names: [String]) -> String {
        let owners = names.map { $0 + "’s" }
        let joined = owners.count > 1
            ? owners.dropLast().joined(separator: ", ") + " and " + owners[owners.count - 1]
            : owners.first ?? ""
        return "Make \(joined) history private?"
    }

    /// Which folders, and what Make Private does to them.
    public static func privateHistoryMessage(_ names: [String], folders: [String]) -> String {
        let list = { (items: [String]) in
            items.count > 1 ? items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1] : items.first ?? ""
        }
        return names.count == 1
            ? "\(list(names)) keeps its sessions in \(list(folders)), with what it reads from your memory, and other "
                + "accounts on this Mac can open them. Make Private lets only you open that folder. "
                + "\(list(names)) works as before."
            : "\(list(names)) keep their sessions in \(list(folders)), with what they read from your memory, and other "
                + "accounts on this Mac can open them. Make Private lets only you open those folders. "
                + "They work as before."
    }

    public static let makePrivate = "Make Private"
    public static func couldNotMakePrivate(_ tool: String) -> String { "Couldn’t make all of \(tool)’s history private." }

    public static let sessionTitle = "Start each session with your recent work?"

    public static func sessionMessage(_ names: String, count: Int, codex: Bool) -> String {
        let gets = count == 1 ? "gets" : "get"
        let receiver = count == 1 ? "The company that runs \(names) receives it." : "The company that runs each tool receives it."
        var message = "At the start of each session, \(names) \(gets) your recent work and up to six things "
            + "Hippocampus learned about you, with sources. Nothing you read on screen is in it. "
            + "It can include other projects. \(receiver)"
        if codex { message += " " + codexStep }
        return message
    }

    public static let disconnectButton = "Disconnect…"
    public static func disconnectTitle(_ tool: String) -> String { "Disconnect \(tool)?" }
    public static let disconnectMessage =
        "It stops looking things up and starting sessions with your work. What it already read stays in its history."
    public static let disconnect = "Disconnect"
    public static let disconnectAllButton = "Disconnect All…"
    public static let disconnectAllTitle = "Disconnect every AI tool?"
    public static let disconnectAllMessage =
        "They stop looking things up and starting sessions with your work. What they already read stays in their history."
    public static func disconnected(_ tool: String) -> String { "Disconnected. Restart \(tool)." }
    public static func couldNotDisconnect(_ tool: String) -> String { "Couldn’t disconnect \(tool). Try again." }
}
