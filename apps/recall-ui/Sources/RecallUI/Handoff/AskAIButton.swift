import AppKit
import RecallUIKit
import SwiftUI

/// What Ask {Tool} reaches: the builder, the tools on this Mac, the choices
/// remembered here, where its notes show, and how a link or an app opens.
/// The window uses this Mac's; the renderer and tests put fixtures here, so
/// nothing reaches the agent, an app or the clipboard from them.
struct HandoffServices {
    var client: SendCardClient
    var tools: () -> [InstalledTool]
    var choices: HandoffChoices
    var notes: BottomNotes
    var open: (URL) -> Bool
    var home: String

    @MainActor
    static var live: HandoffServices {
        let detector = DestinationDetector.live()
        return HandoffServices(
            client: .live, tools: { detector.installed() }, choices: HandoffChoices(), notes: .shared,
            open: { NSWorkspace.shared.open($0) }, home: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }
}

private struct HandoffServicesKey: EnvironmentKey {
    // Nil: nothing shared is ever stored here.
    nonisolated(unsafe) static let defaultValue: HandoffServices? = nil
}

extension EnvironmentValues {
    /// Ask {Tool}'s services; nil means this Mac's.
    var handoffServices: HandoffServices? {
        get { self[HandoffServicesKey.self] }
        set { self[HandoffServicesKey.self] = newValue }
    }
}

/// The one button that hands what a person picked to their AI (SPEC 5.3):
/// on Today's card and a session, in History's detail, on a Working On page
/// and under an answer.
///
/// A split button: its label is the last tool chosen ("Ask Claude"), and
/// its menu lists the AI tools on this Mac with their own icons, Include
/// Screenshot, Include What Hippocampus Knows About Me (both off at the
/// start of every send), and Copy for Your AI. On a code project it reads
/// Open in Claude Code. The first time it reads Ask Your AI and opens the
/// menu; with no tool on this Mac it is Copy for Your AI, so there is never a
/// button that does nothing. The first time for each tool, one sheet shows
/// what opens and the exact message. Then the tool opens with the message in
/// its box, or it is copied and the tool opened, and a note says which.
/// Nothing is ever sent: the person presses send in the tool.
struct AskAIButton: View {
    let source: AskAISource
    let reader: BrainReader
    /// The bordered-prominent look of a card's main button.
    var prominent = false
    /// ⌘↩ is this button (SPEC 2.10): set on the one button whose source is
    /// what the page has selected.
    var handlesCommandReturn = false
    /// The moment picked among several: it never goes to make room.
    var selected: UInt64?
    /// A Working On item's moments, newest first, for when the work read
    /// doesn't know the item yet.
    var itemMoments: [UInt64] = []
    /// A code project's name: the button opens Claude Code in its folder.
    var codeProject: String?
    /// Kept for the places that still pass it; the builder makes every
    /// message now.
    var contextExporter: @Sendable (String) async throws -> String = {
        try await ContextHandoffExporter.export(focus: $0)
    }

    @Environment(\.handoffServices) private var injected
    @Environment(\.screenshots) private var screenshots
    @State private var services: HandoffServices?
    @State private var tools: [InstalledTool] = []
    @State private var sheet: FirstUseSheet.Content?
    @State private var includeScreenshot = false
    @State private var includeAboutMe = false
    @State private var hasScreenshot = false
    @State private var sending = false
    @State private var sendGuard = SendGuard()

    private var handoff: HandoffServices { injected ?? services ?? .live }

    var body: some View {
        Group {
            if tools.isEmpty {
                copyButton
            } else {
                split
            }
        }
        .background(commandReturn)
        .sheet(item: $sheet) { content in
            FirstUseSheet(
                content: content,
                offersScreenshot: offersScreenshot(content.tool.tool),
                includeScreenshot: $includeScreenshot,
                includeAboutMe: $includeAboutMe,
                cancel: { sheet = nil },
                open: {
                    handoff.choices.markTold(content.tool.tool)
                    sheet = nil
                    send(content.tool)
                }
            )
            .onChange(of: includeAboutMe) { _, _ in preview(content.tool) }
        }
        .task {
            if injected == nil, services == nil { services = .live }
            tools = handoff.tools()
            await checkScreenshot()
        }
    }

    // MARK: The button

