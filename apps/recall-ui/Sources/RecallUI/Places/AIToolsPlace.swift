import AppKit
import RecallUIKit
import SwiftUI

/// AI Tools (SPEC 3.8): what leaves this Mac, and to whom. Each connected
/// tool with its plain status and the exact words it starts with, the tool
/// ⌘↩ opens, and the tools on this Mac that aren't connected, each with the
/// truth. The page reads and links: switches and Disconnect work in
/// Preferences › AI Tools, where the app asks its own questions.
struct AIToolsPlace: View {
    let open: (RecallRoute) -> Void
    @StateObject private var model: AIToolsModel
    @State private var startsWithOpen: Bool
    @State private var exactOpen: Bool
    @Environment(\.isSyntheticPreview) private var isSyntheticPreview

    /// The shell's page: this Mac's tools and the agent's reads.
    init(understanding: UnderstandingReader, open: @escaping (RecallRoute) -> Void) {
        self.init(model: AIToolsModel(understanding: understanding), open: open)
    }

    /// The renderer's page, with What It Starts With drawn open.
    init(model: AIToolsModel, open: @escaping (RecallRoute) -> Void,
         startsWithOpen: Bool = false, exactOpen: Bool = false) {
        _model = StateObject(wrappedValue: model)
        self.open = open
        _startsWithOpen = State(initialValue: startsWithOpen)
        _exactOpen = State(initialValue: exactOpen)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(HandoffCopy.pageTitle)
                        .font(MCI.Font.title)
                        .foregroundStyle(MCI.Color.foreground)
                    Text(HandoffCopy.lead)
                        .font(MCI.Font.body)
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            // The column About You, Privacy and Working On use, so the page
            // doesn't jump sideways between its neighbours.
            .pageColumn()
        }
        .background(MCI.Color.background)
        .task {
            // The synthetic preview never reaches the agent or this Mac's
            // tools: its model is filled from fixtures. A model a picture
            // filled already is drawn as it is.
            guard !isSyntheticPreview, model.state == .loading else { return }
            await model.reload()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().controlSize(.small).padding(.vertical, 24)
        case .unavailable:
            VStack(alignment: .leading, spacing: 10) {
                Text(HandoffCopy.unavailable)
                    .font(MCI.Font.body)
                    .foregroundStyle(MCI.Color.foregroundSecondary)
                Button(HandoffCopy.tryAgain) { Task { await model.reload() } }
                    .buttonStyle(.bordered)
            }
        case .ready where model.isEmpty:
            Text(HandoffCopy.empty)
                .font(MCI.Font.body)
                .foregroundStyle(MCI.Color.foregroundSecondary)
                .fixedSize(horizontal: false, vertical: true)
            footer
        case .ready:
            if !model.cards.isEmpty {
                section(HandoffCopy.onTheirOwn) {
                    card {
                        ForEach(Array(model.cards.enumerated()), id: \.element.id) { index, tool in
                            if index > 0 { Divider().overlay(MCI.Color.border) }
                            toolBlock(tool)
                        }
                    }
                }
            }
            if !model.installed.isEmpty {
                section(HandoffCopy.withOneKey) { oneKey }
            }
            if !model.others.isEmpty {
                section(HandoffCopy.alsoOnThisMac) {
                    card {
                        ForEach(Array(model.others.enumerated()), id: \.element.id) { index, other in
                            if index > 0 { Divider().overlay(MCI.Color.border) }
                            HStack(spacing: 14) {
                                ToolIconView(tool: other.tool, size: 32)
                                Text(other.tool.tool.name)
                                    .font(MCI.Font.bodyStrong)
                                    .foregroundStyle(MCI.Color.foreground)
                                    .frame(minWidth: 96, alignment: .leading)
                                Text(other.line)
                                    .font(MCI.Font.body)
                                    .foregroundStyle(MCI.Color.foregroundSecondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                        }
                    }
                }
            }
            footer
        }
    }

    // MARK: Sections

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(MCI.Font.title2)
                .foregroundStyle(MCI.Color.foreground)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MCI.Color.surface, in: RoundedRectangle(cornerRadius: MCI.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: MCI.Radius.l, style: .continuous)
                .strokeBorder(MCI.Color.border, lineWidth: 1))
    }

    private func toolBlock(_ tool: AIToolsModel.Card) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ToolIconView(tool: InstalledTool(tool: tool.id == "codex" ? .codex : .claudeCode, appURL: tool.appURL),
                         size: 32)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tool.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MCI.Color.foreground)
                    Spacer()
                    Text(tool.connected ? HandoffCopy.connected : HandoffCopy.notConnected)
                        .font(MCI.Font.body)
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                    if !tool.connected {
                        Button(HandoffCopy.connectButton) { openPreferences() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .frame(minHeight: 32)
                ForEach(tool.lines, id: \.self) { line in
                    Text(line)
                        .font(MCI.Font.body)
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let step = tool.step {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(HandoffCopy.codexNeedsStep)
                            .font(MCI.Font.bodyStrong)
                            .foregroundStyle(MCI.Color.foreground)
                        Text(step)
                            .font(MCI.Font.body)
                            .foregroundStyle(MCI.Color.foregroundSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if tool.connected {
                    switchRow(HandoffCopy.lookUpsSwitch, on: tool.lookUps)
                    if tool.showsSessionSwitch {
                        switchRow(HandoffCopy.sessionSwitch, on: tool.sessionStart)
                    }
                }
                if tool.showsStartsWith {
                    startsWith
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private func switchRow(_ title: String, on: Bool) -> some View {
        HStack {
            Text(title)
                .font(MCI.Font.body)
                .foregroundStyle(MCI.Color.foreground)
            Spacer()
            Text(on ? HandoffCopy.on : HandoffCopy.off)
                .font(MCI.Font.body)
                .foregroundStyle(MCI.Color.foregroundSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: What It Starts With

    @ViewBuilder
    private var startsWith: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button {
                    withAnimation(MCI.Motion.snap) { startsWithOpen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(startsWithOpen ? 90 : 0))
                        Text(HandoffCopy.whatItStartsWith)
                    }
                    .font(MCI.Font.body)
                    .foregroundStyle(MCI.Color.accent)
                }
                .buttonStyle(.plain)
                .accessibilityValue(startsWithOpen ? "expanded" : "collapsed")
                if let starts = model.startsWith {
                    Text(HandoffCopy.startsWithSize(words: starts.words))
                        .font(MCI.Font.body)
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                }
            }
            if startsWithOpen, let starts = model.startsWith {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(starts.recentWork.enumerated()), id: \.offset) { _, line in
                        sentLine { Text(line).foregroundStyle(MCI.Color.foregroundSecondary) }
                            .onTapGesture { open(RecallRoute(place: .overview)) }
                    }
                    if !starts.aboutYou.isEmpty {
                        Spacer().frame(height: 4)
                    }
                    ForEach(starts.aboutYou) { line in
                        sentLine {
                            Text(line.text).foregroundStyle(MCI.Color.foregroundSecondary)
                                + Text(line.source.map { " " + $0 } ?? "").foregroundStyle(MCI.Color.accent)
                        }
                        .onTapGesture { open(RecallRoute(place: .you)) }
                    }
                    Button {
                        withAnimation(MCI.Motion.snap) { exactOpen.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(exactOpen ? 90 : 0))
                            Text(HandoffCopy.showExactText)
                        }
                        .font(MCI.Font.body)
                        .foregroundStyle(MCI.Color.foregroundSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    if exactOpen {
                        Text(starts.exactText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(MCI.Color.foreground)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(MCI.Color.background,
                                        in: RoundedRectangle(cornerRadius: MCI.Radius.m, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: MCI.Radius.m, style: .continuous)
                                .strokeBorder(MCI.Color.border, lineWidth: 1))
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// One line a session starts with, set off by a quiet bar.
    private func sentLine<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1)
                .fill(MCI.Color.borderStrong)
                .frame(width: 2)
            content()
                .font(MCI.Font.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
    }

    // MARK: With one key

    private var oneKey: some View {
        HStack(spacing: 10) {
            Text("⌘↩")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MCI.Color.foreground)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(MCI.Color.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(MCI.Color.borderStrong))
                .accessibilityLabel("Command Return")
            Text(HandoffCopy.opens)
            // Choose… until a tool is chosen: before then ⌘↩ opens none, and
            // the Ask buttons read Ask Your AI.
            Picker(selection: Binding<AskTool?>(
                get: { model.askTool },
                set: { tool in if let tool { model.choose(tool) } }
            )) {
                if model.askTool == nil {
                    Text(AIToolsModel.chooseTool).tag(AskTool?.none)
                }
                ForEach(model.installed) { tool in
                    Label { Text(tool.tool.name) } icon: { Image(nsImage: ToolIcons.image(for: tool, size: 16)) }
                        .tag(AskTool?.some(tool.tool))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Text(HandoffCopy.oneKeyTail)
        }
        .font(MCI.Font.body)
        .foregroundStyle(MCI.Color.foreground)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(HandoffCopy.companyLine + " " + HandoffCopy.whileQuit)
                .font(MCI.Font.caption)
                .foregroundStyle(MCI.Color.foregroundSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(HandoffCopy.changeInPreferences) { openPreferences() }
                .buttonStyle(.bordered)
        }
    }

    /// Preferences › AI Tools, in the app that opened this window.
    private func openPreferences() {
        guard !isSyntheticPreview else { return }
        Task { _ = await WorkspacePreferencesRouter.shared.open(.sources, bundleURL: Bundle.main.bundleURL) }
    }
}
