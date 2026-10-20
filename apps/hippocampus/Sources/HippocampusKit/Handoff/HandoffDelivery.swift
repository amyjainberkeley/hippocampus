// SPDX-License-Identifier: Apache-2.0
//
// HandoffDelivery.swift — what happens once the builder has answered (SPEC
// 5.3.4, 5.3.8): open the tool's link with the message in its box, or copy
// the message and open the tool (its app, its site, or for Claude Code's
// command line nothing), and the note that says which, with what was left
// out. Nothing is ever sent: the person presses send in the tool.

import Foundation

/// The note after Ask {Tool}: its first line, any lines after it, and its
/// one button.
public struct HandoffNote: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Copy the message that went in the link.
        case copyInstead(String)
        /// Copy the whole message, not the shortened one.
        case copyFullVersion
        /// Open Terminal in the project's folder.
        case openTerminal(URL)

        public var title: String {
            switch self {
            case .copyInstead: HandoffCopy.copyInstead
            case .copyFullVersion: HandoffCopy.copyFullVersion
            case .openTerminal: HandoffCopy.openTerminalHere
            }
        }
    }

    public var text: String
    public var lines: [String]
    public var action: Action?

    public init(text: String, lines: [String] = [], action: Action? = nil) {
        self.text = text
        self.lines = lines
        self.action = action
    }

    /// Everything it says, for VoiceOver.
    public var spoken: String { ([text] + lines).joined(separator: " ") }
}

/// What to do with a card for one tool.
public struct HandoffPlan: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// Open a link, an app or a site.
        case open(URL)
        /// Copy the message by the clipboard rules.
        case copy(String)
    }

    public var steps: [Step]
    public var note: HandoffNote
    /// When a link doesn't open: copy this instead, and say so.
    public var fallbackCopy: String?

    public init(steps: [Step], note: HandoffNote, fallbackCopy: String? = nil) {
        self.steps = steps
        self.note = note
        self.fallbackCopy = fallbackCopy
    }

    /// Nothing to do: everything picked was forgotten.
    public var isEmpty: Bool { steps.isEmpty }
}

public enum HandoffDelivery {
    /// The plan for `card` and `tool`, as `installed` is on this Mac. `home`
    /// makes a `~` folder absolute for Terminal.
    public static func plan(card: SendCard, tool: AskTool, installed: InstalledTool?, home: String) -> HandoffPlan {
        var lines: [String] = []
        if card.leftOut.secretLines > 0 { lines.append(HandoffCopy.heldBack(card.leftOut.secretLines)) }
        if card.leftOut.forgotten > 0 { lines.append(HandoffCopy.forgotten(card.leftOut.forgotten)) }
        if card.peopleMessages { lines.append(HandoffCopy.people) }
        guard !card.message.isEmpty else {
            // Everything picked was forgotten since the click: nothing opens.
            let text = lines.first ?? HandoffCopy.forgotten(max(card.leftOut.forgotten, 1))
            return HandoffPlan(steps: [], note: HandoffNote(text: text, lines: Array(lines.dropFirst())))
        }
        if card.shortened { lines.insert(HandoffCopy.shortened(tool.name), at: 0) }
        let fullAction: HandoffNote.Action? = card.shortened ? .copyFullVersion : nil

        if !card.copy, let link = card.open.flatMap(URL.init(string:)) {
            return HandoffPlan(
                steps: [.open(link)],
                note: HandoffNote(text: HandoffCopy.opened(tool.name), lines: lines,
                                  action: fullAction ?? .copyInstead(card.message)),
                fallbackCopy: card.message
            )
        }
        // Copied: then the tool opens, where it can.
        let clears = [HandoffCopy.clears] + lines
        if tool == .claudeCode, installed?.hasApp != true {
            let folder = card.folder.flatMap { absolute($0, home: home) }
            let name = folder?.lastPathComponent ?? HandoffCopy.yourProject
            return HandoffPlan(
                steps: [.copy(card.message)],
                note: HandoffNote(text: HandoffCopy.copiedRunClaude(name), lines: clears,
                                  action: fullAction ?? folder.map(HandoffNote.Action.openTerminal))
            )
        }
        if let app = installed?.appURL {
            return HandoffPlan(
                steps: [.copy(card.message), .open(app)],
                note: HandoffNote(text: HandoffCopy.copiedPaste(tool.name), lines: clears, action: fullAction)
            )
        }
        if let site = tool.site {
            return HandoffPlan(
                steps: [.copy(card.message), .open(site.url)],
                note: HandoffNote(text: HandoffCopy.notInstalled(tool.name, site: site.name), lines: clears,
                                  action: fullAction)
            )
        }
        return HandoffPlan(
            steps: [.copy(card.message)],
            note: HandoffNote(text: HandoffCopy.copied, lines: lines, action: fullAction)
        )
    }

    /// The note when a link didn't open: it was copied instead.
    public static func couldNotOpen(_ tool: AskTool) -> HandoffNote {
        HandoffNote(text: HandoffCopy.couldNotOpen(tool.name), lines: [HandoffCopy.clears])
    }

    /// A `~` folder made absolute; nil for anything that isn't a folder path.
    static func absolute(_ folder: String, home: String) -> URL? {
        if folder == "~" { return URL(fileURLWithPath: home, isDirectory: true) }
        if folder.hasPrefix("~/") {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(String(folder.dropFirst(2)), isDirectory: true)
        }
        return folder.hasPrefix("/") ? URL(fileURLWithPath: folder, isDirectory: true) : nil
    }
}
