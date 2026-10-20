import RecallUIKit
import SwiftUI

/// The first time a person asks a tool, one quiet sheet (SPEC 5.3.8): what
/// opens, that nothing is sent until they press send there, and who receives
/// what they send, over the exact message, word for word, with its size.
/// Cancel opens nothing; the default button (Return, ⌘↩) opens the tool.
struct FirstUseSheet: View {
    struct Content: Identifiable, Equatable {
        let tool: InstalledTool
        /// The builder's message; nil while it is being made.
        var card: SendCard?
        /// A code project's name, when Claude Code opens in its folder.
        let codeProject: String?
        /// How many moments it holds, until the builder says.
        let moments: Int
        var id: String { tool.id }
    }

    let content: Content
    let offersScreenshot: Bool
    @Binding var includeScreenshot: Bool
    @Binding var includeAboutMe: Bool
    let cancel: () -> Void
    let open: () -> Void

    @Environment(\.drawsKeyDefaultButton) private var drawsKeyDefaultButton

    private var tool: AskTool { content.tool.tool }

    private var opensProject: Bool { content.codeProject != nil && tool == .claudeCode }

    private var title: String {
        if let project = content.codeProject, opensProject { return HandoffCopy.firstUseTitleProject(project) }
        return HandoffCopy.firstUseTitle(tool.name)
    }

    private var message: String {
        tool.isPasted ? HandoffCopy.firstUseBodyPasted(tool.name) : HandoffCopy.firstUseBody(tool.name)
    }

    private var openTitle: String {
        tool.isPasted ? HandoffCopy.copyAndOpen(tool.name) : HandoffCopy.openTool(tool.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ToolIconView(tool: content.tool, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(MCI.Color.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(MCI.Font.body)
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if opensProject, let folder = content.card?.folder {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                    (Text(HandoffCopy.firstUseFolderLead())
                        + Text(folder).fontWeight(.semibold).foregroundColor(MCI.Color.foreground)
                        + Text(HandoffCopy.firstUseFolderTail))
                        .font(MCI.Font.caption)
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MCI.Color.background, in: RoundedRectangle(cornerRadius: MCI.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: MCI.Radius.m, style: .continuous)
                    .strokeBorder(MCI.Color.border, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(HandoffCopy.whatGoes)
                        .font(MCI.Font.bodyStrong)
                        .foregroundStyle(MCI.Color.foreground)
                    Spacer()
                    if let card = content.card {
                        Text(HandoffCopy.size(words: card.words, moments: max(card.included.count, 1)))
                            .font(MCI.Font.caption)
                            .foregroundStyle(MCI.Color.foregroundSecondary)
                    }
                }
                Group {
                    if let card = content.card {
                        ScrollView {
                            Text(MessagePreviewText.attributed(card.message))
                                .font(.system(size: 11, design: .monospaced))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 208)
                .background(MCI.Color.background, in: RoundedRectangle(cornerRadius: MCI.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: MCI.Radius.m, style: .continuous)
                    .strokeBorder(MCI.Color.border, lineWidth: 1))
                .accessibilityLabel(HandoffCopy.whatGoes)
                if content.card?.peopleMessages == true {
                    Text(HandoffCopy.people)
                        .font(MCI.Font.caption)
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if offersScreenshot {
                    Toggle(HandoffCopy.includeScreenshot, isOn: $includeScreenshot)
                }
                Toggle(HandoffCopy.includeAboutMe, isOn: $includeAboutMe)
            }
            .toggleStyle(.checkbox)
            .font(MCI.Font.body)
            HStack {
                Spacer()
                Button(HandoffCopy.cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Group {
                    let button = Button(openTitle, action: open).keyboardShortcut(.defaultAction)
                    if drawsKeyDefaultButton {
                        button.buttonStyle(KeyDefaultButtonStyle())
                    } else {
                        button.buttonStyle(.borderedProminent).tint(MCI.Color.accentFill)
                    }
                }
                .disabled(content.card == nil)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 580)
        .background(MCI.Color.surface)
    }
}

private struct DrawsKeyDefaultButtonKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Off-screen renders have no key window, and AppKit draws a key window's
    /// blue default button grey everywhere else: renders set this to draw it
    /// as the person sees it.
    var drawsKeyDefaultButton: Bool {
        get { self[DrawsKeyDefaultButtonKey.self] }
        set { self[DrawsKeyDefaultButtonKey.self] = newValue }
    }
}

/// The default button as macOS draws it in the key window: the accent fill,
/// white words, the large control's height.
private struct KeyDefaultButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                MCI.Color.accentFill.opacity(configuration.isPressed ? 0.85 : 1),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }
}

/// The message as the sheet shows it: word for word, with heading marks and
/// fences in a quieter grey so the moment's own words read first.
enum MessagePreviewText {
    static func attributed(_ message: String) -> AttributedString {
        var out = AttributedString()
        let lines = message.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("```") {
                var mark = AttributedString(line)
                mark.foregroundColor = MCI.Color.foregroundMuted
                out += mark
            } else if let space = line.firstIndex(of: " "), !line[..<space].isEmpty, line[..<space].allSatisfy({ $0 == "#" }) {
                var mark = AttributedString(String(line[...space]))
                mark.foregroundColor = MCI.Color.foregroundMuted
                var words = AttributedString(String(line[line.index(after: space)...]))
                words.foregroundColor = MCI.Color.foreground
                out += mark
                out += words
            } else {
                var words = AttributedString(line)
                words.foregroundColor = MCI.Color.foreground
                out += words
            }
            if index < lines.count - 1 { out += AttributedString("\n") }
        }
        return out
    }
}