    /// The tool the primary half opens: Claude Code for a code project
    /// (Codex when only it is here), else the last tool chosen.
    private var primaryTool: InstalledTool? {
        AskAIButtonRules.primaryTool(in: tools, codeProject: codeProject, lastTool: handoff.choices.lastTool)
    }

    private var label: String {
        AskAIButtonRules.label(primary: primaryTool, codeProject: codeProject)
    }

    @ViewBuilder
    private var split: some View {
        if let tool = primaryTool {
            styled(Menu { menuItems } label: { Text(label) } primaryAction: { ask(tool) })
                .help(label + "  ⌘↩")
        } else {
            styled(Menu { menuItems } label: { Text(label) })
        }
    }

    private func styled(_ menu: some View) -> some View {
        Group {
            if prominent {
                menu.menuStyle(.button).buttonStyle(.borderedProminent).tint(MCI.Color.accentFill)
            } else {
                menu.menuStyle(.button).buttonStyle(.bordered)
            }
        }
        .fixedSize()
        .disabled(sending)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var menuItems: some View {
        ForEach(tools) { tool in
            let item = Button {
                handoff.choices.lastTool = tool.tool
                ask(tool)
            } label: {
                Label { Text(tool.tool.name) } icon: { Image(nsImage: ToolIcons.image(for: tool, size: 16)) }
            }
            if tool.tool == primaryTool?.tool {
                item.keyboardShortcut(.return, modifiers: .command)
            } else {
                item
            }
        }
        Divider()
        if hasScreenshot {
            Toggle(HandoffCopy.includeScreenshot, isOn: $includeScreenshot)
        }
        Toggle(HandoffCopy.includeAboutMe, isOn: $includeAboutMe)
        Divider()
        Button(HandoffCopy.copyForYourAI) { copyForAI() }
            .keyboardShortcut("c", modifiers: [.command, .shift])
    }

    private var copyButton: some View {
        Group {
            let button = Button(HandoffCopy.copyForYourAI) { copyForAI() }
            if prominent {
                button.buttonStyle(.borderedProminent).tint(MCI.Color.accentFill)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .disabled(sending)
    }

    /// ⌘↩ on this page is this button.
    @ViewBuilder
    private var commandReturn: some View {
        if handlesCommandReturn {
            Button("") {
                if let tool = primaryTool { ask(tool) } else { copyForAI() }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private func offersScreenshot(_ tool: AskTool) -> Bool {
        AskAIButtonRules.offersScreenshot(tool, hasScreenshot: hasScreenshot)
    }

    /// Whether the moment it hands over has a screenshot: only then is one
    /// offered (SPEC 5.3.7).
    private func checkScreenshot() async {
        guard let id = AskAIButtonRules.screenshotMoment(of: source, selected: selected),
              let hit = try? await reader.fetchEventsByIds([id]).first else {
            hasScreenshot = false
            return
        }
        hasScreenshot = hit.thumbnailURL != nil
    }

    // MARK: Asking

    private func ask(_ tool: InstalledTool) {
        guard !sending else { return }
        if handoff.choices.wasTold(tool.tool) {
            send(tool)
            return
        }
        sheet = FirstUseSheet.Content(tool: tool, card: nil, codeProject: codeProject, moments: source.momentCount)
        preview(tool)
    }

    private func request(for tool: InstalledTool, full: Bool = false, to: String? = nil) -> SendCardRequest {
        source.request(
            to: to ?? tool.tool.rawValue, selected: selected, itemMoments: itemMoments, appInstalled: tool.hasApp,
            includeAboutMe: includeAboutMe, includeScreenshot: includeScreenshot && offersScreenshot(tool.tool),
            full: full
        )
    }

    /// The sheet's message, word for word.
    private func preview(_ tool: InstalledTool) {
        let request = request(for: tool)
        let client = handoff.client
        Task {
            let card = try? await client.card(request)
            guard sheet?.tool == tool else { return }
            sheet?.card = card
        }
    }

    /// Asks the builder just before anything opens; a second press within
    /// 2 seconds is ignored.
    private func send(_ tool: InstalledTool) {
        guard sendGuard.allows(at: Date()) else { return }
        sending = true
        let request = request(for: tool)
        let wantsScreenshot = request.includeScreenshot
        let handoff = handoff
        Task {
            defer {
                sending = false
                // Off at the start of every send.
                includeScreenshot = false
                includeAboutMe = false
            }
            do {
                let card = try await handoff.client.card(request)
                let picture = wantsScreenshot ? await screenshot(card.screenshotMoment) : nil
                let plan = HandoffPlan.make(card: card, tool: tool.tool, installed: tool, home: handoff.home,
                                            screenshot: picture != nil)
                perform(plan, tool: tool, card: card, screenshot: picture)
            } catch {
                handoff.notes.show(AskAIButtonRules.failureNote(error))
            }
        }
    }

    private func perform(_ plan: HandoffPlan, tool: InstalledTool, card: SendCard, screenshot: Data?) {
        guard let note = plan.perform(
            tool: tool.tool, screenshot: screenshot,
            copy: { ClipboardHygiene.copy($0) }, copyJPEG: { ClipboardHygiene.copy(jpeg: $0) }, open: handoff.open
        ) else {
            handoff.notes.show(HandoffCopy.couldNotCopy)
            return
        }
        showNote(note, card: card, tool: tool, screenshot: screenshot)
    }

    private func showNote(_ note: HandoffNote, card: SendCard, tool: InstalledTool, screenshot: Data?) {
        let action: BottomNote.Action? = note.action.map { action in
            BottomNote.Action(title: action.title) {
                switch action {
                case .copyInstead(let text):
                    ClipboardHygiene.copy(text)
                    handoff.notes.show(HandoffCopy.copied)
                case .copyFullVersion:
                    copyFullVersion(tool)
                case .openTerminal(let folder):
                    if !TerminalHere.open(folder) { handoff.notes.show(HandoffCopy.couldNotOpenTerminal) }
                case .copyScreenshot:
                    if let screenshot { ClipboardHygiene.copy(jpeg: screenshot) }
                }
            }
        }
        handoff.notes.show(note.fullText, action: action)
    }

    private func copyFullVersion(_ tool: InstalledTool) {
        let request = request(for: tool, full: true, to: "copy")
        let handoff = handoff
        Task {
            guard let card = try? await handoff.client.card(request), !card.message.isEmpty else {
                handoff.notes.show(HandoffCopy.couldNotCopy)
                return
            }
            ClipboardHygiene.copy(card.message)
            handoff.notes.show(HandoffCopy.copied)
        }
    }

    /// Copy for Your AI: the same message, as Markdown, by the clipboard
    /// rules (SPEC 5.3.6).
    private func copyForAI() {
        guard !sending else { return }
        sending = true
        let request = source.request(to: "copy", selected: selected, itemMoments: itemMoments,
                                     includeAboutMe: includeAboutMe)
        let handoff = handoff
        Task {
            defer {
                sending = false
                includeAboutMe = false
            }
            do {
                let card = try await handoff.client.card(request)
                guard card.message.isEmpty || ClipboardHygiene.copy(card.message) else {
                    handoff.notes.show(HandoffCopy.couldNotCopy)
                    return
                }
                handoff.notes.show(AskAIButtonRules.copiedNote(card))
            } catch {
                handoff.notes.show(AskAIButtonRules.failureNote(error))
            }
        }
    }

    /// The ticked moment's screenshot, as an AI tool takes it.
    private func screenshot(_ id: UInt64?) async -> Data? {
        guard let id, let hit = try? await reader.fetchEventsByIds([id]).first, let url = hit.thumbnailURL,
              let data = await screenshots.thumbnailData(for: url, maxPixelSize: 1_568) else { return nil }
        return ClipboardHygiene.jpegForAI(data)
    }
}

/// An AI tool's own app icon, or a quiet tile when its app isn't on this Mac.
enum ToolIcons {
    static func image(for tool: InstalledTool, size: CGFloat) -> NSImage {
        if let app = tool.appURL, FileManager.default.fileExists(atPath: app.path) {
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: size, height: size)
            return icon
        }
        let symbol = tool.tool == .claudeCode ? "terminal" : "sparkle"
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
    }
}

/// An AI tool's icon at `size`.
struct ToolIconView: View {
    let tool: InstalledTool
    let size: CGFloat

    var body: some View {
        if let app = tool.appURL, FileManager.default.fileExists(atPath: app.path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable().interpolation(.high)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(MCI.Color.foreground.opacity(0.07))
                .overlay(
                    Text(String(tool.tool.name.prefix(1)))
                        .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                )
                .frame(width: size, height: size)
        }
    }
}
